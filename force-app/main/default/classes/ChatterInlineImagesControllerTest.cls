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

    // ─── removeAttachment ───────────────────────────────────────────

    @IsTest
    static void removeAttachment_deletesRunningUsersFile() {
        CollaborationGroup a = setupParent();
        ChatterInlineImagesController.UploadResult upload =
            ChatterInlineImagesController.uploadImage(a.Id, 'remove-me.png', RED_PNG_B64);

        Test.startTest();
        ChatterInlineImagesController.removeAttachment(upload.contentDocumentId);
        Test.stopTest();

        System.assertEquals(
            0,
            [SELECT COUNT() FROM ContentDocument WHERE Id = :upload.contentDocumentId],
            'file is deleted'
        );
    }

    @IsTest
    static void removeAttachment_nullIsIgnored() {
        ChatterInlineImagesController.removeAttachment(null);
        System.assert(true, 'null id does not throw');
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
            ChatterInlineImagesController.searchMentionableUsers(me.Name, null, true);
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
            ChatterInlineImagesController.searchMentionableUsers('', null, true);
        Test.stopTest();

        System.assert(results.size() <= 8, 'never returns more than the 8-result cap');
    }

    @IsTest
    static void searchMentionableUsers_ranksStaffThenCaseContactThenAccountUsers() {
        ChatterMentionTestData d = ChatterMentionTestData.create();

        List<ChatterInlineImagesController.MentionCandidate> results;
        System.runAs(d.agent) {
            Test.startTest();
            results = ChatterInlineImagesController.searchMentionableUsers(
                ChatterMentionTestData.NAME_PREFIX, d.supportCase.Id, true
            );
            Test.stopTest();
        }

        System.assertEquals(3, results.size(), 'staff, case contact and account user — no other-account customers: ' + results);
        System.assertEquals(d.agent.Id, results[0].recordId, 'staff come first');
        System.assertEquals(false, results[0].isCustomer);
        System.assertEquals(null, results[0].subtitle, 'staff have no subtitle');

        System.assertEquals(d.caseContactUser.Id, results[1].recordId, 'case contact comes second');
        System.assertEquals(true, results[1].isCustomer);
        System.assert(results[1].subtitle.startsWith('Case contact'), results[1].subtitle);
        System.assert(results[1].subtitle.contains(ChatterMentionTestData.NAME_PREFIX + ' Account'), results[1].subtitle);

        System.assertEquals(d.accountUser.Id, results[2].recordId, 'other users on the case account come third');
        System.assertEquals(true, results[2].isCustomer);
        System.assert(results[2].subtitle.startsWith('Customer'), results[2].subtitle);
    }

    @IsTest
    static void searchMentionableUsers_excludesCustomersWhenNotRequested() {
        ChatterMentionTestData d = ChatterMentionTestData.create();

        List<ChatterInlineImagesController.MentionCandidate> results;
        System.runAs(d.agent) {
            results = ChatterInlineImagesController.searchMentionableUsers(
                ChatterMentionTestData.NAME_PREFIX, d.supportCase.Id, false
            );
        }

        System.assertEquals(1, results.size(), 'only staff for internal-only posts: ' + results);
        System.assertEquals(d.agent.Id, results[0].recordId);
    }

    @IsTest
    static void searchMentionableUsers_excludesCustomersWhenRecordIsNotACase() {
        ChatterMentionTestData d = ChatterMentionTestData.create();
        CollaborationGroup notACase = setupParent();

        List<ChatterInlineImagesController.MentionCandidate> results;
        System.runAs(d.agent) {
            results = ChatterInlineImagesController.searchMentionableUsers(
                ChatterMentionTestData.NAME_PREFIX, notACase.Id, true
            );
        }

        System.assertEquals(1, results.size(), 'customers are only offered on a Case: ' + results);
        System.assertEquals(d.agent.Id, results[0].recordId);
    }

    @IsTest
    static void searchMentionableUsers_noMatchReturnsEmptyList() {
        Test.startTest();
        List<ChatterInlineImagesController.MentionCandidate> results =
            ChatterInlineImagesController.searchMentionableUsers(
                'zzzzznonexistentusernamezzzzz', null, true
            );
        Test.stopTest();

        System.assertEquals(0, results.size(), 'no matches returns an empty list, not null');
    }
}