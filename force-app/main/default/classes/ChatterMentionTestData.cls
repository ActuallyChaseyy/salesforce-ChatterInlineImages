/**
 * @description Shared fixture for mention tests that need real customer
 *              (community) users: a Case whose contact has a community user,
 *              another community user on the same account, and one on an
 *              unrelated account. Community users need an account owner with
 *              a role, so everything is built inside runAs(owner) to avoid
 *              mixed setup/non-setup DML.
 */
@IsTest
public class ChatterMentionTestData {

    // Unusual enough that no real user in the org shares it, so searches
    // for it only ever hit fixture users.
    public static final String NAME_PREFIX = 'Zqxmention';

    public User agent;
    public User caseContactUser;
    public User accountUser;
    public User otherAccountUser;
    public Case supportCase;

    public static ChatterMentionTestData create() {
        ChatterMentionTestData d = new ChatterMentionTestData();

        UserRole role = new UserRole(Name = NAME_PREFIX + ' Role');
        insert role;

        Profile adminProfile = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];
        d.agent = buildUser(adminProfile.Id, NAME_PREFIX + ' Agent', 'agt');
        d.agent.UserRoleId = role.Id;
        insert d.agent;

        System.runAs(d.agent) {
            Profile communityProfile = [
                SELECT Id FROM Profile
                WHERE UserLicense.Name = 'Customer Community'
                LIMIT 1
            ];

            Account acct = new Account(Name = NAME_PREFIX + ' Account');
            Account otherAcct = new Account(Name = NAME_PREFIX + ' Other Account');
            insert new List<Account>{ acct, otherAcct };

            Contact caseContact = new Contact(LastName = NAME_PREFIX + ' Contact', AccountId = acct.Id);
            Contact colleague = new Contact(LastName = NAME_PREFIX + ' Colleague', AccountId = acct.Id);
            Contact stranger = new Contact(LastName = NAME_PREFIX + ' Stranger', AccountId = otherAcct.Id);
            insert new List<Contact>{ caseContact, colleague, stranger };

            d.caseContactUser = buildUser(communityProfile.Id, NAME_PREFIX + ' Contact', 'con');
            d.caseContactUser.ContactId = caseContact.Id;
            d.accountUser = buildUser(communityProfile.Id, NAME_PREFIX + ' Colleague', 'col');
            d.accountUser.ContactId = colleague.Id;
            d.otherAccountUser = buildUser(communityProfile.Id, NAME_PREFIX + ' Stranger', 'str');
            d.otherAccountUser.ContactId = stranger.Id;
            insert new List<User>{ d.caseContactUser, d.accountUser, d.otherAccountUser };

            d.supportCase = new Case(
                Subject = NAME_PREFIX + ' Case',
                AccountId = acct.Id,
                ContactId = caseContact.Id
            );
            insert d.supportCase;
        }
        return d;
    }

    private static User buildUser(Id profileId, String lastName, String alias) {
        String unique = alias + Datetime.now().getTime() + Crypto.getRandomInteger();
        return new User(
            ProfileId = profileId,
            LastName = lastName,
            Alias = alias,
            Email = unique + '@example.com',
            Username = unique + '@chattermention.test',
            TimeZoneSidKey = 'Australia/Sydney',
            LocaleSidKey = 'en_AU',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
    }
}
