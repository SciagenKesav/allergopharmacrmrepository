/**
 * Proves the KAM/rep territory-visibility requirement for Data_Change_Request__c without
 * creating any real, persistent Salesforce Users — same technique as
 * TerritorySharingServiceTest. System.runAs() is what makes Salesforce actually enforce
 * sharing (not just FLS) for the block it wraps.
 */
@isTest
private with sharing class DCRTerritorySharingServiceTest {

    @TestSetup
    static void setup() {
        Territory__c chennai = new Territory__c(Name = 'Test DCR Chennai', Territory_Code__c = 'TDCRC', Type__c = 'Territory');
        Territory__c otherTerritory = new Territory__c(Name = 'Test DCR Other', Territory_Code__c = 'TDCRO', Type__c = 'Territory');
        insert new List<Territory__c>{ chennai, otherTerritory };

        Profile standardProfile = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User repA = testUser('DCRRepA', 'Chennai', standardProfile.Id);
        User repB = testUser('DCRRepB', 'Other', standardProfile.Id);
        User owner = testUser('DCRRepOwner', 'Submitter', standardProfile.Id);

        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert new List<User>{ repA, repB, owner };

            PermissionSet mobileAccess = [SELECT Id FROM PermissionSet WHERE Name = 'Sciagen_Mobile_App_Access' LIMIT 1];
            insert new List<PermissionSetAssignment>{
                new PermissionSetAssignment(AssigneeId = repA.Id, PermissionSetId = mobileAccess.Id),
                new PermissionSetAssignment(AssigneeId = repB.Id, PermissionSetId = mobileAccess.Id),
                new PermissionSetAssignment(AssigneeId = owner.Id, PermissionSetId = mobileAccess.Id)
            };
        }

        // Rep A is assigned to Chennai; Rep B is assigned to a different territory entirely.
        insert new List<User_Territory__c>{
            new User_Territory__c(User__c = repA.Id, Territory__c = chennai.Id),
            new User_Territory__c(User__c = repB.Id, Territory__c = otherTerritory.Id)
        };

        Sciagen_Account__c hco = new Sciagen_Account__c(Name = 'Test DCR Chennai Hospital', Type__c = 'HCO');
        insert hco;
        insert new Account_Territory__c(Account__c = hco.Id, Territory__c = chennai.Id);

        Data_Change_Request__c editDcr = new Data_Change_Request__c(
            Type__c = 'Edit HCO', Subject_Name__c = 'Test DCR Chennai Hospital',
            Subject_Account__c = hco.Id, Status__c = 'Pending Approval', OwnerId = owner.Id
        );
        Data_Change_Request__c newHcpDcr = new Data_Change_Request__c(
            Type__c = 'New HCP', Subject_Name__c = 'Test New Doctor',
            Related_HCO__c = hco.Id, Status__c = 'Pending Approval', OwnerId = owner.Id
        );
        Data_Change_Request__c newHcoDcr = new Data_Change_Request__c(
            Type__c = 'New HCO', Subject_Name__c = 'Test Brand New Hospital',
            Status__c = 'Pending Approval', OwnerId = owner.Id
        );
        insert new List<Data_Change_Request__c>{ editDcr, newHcpDcr, newHcoDcr };
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
    static void manualShareExistsForRepAOnly_notForOwner() {
        Data_Change_Request__c dcr = [SELECT Id FROM Data_Change_Request__c WHERE Subject_Name__c = 'Test DCR Chennai Hospital' LIMIT 1];
        User repA = [SELECT Id FROM User WHERE LastName = 'Chennai' LIMIT 1];
        List<Data_Change_Request__Share> manualShares = [
            SELECT UserOrGroupId FROM Data_Change_Request__Share WHERE ParentId = :dcr.Id AND RowCause = 'Manual'
        ];
        System.assertEquals(1, manualShares.size(), 'Expected exactly one Apex-managed share');
        System.assertEquals(repA.Id, manualShares[0].UserOrGroupId, 'The share must be for Rep A, who is assigned to the subject account\'s territory');
    }

    @isTest
    static void repInTerritorySeesEditDCR_repInOtherTerritoryDoesNot() {
        User repA = [SELECT Id FROM User WHERE LastName = 'Chennai' LIMIT 1];
        User repB = [SELECT Id FROM User WHERE LastName = 'Other' LIMIT 1];
        Data_Change_Request__c dcr = [SELECT Id FROM Data_Change_Request__c WHERE Subject_Name__c = 'Test DCR Chennai Hospital' LIMIT 1];

        System.runAs(repA) {
            System.assertEquals(1, [SELECT Id FROM Data_Change_Request__c WHERE Id = :dcr.Id].size(),
                'Rep assigned to the subject account\'s territory must see the edit request');
        }
        System.runAs(repB) {
            System.assertEquals(0, [SELECT Id FROM Data_Change_Request__c WHERE Id = :dcr.Id].size(),
                'Rep assigned to a different territory must not see it');
        }
    }

    @isTest
    static void newHCPRequestDerivesSharingThroughRelatedHCO() {
        User repA = [SELECT Id FROM User WHERE LastName = 'Chennai' LIMIT 1];
        User repB = [SELECT Id FROM User WHERE LastName = 'Other' LIMIT 1];
        Data_Change_Request__c dcr = [SELECT Id FROM Data_Change_Request__c WHERE Subject_Name__c = 'Test New Doctor' LIMIT 1];

        System.runAs(repA) {
            System.assertEquals(1, [SELECT Id FROM Data_Change_Request__c WHERE Id = :dcr.Id].size(),
                'A New HCP request must be visible via its Related_HCO__c\'s territory');
        }
        System.runAs(repB) {
            System.assertEquals(0, [SELECT Id FROM Data_Change_Request__c WHERE Id = :dcr.Id].size());
        }
    }

    @isTest
    static void newHCORequestWithNoAccountYetIsVisibleToOwnerOnly() {
        User repA = [SELECT Id FROM User WHERE LastName = 'Chennai' LIMIT 1];
        Data_Change_Request__c dcr = [SELECT Id FROM Data_Change_Request__c WHERE Subject_Name__c = 'Test Brand New Hospital' LIMIT 1];

        System.runAs(repA) {
            System.assertEquals(0, [SELECT Id FROM Data_Change_Request__c WHERE Id = :dcr.Id].size(),
                'A New HCO request has no account yet to derive sharing from, so nobody but the owner can see it');
        }
    }

    @isTest
    static void accessRevokedWhenTerritoryAssignmentDeleted() {
        User repA = [SELECT Id FROM User WHERE LastName = 'Chennai' LIMIT 1];
        Data_Change_Request__c dcr = [SELECT Id FROM Data_Change_Request__c WHERE Subject_Name__c = 'Test DCR Chennai Hospital' LIMIT 1];

        System.runAs(repA) {
            System.assertEquals(1, [SELECT Id FROM Data_Change_Request__c WHERE Id = :dcr.Id].size(),
                'Sanity check: Rep A can see it before the assignment is removed');
        }

        delete [SELECT Id FROM User_Territory__c WHERE User__c = :repA.Id];

        System.runAs(repA) {
            System.assertEquals(0, [SELECT Id FROM Data_Change_Request__c WHERE Id = :dcr.Id].size(),
                'Removing the territory assignment must revoke visibility');
        }
    }

    @isTest
    static void accessGrantedWhenAccountMovedIntoRepsTerritory() {
        User repB = [SELECT Id FROM User WHERE LastName = 'Other' LIMIT 1];
        User owner = [SELECT Id FROM User WHERE LastName = 'Submitter' LIMIT 1];
        Territory__c otherTerritory = [SELECT Id FROM Territory__c WHERE Name = 'Test DCR Other' LIMIT 1];

        Sciagen_Account__c newHco = new Sciagen_Account__c(Name = 'Test DCR Other-Territory Hospital', Type__c = 'HCO');
        insert newHco;
        Data_Change_Request__c dcr = new Data_Change_Request__c(
            Type__c = 'Edit HCO', Subject_Name__c = 'Test DCR Other-Territory Hospital',
            Subject_Account__c = newHco.Id, Status__c = 'Pending Approval', OwnerId = owner.Id
        );
        insert dcr;

        System.runAs(repB) {
            System.assertEquals(0, [SELECT Id FROM Data_Change_Request__c WHERE Id = :dcr.Id].size(),
                'Not yet linked to Rep B\'s territory — must not be visible yet');
        }

        insert new Account_Territory__c(Account__c = newHco.Id, Territory__c = otherTerritory.Id);

        System.runAs(repB) {
            System.assertEquals(1, [SELECT Id FROM Data_Change_Request__c WHERE Id = :dcr.Id].size(),
                'Linking the account to Rep B\'s territory must grant visibility');
        }
    }
}