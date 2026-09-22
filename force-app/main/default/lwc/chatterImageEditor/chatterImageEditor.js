/**
 * chatterImageEditor
 *
 * Flow screen rich text editor that lets users paste screenshots and have
 * them post inline to the native Chatter feed.
 *
 * The trick: Salesforce's lightning-input-rich-text intercepts pasted
 * images and uploads them as legacy Rich Text Area images with
 * /servlet/rtaImage?refid=... URLs. Those can't be referenced as ConnectApi
 * inline image segments. So we catch the paste at document-level capture
 * phase BEFORE Salesforce's handler runs, upload the image ourselves as a
 * real ContentVersion, and insert an <img src="/sfc/servlet.shepherd/document/download/069...">
 * tag into the editor value. The companion ChatterInlineImagePoster Apex
 * then parses those 069 Ids back out and builds real inline image segments.
 *
 * Supports @mentions the same way native Chatter does: typing "@" opens a
 * live typeahead dropdown of matching users (see the "Mention typeahead"
 * section below) that inserts <a href="/{recordId}">@Name</a> anchors,
 * which the poster turns into ConnectApi MentionSegments.
 *
 * Part of the chatter-inline-images sharing package.
 * https://github.com/neilcorp2kx/salesforce-ChatterInlineImages
 */
import { LightningElement, api } from 'lwc';
import { FlowAttributeChangeEvent } from 'lightning/flowSupport';
import uploadImage from '@salesforce/apex/ChatterInlineImagesController.uploadImage';
import searchMentionableUsers from '@salesforce/apex/ChatterInlineImagesController.searchMentionableUsers';

// 'font', 'size', 'header', 'color', and 'background' are deliberately
// excluded: ConnectApi.MarkupType (the enum ChatterInlineImagePoster.cls
// uses to carry formatting into the native Chatter feed) has no member for
// any of them — confirmed against the live enum (Bold, Code, Hyperlink,
// Italic, ListItem, OrderedList, Paragraph, Strikethrough, Underline,
// UnorderedList only). Offering those toolbar buttons let users apply
// formatting that then silently vanished on post, since there's no segment
// type that can carry it.
const DEFAULT_FORMATS = [
    'bold', 'italic', 'underline', 'strike',
    'list', 'indent', 'align', 'link', 'image', 'clean',
    'code', 'code-block'
];

const BASIC_FORMATS = [
    'bold', 'italic', 'underline', 'list', 'link'
];

const VISIBILITY_OPTIONS = [
    { label: 'Internal Users Only', value: 'InternalUsers' },
    { label: 'All with Access',     value: 'AllUsers' }
];

const MENTION_SEARCH_DEBOUNCE_MS = 250;

export default class ChatterImageEditor extends LightningElement {

    // ── Flow inputs ──────────────────────────────────────────────────────
    @api recordId;
    @api label = 'Comment';
    @api placeholder = 'Type your comment here. Paste screenshots directly with Ctrl+V...';
    @api required = false;
    @api disableAdvancedTools = false;
    @api hideVisibilitySelector = false;
    @api disableMentions = false;
    // Deprecated: replaced by disableMentions when the old Mention button
    // was removed in favor of @mention typeahead. Kept only because an
    // existing flow version ('Chatter Inline Image Post-1') still sets a
    // value into it — the platform won't let us delete a property that's
    // referenced by a deployed flow. Intentionally unused.
    @api hideMentionButton = false;
    @api defaultVisibility = 'InternalUsers';
    @api initialEditorHeight = 150;
    @api minEditorHeight = 150;
    @api maxEditorHeight = 900;

    // ── Flow input/output (bidirectional) ────────────────────────────────
    @api richTextValue = '';
    @api selectedVisibility;

    // ── Internal state ───────────────────────────────────────────────────
    isUploading = false;
    uploadError;
    mentionQuery = null;
    mentionCandidates = [];
    mentionDropdownTop = 40;
    mentionDropdownLeft = 12;
    mentionDropdownMaxHeight = 224;
    _visibilityValue;
    _pasteHandler;
    _inputHandler;
    _hasFocus = false;
    _pasteCounter = 0;
    _mentionMarker = null;
    _mentionCounter = 0;
    _mentionSearchTimeout;

    // ── Resize state ─────────────────────────────────────────────────────
    editorHeight;
    _resizeStartY = 0;
    _resizeStartHeight = 0;
    _resizeMoveHandler;
    _resizeUpHandler;

    // The toolbar (two rows: font/size/color/basic formatting, then
    // link/image/clear-format) paints below the editable area but isn't
    // counted in lightning-input-rich-text's own layout box, so our wrapper
    // needs extra headroom reserved or the toolbar visually overlaps
    // whatever comes next in the DOM (the visibility selector, mention
    // dropdown, etc.) instead of pushing it down.
    static TOOLBAR_ALLOWANCE = 92;

    // Estimates of the editable area's internal padding, used by the
    // mention-dropdown caret mirror below — we don't have the real value
    // (it's inside the sealed shadow root), so these are tuned constants.
    static MIRROR_HORIZONTAL_PADDING_PX = 24;
    static MIRROR_TOP_PADDING_PX = 17;
    static MIRROR_LEFT_PADDING_PX = 12;
    // Multiplied by font-size to get the mirror's per-line height. This is
    // the one constant that compounds — being off by even 1-2px multiplies
    // by the number of lines typed before the mention, so it's the first
    // thing to retune if the dropdown drifts more on longer comments than
    // short ones. 1.5 matches SLDS's standard body-text line-height ratio.
    static MENTION_LINE_HEIGHT_RATIO = 1.5;

    connectedCallback() {
        this.editorHeight = this.initialEditorHeight || this.minEditorHeight || 150;

        this._visibilityValue =
            this.selectedVisibility || this.defaultVisibility || 'InternalUsers';
        this.dispatchEvent(
            new FlowAttributeChangeEvent('selectedVisibility', this._visibilityValue)
        );

        // focusin/focusout are composed events that cross shadow root
        // boundaries, so they reach our host element. We use this flag in
        // the document-level paste handler to decide whether a paste
        // targets our editor — Lightning Web Security retargets composed
        // event paths at the outermost shadow root, so we can't inspect
        // the paste event's target directly.
        this.addEventListener('focusin', () => { this._hasFocus = true; });
        this.addEventListener('focusout', () => { this._hasFocus = false; });

        // Document-level paste listener in CAPTURE phase runs top-down
        // before lightning-input-rich-text's handler, so we intercept the
        // image before Salesforce converts it to a /servlet/rtaImage URL.
        this._pasteHandler = (event) => this._onDocumentPaste(event);
        document.addEventListener('paste', this._pasteHandler, true);

        // Document-level 'input' listener (composed, crosses the shadow
        // boundary) drives the @mention typeahead — see "Mention typeahead"
        // below for why this is the only viable way to observe keystrokes
        // inside lightning-input-rich-text's sealed editable surface.
        if (!this.disableMentions) {
            this._inputHandler = (event) => this._onDocumentInput(event);
            document.addEventListener('input', this._inputHandler, true);
        }
    }

    disconnectedCallback() {
        if (this._pasteHandler) {
            document.removeEventListener('paste', this._pasteHandler, true);
            this._pasteHandler = null;
        }
        if (this._inputHandler) {
            document.removeEventListener('input', this._inputHandler, true);
            this._inputHandler = null;
        }
        this._teardownResizeListeners();
    }

    renderedCallback() {
        this._applyEditorHeight();
    }

    /**
     * lightning-input-rich-text's editable surface lives inside its own
     * (real, encapsulated) shadow root, so a plain querySelector from out
     * here can never reach it — that approach silently found nothing and
     * did nothing. CSS custom properties are the one thing guaranteed to
     * cross a shadow boundary (that's the whole point of SLDS styling
     * hooks), so we set height/min-height directly on the custom element
     * (which always affects its own box, hook or no hook) AND set both
     * known textarea-sizing hook names, so whichever one this component's
     * internal template actually reads picks up the new size.
     */
    _applyEditorHeight() {
        const richText = this.template.querySelector('lightning-input-rich-text');
        if (!richText) return;
        const px = `${this.editorHeight}px`;
        // min-height only, never a hard height: a fixed height fights the
        // component's own auto-grow when content needs more room than the
        // dragged size (e.g. a pasted image), which is what caused the
        // toolbar to jump around after a paste.
        richText.style.setProperty('min-height', px);
        richText.style.setProperty('--slds-c-textarea-sizing-min-height', px);
        richText.style.setProperty('--sds-c-textarea-sizing-min-height', px);

        // Force our own wrapper to reserve room for the editable area plus
        // the toolbar, rather than trusting lightning-input-rich-text's own
        // layout box (which doesn't grow to match its painted content).
        const wrapper = this.template.querySelector('.publisher-editor');
        if (wrapper) {
            wrapper.style.minHeight =
                `${this.editorHeight + ChatterImageEditor.TOOLBAR_ALLOWANCE}px`;
        }
    }

    get showVisibilitySelector() {
        return !this.hideVisibilitySelector;
    }

    get showMentionDropdown() {
        return this.mentionCandidates && this.mentionCandidates.length > 0;
    }

    get mentionDropdownStyle() {
        return `top: ${this.mentionDropdownTop}px; left: ${this.mentionDropdownLeft}px; `
            + `max-height: ${this.mentionDropdownMaxHeight}px;`;
    }

    get currentVisibility() {
        return this._visibilityValue || this.defaultVisibility || 'InternalUsers';
    }

    get formats() {
        return this.disableAdvancedTools ? BASIC_FORMATS : DEFAULT_FORMATS;
    }

    get visibilityOptions() {
        return VISIBILITY_OPTIONS;
    }

    // ── Event handlers ───────────────────────────────────────────────────

    // Drag-to-resize on the bottom-right handle, same interaction as a
    // native <textarea style="resize"> or the classic email compose window.
    handleResizeMouseDown(event) {
        event.preventDefault();
        this._resizeStartY = event.clientY;
        this._resizeStartHeight = this.editorHeight;
        this._resizeMoveHandler = (e) => this._onResizeMouseMove(e);
        this._resizeUpHandler = () => this._teardownResizeListeners();
        document.addEventListener('mousemove', this._resizeMoveHandler);
        document.addEventListener('mouseup', this._resizeUpHandler);
    }

    _onResizeMouseMove(event) {
        const min = this.minEditorHeight || 150;
        const max = this.maxEditorHeight || 900;
        const delta = event.clientY - this._resizeStartY;
        const next = this._resizeStartHeight + delta;
        this.editorHeight = Math.min(max, Math.max(min, next));
        // editorHeight isn't template-bound, so drive the DOM update
        // directly rather than waiting on a rerender that won't happen.
        this._applyEditorHeight();
    }

    _teardownResizeListeners() {
        if (this._resizeMoveHandler) {
            document.removeEventListener('mousemove', this._resizeMoveHandler);
            this._resizeMoveHandler = null;
        }
        if (this._resizeUpHandler) {
            document.removeEventListener('mouseup', this._resizeUpHandler);
            this._resizeUpHandler = null;
        }
    }

    handleRichTextChange(event) {
        const newValue = event.target.value;
        this.richTextValue = newValue;
        this.dispatchEvent(new FlowAttributeChangeEvent('richTextValue', newValue));

        // Backstop: our own 'input'-based tracking (_resyncMentionQueryFromContent)
        // can miss edge cases — rapid/compound deletions, select-all-then-delete,
        // undo, etc. — and leave mention mode (and the dropdown) stuck open even
        // though the marker's actually gone. lightning-input-rich-text's onchange
        // is the authoritative settled value regardless of how it got there, so
        // use it to force an exit whenever the marker's missing from it.
        if (this._mentionMarker && newValue.indexOf(this._mentionMarker) === -1) {
            this._exitMentionCapture(false);
        }
    }

    handleVisibilityChange(event) {
        this._visibilityValue = event.detail.value;
        this.dispatchEvent(new FlowAttributeChangeEvent('selectedVisibility', this._visibilityValue));
    }

    // ── Mention typeahead ────────────────────────────────────────────────
    //
    // Native Chatter lets you type "@name" and pick from a live dropdown.
    // lightning-input-rich-text's editable surface is sealed inside its own
    // shadow root (confirmed while building the resize feature — a plain
    // querySelector into it finds nothing), so we can't read the caret's
    // surrounding text or its on-screen position from out here. What DOES
    // cross that boundary is the 'input' event (it's composed, like focus
    // events), and specifically InputEvent.data — a plain string property
    // on the event object itself, not a DOM reference, so shadow retargeting
    // doesn't touch it. That's enough to reconstruct what's been typed
    // since "@" without ever touching the sealed DOM.
    //
    // The moment "@" is typed we drop an invisible zero-width marker right
    // after it via execCommand — focus is still guaranteed to be in the
    // editor at that instant, since this runs synchronously off the user's
    // own keystroke (the same trick _insertCaretMarker uses for pasted
    // images). Every keystroke after that just updates our own mentionQuery
    // buffer; we don't touch the DOM again until the user either bails
    // (space, backspace back to "@") or picks a candidate, at which point
    // we locate the marker in the current HTML string and do a plain
    // string replace — no live selection needed for that part.

    _onDocumentInput(event) {
        if (!this._hasFocus) return;

        if (this._mentionMarker) {
            this._handleMentionModeInput(event);
            return;
        }

        if (event.data === '@') {
            this._beginMentionCapture();
        }
    }

    _beginMentionCapture() {
        const marker = this._insertMentionMarker();
        if (!marker) return;
        this._mentionMarker = marker;
        this.mentionQuery = '';
        this.mentionCandidates = [];

        // Don't measure position synchronously here: editor.value is a
        // reactive getter reflecting Quill's OWN internal change-tracking,
        // which lags one tick behind a raw DOM mutation from execCommand —
        // reading it immediately after inserting the marker can return a
        // stale snapshot that doesn't contain it yet. When that happens,
        // _updateMentionDropdownPosition's "marker not found" fallback
        // treats the WHOLE existing document as "before the cursor",
        // which is exactly what put the dropdown near the bottom of a
        // comment that had lines below (not before) the cursor. A
        // microtask is enough to let that catch up.
        Promise.resolve().then(() => this._updateMentionDropdownPosition(marker));

        this._searchMentions('');
    }

    /**
     * Estimates where the dropdown should float, since we can't read the
     * real caret position (lightning-input-rich-text's shadow root isn't
     * reachable — see the "Mention typeahead" notes above). This is the
     * classic "mirror div" caret-estimation trick: we can't measure the
     * real editable surface, but we CAN build our own hidden clone with
     * the same width/font and feed it the same text, then let the browser's
     * own layout engine do the line-wrapping math for us — that's the part
     * naive line-counting couldn't handle. We measure a marker span glued
     * to the end of the mirrored text to read where that text would end.
     *
     * Two numbers remain pure estimates rather than measurements: the
     * editable area's internal padding (we don't have the real value, so
     * MIRROR_*_PADDING_PX are tuned constants) and the "next line" gap we
     * add so the dropdown appears below the cursor's line rather than on
     * top of it. Both are easy to retune from visual feedback since
     * everything else here is now real layout, not guesswork.
     */
    _updateMentionDropdownPosition(marker) {
        // Guard against a stale deferred call: mode may have already been
        // exited, or moved on to a different marker, by the time this
        // microtask runs.
        if (this._mentionMarker !== marker) return;

        const richText = this.template.querySelector('lightning-input-rich-text');
        const mirror = this.template.querySelector('.mention-caret-mirror');
        if (!richText || !mirror) {
            this.mentionDropdownTop = 40;
            this.mentionDropdownLeft = 12;
            this.mentionDropdownMaxHeight = 224;
            return;
        }

        const current = this._currentValue(marker);
        // lastIndexOf, not indexOf: an old, never-cleaned-up marker from an
        // earlier session (invisible zero-width characters, easy to miss)
        // can still be sitting earlier in the content. The marker we just
        // inserted is always the most recent occurrence, so searching from
        // the end is what actually finds it — indexOf here previously
        // anchored the whole position calculation on stale leftover
        // residue instead, which is why the dropdown could end up
        // measuring against content near the end of a long comment.
        const markerIdx = current.lastIndexOf(marker);
        const beforeHtml = markerIdx >= 0 ? current.substring(0, markerIdx) : current;
        const beforeText = this._htmlToPlainTextPreservingBreaks(beforeHtml);

        const hostRect = richText.getBoundingClientRect();
        const style = window.getComputedStyle(richText);
        const fontSize = parseFloat(style.fontSize) || 13;
        // getComputedStyle(richText).lineHeight reflects what the HOST
        // element would use if it rendered text itself — not what Quill's
        // internal stylesheet actually applies deep in the shadow
        // template, which is almost certainly unrelated. Using it produced
        // a per-line error that compounded with every line (fine for a
        // few lines, increasingly overlapping further down), so this is a
        // flat calibrated ratio instead — tune MENTION_LINE_HEIGHT_RATIO
        // directly from observed drift rather than trusting that read.
        const lineHeight = fontSize * ChatterImageEditor.MENTION_LINE_HEIGHT_RATIO;

        mirror.style.width = `${Math.max(50, hostRect.width - ChatterImageEditor.MIRROR_HORIZONTAL_PADDING_PX)}px`;
        mirror.style.fontSize = `${fontSize}px`;
        mirror.style.lineHeight = `${lineHeight}px`;
        mirror.style.fontFamily = style.fontFamily;

        // Rebuild the mirror's content: the text typed so far, plus a
        // zero-width marker span glued to the very end — its position
        // after layout tells us where the real caret would be.
        mirror.textContent = '';
        mirror.appendChild(document.createTextNode(beforeText));
        const caretMarker = document.createElement('span');
        caretMarker.textContent = '​';
        mirror.appendChild(caretMarker);

        const mirrorRect = mirror.getBoundingClientRect();
        const caretRect = caretMarker.getBoundingClientRect();
        // caretRect.bottom is the actual rendered bottom edge of the
        // marker's own line box — using it directly (rather than re-adding
        // our separately-estimated lineHeight to caretRect.top) avoids
        // compounding two independent estimates into one error.
        const relativeBottom = caretRect.bottom - mirrorRect.top;
        const relativeLeft = caretRect.left - mirrorRect.left;

        const rawTop = relativeBottom + ChatterImageEditor.MIRROR_TOP_PADDING_PX;
        const rawLeft = relativeLeft + ChatterImageEditor.MIRROR_LEFT_PADDING_PX;

        // Clamp to the editable area's own rendered height, not an
        // unbounded upper limit: the earlier "no clamp" approach assumed
        // .publisher-editor not clipping its children meant an
        // over-the-bottom dropdown was harmless, but it missed that the
        // editor itself scrolls internally once content exceeds its
        // current height (min-height reached, or the user dragged it to
        // maxEditorHeight) — the mirror keeps growing with every line
        // regardless, so rawTop can land far below content that's
        // actually been scrolled out of view. hostRect.height reflects
        // whatever height is in effect right now (initial, resized, or
        // auto-grown), so clamping against it tracks the resize live
        // instead of baking in a fixed pixel ceiling.
        const maxTop = Math.max(0, hostRect.height - ChatterImageEditor.MIRROR_TOP_PADDING_PX - 35);
        this.mentionDropdownTop = Math.min(Math.round(rawTop), maxTop);

        const maxLeft = Math.max(12, hostRect.width - 60);
        this.mentionDropdownLeft = Math.min(Math.max(12, Math.round(rawLeft)), maxLeft);
    }

    /**
     * Mirrors stripHtmlToPlainText's block-break handling (Apex side), but
     * keeps the breaks as real '\n' characters instead of counting them —
     * the mirror div (white-space: pre-wrap) renders '\n' as an actual line
     * break, same as the browser would in the real editor.
     */
    _htmlToPlainTextPreservingBreaks(html) {
        if (!html) return '';
        let text = html;
        // Quill represents an empty line as e.g. <p><br></p> — collapse the
        // <br> into that block's own closing-tag newline instead of adding
        // a second one, or every blank line ends up double height in the
        // mirror (which is what pushed the dropdown a full extra line too
        // low whenever a blank line preceded the "@").
        text = text.replace(/<br\s*\/?>\s*(<\/(?:p|div|li|h[1-6])>)/gi, '$1');
        text = text.replace(/<br\s*\/?>/gi, '\n');
        text = text.replace(/<\/(p|div|li|h[1-6])>/gi, '\n');
        text = text.replace(/<[^>]+>/g, '');
        text = text
            .replace(/&nbsp;/g, ' ')
            .replace(/&amp;/g, '&')
            .replace(/&lt;/g, '<')
            .replace(/&gt;/g, '>')
            .replace(/&quot;/g, '"')
            .replace(/&#39;/g, '\'');
        // The block-break regex above adds a trailing '\n' for the block
        // the marker itself sits in — drop it so the marker isn't measured
        // one line lower than the text actually ends.
        return text.replace(/\n$/, '');
    }

    _handleMentionModeInput(event) {
        // A plain typed space (or similar whitespace) always ends the
        // mention attempt outright, same as native Chatter, regardless of
        // what resyncing below would otherwise compute.
        if (typeof event.data === 'string' && /\s/.test(event.data)) {
            this._exitMentionCapture();
            return;
        }

        this._resyncMentionQueryFromContent();
    }

    /**
     * Re-derives mentionQuery from the live editor content instead of
     * patching it by an assumed delta (e.g. "one backspace removes one
     * character"). That assumption broke for anything that changes more
     * than one character in a single 'input' event — word-delete
     * (Ctrl+Backspace), selecting "@chris" and pressing Delete once, cut,
     * undo — leaving mentionQuery stale and the dropdown stuck open even
     * though the "@" was already gone from the actual text. Recomputing
     * from ground truth on every keystroke sidesteps the whole class of
     * bug rather than chasing each input method individually.
     */
    _resyncMentionQueryFromContent() {
        const marker = this._mentionMarker;
        if (!marker) return;

        const current = this._currentValue(marker);
        const plain = this._htmlToPlainTextPreservingBreaks(current);
        const markerIdx = plain.lastIndexOf(marker);

        if (markerIdx === -1) {
            // Marker's gone — whatever removed/mangled it took the
            // in-progress mention with it.
            this._exitMentionCapture(false);
            return;
        }

        const before = plain.substring(0, markerIdx);
        if (!before.endsWith('@')) {
            // The "@" that started this mention no longer precedes the
            // marker (deleted along with it in one action, or the marker
            // drifted for some other reason) — nothing left to anchor on.
            this._exitMentionCapture();
            return;
        }

        const after = plain.substring(markerIdx + marker.length);
        const match = after.match(/^\S*/);
        const query = match ? match[0] : '';

        this.mentionQuery = query;
        this._searchMentions(query);
    }

    _searchMentions(query) {
        if (this._mentionSearchTimeout) {
            clearTimeout(this._mentionSearchTimeout);
        }
        this._mentionSearchTimeout = setTimeout(() => {
            this._runMentionSearch(query);
        }, MENTION_SEARCH_DEBOUNCE_MS);
    }

    async _runMentionSearch(query) {
        try {
            const results = await searchMentionableUsers({ searchTerm: query });
            // Mode may have already been exited (or moved on to a longer
            // query) while this call was in flight — don't resurrect a
            // dropdown for a mention attempt that's no longer active.
            if (this._mentionMarker) {
                this.mentionCandidates = results || [];
            }
        } catch (err) {
            this.mentionCandidates = [];
        }
    }

    handleMentionCandidateSelect(event) {
        const recordId = event.currentTarget.dataset.id;
        const name = event.currentTarget.dataset.name;
        const marker = this._mentionMarker;
        const query = this.mentionQuery || '';

        if (!marker || !recordId) {
            this._exitMentionCapture();
            return;
        }

        const current = this._currentValue(marker);
        const markerIdx = current.lastIndexOf(marker);
        if (markerIdx === -1) {
            this._exitMentionCapture(false);
            return;
        }

        // Remove the "@", the marker, and the typed query text, replacing
        // all of it with the mention anchor. Quill preserves <a href=...>
        // unchanged, so the Id survives the round-trip through the editor;
        // the invocable action regex-parses it back out to build a
        // MentionSegmentInput.
        let before = current.substring(0, markerIdx);
        if (before.endsWith('@')) {
            before = before.slice(0, -1);
        }
        const after = current.substring(markerIdx + marker.length + query.length);
        const mentionHtml = `&nbsp;<a href="/${recordId}">@${name}</a>&nbsp;`;
        const updated = before + mentionHtml + after;

        this.richTextValue = updated;
        this.dispatchEvent(new FlowAttributeChangeEvent('richTextValue', updated));
        this._exitMentionCapture(false);
    }

    /**
     * Ends mention capture. By default also strips the leftover invisible
     * marker out of the content (space/backspace exits leave "@query" as
     * plain text but shouldn't leave marker junk buried in it); pass false
     * when the caller has already folded the marker into a replacement
     * (a successful mention pick).
     */
    _exitMentionCapture(stripMarker = true) {
        if (stripMarker && this._mentionMarker) {
            this._stripMarker(this._mentionMarker);
        }
        if (this._mentionSearchTimeout) {
            clearTimeout(this._mentionSearchTimeout);
            this._mentionSearchTimeout = null;
        }
        this._mentionMarker = null;
        this.mentionQuery = null;
        this.mentionCandidates = [];
    }

    /**
     * Same zero-width-marker trick as _insertCaretMarker, but with a
     * structurally different wrapper character (ZWNJ vs. word joiner) so a
     * mention marker can never collide with a same-numbered image-paste
     * marker if both are live at once.
     */
    _insertMentionMarker() {
        const zwsp = String.fromCharCode(0x200B);
        const zwnj = String.fromCharCode(0x200C);
        const marker = zwnj + zwsp.repeat(++this._mentionCounter) + zwnj;
        try {
            if (document.execCommand('insertText', false, marker)) {
                return marker;
            }
        } catch (e) {
            // Editor refused the marker — no mention dropdown this time.
        }
        return null;
    }

    async _onDocumentPaste(event) {
        if (!this._hasFocus) {
            return;
        }

        const clipboardData = event.clipboardData;
        if (!clipboardData || !clipboardData.items) {
            return;
        }

        let imageFile = null;
        for (let i = 0; i < clipboardData.items.length; i++) {
            const item = clipboardData.items[i];
            if (item.type && item.type.startsWith('image/')) {
                imageFile = item.getAsFile();
                break;
            }
        }

        if (!imageFile) {
            return;
        }

        // Block Salesforce's rta-image handler from running after us
        event.preventDefault();
        event.stopPropagation();
        if (event.stopImmediatePropagation) {
            event.stopImmediatePropagation();
        }

        // Drop a caret marker synchronously, while the editor still has
        // focus and the selection is exactly where the user pasted. The
        // upload is async, so by the time it resolves the caret is long
        // gone — this marker is the only record of where the image belongs.
        const marker = this._insertCaretMarker();

        await this._uploadAndInsertFile(imageFile, marker);
    }

    /**
     * Inserts a zero-width marker at the caret and returns it, or null if
     * the editor refused it. Each paste gets its own marker (widened by the
     * paste counter) so two images pasted in quick succession can't land in
     * each other's slot when the uploads resolve out of order.
     */
    _insertCaretMarker() {
        const zwsp = String.fromCharCode(0x200B);
        const wordJoiner = String.fromCharCode(0x2060);
        const marker = wordJoiner + zwsp.repeat(++this._pasteCounter) + wordJoiner;
        try {
            // preventDefault above kept focus in the editor, so execCommand
            // operates on Quill's live selection.
            if (document.execCommand('insertText', false, marker)) {
                return marker;
            }
        } catch (e) {
            // Editor refused the marker — we'll fall back to appending.
        }
        return null;
    }

    async _uploadAndInsertFile(file, marker) {
        if (!this.recordId) {
            this.uploadError = 'Cannot upload image: parent record Id not available in flow context.';
            return;
        }

        this.isUploading = true;
        this.uploadError = undefined;

        try {
            const base64 = await this._blobToBase64(file);
            const extension = this._extensionForMime(file.type);
            const fileName = file.name && file.name.length > 0
                ? file.name
                : `image-${this._timestampForFileName()}-${this._pasteCounter}.${extension}`;

            const result = await uploadImage({
                parentId: this.recordId,
                fileName: fileName,
                base64Data: base64
            });

            // Swap the caret marker for the img tag so the image lands where
            // the user actually pasted. We can't let Quill insert it at the
            // cursor itself — we blocked its paste handler, so it never
            // learns about the image and just re-renders from the value we
            // hand back. With no marker we fall back to appending.
            const imgTag = `<img src="${result.downloadUrl}" alt="${fileName}" />`;
            const current = this._currentValue(marker);
            const updated = (marker && current.indexOf(marker) >= 0)
                ? current.split(marker).join(imgTag)
                : current + imgTag;

            this.richTextValue = updated;
            this.dispatchEvent(new FlowAttributeChangeEvent('richTextValue', updated));
        } catch (err) {
            // eslint-disable-next-line no-console
            console.error('[chatterImageEditor] upload failed', err);
            this.uploadError = 'Failed to upload image: ' + this._reduceError(err);
            this._stripMarker(marker);
        } finally {
            this.isUploading = false;
        }
    }

    /**
     * Newest editor content. Quill's change event may not have propagated
     * into richTextValue yet when a fast upload returns, so prefer the live
     * editor value whenever it still carries our marker.
     */
    _currentValue(marker) {
        const editor = this.template.querySelector('lightning-input-rich-text');
        const live = editor ? editor.value : undefined;
        if (typeof live === 'string' && (!marker || live.indexOf(marker) >= 0)) {
            return live;
        }
        return this.richTextValue || '';
    }

    _stripMarker(marker) {
        if (!marker) return;
        const current = this._currentValue(marker);
        if (current.indexOf(marker) < 0) return;
        const cleaned = current.split(marker).join('');
        this.richTextValue = cleaned;
        this.dispatchEvent(new FlowAttributeChangeEvent('richTextValue', cleaned));
    }

    // ── Helpers ──────────────────────────────────────────────────────────

    _blobToBase64(blob) {
        return new Promise((resolve, reject) => {
            const reader = new FileReader();
            reader.onload = () => {
                const result = reader.result || '';
                const comma = result.indexOf(',');
                resolve(comma >= 0 ? result.substring(comma + 1) : result);
            };
            reader.onerror = reject;
            reader.readAsDataURL(blob);
        });
    }

    _extensionForMime(mimeType) {
        if (!mimeType) return 'png';
        const lower = mimeType.toLowerCase();
        if (lower.indexOf('jpeg') >= 0 || lower.indexOf('jpg') >= 0) return 'jpg';
        if (lower.indexOf('gif') >= 0) return 'gif';
        if (lower.indexOf('webp') >= 0) return 'webp';
        if (lower.indexOf('svg') >= 0) return 'svg';
        return 'png';
    }

    _timestampForFileName() {
        const d = new Date();
        const pad = (n) => String(n).padStart(2, '0');
        return d.getFullYear()
            + pad(d.getMonth() + 1)
            + pad(d.getDate())
            + '-'
            + pad(d.getHours())
            + pad(d.getMinutes())
            + pad(d.getSeconds());
    }

    _reduceError(error) {
        if (error?.body?.message) return error.body.message;
        if (error?.message) return error.message;
        return 'Unknown error';
    }

    // ── Flow validation hook ─────────────────────────────────────────────

    @api
    validate() {
        if (this.isUploading) {
            return {
                isValid: false,
                errorMessage: 'Please wait — image is still uploading.'
            };
        }

        if (this.required) {
            const val = (this.richTextValue || '').trim();
            if (!val || val === '<p><br></p>') {
                return {
                    isValid: false,
                    errorMessage: (this.label || 'Comment') + ' is required.'
                };
            }
        }

        return { isValid: true };
    }
}