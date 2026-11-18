/**
 * Test data builders shared by all renewal test classes.
 *
 * build* methods return records in memory (no DML) so tests can adjust them
 * before inserting; create* methods insert.
 */
@IsTest
public class TestDataFactory {
    public static final String RENEWAL_PERMISSION_SET = 'Renewal_Management';
    private static final String STANDARD_PROFILE = 'Standard User';

    public static Account createAccount(String name) {
        Account account = new Account(Name = name);
        insert account;
        return account;
    }

    /**
     * An agreement that satisfies every renewal criterion; whether it
     * qualifies depends only on the End Date relative to "today".
     */
    public static Service_Agreement__c buildAgreement(Id accountId, String name, Date endDate) {
        return new Service_Agreement__c(
            Name = name,
            Account__c = accountId,
            Status__c = RenewalService.STATUS_ACTIVE,
            Renewal_Required__c = true,
            Start_Date__c = endDate.addYears(-1),
            End_Date__c = endDate,
            Agreement_Value__c = 10000,
            Account_Manager__c = UserInfo.getUserId()
        );
    }

    public static List<Service_Agreement__c> buildAgreements(Id accountId, Integer count, Date endDate) {
        List<Service_Agreement__c> agreements = new List<Service_Agreement__c>();
        for (Integer i = 0; i < count; i++) {
            agreements.add(buildAgreement(accountId, 'Agreement ' + i, endDate));
        }
        return agreements;
    }

    /**
     * Inserts a Standard User, optionally assigning a permission set.
     * Runs as the current user to isolate setup-object DML from the
     * non-setup DML performed by tests (avoids MIXED_DML_OPERATION).
     */
    public static User createStandardUser(String lastName, String permissionSetName) {
        Profile standardProfile = [SELECT Id FROM Profile WHERE Name = :STANDARD_PROFILE LIMIT 1];
        String uniqueKey = String.valueOf(Math.abs(Crypto.getRandomInteger()));

        User user = new User(
            LastName = lastName,
            FirstName = 'Test',
            Alias = 'u' + uniqueKey.left(7),
            Email = 'renewal.test' + uniqueKey + '@example.com',
            Username = 'renewal.test' + uniqueKey + '@example.com.test',
            ProfileId = standardProfile.Id,
            TimeZoneSidKey = 'America/Sao_Paulo',
            LocaleSidKey = 'en_US',
            LanguageLocaleKey = 'en_US',
            EmailEncodingKey = 'UTF-8'
        );

        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert user;
            if (permissionSetName != null) {
                PermissionSet permissionSet = [SELECT Id FROM PermissionSet WHERE Name = :permissionSetName LIMIT 1];
                insert new PermissionSetAssignment(AssigneeId = user.Id, PermissionSetId = permissionSet.Id);
            }
        }
        return user;
    }
}
