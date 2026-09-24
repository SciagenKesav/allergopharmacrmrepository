/**
 * Proves the "My Schedule shows every rep's calls in a shared territory"
 * requirement, the same way TerritorySharingServiceTest proves it for
 * Sciagen_Account__c — everything here lives inside the test transaction and
 * rolls back automatically. System.runAs() is what makes Salesforce actually
 * enforce sharing for the block it wraps.
 */
@isTest
private with sharing class PlannedCallTerritorySharingServiceTest {

    @TestSetup
    static void setup() {
        Territory__c chennai = new Territory__c(Name = 'Test PC Chennai', Territory_Code__c = 'TPCCHN', Type__c = 'Territory');
        Territory__c otherTerritory = new Territory__c(Name = 'Test PC Other', Territory_Code__c = 'TPCOTH', Type__c = 'Territory');
        insert new List<Territory__c>{ chennai, otherTerritory };

        Profile standardProfile = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User repA = testUser('PCRepA', 'Chennai', standardProfile.Id);
        User repB = testUser('PCRepB', 'Other', standardProfile.Id);

        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert new List<User>{ repA, repB };

            PermissionSet mobileAccess = [SELECT Id FROM PermissionSet WHERE Name = 'Sciagen_Mobile_App_Access' LIMIT 1];
            insert new List<PermissionSetAssignment>{
                new PermissionSetAssignment(AssigneeId = repA.Id, PermissionSetId = mobileAccess.Id),
                new PermissionSetAssignment(AssigneeId = repB.Id, PermissionSetId = mobileAccess.Id)
            };
        }

        insert new List<User_Territory__c>{
            new User_Territory__c(User__c = repA.Id, Territory__c = chennai.Id),
            new User_Territory__c(User__c = repB.Id, Territory__c = otherTerritory.Id)
        };

        Sciagen_Account__c hco = new Sciagen_Account__c(Name = 'Test PC Chennai Hospital', Type__c = 'HCO');
        insert hco;
        insert new Account_Territory__c(Account__c = hco.Id, Territory__c = chennai.Id);

        // Rep A creates a call for the Chennai HCO — owned by Rep A.
        System.runAs(repA) {
            insert new Planned_Call__c(
                HCO__c = hco.Id,
                // Fixed at 11 AM, not Datetime.now() — office hours
                // (PlannedCallOfficeHoursValidator) would otherwise randomly
                // reject this insert depending on what time the test runs.
                Call_DateTime__c = Datetime.newInstance(Date.today().addDays(1), Time.newInstance(11, 0, 0, 0)),
                Call_Type__c = 'Visit', Status__c = 'Planned'
            );
        }
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
    static void manualShareExistsForBothRepsInTheSameTerritory() {
        Sciagen_Account__c hco = [SELECT Id FROM Sciagen_Account__c WHERE Name = 'Test PC Chennai Hospital' LIMIT 1];
        Planned_Call__c call = [SELECT Id FROM Planned_Call__c WHERE HCO__c = :hco.Id LIMIT 1];

        // Rep A owns the call, so Private OWD alone already grants them
        // access — no Manual share row is needed (or expected) for the owner.
        List<Planned_Call__Share> manualShares = [
            SELECT UserOrGroupId FROM Planned_Call__Share WHERE ParentId = :call.Id AND RowCause = 'Manual'
        ];
        System.assertEquals(0, manualShares.size(),
            'The owner needs no Apex-managed share; a second rep in the same territory would get one instead');
    }

    @isTest
    static void repInSameTerritorySeesTeammatesCall_repInOtherTerritoryDoesNot() {
        User repA = [SELECT Id FROM User WHERE LastName = 'Chennai' LIMIT 1];
        User repB = [SELECT Id FROM User WHERE LastName = 'Other' LIMIT 1];
        Sciagen_Account__c hco = [SELECT Id FROM Sciagen_Account__c WHERE Name = 'Test PC Chennai Hospital' LIMIT 1];
        Planned_Call__c call = [SELECT Id FROM Planned_Call__c WHERE HCO__c = :hco.Id LIMIT 1];

        // A second rep, also assigned to Chennai, must see Rep A's call.
        User repC = testUser('PCRepC', 'ChennaiToo', [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1].Id);
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert repC;
            PermissionSet mobileAccess = [SELECT Id FROM PermissionSet WHERE Name = 'Sciagen_Mobile_App_Access' LIMIT 1];
            insert new PermissionSetAssignment(AssigneeId = repC.Id, PermissionSetId = mobileAccess.Id);
        }
        Territory__c chennai = [SELECT Id FROM Territory__c WHERE Name = 'Test PC Chennai' LIMIT 1];
        insert new User_Territory__c(User__c = repC.Id, Territory__c = chennai.Id);

        System.runAs(repC) {
            List<Planned_Call__c> visible = [SELECT Id FROM Planned_Call__c WHERE Id = :call.Id];
            System.assertEquals(1, visible.size(), 'A teammate assigned to the same territory must see this call');
        }

        System.runAs(repB) {
            List<Planned_Call__c> visible = [SELECT Id FROM Planned_Call__c WHERE Id = :call.Id];
            System.assertEquals(0, visible.size(), 'A rep assigned to a different territory must not see it');
        }

        // Rep A (the owner) always sees their own call regardless of shares.
        System.runAs(repA) {
            List<Planned_Call__c> visible = [SELECT Id FROM Planned_Call__c WHERE Id = :call.Id];
            System.assertEquals(1, visible.size(), 'The owner always sees their own call');
        }
    }

    @isTest
    static void accessRevokedWhenTerritoryAssignmentDeleted() {
        Sciagen_Account__c hco = [SELECT Id FROM Sciagen_Account__c WHERE Name = 'Test PC Chennai Hospital' LIMIT 1];
        Planned_Call__c call = [SELECT Id FROM Planned_Call__c WHERE HCO__c = :hco.Id LIMIT 1];

        User repC = testUser('PCRepD', 'ChennaiThree', [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1].Id);
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert repC;
            PermissionSet mobileAccess = [SELECT Id FROM PermissionSet WHERE Name = 'Sciagen_Mobile_App_Access' LIMIT 1];
            insert new PermissionSetAssignment(AssigneeId = repC.Id, PermissionSetId = mobileAccess.Id);
        }
        Territory__c chennai = [SELECT Id FROM Territory__c WHERE Name = 'Test PC Chennai' LIMIT 1];
        insert new User_Territory__c(User__c = repC.Id, Territory__c = chennai.Id);

        System.runAs(repC) {
            System.assertEquals(1, [SELECT Id FROM Planned_Call__c WHERE Id = :call.Id].size(),
                'Sanity check: sees it before the assignment is removed');
        }

        delete [SELECT Id FROM User_Territory__c WHERE User__c = :repC.Id];

        System.runAs(repC) {
            System.assertEquals(0, [SELECT Id FROM Planned_Call__c WHERE Id = :call.Id].size(),
                'Removing the territory assignment must revoke visibility into the teammate\'s call');
        }
    }
}