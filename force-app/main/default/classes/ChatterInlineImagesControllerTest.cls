/**
 * @description Tests for ChatterInlineImagesController.
 */
@IsTest
private class ChatterInlineImagesControllerTest {

    // 1x1 red PNG
    private static final String RED_PNG_B64 =
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

    /**
     * CollaborationGroup is chosen as the parent record because it's a
     * standard object with no custom fields or validation rules in any
     * org — Account wouldn't work as a test fixture because install orgs
     * may require custom fields we don't know about.
     */
    private static CollaborationGroup setupParent() {
        CollaborationGroup cg = new CollaborationGroup(
            Name = 'Chatter Inline Images Test ' + Datetime.now().getTime(),
            CollaborationType = 'Private'
        );
        insert cg;
        return cg;
    }

    @IsTest
    static void uploadImage_createsContentVersionAndReturnsDownloadUrl() {
        CollaborationGroup a = setupParent();

        Test.startTest();
        ChatterInlineImagesController.UploadResult result =
            ChatterInlineImagesController.uploadImage(a.Id, 'test.png', RED_PNG_B64);
        Test.stopTest();

        System.assertNotEquals(null, result, 'result is returned');
        System.assertNotEquals(null, result.contentDocumentId, 'contentDocumentId is populated');
        System.assert(
            result.downloadUrl.startsWith('/sfc/servlet.shepherd/document/download/'),
            'downloadUrl has the document download prefix'
        );
        System.assert(
            result.downloadUrl.endsWith(String.valueOf(result.contentDocumentId)),
            'downloadUrl ends with the ContentDocumentId'
        );

        List<ContentVersion> versions = [
            SELECT Id, Title, ContentDocumentId
            FROM ContentVersion
            WHERE ContentDocumentId = :result.contentDocumentId
        ];
        System.assertEquals(1, versions.size(), 'one ContentVersion was created');
        System.assertEquals('test.png', versions[0].Title, 'title matches provided fileName');

        List<ContentDocumentLink> links = [
            SELECT Id, LinkedEntityId
            FROM ContentDocumentLink
            WHERE ContentDocumentId = :result.contentDocumentId
            AND LinkedEntityId = :a.Id
        ];
        System.assertEquals(1, links.size(), 'file is linked to the parent record');
    }

    @IsTest
    static void uploadImage_blankFileNameGetsDefaultName() {
        CollaborationGroup a = setupParent();

        Test.startTest();
        ChatterInlineImagesController.UploadResult result =
            ChatterInlineImagesController.uploadImage(a.Id, null, RED_PNG_B64);
        Test.stopTest();

        ContentVersion cv = [
            SELECT Title FROM ContentVersion
            WHERE ContentDocumentId = :result.contentDocumentId
        ];
        System.assert(cv.Title.startsWith('pasted-image-'), 'default name was generated');
        System.assert(cv.Title.endsWith('.png'), 'default name has png extension');
    }

    @IsTest
    static void uploadImage_nullParentThrows() {
        Boolean threw = false;
        try {
            ChatterInlineImagesController.uploadImage(null, 'x.png', RED_PNG_B64);
        } catch (AuraHandledException e) {
            threw = true;
        }
        System.assert(threw, 'null parentId throws AuraHandledException');
    }

    @IsTest
    static void uploadImage_blankDataThrows() {
        CollaborationGroup a = setupParent();
        Boolean threw = false;
        try {
            ChatterInlineImagesController.uploadImage(a.Id, 'x.png', null);
        } catch (AuraHandledException e) {
            threw = true;
        }
        System.assert(threw, 'blank base64 throws AuraHandledException');
    }

    @IsTest
    static void getMentionableName_returnsRunningUserName() {
        Id userId = UserInfo.getUserId();

        Test.startTest();
        String name = ChatterInlineImagesController.getMentionableName(userId);
        Test.stopTest();

        System.assertNotEquals(null, name, 'running user name is returned');
        System.assertNotEquals('', name, 'running user name is non-empty');
    }

    @IsTest
    static void getMentionableName_returnsCollaborationGroupName() {
        CollaborationGroup cg = new CollaborationGroup(
            Name = 'ChatterInlineImages Test Group',
            CollaborationType = 'Private'
        );
        insert cg;

        Test.startTest();
        String name = ChatterInlineImagesController.getMentionableName(cg.Id);
        Test.stopTest();

        System.assertEquals('ChatterInlineImages Test Group', name, 'group name is returned');
    }

    @IsTest
    static void getMentionableName_nullReturnsNull() {
        System.assertEquals(null, ChatterInlineImagesController.getMentionableName(null));
    }

    @IsTest
    static void getMentionableName_unsupportedPrefixReturnsNull() {
        // A Case Id (500 prefix) is neither a User (005) nor a Group (0F9),
        // so the method should return null without throwing. We don't need
        // the Id to actually exist — the method short-circuits on prefix.
        Id fakeCaseId = '500000000000001AAA';
        String name = ChatterInlineImagesController.getMentionableName(fakeCaseId);
        System.assertEquals(null, name, 'non-user/group prefix returns null');
    }

    // ─── searchMentionableUsers ─────────────────────────────────────

    @IsTest
    static void searchMentionableUsers_matchesRunningUserByNameFragment() {
        User me = [SELECT Id, Name, IsActive FROM User WHERE Id = :UserInfo.getUserId()];

        // Search on the full name rather than a short (e.g. 3-char) fragment.
        // A short fragment is fine in a near-empty scratch org, but in
        // production the query's `ORDER BY Name LIMIT 8` can easily push the
        // running user out of the result window when many other real users
        // share that same name prefix. The full name is selective enough
        // that the running user (almost always) sorts within the top 8
        // matches regardless of how much other user data exists in the org.
        Test.startTest();
        List<ChatterInlineImagesController.MentionCandidate> results =
            ChatterInlineImagesController.searchMentionableUsers(me.Name);
        Test.stopTest();

        Boolean found = false;
        for (ChatterInlineImagesController.MentionCandidate c : results) {
            if (c.recordId == me.Id) {
                found = true;
                System.assertEquals(me.Name, c.name, 'candidate name matches user name');
            }
        }
        System.assert(found, 'running user is returned as a candidate for their own full name');
    }

    @IsTest
    static void searchMentionableUsers_blankTermReturnsResultsWithinLimit() {
        Test.startTest();
        List<ChatterInlineImagesController.MentionCandidate> results =
            ChatterInlineImagesController.searchMentionableUsers('');
        Test.stopTest();

        System.assert(results.size() <= 8, 'never returns more than the 8-result cap');
    }

    @IsTest
    static void searchMentionableUsers_excludesNonStandardUserType() {
        // We don't fabricate a community/portal user here — that needs a
        // license assignment a test can't reliably set up across orgs.
        // Instead, check against whatever non-Standard active users
        // already exist (if any) in the org this test runs in.
        List<User> nonStandard = [
            SELECT Id, Name FROM User
            WHERE IsActive = true AND UserType != 'Standard'
            LIMIT 1
        ];
        if (nonStandard.isEmpty()) {
            return;
        }

        Test.startTest();
        List<ChatterInlineImagesController.MentionCandidate> results =
            ChatterInlineImagesController.searchMentionableUsers(nonStandard[0].Name);
        Test.stopTest();

        for (ChatterInlineImagesController.MentionCandidate c : results) {
            System.assertNotEquals(
                nonStandard[0].Id, c.recordId,
                'non-Standard UserType is excluded from mention search'
            );
        }
    }

    @IsTest
    static void searchMentionableUsers_noMatchReturnsEmptyList() {
        Test.startTest();
        List<ChatterInlineImagesController.MentionCandidate> results =
            ChatterInlineImagesController.searchMentionableUsers(
                'zzzzznonexistentusernamezzzzz'
            );
        Test.stopTest();

        System.assertEquals(0, results.size(), 'no matches returns an empty list, not null');
    }
}