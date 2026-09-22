/**
 * @description Invocable action that posts a Chatter FeedItem with native
 *              inline images (and optional @mentions) via ConnectApi. Parses
 *              rich text HTML from the chatterImageEditor LWC and emits
 *              alternating text + inline image + mention message segments
 *              in document order so the resulting feed item renders inline
 *              in the native Chatter feed — something the standard
 *              FeedItem.Body text field cannot do on its own.
 *
 *              Why this exists: Salesforce's lightning-input-rich-text
 *              intercepts pasted images and uploads them as legacy Rich Text
 *              Area images with /servlet/rtaImage?refid=... URLs. Those
 *              cannot be referenced by ConnectApi as inline image segments
 *              — only real ContentDocumentIds (069... key prefix) can. The
 *              companion LWC defeats the rta-image interception by catching
 *              paste events at document-level capture phase BEFORE
 *              lightning-input-rich-text sees them, uploading the image as
 *              a real ContentVersion, and inserting an <img src="...069..."
 *              tag into the editor value. This Apex class then parses those
 *              src URLs to build InlineImageSegmentInput objects.
 *
 *              For @mentions, the LWC inserts <a href="/005..."> anchors
 *              (using 005 for User or 0F9 for CollaborationGroup). This
 *              class emits MentionSegmentInput for each one.
 *
 *              Rich text formatting (bold, italic, underline, strikethrough,
 *              inline code / code blocks, ordered/unordered lists, and
 *              hyperlinks) is preserved by translating the corresponding
 *              Quill HTML tags (<b>/<strong>, <i>/<em>, <u>, <s>/<strike>,
 *              <code>/<pre>, <ol>/<ul>/<li>, <a href="...">) into paired
 *              ConnectApi.MarkupBeginSegmentInput/MarkupEndSegmentInput
 *              segments — the same mechanism Salesforce's own
 *              ConnectApiHelper uses. A hyperlink's Begin segment carries the
 *              URL directly (only http(s):// and mailto: are accepted —
 *              anything else is dropped as a link but its visible text is
 *              kept, since the URL comes from user-authored content). There
 *              is no ConnectApi markup type for font color/background or
 *              headers, so those are still flattened to plain text.
 *
 *              Part of the chatter-inline-images sharing package.
 *              https://github.com/neilcorp2kx/salesforce-ChatterInlineImages
 */
public with sharing class ChatterInlineImagePoster {

    // Combined pattern: matches an <img> tag (inline images), an
    // <a href="/{id}"> mention anchor (user/group mentions), or an opening/
    // closing rich-text formatting tag, whichever comes first in the HTML.
    // Alternation lets us walk the HTML once in document order.
    //
    // Group 1: img src  (set when an img tag matched)
    // Group 2: mention record id from href  (set when an anchor tag matched)
    //          Accepts 005 (User) and 0F9 (CollaborationGroup) key prefixes.
    // Group 3: the full opening/closing formatting tag text, e.g. "<strong>"
    //          or "</li>" (set when a supported markup tag matched).
    // Group 4: a block/line break token — <br>, </p>, or </div> (set when a
    //          break-producing tag matched). See buildLineBreakSegments for
    //          why these become their own segments instead of a literal '\n'.
    // Group 5: an opening <a href="..."> tag whose href is NOT a mention
    //          (didn't match group 2's /005.../0F9... pattern) — a regular
    //          hyperlink. Captures the raw (still entity-encoded) href.
    // Group 6: a closing </a> tag pairing with group 5.
    // Group 7: a whole blank-line block — <p><br></p> or <div><br></div> —
    //          matched as ONE unit rather than being decomposed into
    //          separate <br> and </p>/</div> break tokens. See
    //          buildBlankLineSegments for why a deliberate blank line needs
    //          different handling than an ordinary paragraph break.
    //
    // Order matters here: the mention-anchor alternative (group 2, which
    // matches the FULL <a ...>text</a> as one unit) is tried before the
    // generic opening-tag alternative (group 5). Regex alternation tries
    // branches left-to-right and takes the first that matches at the
    // current position, so a mention href is always claimed by group 2
    // first; group 5 only ever fires once group 2 has already failed
    // (a non-mention href), leaving the tag's closing </a> for group 6.
    // Group 7 doesn't need similar ordering care: find() always prefers
    // the leftmost match across ALL alternatives, and <p>/<div> opening
    // tags aren't matched by anything else, so group 7 (anchored on that
    // opening tag) is naturally found before the <br>/</p> it contains
    // could be matched on their own by group 4.
    private static final Pattern MARKER_PATTERN = Pattern.compile(
        '(?is)' +
        '<img[^>]*\\bsrc\\s*=\\s*["\\\']([^"\\\']+)["\\\'][^>]*/?\\s*>' +
        '|' +
        '<a[^>]*\\bhref\\s*=\\s*["\\\']/(0(?:05|F9)[a-zA-Z0-9]{12,15})["\\\'][^>]*>[^<]*</a>' +
        '|' +
        '(</?(?:b|strong|i|em|u|s|strike|code|pre|ol|ul|li)\\b[^>]*>)' +
        '|' +
        '(<br\\s*/?\\s*>|</p\\s*>|</div\\s*>)' +
        '|' +
        '<a[^>]*\\bhref\\s*=\\s*["\\\']([^"\\\']+)["\\\'][^>]*>' +
        '|' +
        '(</a\\s*>)' +
        '|' +
        '(<(?:p|div)\\b[^>]*>\\s*<br\\s*/?\\s*>\\s*</(?:p|div)\\s*>)'
    );

    // Extract a 15- or 18-char ContentDocumentId (069 prefix) from an img src
    private static final Pattern CONTENT_DOC_ID_PATTERN = Pattern.compile(
        '(069[a-zA-Z0-9]{12}(?:[a-zA-Z0-9]{3})?)'
    );

    // Extracts the bare tag name from a matched markup tag, e.g. "strong"
    // from either "<strong>" or "</strong class=\"foo\">".
    private static final Pattern TAG_NAME_PATTERN = Pattern.compile('(?i)^</?([a-zA-Z]+)');

    // Maps Quill's HTML tags to the ConnectApi markup type that renders the
    // same formatting in the native Chatter feed. <b>/<strong> and <i>/<em>
    // both map to the same type since Quill (and hand-authored HTML) can
    // produce either. <code> (inline) and <pre> (code block) both map to
    // Code — ConnectApi has no separate block-code markup type.
    private static final Map<String, ConnectApi.MarkupType> MARKUP_TAG_TYPES =
        new Map<String, ConnectApi.MarkupType>{
            'b' => ConnectApi.MarkupType.Bold,
            'strong' => ConnectApi.MarkupType.Bold,
            'i' => ConnectApi.MarkupType.Italic,
            'em' => ConnectApi.MarkupType.Italic,
            'u' => ConnectApi.MarkupType.Underline,
            's' => ConnectApi.MarkupType.Strikethrough,
            'strike' => ConnectApi.MarkupType.Strikethrough,
            'code' => ConnectApi.MarkupType.Code,
            'pre' => ConnectApi.MarkupType.Code,
            'ol' => ConnectApi.MarkupType.OrderedList,
            'ul' => ConnectApi.MarkupType.UnorderedList,
            'li' => ConnectApi.MarkupType.ListItem
        };

    // Only these URL schemes are accepted for a hyperlink markup segment.
    // The href comes from user-authored rich text, so anything else
    // (javascript:, data:, etc.) is rejected outright rather than trusted.
    private static final Pattern SAFE_LINK_URL_PATTERN =
        Pattern.compile('(?i)^(https?://|mailto:).+');

    @InvocableMethod(
        label='Post Chatter FeedItem with Inline Images'
        description='Posts a Chatter FeedItem via ConnectApi with inline images and optional @mentions parsed from rich text HTML produced by the chatterImageEditor LWC.'
        category='Chatter'
    )
    public static List<Result> postFeedItems(List<Request> requests) {
        List<Result> results = new List<Result>();

        for (Request req : requests) {
            Result r = new Result();
            try {
                if (req.parentId == null) {
                    throw new IllegalArgumentException('parentId is required');
                }
                if (String.isBlank(req.richTextHtml)) {
                    throw new IllegalArgumentException('richTextHtml is required');
                }

                ConnectApi.FeedItemVisibilityType visibility = resolveVisibility(req.visibility);

                Set<Id> imageDocIds = new Set<Id>();
                List<ConnectApi.MessageSegmentInput> segments =
                    buildSegments(req.richTextHtml, imageDocIds);

                if (segments.isEmpty()) {
                    ConnectApi.TextSegmentInput empty = new ConnectApi.TextSegmentInput();
                    empty.text = '(no content)';
                    segments.add(empty);
                }

                updateContentDocumentLinkVisibility(imageDocIds, req.parentId, visibility);

                ConnectApi.FeedItemInput feedItemInput = new ConnectApi.FeedItemInput();
                feedItemInput.subjectId = req.parentId;
                feedItemInput.feedElementType = ConnectApi.FeedElementType.FeedItem;
                feedItemInput.visibility = visibility;

                ConnectApi.MessageBodyInput body = new ConnectApi.MessageBodyInput();
                body.messageSegments = segments;
                feedItemInput.body = body;

                ConnectApi.FeedElement posted =
                    ConnectApi.ChatterFeeds.postFeedElement(null, feedItemInput);

                r.success = true;
                r.postId = posted.id;
            } catch (Exception e) {
                r.success = false;
                r.errorMessage = e.getMessage();
            }
            results.add(r);
        }

        return results;
    }

    // ─── Segment Builder (testable in isolation) ─────────────────────────
    // Forward-walks the HTML emitting a text segment for each HTML chunk
    // between markers and the matching InlineImage / Mention segment for
    // each marker. Output is in document order.

    @TestVisible
    private static List<ConnectApi.MessageSegmentInput> buildSegments(
        String html, Set<Id> outContentDocumentIds
    ) {
        List<ConnectApi.MessageSegmentInput> segments = new List<ConnectApi.MessageSegmentInput>();
        if (String.isBlank(html)) return segments;

        Matcher m = MARKER_PATTERN.matcher(html);
        Integer lastEnd = 0;

        // Tracks how many hyperlink Begin segments are currently open and
        // still awaiting their matching </a>, so a stray or rejected-as-
        // unsafe closing tag can never emit an orphaned End(Hyperlink) with
        // no Begin — ConnectApi rejects the whole post if markup segments
        // aren't balanced.
        Integer openHyperlinks = 0;

        while (m.find()) {
            String imgSrc = m.group(1);
            String mentionRecordId = m.group(2);
            String markupTag = m.group(3);
            String breakToken = m.group(4);
            String linkHref = m.group(5);
            String linkClose = m.group(6);
            String blankLine = m.group(7);

            List<ConnectApi.MessageSegmentInput> markerSegments = new List<ConnectApi.MessageSegmentInput>();

            if (imgSrc != null) {
                Id docId = extractContentDocumentId(imgSrc);
                if (docId != null) {
                    if (outContentDocumentIds != null) {
                        outContentDocumentIds.add(docId);
                    }
                    ConnectApi.InlineImageSegmentInput imgSeg = new ConnectApi.InlineImageSegmentInput();
                    imgSeg.fileId = docId;
                    imgSeg.altText = 'Inline image';
                    markerSegments.add(imgSeg);
                }
            } else if (mentionRecordId != null) {
                try {
                    ConnectApi.MentionSegmentInput mentionSeg = new ConnectApi.MentionSegmentInput();
                    mentionSeg.id = Id.valueOf(mentionRecordId);
                    markerSegments.add(mentionSeg);
                } catch (Exception e) {
                    // Malformed id — fall through and keep the anchor's text as text
                }
            } else if (markupTag != null) {
                ConnectApi.MessageSegmentInput markupSeg = buildMarkupSegment(markupTag);
                if (markupSeg != null) {
                    markerSegments.add(markupSeg);
                }
            } else if (breakToken != null) {
                markerSegments.addAll(buildLineBreakSegments());
            } else if (blankLine != null) {
                markerSegments.addAll(buildBlankLineSegments());
            } else if (linkHref != null) {
                String url = decodeHtmlEntities(linkHref);
                if (isSafeLinkUrl(url)) {
                    ConnectApi.MarkupBeginSegmentInput beginSeg = new ConnectApi.MarkupBeginSegmentInput();
                    beginSeg.markupType = ConnectApi.MarkupType.Hyperlink;
                    beginSeg.url = url;
                    markerSegments.add(beginSeg);
                    openHyperlinks++;
                }
                // Unsafe scheme (javascript:, data:, etc.) — drop the link
                // entirely; the anchor's visible text still comes through
                // as plain text via the normal chunk-stripping below.
            } else if (linkClose != null && openHyperlinks > 0) {
                ConnectApi.MarkupEndSegmentInput endSeg = new ConnectApi.MarkupEndSegmentInput();
                endSeg.markupType = ConnectApi.MarkupType.Hyperlink;
                markerSegments.add(endSeg);
                openHyperlinks--;
            }

            if (markerSegments.isEmpty()) {
                continue;
            }

            String precedingHtml = html.substring(lastEnd, m.start());
            if (blankLine != null) {
                mergeImmediatelyPrecedingBareParagraphBreak(segments, precedingHtml);
            }

            appendTextSegment(segments, precedingHtml);
            segments.addAll(markerSegments);
            lastEnd = m.end();
        }

        appendTextSegment(segments, html.substring(lastEnd));
        stripTrailingLineBreaks(segments);
        return segments;
    }

    /**
     * A line/paragraph break as its own empty Paragraph markup segment pair,
     * rather than a literal '\n' character inside a text segment.
     *
     * Lightning's feed renderer only honors '\n' inside a TextSegment when
     * the ENTIRE body is a single text segment. As soon as the body contains
     * any other segment type (inline image, mention, or — since rich text
     * formatting was added — a markup segment), embedded '\n' characters are
     * rendered as if they weren't there, running every line together. An
     * empty Begin(Paragraph)/End(Paragraph) pair is ConnectApi's own
     * mechanism for representing a block break (it's what Salesforce's
     * ConnectApiHelper falls back to for embedded newlines), and — unlike a
     * literal '\n' — it renders correctly regardless of what other segment
     * types are present.
     */
    private static List<ConnectApi.MessageSegmentInput> buildLineBreakSegments() {
        ConnectApi.MarkupBeginSegmentInput beginSeg = new ConnectApi.MarkupBeginSegmentInput();
        beginSeg.markupType = ConnectApi.MarkupType.Paragraph;
        ConnectApi.MarkupEndSegmentInput endSeg = new ConnectApi.MarkupEndSegmentInput();
        endSeg.markupType = ConnectApi.MarkupType.Paragraph;
        return new List<ConnectApi.MessageSegmentInput>{ beginSeg, endSeg };
    }

    /**
     * A deliberate blank line (the user pressed Enter on an empty line —
     * Quill represents that as <p><br></p>) as a Paragraph pair with a
     * non-breaking space between Begin and End, rather than the bare empty
     * pair buildLineBreakSegments produces for an ordinary line break.
     *
     * An empty Paragraph pair has no content to hold its line height open,
     * so consecutive empty pairs collapse into each other in the feed's
     * renderer the same way adjacent empty HTML block elements' margins
     * collapse in any browser — several blank lines in a row visually
     * shrink to one. Giving the pair actual (invisible) content prevents
     * that collapse. This mirrors Salesforce's own ConnectApiHelper
     * reference implementation, which encodes a double newline as
     * "<p>&nbsp;</p>" specifically (as opposed to a bare "<p></p>" for a
     * single one).
     */
    private static List<ConnectApi.MessageSegmentInput> buildBlankLineSegments() {
        ConnectApi.MarkupBeginSegmentInput beginSeg = new ConnectApi.MarkupBeginSegmentInput();
        beginSeg.markupType = ConnectApi.MarkupType.Paragraph;
        ConnectApi.TextSegmentInput textSeg = new ConnectApi.TextSegmentInput();
        textSeg.text = ' ';
        ConnectApi.MarkupEndSegmentInput endSeg = new ConnectApi.MarkupEndSegmentInput();
        endSeg.markupType = ConnectApi.MarkupType.Paragraph;
        return new List<ConnectApi.MessageSegmentInput>{ beginSeg, textSeg, endSeg };
    }

    /**
     * When a blank-line token is immediately preceded by nothing but a bare
     * Paragraph break (i.e. the </p> that just closed the previous line of
     * real content, with no other content in between), that bare pair and
     * the blank line represent the SAME transition — not two stacked ones —
     * so the bare pair is removed here, leaving just the one nbsp-bearing
     * pair buildBlankLineSegments is about to add.
     *
     * Without this, "Test 1" + one blank line + "Test 2" would emit a bare
     * pair for Test 1's own closing tag AND a separate nbsp pair for the
     * blank line — two paragraph pairs for what should read as a single
     * blank-line gap. This mirrors how Salesforce's own ConnectApiHelper
     * reference implementation treats a double newline as one substitution
     * ("<p>&nbsp;</p>"), not an ordinary break followed by a blank one.
     */
    private static void mergeImmediatelyPrecedingBareParagraphBreak(
        List<ConnectApi.MessageSegmentInput> segments, String interveningHtml
    ) {
        if (String.isNotBlank(stripHtmlToPlainText(interveningHtml))) return;
        if (segments.size() < 2) return;
        if (isParagraphEnd(segments[segments.size() - 1]) && isParagraphBegin(segments[segments.size() - 2])) {
            segments.remove(segments.size() - 1);
            segments.remove(segments.size() - 1);
        }
    }

    /**
     * Drops break segments left dangling at the very end of the body — both
     * a bare empty Paragraph pair and a blank-line (nbsp) triple. Quill
     * wraps every line — including the last one — in its own <p>...</p>
     * (and a trailing blank line the user leaves in the editor becomes a
     * trailing <p><br></p>), so without this every post touching either
     * case would pick up trailing, content-free space from its final tag.
     */
    private static void stripTrailingLineBreaks(List<ConnectApi.MessageSegmentInput> segments) {
        while (true) {
            if (segments.size() >= 2 && isParagraphEnd(segments[segments.size() - 1])
                && isParagraphBegin(segments[segments.size() - 2])
            ) {
                segments.remove(segments.size() - 1);
                segments.remove(segments.size() - 1);
                continue;
            }
            if (segments.size() >= 3 && isParagraphEnd(segments[segments.size() - 1])
                && isNbspText(segments[segments.size() - 2])
                && isParagraphBegin(segments[segments.size() - 3])
            ) {
                segments.remove(segments.size() - 1);
                segments.remove(segments.size() - 1);
                segments.remove(segments.size() - 1);
                continue;
            }
            break;
        }
    }

    private static Boolean isNbspText(ConnectApi.MessageSegmentInput seg) {
        return seg instanceof ConnectApi.TextSegmentInput
            && ((ConnectApi.TextSegmentInput) seg).text == ' ';
    }

    private static Boolean isParagraphBegin(ConnectApi.MessageSegmentInput seg) {
        return seg instanceof ConnectApi.MarkupBeginSegmentInput
            && ((ConnectApi.MarkupBeginSegmentInput) seg).markupType == ConnectApi.MarkupType.Paragraph;
    }

    private static Boolean isParagraphEnd(ConnectApi.MessageSegmentInput seg) {
        return seg instanceof ConnectApi.MarkupEndSegmentInput
            && ((ConnectApi.MarkupEndSegmentInput) seg).markupType == ConnectApi.MarkupType.Paragraph;
    }

    /**
     * Turns a matched opening/closing markup tag (e.g. "<strong>" or
     * "</li>") into the equivalent MarkupBeginSegmentInput /
     * MarkupEndSegmentInput. Returns null for a tag name MARKER_PATTERN
     * shouldn't have matched in the first place (defensive only — every tag
     * the pattern captures is a key in MARKUP_TAG_TYPES).
     */
    @TestVisible
    private static ConnectApi.MessageSegmentInput buildMarkupSegment(String tagText) {
        Matcher nameMatcher = TAG_NAME_PATTERN.matcher(tagText);
        if (!nameMatcher.find()) return null;

        ConnectApi.MarkupType markupType = MARKUP_TAG_TYPES.get(nameMatcher.group(1).toLowerCase());
        if (markupType == null) return null;

        if (tagText.startsWith('</')) {
            ConnectApi.MarkupEndSegmentInput endSeg = new ConnectApi.MarkupEndSegmentInput();
            endSeg.markupType = markupType;
            return endSeg;
        }

        ConnectApi.MarkupBeginSegmentInput beginSeg = new ConnectApi.MarkupBeginSegmentInput();
        beginSeg.markupType = markupType;
        return beginSeg;
    }

    /**
     * True if url starts with http://, https://, or mailto: (after entity
     * decoding). Anything else — javascript:, data:, a bare "#", relative
     * paths that aren't the mention-anchor pattern already handled above,
     * etc. — comes from user-authored rich text and is rejected rather than
     * turned into a live link.
     */
    @TestVisible
    private static Boolean isSafeLinkUrl(String url) {
        return String.isNotBlank(url) && SAFE_LINK_URL_PATTERN.matcher(url.trim()).matches();
    }

    private static Id extractContentDocumentId(String src) {
        if (String.isBlank(src)) return null;
        Matcher idMatcher = CONTENT_DOC_ID_PATTERN.matcher(src);
        if (!idMatcher.find()) return null;
        try {
            return Id.valueOf(idMatcher.group(1));
        } catch (Exception e) {
            return null;
        }
    }

    private static void appendTextSegment(
        List<ConnectApi.MessageSegmentInput> segments, String rawHtml
    ) {
        String plain = stripHtmlToPlainText(rawHtml);
        if (String.isBlank(plain)) return;
        ConnectApi.TextSegmentInput seg = new ConnectApi.TextSegmentInput();
        seg.text = plain;
        segments.add(seg);
    }

    /**
     * Strip HTML tags and decode common entities. Preserves line breaks from
     * <br>, </p>, </div>, </li> so the posted text reads naturally.
     */
    @TestVisible
    private static String stripHtmlToPlainText(String html) {
        if (String.isBlank(html)) return '';

        String text = html;
        text = text.replaceAll('(?i)<br\\s*/?\\s*>', '\n');
        text = text.replaceAll('(?i)</p\\s*>', '\n');
        text = text.replaceAll('(?i)</div\\s*>', '\n');
        text = text.replaceAll('(?i)</li\\s*>', '\n');
        text = text.replaceAll('<[^>]+>', '');
        text = decodeHtmlEntities(text);
        text = text.replaceAll('\\n{3,}', '\n\n');
        return text.trim();
    }

    /**
     * Decodes the handful of HTML entities Quill (and hand-authored HTML)
     * actually produces. Used both for visible text and for a hyperlink's
     * href — an href like "?a=1&amp;b=2" needs the &amp; decoded before the
     * URL is usable or scheme-checked.
     */
    private static String decodeHtmlEntities(String text) {
        return text.replace('&nbsp;', ' ')
                   .replace('&amp;', '&')
                   .replace('&lt;', '<')
                   .replace('&gt;', '>')
                   .replace('&quot;', '"')
                   .replace('&#39;', '\'')
                   .replace('&apos;', '\'');
    }

    @TestVisible
    private static ConnectApi.FeedItemVisibilityType resolveVisibility(String visibility) {
        if (String.isBlank(visibility)) {
            return ConnectApi.FeedItemVisibilityType.InternalUsers;
        }
        String v = visibility.toLowerCase();
        if (v == 'allusers' || v == 'all' || v == 'external') {
            return ConnectApi.FeedItemVisibilityType.AllUsers;
        }
        return ConnectApi.FeedItemVisibilityType.InternalUsers;
    }

    /**
     * Align CDL visibility with the post visibility so external users can
     * see inline images when the post is AllUsers.
     */
    private static void updateContentDocumentLinkVisibility(
        Set<Id> contentDocumentIds,
        Id parentId,
        ConnectApi.FeedItemVisibilityType visibility
    ) {
        if (contentDocumentIds == null || contentDocumentIds.isEmpty()) return;

        String targetVisibility =
            visibility == ConnectApi.FeedItemVisibilityType.AllUsers ? 'AllUsers' : 'InternalUsers';

        List<ContentDocumentLink> links = [
            SELECT Id, Visibility
            FROM ContentDocumentLink
            WHERE ContentDocumentId IN :contentDocumentIds
            AND LinkedEntityId = :parentId
        ];

        List<ContentDocumentLink> toUpdate = new List<ContentDocumentLink>();
        for (ContentDocumentLink link : links) {
            if (link.Visibility != targetVisibility) {
                link.Visibility = targetVisibility;
                toUpdate.add(link);
            }
        }
        if (!toUpdate.isEmpty()) {
            update toUpdate;
        }
    }

    // ─── Request / Result Wrappers ────────────────────────────────────

    public class Request {
        @InvocableVariable(
            label='Parent Record Id'
            description='The record to post the FeedItem to (Case, Account, custom object, etc.)'
            required=true
        )
        public Id parentId;

        @InvocableVariable(
            label='Rich Text HTML'
            description='HTML from chatterImageEditor LWC. Any <img> tag whose src contains a ContentDocumentId (069...) becomes an inline image segment. Any <a href="/{id}"> with a 005 or 0F9 href becomes a mention segment. Any other <a href="http(s)://..."> or <a href="mailto:...">  becomes a hyperlink segment.'
            required=true
        )
        public String richTextHtml;

        @InvocableVariable(
            label='Visibility'
            description='InternalUsers or AllUsers. Defaults to InternalUsers.'
        )
        public String visibility;
    }

    public class Result {
        @InvocableVariable(label='Post Id' description='The created FeedItem Id')
        public Id postId;

        @InvocableVariable(label='Success')
        public Boolean success;

        @InvocableVariable(label='Error Message')
        public String errorMessage;
    }
}