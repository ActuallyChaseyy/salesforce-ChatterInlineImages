/**
 * @description Apex controller for the chatterImageEditor LWC. Handles:
 *              - Uploading pasted/dropped images as ContentVersion records
 *                linked to the parent record. Returns a document download
 *                URL that embeds the ContentDocumentId, which
 *                ChatterInlineImagePoster later parses out of <img src="...">
 *                to build ConnectApi inline image segments.
 *              - Deleting attached files the user removes before posting.
 *              - Resolving User / Chatter Group names for the mention picker
 *                (the record picker in the LWC only returns the Id).
 *
 *              Part of the chatter-inline-images sharing package.
 *              https://github.com/neilcorp2kx/salesforce-ChatterInlineImages
 */
public with sharing class ChatterInlineImagesController {

    public class UploadResult {
        @AuraEnabled public String contentDocumentId;
        @AuraEnabled public String downloadUrl;
    }

    public class MentionCandidate {
        @AuraEnabled public String recordId;
        @AuraEnabled public String name;
        @AuraEnabled public String photoUrl;
        // Secondary line in the dropdown, e.g. "Case contact · Acme Ltd" —
        // null for staff. Lets agents tell two customers with the same name
        // apart (and tell customers apart from staff at all).
        @AuraEnabled public String subtitle;
        @AuraEnabled public Boolean isCustomer = false;
    }

    private static final Integer MENTION_RESULT_LIMIT = 8;

    /**
     * Uploads a base64-encoded image as a ContentVersion linked to parentId
     * and returns a document download URL that the LWC can embed in an
     * <img src="..."> tag. The invocable poster parses the ContentDocumentId
     * back out of the src when building inline image segments.
     */
    @AuraEnabled
    public static UploadResult uploadImage(Id parentId, String fileName, String base64Data) {
        if (parentId == null) {
            throw new AuraHandledException('Parent record Id is required.');
        }
        if (String.isBlank(base64Data)) {
            throw new AuraHandledException('Image data is required.');
        }

        String safeName = String.isBlank(fileName)
            ? ('pasted-image-' + Datetime.now().getTime() + '.png')
            : fileName;

        ContentVersion cv = new ContentVersion();
        cv.Title = safeName;
        cv.PathOnClient = safeName;
        cv.VersionData = EncodingUtil.base64Decode(base64Data);
        cv.FirstPublishLocationId = parentId;

        try {
            insert cv;
        } catch (DmlException e) {
            throw new AuraHandledException('Failed to upload image: ' + e.getDmlMessage(0));
        }

        ContentVersion inserted = [
            SELECT Id, ContentDocumentId
            FROM ContentVersion
            WHERE Id = :cv.Id
            LIMIT 1
        ];

        UploadResult result = new UploadResult();
        result.contentDocumentId = inserted.ContentDocumentId;
        result.downloadUrl = '/sfc/servlet.shepherd/document/download/' + inserted.ContentDocumentId;
        return result;
    }

    /**
     * Deletes a file the user attached in the editor and then removed
     * before posting. lightning-file-upload has already linked it to the
     * record, so without this it would stay on the record unposted. Only
     * the running user's own files are deleted, so an Id passed in from the
     * client can't be used to remove someone else's file.
     */
    @AuraEnabled
    public static void removeAttachment(Id contentDocumentId) {
        if (contentDocumentId == null) return;

        List<ContentDocument> docs = [
            SELECT Id
            FROM ContentDocument
            WHERE Id = :contentDocumentId
            AND OwnerId = :UserInfo.getUserId()
            LIMIT 1
        ];
        if (docs.isEmpty()) return;

        try {
            delete docs;
        } catch (DmlException e) {
            throw new AuraHandledException('Failed to remove file: ' + e.getDmlMessage(0));
        }
    }

    /**
     * Returns the display name for a User (005) or CollaborationGroup (0F9).
     * Used by the mention picker in the LWC to resolve the picked record Id
     * into a name for the anchor text. Returns null for unsupported key
     * prefixes or records the running user can't see.
     */
    @AuraEnabled(cacheable=true)
    public static String getMentionableName(Id recordId) {
        if (recordId == null) return null;

        String prefix = String.valueOf(recordId).substring(0, 3);
        if (prefix == '005') {
            List<User> users = [SELECT Name FROM User WHERE Id = :recordId LIMIT 1];
            return users.isEmpty() ? null : users[0].Name;
        }
        if (prefix == '0F9') {
            List<CollaborationGroup> groups = [SELECT Name FROM CollaborationGroup WHERE Id = :recordId LIMIT 1];
            return groups.isEmpty() ? null : groups[0].Name;
        }
        return null;
    }

    /**
     * Type-ahead search for the @mention dropdown in the LWC: as the user
     * types after "@", this returns matching active Users so the editor can
     * render a live picklist instead of requiring the old modal record
     * picker. Limited to 8 results — this backs an inline typeahead, not a
     * full search results page.
     *
     * Results are filled in priority tiers, each only using whatever slots
     * the tiers above it left free:
     *   1. Staff (UserType = 'Standard') — always first, so mentioning a
     *      colleague is never buried under customers sharing that name.
     *   2. The community user for the Case's contact.
     *   3. Other community users belonging to the Case's account.
     * Customers outside the Case's account are never offered: they almost
     * certainly can't see the case, and it's how an agent ends up tagging
     * the wrong company's "Aaron".
     *
     * Tiers 2-3 only apply when recordId is a Case AND includeCustomers is
     * true. The LWC passes includeCustomers = false for Internal Users Only
     * posts, since a customer can't see those (ChatterInlineImagePoster
     * enforces the same rule server-side).
     */
    @AuraEnabled(cacheable=true)
    public static List<MentionCandidate> searchMentionableUsers(
        String searchTerm, Id recordId, Boolean includeCustomers
    ) {
        String term = '%' + String.escapeSingleQuotes(
            searchTerm == null ? '' : searchTerm
        ) + '%';

        List<MentionCandidate> results = new List<MentionCandidate>();
        for (User u : [
            SELECT Id, Name, SmallPhotoUrl
            FROM User
            WHERE IsActive = true
            AND UserType = 'Standard'
            AND Name LIKE :term
            ORDER BY Name
            LIMIT :MENTION_RESULT_LIMIT
        ]) {
            results.add(toCandidate(u, null, false));
        }

        if (includeCustomers != true
            || recordId == null
            || recordId.getSObjectType() != Case.SObjectType
            || results.size() >= MENTION_RESULT_LIMIT) {
            return results;
        }

        List<Case> cases = [SELECT ContactId, AccountId FROM Case WHERE Id = :recordId LIMIT 1];
        if (cases.isEmpty()) return results;
        Case c = cases[0];

        Set<Id> seen = new Set<Id>();
        if (c.ContactId != null) {
            for (User u : [
                SELECT Id, Name, SmallPhotoUrl, Contact.Account.Name
                FROM User
                WHERE IsActive = true
                AND ContactId = :c.ContactId
                AND Name LIKE :term
                LIMIT 1
            ]) {
                results.add(toCandidate(u, joinSubtitle('Case contact', u.Contact?.Account?.Name), true));
                seen.add(u.Id);
            }
        }

        Integer remaining = MENTION_RESULT_LIMIT - results.size();
        if (c.AccountId != null && remaining > 0) {
            for (User u : [
                SELECT Id, Name, SmallPhotoUrl, Contact.Account.Name
                FROM User
                WHERE IsActive = true
                AND UserType != 'Standard'
                AND AccountId = :c.AccountId
                AND Id NOT IN :seen
                AND Name LIKE :term
                ORDER BY Name
                LIMIT :remaining
            ]) {
                results.add(toCandidate(u, joinSubtitle('Customer', u.Contact?.Account?.Name), true));
            }
        }
        return results;
    }

    private static MentionCandidate toCandidate(User u, String subtitle, Boolean isCustomer) {
        MentionCandidate c = new MentionCandidate();
        c.recordId = u.Id;
        c.name = u.Name;
        c.photoUrl = u.SmallPhotoUrl;
        c.subtitle = subtitle;
        c.isCustomer = isCustomer;
        return c;
    }

    private static String joinSubtitle(String label, String accountName) {
        return String.isBlank(accountName) ? label : label + ' · ' + accountName;
    }
}