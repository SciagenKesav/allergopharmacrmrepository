/**
 * Proves the Rep A / Rep B territory-visibility requirement without creating any real,
 * persistent Salesforce Users — everything here lives inside the test transaction and is
 * rolled back automatically when the test finishes. System.runAs() is what makes Salesforce
 * actually enforce sharing (not just FLS) for the block it wraps, which is the standard,
 * correct way to test an Apex-managed sharing engine.
 */
@isTest
private with sharing class TerritorySharingServiceTest {

    @TestSetup
    static void setup() {
        Territory__c chennai = new Territory__c(Name = 'Test Chennai', Territory_Code__c = 'TCHN', Type__c = 'Territory');
        Territory__c otherTerritory = new Territory__c(Name = 'Test Other', Territory_Code__c = 'TOTH', Type__c = 'Territory');
        insert new List<Territory__c>{ chennai, otherTerritory };

        Profile standardProfile = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User repA = testUser('RepA', 'Chennai', standardProfile.Id);
        User repB = testUser('RepB', 'Other', standardProfile.Id);

        // User + PermissionSetAssignment are "setup objects" — Salesforce forbids mixing DML on
        // setup and non-setup objects (Territory__c, above) in one transaction. Wrapping the
        // setup-object DML in its own runAs isolates it into a separate pseudo-transaction,
        // which is the standard, documented way around MIXED_DML_OPERATION in test context.
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert new List<User>{ repA, repB };

            PermissionSet mobileAccess = [SELECT Id FROM PermissionSet WHERE Name = 'Sciagen_Mobile_App_Access' LIMIT 1];
            insert new List<PermissionSetAssignment>{
                new PermissionSetAssignment(AssigneeId = repA.Id, PermissionSetId = mobileAccess.Id),
                new PermissionSetAssignment(AssigneeId = repB.Id, PermissionSetId = mobileAccess.Id)
            };
        }

        // Rep A is assigned to Chennai; Rep B is assigned to a different territory entirely.
        insert new List<User_Territory__c>{
            new User_Territory__c(User__c = repA.Id, Territory__c = chennai.Id),
            new User_Territory__c(User__c = repB.Id, Territory__c = otherTerritory.Id)
        };

        Sciagen_Account__c hco = new Sciagen_Account__c(Name = 'Test Chennai Hospital', Type__c = 'HCO');
        insert hco;
        insert new Account_Territory__c(Account__c = hco.Id, Territory__c = chennai.Id);
    }

    private static User testUser(String firstName, String lastName, Id profileId) {
        String uniq = firstName.toLowerCase() + '.' + lastName.toLowerCase() + '.' + Datetime.now().getTime();
        return new User(
            FirstName = firstName, LastName = lastName,
            Email = uniq + '@sciagen.invalid',
            Username = uniq + '@sciagen.invalid',
            Alias = firstName.left(1).toLowerCase() + lastName.left(4).toLowerCase(),
            TimeZoneSidKey = 'Asia/Kolkata', LocaleSidKey = 'en_IN',
            EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US', ProfileId = profileId
        );
    }

    @isTest
    static void manualShareExistsForRepAOnly() {
        Sciagen_Account__c hco = [SELECT Id FROM Sciagen_Account__c WHERE Name = 'Test Chennai Hospital' LIMIT 1];
        User repA = [SELECT Id FROM User WHERE LastName = 'Chennai' LIMIT 1];
        List<Sciagen_Account__Share> manualShares = [
            SELECT UserOrGroupId FROM Sciagen_Account__Share WHERE ParentId = :hco.Id AND RowCause = 'Manual'
        ];
        System.assertEquals(1, manualShares.size(), 'Expected exactly one Apex-managed share');
        System.assertEquals(repA.Id, manualShares[0].UserOrGroupId, 'The share must be for Rep A, who is assigned to the account\'s territory');
    }

    @isTest
    static void repInTerritorySeesAccount_repInOtherTerritoryDoesNot() {
        User repA = [SELECT Id FROM User WHERE LastName = 'Chennai' LIMIT 1];
        User repB = [SELECT Id FROM User WHERE LastName = 'Other' LIMIT 1];
        Sciagen_Account__c hco = [SELECT Id FROM Sciagen_Account__c WHERE Name = 'Test Chennai Hospital' LIMIT 1];

        System.runAs(repA) {
            List<Sciagen_Account__c> visible = [SELECT Id FROM Sciagen_Account__c WHERE Id = :hco.Id];
            System.assertEquals(1, visible.size(), 'Rep assigned to the account\'s territory must see it');
        }

        System.runAs(repB) {
            List<Sciagen_Account__c> visible = [SELECT Id FROM Sciagen_Account__c WHERE Id = :hco.Id];
            System.assertEquals(0, visible.size(), 'Rep assigned to a different territory must not see it');
        }
    }

    @isTest
    static void accessRevokedWhenTerritoryAssignmentDeleted() {
        User repA = [SELECT Id FROM User WHERE LastName = 'Chennai' LIMIT 1];
        Sciagen_Account__c hco = [SELECT Id FROM Sciagen_Account__c WHERE Name = 'Test Chennai Hospital' LIMIT 1];

        System.runAs(repA) {
            System.assertEquals(1, [SELECT Id FROM Sciagen_Account__c WHERE Id = :hco.Id].size(),
                'Sanity check: Rep A can see it before the assignment is removed');
        }

        delete [SELECT Id FROM User_Territory__c WHERE User__c = :repA.Id];

        System.runAs(repA) {
            System.assertEquals(0, [SELECT Id FROM Sciagen_Account__c WHERE Id = :hco.Id].size(),
                'Removing the territory assignment must revoke visibility');
        }
    }

    @isTest
    static void accessGrantedWhenAccountMovedIntoRepsTerritory() {
        User repB = [SELECT Id FROM User WHERE LastName = 'Other' LIMIT 1];
        Territory__c otherTerritory = [SELECT Id FROM Territory__c WHERE Name = 'Test Other' LIMIT 1];

        Sciagen_Account__c newHco = new Sciagen_Account__c(Name = 'Test Other-Territory Hospital', Type__c = 'HCO');
        insert newHco;

        System.runAs(repB) {
            System.assertEquals(0, [SELECT Id FROM Sciagen_Account__c WHERE Id = :newHco.Id].size(),
                'Not yet linked to Rep B\'s territory — must not be visible yet');
        }

        insert new Account_Territory__c(Account__c = newHco.Id, Territory__c = otherTerritory.Id);

        System.runAs(repB) {
            System.assertEquals(1, [SELECT Id FROM Sciagen_Account__c WHERE Id = :newHco.Id].size(),
                'Linking the account to Rep B\'s territory must grant visibility');
        }
    }

    /**
     * Territory__c/Account_Territory__c/User_Territory__c are what CONTROL who sees which
     * accounts (via the AccountTerritoryShareSync/UserTerritoryShareSync triggers) — if a rep
     * could write to them (e.g. via the REST/SOAP API, which — unlike a plain Apex `insert` —
     * always enforces the running user's own object permissions), they could simply assign
     * themselves to every territory and grant themselves org-wide account access, bypassing
     * this whole sharing engine. Sciagen_Mobile_App_Access (and SciagenCrm) must grant Read
     * only on these three objects, never Create/Edit/Delete — checked here via isCreateable()/
     * isDeletable(), the same object-permission check the API layer enforces, since a raw
     * Apex `insert` runs in system mode for CRUD regardless of System.runAs().
     */
    @isTest
    static void repCannotWriteTerritoryAssignments() {
        User repB = [SELECT Id FROM User WHERE LastName = 'Other' LIMIT 1];

        System.runAs(repB) {
            System.assertEquals(false, Schema.SObjectType.User_Territory__c.isCreateable(),
                'A rep must not be able to self-assign into another territory');
            System.assertEquals(false, Schema.SObjectType.User_Territory__c.isDeletable(),
                'A rep must not be able to remove another user\'s territory assignment');
            System.assertEquals(false, Schema.SObjectType.Account_Territory__c.isCreateable(),
                'A rep must not be able to move accounts between territories');
            System.assertEquals(false, Schema.SObjectType.Account_Territory__c.isDeletable(),
                'A rep must not be able to unlink an account from its territory');
            System.assertEquals(false, Schema.SObjectType.Territory__c.isCreateable(),
                'A rep must not be able to create new territories');
            System.assertEquals(true, Schema.SObjectType.User_Territory__c.isAccessible(),
                'A rep still needs Read on User_Territory__c to see territory assignments in the UI');
        }
    }
}