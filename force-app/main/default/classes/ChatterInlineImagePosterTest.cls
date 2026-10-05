/**
 * @description Tests for ChatterInlineImagePoster.
 *              Covers the segment-building logic directly (via the
 *              @TestVisible buildSegments method) plus the full invocable
 *              path through ConnectApi.ChatterFeeds.postFeedElement.
 */
@IsTest
private class ChatterInlineImagePosterTest {

    private static final String RED_PNG_B64 =
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

    private static final String SAMPLE_DOC_ID_1 = '069000000000001AAA';
    private static final String SAMPLE_DOC_ID_2 = '069000000000002AAA';

    // ─── buildSegments: pure parsing logic ────────────────────────────

    @IsTest
    static void buildSegments_emptyHtmlReturnsEmptyList() {
        List<ConnectApi.MessageSegmentInput> segments =
            ChatterInlineImagePoster.buildSegments(null, new Set<Id>());
        System.assertEquals(0, segments.size());

        segments = ChatterInlineImagePoster.buildSegments('', new Set<Id>());
        System.assertEquals(0, segments.size());
    }

    @IsTest
    static void buildSegments_textOnlyProducesSingleTextSegment() {
        List<ConnectApi.MessageSegmentInput> segments =
            ChatterInlineImagePoster.buildSegments('<p>Hello world</p>', new Set<Id>());

        System.assertEquals(1, segments.size(), 'one segment');
        System.assert(
            segments[0] instanceof ConnectApi.TextSegmentInput,
            'segment is a TextSegmentInput'
        );
    }

    @IsTest
    static void buildSegments_imgWithContentDocumentIdProducesInlineImageSegment() {
        Set<Id> docIds = new Set<Id>();
        String html = '<p>Before</p><p><img src="/sfc/servlet.shepherd/document/download/'
            + SAMPLE_DOC_ID_1 + '" /></p><p>After</p>';

        List<ConnectApi.MessageSegmentInput> segments =
            ChatterInlineImagePoster.buildSegments(html, docIds);

        // Text("Before"), Begin(Paragraph), End(Paragraph), InlineImage,
        // Begin(Paragraph), End(Paragraph), Text("After") — the paragraph
        // break after the very last </p> is stripped as trailing.
        System.assertEquals(7, segments.size(), 'text + break + image + break + text');
        System.assert(segments[0] instanceof ConnectApi.TextSegmentInput, 'segment 0 is text');
        assertParagraphBreak(segments, 1);
        System.assert(segments[3] instanceof ConnectApi.InlineImageSegmentInput, 'segment 3 is inline image');
        assertParagraphBreak(segments, 4);
        System.assert(segments[6] instanceof ConnectApi.TextSegmentInput, 'segment 6 is text');

        System.assertEquals(1, docIds.size(), 'one doc id collected');
        System.assert(docIds.contains(Id.valueOf(SAMPLE_DOC_ID_1)));
    }

    @IsTest
    static void buildSegments_imgWithoutContentDocumentIdIsSkipped() {
        // An img tag that doesn't have a 069 Id in its src should be skipped
        // (not turned into an orphan image segment).
        Set<Id> docIds = new Set<Id>();
        String html = '<p>Before</p><img src="https://example.com/not-a-sf-file.png" /><p>After</p>';

        List<ConnectApi.MessageSegmentInput> segments =
            ChatterInlineImagePoster.buildSegments(html, docIds);

        // The img tag itself is stripped away with the surrounding HTML,
        // leaving text plus the paragraph break between the two lines —
        // no inline image segment, since the src carries no 069 Id.
        for (ConnectApi.MessageSegmentInput seg : segments) {
            System.assert(
                !(seg instanceof ConnectApi.InlineImageSegmentInput),
                'no inline image segment produced'
            );
        }
        System.assertEquals(0, docIds.size(), 'no doc ids collected');
    }

    @IsTest
    static void buildSegments_mentionAnchorProducesMentionSegment() {
        Id userId = UserInfo.getUserId();
        String html = '<p>Hey <a href="/' + userId + '">@Test User</a>&nbsp; check this</p>';

        List<ConnectApi.MessageSegmentInput> segments =
            ChatterInlineImagePoster.buildSegments(html, new Set<Id>());

        System.assertEquals(3, segments.size(), 'text + mention + text');
        System.assert(segments[1] instanceof ConnectApi.MentionSegmentInput, 'segment 1 is a mention');

        ConnectApi.MentionSegmentInput mention = (ConnectApi.MentionSegmentInput) segments[1];
        System.assertEquals(userId, mention.id, 'mention references the correct user');
    }

    @IsTest
    static void buildSegments_mixedImageAndMentionPreservesDocumentOrder() {
        Id userId = UserInfo.getUserId();
        Set<Id> docIds = new Set<Id>();

        String html =
            '<p>Hey <a href="/' + userId + '">@Test</a>&nbsp; look:</p>' +
            '<p><img src="/sfc/servlet.shepherd/document/download/' + SAMPLE_DOC_ID_1 + '" /></p>' +
            '<p>And also:</p>' +
            '<p><img src="/sfc/servlet.shepherd/document/download/' + SAMPLE_DOC_ID_2 + '" /></p>' +
            '<p>Thanks</p>';

        List<ConnectApi.MessageSegmentInput> segments =
            ChatterInlineImagePoster.buildSegments(html, docIds);

        // Expected order: Text, Mention, Text, [break], Image, [break],
        // Text, [break], Image, [break], Text — the final trailing break
        // is stripped.
        System.assertEquals(15, segments.size(), 'expected 15 segments in order');
        System.assert(segments[0] instanceof ConnectApi.TextSegmentInput,        '0: text');
        System.assert(segments[1] instanceof ConnectApi.MentionSegmentInput,     '1: mention');
        System.assert(segments[2] instanceof ConnectApi.TextSegmentInput,        '2: text');
        assertParagraphBreak(segments, 3);
        System.assert(segments[5] instanceof ConnectApi.InlineImageSegmentInput, '5: image');
        assertParagraphBreak(segments, 6);
        System.assert(segments[8] instanceof ConnectApi.TextSegmentInput,        '8: text');
        assertParagraphBreak(segments, 9);
        System.assert(segments[11] instanceof ConnectApi.InlineImageSegmentInput, '11: image');
        assertParagraphBreak(segments, 12);
        System.assert(segments[14] instanceof ConnectApi.TextSegmentInput,       '14: text');

        System.assertEquals(2, docIds.size(), 'two doc ids collected');
    }

    @IsTest
    static void buildSegments_mentionAnchorWithMalformedIdIsSkipped() {
        // Href doesn't match 005/0F9 pattern — should not produce a mention
        String html = '<p>Try <a href="/001abc">not a user</a> here</p>';

        List<ConnectApi.MessageSegmentInput> segments =
            ChatterInlineImagePoster.buildSegments(html, new Set<Id>());

        for (ConnectApi.MessageSegmentInput seg : segments) {
            System.assert(
                !(seg instanceof ConnectApi.MentionSegmentInput),
                'no mention produced for malformed href'
            );
        }
    }

    // ─── buildSegments: rich text formatting ───────────────────────────

    @IsTest
    static void buildSegments_boldTagProducesMarkupBeginAndEndAroundText() {
        List<ConnectApi.MessageSegmentInput> segments =
            ChatterInlineImagePoster.buildSegments('<p><strong>bold text</strong></p>', new Set<Id>());

        System.assertEquals(3, segments.size(), 'markup begin + text + markup end');
        System.assert(segments[0] instanceof ConnectApi.MarkupBeginSegmentInput, '0: markup begin');
        System.assertEquals(
            ConnectApi.MarkupType.Bold,
            ((ConnectApi.MarkupBeginSegmentInput) segments[0]).markupType
        );
        System.assert(segments[1] instanceof ConnectApi.TextSegmentInput, '1: text');
        System.assertEquals('bold text', ((ConnectApi.TextSegmentInput) segments[1]).text);
        System.assert(segments[2] instanceof ConnectApi.MarkupEndSegmentInput, '2: markup end');
        System.assertEquals(
            ConnectApi.MarkupType.Bold,
            ((ConnectApi.MarkupEndSegmentInput) segments[2]).markupType
        );
    }

    @IsTest
    static void buildSegments_supportsAllInlineMarkupTags() {
        Map<String, ConnectApi.MarkupType> tagToType = new Map<String, ConnectApi.MarkupType>{
            'b' => ConnectApi.MarkupType.Bold,
            'strong' => ConnectApi.MarkupType.Bold,
            'i' => ConnectApi.MarkupType.Italic,
            'em' => ConnectApi.MarkupType.Italic,
            'u' => ConnectApi.MarkupType.Underline,
            's' => ConnectApi.MarkupType.Strikethrough,
            'strike' => ConnectApi.MarkupType.Strikethrough,
            'code' => ConnectApi.MarkupType.Code,
            'pre' => ConnectApi.MarkupType.Code
        };

        for (String tag : tagToType.keySet()) {
            String html = '<' + tag + '>x</' + tag + '>';
            List<ConnectApi.MessageSegmentInput> segments =
                ChatterInlineImagePoster.buildSegments(html, new Set<Id>());

            System.assertEquals(3, segments.size(), 'tag <' + tag + '>');
            System.assertEquals(
                tagToType.get(tag),
                ((ConnectApi.MarkupBeginSegmentInput) segments[0]).markupType,
                'begin type for <' + tag + '>'
            );
            System.assertEquals(
                tagToType.get(tag),
                ((ConnectApi.MarkupEndSegmentInput) segments[2]).markupType,
                'end type for <' + tag + '>'
            );
        }
    }

    @IsTest
    static void buildSegments_orderedListProducesNestedListMarkup() {
        String html = '<ol><li>One</li><li>Two</li></ol>';

        List<ConnectApi.MessageSegmentInput> segments =
            ChatterInlineImagePoster.buildSegments(html, new Set<Id>());

        // Begin(OL), Begin(LI), Text("One"), End(LI), Begin(LI), Text("Two"), End(LI), End(OL)
        System.assertEquals(8, segments.size());
        System.assertEquals(ConnectApi.MarkupType.OrderedList, ((ConnectApi.MarkupBeginSegmentInput) segments[0]).markupType);
        System.assertEquals(ConnectApi.MarkupType.ListItem, ((ConnectApi.MarkupBeginSegmentInput) segments[1]).markupType);
        System.assertEquals('One', ((ConnectApi.TextSegmentInput) segments[2]).text);
        System.assertEquals(ConnectApi.MarkupType.ListItem, ((ConnectApi.MarkupEndSegmentInput) segments[3]).markupType);
        System.assertEquals(ConnectApi.MarkupType.ListItem, ((ConnectApi.MarkupBeginSegmentInput) segments[4]).markupType);
        System.assertEquals('Two', ((ConnectApi.TextSegmentInput) segments[5]).text);
        System.assertEquals(ConnectApi.MarkupType.ListItem, ((ConnectApi.MarkupEndSegmentInput) segments[6]).markupType);
        System.assertEquals(ConnectApi.MarkupType.OrderedList, ((ConnectApi.MarkupEndSegmentInput) segments[7]).markupType);
    }

    @IsTest
    static void buildSegments_markupInterleavesWithImagesAndMentionsInOrder() {
        Id userId = UserInfo.getUserId();
        Set<Id> docIds = new Set<Id>();
        String html =
            '<p><strong>Hey</strong> <a href="/' + userId + '">@Test</a>&nbsp; look:</p>' +
            '<p><img src="/sfc/servlet.shepherd/document/download/' + SAMPLE_DOC_ID_1 + '" /></p>';

        List<ConnectApi.MessageSegmentInput> segments =
            ChatterInlineImagePoster.buildSegments(html, docIds);

        // Begin(Bold), Text("Hey"), End(Bold), Text(" "), Mention,
        // Text("  look:"), [paragraph break], InlineImage. (The lone space
        // between </strong> and the mention anchor is kept as its own text
        // segment so the words don't run together. The trailing break
        // after the final </p> is stripped.)
        System.assertEquals(9, segments.size());
        System.assert(segments[0] instanceof ConnectApi.MarkupBeginSegmentInput);
        System.assert(segments[1] instanceof ConnectApi.TextSegmentInput);
        System.assertEquals('Hey', ((ConnectApi.TextSegmentInput) segments[1]).text);
        System.assert(segments[2] instanceof ConnectApi.MarkupEndSegmentInput);
        System.assertEquals(' ', ((ConnectApi.TextSegmentInput) segments[3]).text);
        System.assert(segments[4] instanceof ConnectApi.MentionSegmentInput);
        System.assertEquals('  look:', ((ConnectApi.TextSegmentInput) segments[5]).text);
        assertParagraphBreak(segments, 6);
        System.assert(segments[8] instanceof ConnectApi.InlineImageSegmentInput);
    }

    // ─── buildSegments: line/paragraph breaks ──────────────────────────
    //
    // Regression coverage for the reported bug: rich text formatting
    // (bold/italic/underline/strike, each on its own line) posted fine but
    // every line ran together with no breaks. Root cause was that breaks
    // were literal '\n' characters embedded in a TextSegmentInput, and
    // Lightning's feed UI only honors '\n' when the WHOLE body is a single
    // text segment — once markup segments were introduced for formatting,
    // every post's line breaks broke. Fix: breaks are their own empty
    // Paragraph markup segment pair instead.

    @IsTest
    static void buildSegments_multiLineTextProducesParagraphBreaksNotEmbeddedNewlines() {
        String html = '<p>line1</p><p>line2</p><p>line3</p>';

        List<ConnectApi.MessageSegmentInput> segments =
            ChatterInlineImagePoster.buildSegments(html, new Set<Id>());

        System.assertEquals(7, segments.size());
        System.assertEquals('line1', ((ConnectApi.TextSegmentInput) segments[0]).text);
        assertParagraphBreak(segments, 1);
        System.assertEquals('line2', ((ConnectApi.TextSegmentInput) segments[3]).text);
        assertParagraphBreak(segments, 4);
        System.assertEquals('line3', ((ConnectApi.TextSegmentInput) segments[6]).text);

        for (ConnectApi.MessageSegmentInput seg : segments) {
            if (seg instanceof ConnectApi.TextSegmentInput) {
                System.assert(
                    !((ConnectApi.TextSegmentInput) seg).text.contains('\n'),
                    'no text segment should carry an embedded newline'
                );
            }
        }
    }

    @IsTest
    static void buildSegments_softBreakWithinParagraphProducesParagraphBreak() {
        String html = '<p>line1<br>line2</p>';

        List<ConnectApi.MessageSegmentInput> segments =
            ChatterInlineImagePoster.buildSegments(html, new Set<Id>());

        System.assertEquals(4, segments.size());
        System.assertEquals('line1', ((ConnectApi.TextSegmentInput) segments[0]).text);
        assertParagraphBreak(segments, 1);
        System.assertEquals('line2', ((ConnectApi.TextSegmentInput) segments[3]).text);
    }

    @IsTest
    static void buildSegments_trailingParagraphBreakIsStripped() {
        List<ConnectApi.MessageSegmentInput> segments =
            ChatterInlineImagePoster.buildSegments('<p>Hello world</p>', new Set<Id>());

        System.assertEquals(1, segments.size(), 'no dangling break at the end of the body');
        System.assert(segments[0] instanceof ConnectApi.TextSegmentInput);
        System.assertEquals('Hello world', ((ConnectApi.TextSegmentInput) segments[0]).text);
    }

    @IsTest
    static void buildSegments_blankLineProducesSingleNbspParagraphPair() {
        // Quill represents a deliberate blank line (user pressed Enter on
        // an empty line) as <p><br></p>. Without special handling this
        // decomposes into 3 separate empty Paragraph pairs (one for the
        // <br>, one for each </p>) which the feed's renderer visually
        // collapses back down to a single line break — the reported bug.
        // The fix merges it down to exactly ONE Paragraph pair carrying a
        // non-breaking space, matching Salesforce's own ConnectApiHelper
        // encoding of a double newline.
        String html = '<p>Test 1</p><p><br></p><p>Test 2</p>';

        List<ConnectApi.MessageSegmentInput> segments =
            ChatterInlineImagePoster.buildSegments(html, new Set<Id>());

        System.assertEquals(5, segments.size());
        System.assertEquals('Test 1', ((ConnectApi.TextSegmentInput) segments[0]).text);
        System.assert(segments[1] instanceof ConnectApi.MarkupBeginSegmentInput);
        System.assertEquals(ConnectApi.MarkupType.Paragraph, ((ConnectApi.MarkupBeginSegmentInput) segments[1]).markupType);
        System.assertEquals(' ', ((ConnectApi.TextSegmentInput) segments[2]).text);
        System.assert(segments[3] instanceof ConnectApi.MarkupEndSegmentInput);
        System.assertEquals(ConnectApi.MarkupType.Paragraph, ((ConnectApi.MarkupEndSegmentInput) segments[3]).markupType);
        System.assertEquals('Test 2', ((ConnectApi.TextSegmentInput) segments[4]).text);
    }

    @IsTest
    static void buildSegments_twoConsecutiveBlankLinesProduceTwoDistinctNbspPairs() {
        String html = '<p>Test 1</p><p><br></p><p><br></p><p>Test 2</p>';

        List<ConnectApi.MessageSegmentInput> segments =
            ChatterInlineImagePoster.buildSegments(html, new Set<Id>());

        System.assertEquals(8, segments.size());
        System.assertEquals('Test 1', ((ConnectApi.TextSegmentInput) segments[0]).text);
        System.assertEquals(' ', ((ConnectApi.TextSegmentInput) segments[2]).text);
        System.assertEquals(' ', ((ConnectApi.TextSegmentInput) segments[5]).text);
        System.assertEquals('Test 2', ((ConnectApi.TextSegmentInput) segments[7]).text);
    }

    @IsTest
    static void buildSegments_leadingBlankLineHasNoPrecedingBreakToMerge() {
        String html = '<p><br></p><p>Test 1</p>';

        List<ConnectApi.MessageSegmentInput> segments =
            ChatterInlineImagePoster.buildSegments(html, new Set<Id>());

        System.assertEquals(4, segments.size());
        System.assert(segments[0] instanceof ConnectApi.MarkupBeginSegmentInput);
        System.assertEquals(' ', ((ConnectApi.TextSegmentInput) segments[1]).text);
        System.assert(segments[2] instanceof ConnectApi.MarkupEndSegmentInput);
        System.assertEquals('Test 1', ((ConnectApi.TextSegmentInput) segments[3]).text);
    }

    @IsTest
    static void buildSegments_trailingBlankLineIsStripped() {
        String html = '<p>Test 1</p><p><br></p>';

        List<ConnectApi.MessageSegmentInput> segments =
            ChatterInlineImagePoster.buildSegments(html, new Set<Id>());

        System.assertEquals(1, segments.size(), 'no dangling blank line at the end of the body');
        System.assertEquals('Test 1', ((ConnectApi.TextSegmentInput) segments[0]).text);
    }

    @IsTest
    static void buildSegments_blankLineViaDivWrapperIsAlsoHandled() {
        String html = '<div>Test 1</div><div><br></div><div>Test 2</div>';

        List<ConnectApi.MessageSegmentInput> segments =
            ChatterInlineImagePoster.buildSegments(html, new Set<Id>());

        System.assertEquals(5, segments.size());
        System.assertEquals(' ', ((ConnectApi.TextSegmentInput) segments[2]).text);
    }

    private static void assertParagraphBreak(List<ConnectApi.MessageSegmentInput> segments, Integer beginIndex) {
        System.assert(
            segments[beginIndex] instanceof ConnectApi.MarkupBeginSegmentInput,
            'segment ' + beginIndex + ' is a Paragraph markup begin'
        );
        System.assertEquals(
            ConnectApi.MarkupType.Paragraph,
            ((ConnectApi.MarkupBeginSegmentInput) segments[beginIndex]).markupType
        );
        System.assert(
            segments[beginIndex + 1] instanceof ConnectApi.MarkupEndSegmentInput,
            'segment ' + (beginIndex + 1) + ' is a Paragraph markup end'
        );
        System.assertEquals(
            ConnectApi.MarkupType.Paragraph,
            ((ConnectApi.MarkupEndSegmentInput) segments[beginIndex + 1]).markupType
        );
    }

    // ─── buildSegments: hyperlinks ─────────────────────────────────────

    @IsTest
    static void buildSegments_httpLinkProducesHyperlinkMarkupWithUrl() {
        String html = '<p>Check <a href="https://example.com/page">this out</a> now</p>';

        List<ConnectApi.MessageSegmentInput> segments =
            ChatterInlineImagePoster.buildSegments(html, new Set<Id>());

        System.assertEquals(5, segments.size());
        System.assertEquals('Check ', ((ConnectApi.TextSegmentInput) segments[0]).text);
        System.assert(segments[1] instanceof ConnectApi.MarkupBeginSegmentInput);
        ConnectApi.MarkupBeginSegmentInput beginSeg = (ConnectApi.MarkupBeginSegmentInput) segments[1];
        System.assertEquals(ConnectApi.MarkupType.Hyperlink, beginSeg.markupType);
        System.assertEquals('https://example.com/page', beginSeg.url);
        System.assertEquals('this out', ((ConnectApi.TextSegmentInput) segments[2]).text);
        System.assert(segments[3] instanceof ConnectApi.MarkupEndSegmentInput);
        System.assertEquals(
            ConnectApi.MarkupType.Hyperlink,
            ((ConnectApi.MarkupEndSegmentInput) segments[3]).markupType
        );
        System.assertEquals(' now', ((ConnectApi.TextSegmentInput) segments[4]).text);
    }

    // ─── buildSegments: word spacing at segment boundaries ─────────────
    //
    // Regression coverage for RIS-18546: spacing looked right in the editor
    // but words ran together once posted. Every text chunk between markers
    // was trimmed, so the space next to a link, mention or formatting run
    // was lost — most visibly around URLs (text with forward slashes),
    // which the editor auto-links as the user types.

    @IsTest
    static void buildSegments_autoLinkedUrlKeepsSurroundingSpaces() {
        String html = '<p>Please see <a href="https://example.com/a/b" target="_blank">'
            + 'https://example.com/a/b</a> for details</p>';

        List<ConnectApi.MessageSegmentInput> segments =
            ChatterInlineImagePoster.buildSegments(html, new Set<Id>());

        System.assertEquals(5, segments.size());
        System.assertEquals('Please see ', ((ConnectApi.TextSegmentInput) segments[0]).text);
        System.assertEquals('https://example.com/a/b', ((ConnectApi.TextSegmentInput) segments[2]).text);
        System.assertEquals(' for details', ((ConnectApi.TextSegmentInput) segments[4]).text);
    }

    @IsTest
    static void buildSegments_formattingKeepsSurroundingSpaces() {
        String html = '<p>This is <strong>bold</strong> and <em>italic</em> text</p>';

        List<ConnectApi.MessageSegmentInput> segments =
            ChatterInlineImagePoster.buildSegments(html, new Set<Id>());

        System.assertEquals('This is bold and italic text', joinText(segments));
    }

    @IsTest
    static void buildSegments_spaceBetweenAdjacentMarkupIsKept() {
        String html = '<p><strong>one</strong> <em>two</em></p>';

        List<ConnectApi.MessageSegmentInput> segments =
            ChatterInlineImagePoster.buildSegments(html, new Set<Id>());

        System.assertEquals('one two', joinText(segments));
    }

    @IsTest
    static void buildSegments_sourceFormattingNewlinesBetweenTagsAreDropped() {
        String html = '<p>line1</p>\n<p>line2</p>\n';

        List<ConnectApi.MessageSegmentInput> segments =
            ChatterInlineImagePoster.buildSegments(html, new Set<Id>());

        System.assertEquals(4, segments.size());
        System.assertEquals('line1', ((ConnectApi.TextSegmentInput) segments[0]).text);
        assertParagraphBreak(segments, 1);
        System.assertEquals('line2', ((ConnectApi.TextSegmentInput) segments[3]).text);
    }

    private static String joinText(List<ConnectApi.MessageSegmentInput> segments) {
        String joined = '';
        for (ConnectApi.MessageSegmentInput seg : segments) {
            if (seg instanceof ConnectApi.TextSegmentInput) {
                joined += ((ConnectApi.TextSegmentInput) seg).text;
            }
        }
        return joined;
    }

    @IsTest
    static void buildSegments_mailtoLinkIsAccepted() {
        String html = '<a href="mailto:test@example.com">email me</a>';

        List<ConnectApi.MessageSegmentInput> segments =
            ChatterInlineImagePoster.buildSegments(html, new Set<Id>());

        System.assertEquals(3, segments.size());
        System.assertEquals(
            'mailto:test@example.com',
            ((ConnectApi.MarkupBeginSegmentInput) segments[0]).url
        );
    }

    @IsTest
    static void buildSegments_unsafeSchemeLinkIsDroppedButTextKept() {
        String html = '<p>Click <a href="javascript:alert(1)">here</a> please</p>';

        List<ConnectApi.MessageSegmentInput> segments =
            ChatterInlineImagePoster.buildSegments(html, new Set<Id>());

        // No Hyperlink markup at all — just the text, unbroken, with the
        // dangerous href stripped away along with the tag.
        for (ConnectApi.MessageSegmentInput seg : segments) {
            System.assert(!(seg instanceof ConnectApi.MarkupBeginSegmentInput), 'no markup begin');
            System.assert(!(seg instanceof ConnectApi.MarkupEndSegmentInput), 'no markup end');
        }
        System.assertEquals(1, segments.size());
        System.assertEquals('Click here please', ((ConnectApi.TextSegmentInput) segments[0]).text);
    }

    @IsTest
    static void buildSegments_linkHrefDecodesAmpEntity() {
        String html = '<a href="https://example.com/x?a=1&amp;b=2">link</a>';

        List<ConnectApi.MessageSegmentInput> segments =
            ChatterInlineImagePoster.buildSegments(html, new Set<Id>());

        System.assertEquals(
            'https://example.com/x?a=1&b=2',
            ((ConnectApi.MarkupBeginSegmentInput) segments[0]).url
        );
    }

    @IsTest
    static void buildSegments_linkCombinesWithBoldFormatting() {
        String html = '<p><strong><a href="https://example.com">bold link</a></strong></p>';

        List<ConnectApi.MessageSegmentInput> segments =
            ChatterInlineImagePoster.buildSegments(html, new Set<Id>());

        // Begin(Bold), Begin(Hyperlink), Text, End(Hyperlink), End(Bold)
        System.assertEquals(5, segments.size());
        System.assertEquals(ConnectApi.MarkupType.Bold, ((ConnectApi.MarkupBeginSegmentInput) segments[0]).markupType);
        System.assertEquals(ConnectApi.MarkupType.Hyperlink, ((ConnectApi.MarkupBeginSegmentInput) segments[1]).markupType);
        System.assertEquals('bold link', ((ConnectApi.TextSegmentInput) segments[2]).text);
        System.assertEquals(ConnectApi.MarkupType.Hyperlink, ((ConnectApi.MarkupEndSegmentInput) segments[3]).markupType);
        System.assertEquals(ConnectApi.MarkupType.Bold, ((ConnectApi.MarkupEndSegmentInput) segments[4]).markupType);
    }

    @IsTest
    static void buildSegments_mentionAnchorStillTakesPriorityOverGenericLinkHandling() {
        // A mention href (/005... or /0F9...) must still become a
        // MentionSegmentInput, not a Hyperlink markup segment.
        Id userId = UserInfo.getUserId();
        String html = '<a href="/' + userId + '">@Test User</a>';

        List<ConnectApi.MessageSegmentInput> segments =
            ChatterInlineImagePoster.buildSegments(html, new Set<Id>());

        System.assertEquals(1, segments.size());
        System.assert(segments[0] instanceof ConnectApi.MentionSegmentInput);
    }

    // ─── isSafeLinkUrl ──────────────────────────────────────────────────

    @IsTest
    static void isSafeLinkUrl_acceptsHttpHttpsAndMailto() {
        System.assert(ChatterInlineImagePoster.isSafeLinkUrl('https://example.com'));
        System.assert(ChatterInlineImagePoster.isSafeLinkUrl('http://example.com'));
        System.assert(ChatterInlineImagePoster.isSafeLinkUrl('mailto:someone@example.com'));
        System.assert(ChatterInlineImagePoster.isSafeLinkUrl('HTTPS://EXAMPLE.COM'), 'scheme check is case-insensitive');
    }

    @IsTest
    static void isSafeLinkUrl_rejectsOtherSchemesAndBlank() {
        System.assert(!ChatterInlineImagePoster.isSafeLinkUrl('javascript:alert(1)'));
        System.assert(!ChatterInlineImagePoster.isSafeLinkUrl('data:text/html,evil'));
        System.assert(!ChatterInlineImagePoster.isSafeLinkUrl('/relative/path'));
        System.assert(!ChatterInlineImagePoster.isSafeLinkUrl(''));
        System.assert(!ChatterInlineImagePoster.isSafeLinkUrl(null));
    }

    // ─── stripHtmlToPlainText ─────────────────────────────────────────

    @IsTest
    static void stripHtmlToPlainText_stripsTagsAndDecodesEntities() {
        String result = ChatterInlineImagePoster.stripHtmlToPlainText(
            '<p>Hello <b>world</b> &amp; goodbye</p>'
        );
        System.assertEquals('Hello world & goodbye', result);
    }

    @IsTest
    static void stripHtmlToPlainText_preservesBlockBreaks() {
        String result = ChatterInlineImagePoster.stripHtmlToPlainText(
            '<p>Line 1</p><p>Line 2</p>'
        );
        System.assert(result.contains('\n'), 'block break preserved as newline');
        System.assert(result.contains('Line 1'));
        System.assert(result.contains('Line 2'));
    }

    @IsTest
    static void stripHtmlToPlainText_blankInputReturnsEmpty() {
        System.assertEquals('', ChatterInlineImagePoster.stripHtmlToPlainText(null));
        System.assertEquals('', ChatterInlineImagePoster.stripHtmlToPlainText(''));
    }

    // ─── decodeHtmlEntities ───────────────────────────────────────────

    @IsTest
    static void decodeHtmlEntities_literalEntityTextIsNotDoubleDecoded() {
        // A user typing "&lt;b&gt;" as text reaches Apex as
        // "&amp;lt;b&amp;gt;" — it must post as the literal "&lt;b&gt;",
        // not be decoded a second time into "<b>".
        System.assertEquals(
            '&lt;b&gt; &amp; &nbsp; &quot;',
            ChatterInlineImagePoster.decodeHtmlEntities(
                '&amp;lt;b&amp;gt; &amp;amp; &amp;nbsp; &amp;quot;'
            )
        );
    }

    @IsTest
    static void decodeHtmlEntities_decodesEachEntityOnce() {
        System.assertEquals(
            '< > & " \' \'  ',
            ChatterInlineImagePoster.decodeHtmlEntities('&lt; &gt; &amp; &quot; &#39; &apos; &nbsp;')
        );
    }

    @IsTest
    static void buildSegments_literalEntityTextPostsAsTyped() {
        List<ConnectApi.MessageSegmentInput> segments =
            ChatterInlineImagePoster.buildSegments('<p>Use &amp;lt;br&amp;gt; for a break</p>', new Set<Id>());

        System.assertEquals(1, segments.size());
        System.assertEquals('Use &lt;br&gt; for a break', ((ConnectApi.TextSegmentInput) segments[0]).text);
    }

    // ─── resolveVisibility ─────────────────────────────────────────

    @IsTest
    static void resolveVisibility_defaultsToInternal() {
        System.assertEquals(
            ConnectApi.FeedItemVisibilityType.InternalUsers,
            ChatterInlineImagePoster.resolveVisibility(null)
        );
        System.assertEquals(
            ConnectApi.FeedItemVisibilityType.InternalUsers,
            ChatterInlineImagePoster.resolveVisibility('')
        );
    }

    @IsTest
    static void resolveVisibility_allUsersAliases() {
        System.assertEquals(
            ConnectApi.FeedItemVisibilityType.AllUsers,
            ChatterInlineImagePoster.resolveVisibility('AllUsers')
        );
        System.assertEquals(
            ConnectApi.FeedItemVisibilityType.AllUsers,
            ChatterInlineImagePoster.resolveVisibility('all')
        );
        System.assertEquals(
            ConnectApi.FeedItemVisibilityType.AllUsers,
            ChatterInlineImagePoster.resolveVisibility('external')
        );
    }

    @IsTest
    static void resolveVisibility_unknownDefaultsToInternal() {
        System.assertEquals(
            ConnectApi.FeedItemVisibilityType.InternalUsers,
            ChatterInlineImagePoster.resolveVisibility('something-weird')
        );
    }

    // ─── Invocable: validation + error handling ───────────────────────

    @IsTest
    static void postFeedItems_missingParentIdReturnsError() {
        ChatterInlineImagePoster.Request req = new ChatterInlineImagePoster.Request();
        req.richTextHtml = '<p>Hi</p>';

        Test.startTest();
        List<ChatterInlineImagePoster.Result> results =
            ChatterInlineImagePoster.postFeedItems(
                new List<ChatterInlineImagePoster.Request>{ req }
            );
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assertEquals(false, results[0].success);
        System.assert(results[0].errorMessage.contains('parentId'));
    }

    @IsTest
    static void postFeedItems_missingHtmlReturnsError() {
        CollaborationGroup a = new CollaborationGroup(
            Name = 'Test Group ' + Datetime.now().getTime(),
            CollaborationType = 'Private'
        );
        insert a;

        ChatterInlineImagePoster.Request req = new ChatterInlineImagePoster.Request();
        req.parentId = a.Id;

        Test.startTest();
        List<ChatterInlineImagePoster.Result> results =
            ChatterInlineImagePoster.postFeedItems(
                new List<ChatterInlineImagePoster.Request>{ req }
            );
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assertEquals(false, results[0].success);
        System.assert(results[0].errorMessage.contains('richTextHtml'));
    }

    // ─── Invocable: full end-to-end with real ConnectApi post ───────

    /**
     * ConnectApi.ChatterFeeds.postFeedElement requires SeeAllData=true in
     * tests because Salesforce's data-siloed test runner doesn't give it
     * access to the feed tables. The alternative is ConnectApi.setTestPostFeedElement
     * mocking, which is finicky — SeeAllData=true is simpler and these
     * tests run against the running user's own Chatter wall, so they
     * don't depend on any particular org data to exist.
     */
    @IsTest(SeeAllData=true)
    static void postFeedItems_textOnlyEndToEnd() {
        ChatterInlineImagePoster.Request req = new ChatterInlineImagePoster.Request();
        req.parentId = UserInfo.getUserId();
        req.richTextHtml = '<p>Hello from test</p>';
        // Posting to a user wall requires AllUsers visibility — the platform
        // rejects InternalUsers on user/group/DM feed posts.
        req.visibility = 'AllUsers';

        Test.startTest();
        List<ChatterInlineImagePoster.Result> results =
            ChatterInlineImagePoster.postFeedItems(
                new List<ChatterInlineImagePoster.Request>{ req }
            );
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assertEquals(true, results[0].success, 'post succeeded: ' + results[0].errorMessage);
        System.assertNotEquals(null, results[0].postId, 'postId returned');
    }

    @IsTest(SeeAllData=true)
    static void postFeedItems_withRealInlineImageEndToEnd() {
        Id parentId = UserInfo.getUserId();

        ChatterInlineImagesController.UploadResult upload =
            ChatterInlineImagesController.uploadImage(parentId, 'test.png', RED_PNG_B64);

        String html =
            '<p>Before image</p>' +
            '<p><img src="' + upload.downloadUrl + '" /></p>' +
            '<p>After image</p>';

        ChatterInlineImagePoster.Request req = new ChatterInlineImagePoster.Request();
        req.parentId = parentId;
        req.richTextHtml = html;
        req.visibility = 'AllUsers';

        Test.startTest();
        List<ChatterInlineImagePoster.Result> results =
            ChatterInlineImagePoster.postFeedItems(
                new List<ChatterInlineImagePoster.Request>{ req }
            );
        Test.stopTest();

        System.assertEquals(true, results[0].success, 'post succeeded: ' + results[0].errorMessage);
        System.assertNotEquals(null, results[0].postId);

        List<FeedAttachment> attachments = [
            SELECT Id, Type, RecordId
            FROM FeedAttachment
            WHERE FeedEntityId = :results[0].postId
        ];
        System.assertEquals(1, attachments.size(), 'one feed attachment created');
        System.assertEquals('InlineImage', attachments[0].Type);
    }

    // ─── File attachments ─────────────────────────────────────────────

    @IsTest
    static void parseAttachmentIds_keepsValidIdsInOrderWithoutDuplicates() {
        String first = '069000000000001AAA';
        String second = '069000000000002AAA';

        List<Id> ids = ChatterInlineImagePoster.parseAttachmentIds(
            new List<String>{ first, '', null, 'not-an-id', ' ' + second + ' ', first }
        );

        System.assertEquals(2, ids.size(), 'blank, invalid and duplicate ids dropped');
        System.assertEquals(Id.valueOf(first), ids[0]);
        System.assertEquals(Id.valueOf(second), ids[1]);
    }

    @IsTest
    static void parseAttachmentIds_nullReturnsEmptyList() {
        System.assertEquals(0, ChatterInlineImagePoster.parseAttachmentIds(null).size());
    }

    @IsTest
    static void buildFilesCapability_addsEachFile() {
        List<Id> docIds = new List<Id>{
            Id.valueOf('069000000000001AAA'), Id.valueOf('069000000000002AAA')
        };

        ConnectApi.FeedElementCapabilitiesInput capabilities =
            ChatterInlineImagePoster.buildFilesCapability(docIds);

        System.assertEquals(2, capabilities.files.items.size());
        System.assertEquals(docIds[0], ((ConnectApi.FileIdInput) capabilities.files.items[0]).id);
        System.assertEquals(docIds[1], ((ConnectApi.FileIdInput) capabilities.files.items[1]).id);
    }

    @IsTest
    static void postFeedItems_moreThanTenAttachmentsReturnsError() {
        List<String> ids = new List<String>();
        for (Integer i = 10; i < 21; i++) {
            ids.add('0690000000000' + i + 'AAA');
        }

        ChatterInlineImagePoster.Request req = new ChatterInlineImagePoster.Request();
        req.parentId = UserInfo.getUserId();
        req.richTextHtml = '<p>Too many files</p>';
        req.attachmentIds = ids;

        List<ChatterInlineImagePoster.Result> results =
            ChatterInlineImagePoster.postFeedItems(
                new List<ChatterInlineImagePoster.Request>{ req }
            );

        System.assertEquals(false, results[0].success);
        System.assert(results[0].errorMessage.contains('at most 10'), results[0].errorMessage);
    }

    @IsTest(SeeAllData=true)
    static void postFeedItems_withAttachmentEndToEnd() {
        Id parentId = UserInfo.getUserId();

        ContentVersion cv = new ContentVersion(
            Title = 'attachment.txt',
            PathOnClient = 'attachment.txt',
            VersionData = Blob.valueOf('attachment body'),
            FirstPublishLocationId = parentId
        );
        insert cv;
        Id docId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;

        ChatterInlineImagePoster.Request req = new ChatterInlineImagePoster.Request();
        req.parentId = parentId;
        req.richTextHtml = '<p>See attached</p>';
        req.visibility = 'AllUsers';
        req.attachmentIds = new List<String>{ docId };

        Test.startTest();
        List<ChatterInlineImagePoster.Result> results =
            ChatterInlineImagePoster.postFeedItems(
                new List<ChatterInlineImagePoster.Request>{ req }
            );
        Test.stopTest();

        System.assertEquals(true, results[0].success, 'post succeeded: ' + results[0].errorMessage);

        List<FeedAttachment> attachments = [
            SELECT Id, Type, RecordId
            FROM FeedAttachment
            WHERE FeedEntityId = :results[0].postId
        ];
        System.assertEquals(1, attachments.size(), 'one feed attachment created');
        System.assertEquals('Content', attachments[0].Type);
    }

    @IsTest(SeeAllData=true)
    static void postFeedItems_attachmentOnlyWithBlankHtmlEndToEnd() {
        Id parentId = UserInfo.getUserId();

        ContentVersion cv = new ContentVersion(
            Title = 'attachment-only.txt',
            PathOnClient = 'attachment-only.txt',
            VersionData = Blob.valueOf('attachment body'),
            FirstPublishLocationId = parentId
        );
        insert cv;
        Id docId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;

        ChatterInlineImagePoster.Request req = new ChatterInlineImagePoster.Request();
        req.parentId = parentId;
        req.richTextHtml = '';
        req.visibility = 'AllUsers';
        req.attachmentIds = new List<String>{ docId };

        Test.startTest();
        List<ChatterInlineImagePoster.Result> results =
            ChatterInlineImagePoster.postFeedItems(
                new List<ChatterInlineImagePoster.Request>{ req }
            );
        Test.stopTest();

        System.assertEquals(true, results[0].success, 'post succeeded: ' + results[0].errorMessage);
        System.assertEquals(
            1,
            [SELECT COUNT() FROM FeedAttachment WHERE FeedEntityId = :results[0].postId AND Type = 'Content'],
            'file attached to the post'
        );
    }

    // ─── Customer mentions vs. Internal Users Only ────────────────────

    @IsTest
    static void postFeedItems_internalPostWithCustomerMentionIsRejected() {
        ChatterMentionTestData d = ChatterMentionTestData.create();

        ChatterInlineImagePoster.Request req = new ChatterInlineImagePoster.Request();
        req.parentId = d.supportCase.Id;
        req.richTextHtml = '<p>Hi <a href="/' + d.caseContactUser.Id + '">@Contact</a></p>';
        req.visibility = 'InternalUsers';

        List<ChatterInlineImagePoster.Result> results;
        System.runAs(d.agent) {
            Test.startTest();
            results = ChatterInlineImagePoster.postFeedItems(
                new List<ChatterInlineImagePoster.Request>{ req }
            );
            Test.stopTest();
        }

        System.assertEquals(false, results[0].success, 'customer mention on an internal post is rejected');
        System.assert(
            results[0].errorMessage.contains('Internal Users Only'),
            'error explains why: ' + results[0].errorMessage
        );
    }

    @IsTest
    static void assertNoCustomerMentions_allowsStaffMentions() {
        List<ConnectApi.MessageSegmentInput> segments = ChatterInlineImagePoster.buildSegments(
            '<p>Hi <a href="/' + UserInfo.getUserId() + '">@Me</a></p>', null
        );
        // Throws if the running (Standard) user were treated as a customer.
        ChatterInlineImagePoster.assertNoCustomerMentions(segments);
    }

    @IsTest
    static void assertNoCustomerMentions_rejectsCustomerMentions() {
        ChatterMentionTestData d = ChatterMentionTestData.create();
        List<ConnectApi.MessageSegmentInput> segments = ChatterInlineImagePoster.buildSegments(
            '<p>Hi <a href="/' + d.accountUser.Id + '">@Colleague</a></p>', null
        );

        Boolean threw = false;
        System.runAs(d.agent) {
            try {
                ChatterInlineImagePoster.assertNoCustomerMentions(segments);
            } catch (IllegalArgumentException e) {
                threw = true;
                System.assert(e.getMessage().contains(ChatterMentionTestData.NAME_PREFIX), e.getMessage());
            }
        }
        System.assert(threw, 'customer mention is rejected');
    }
}
