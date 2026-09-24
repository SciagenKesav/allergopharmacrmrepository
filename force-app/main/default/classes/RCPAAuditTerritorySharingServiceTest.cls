/**
 * Proves RCPA_Audit__c's "a rep sees another rep's audit iff they share a
 * Territory__c" requirement, the same way PlannedCallTerritorySharingServiceTest
 * proves it for Planned_Call__c — everything here lives inside the test
 * transaction and rolls back automatically. System.runAs() is what makes
 * Salesforce actually enforce sharing for the block it wraps.
 */
@isTest
private with sharing class RCPAAuditTerritorySharingServiceTest {

    @TestSetup
    static void setup() {
        Territory__c chennai = new Territory__c(Name = 'Test RCPA Chennai', Territory_Code__c = 'TRCPACHN', Type__c = 'Territory');
        Territory__c otherTerritory = new Territory__c(Name = 'Test RCPA Other', Territory_Code__c = 'TRCPAOTH', Type__c = 'Territory');
        insert new List<Territory__c>{ chennai, otherTerritory };

        Profile standardProfile = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User repA = testUser('RARepA', 'Chennai', standardProfile.Id);
        User repB = testUser('RARepB', 'Other', standardProfile.Id);

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

        Sciagen_Account__c chemist = new Sciagen_Account__c(Name = 'Test RCPA Chennai Chemist', Type__c = 'HCO');
        insert chemist;
        // Sciagen_Account__c is itself Private OWD — Rep A needs this link so
        // TerritorySharingService grants them read access to `chemist` before
        // they can reference it as Chemist__c below (a separate sharing
        // requirement from RCPA_Audit__c's own, which this test is about).
        insert new Account_Territory__c(Account__c = chemist.Id, Territory__c = chennai.Id);

        // Rep A creates an audit assigned to Chennai — owned by Rep A.
        System.runAs(repA) {
            insert new RCPA_Audit__c(
                Chemist__c = chemist.Id, Audit_Date__c = Date.today(),
                Territory__c = chennai.Id, Status__c = 'Draft'
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
    static void manualShareExistsOnlyForTeammatesNotTheOwner() {
        RCPA_Audit__c audit = [SELECT Id FROM RCPA_Audit__c WHERE Chemist__r.Name = 'Test RCPA Chennai Chemist' LIMIT 1];

        // Rep A owns the audit, so Private OWD alone already grants them
        // access — no Manual share row is needed (or expected) for the owner.
        List<RCPA_Audit__Share> manualShares = [
            SELECT UserOrGroupId FROM RCPA_Audit__Share WHERE ParentId = :audit.Id AND RowCause = 'Manual'
        ];
        System.assertEquals(0, manualShares.size(),
            'The owner needs no Apex-managed share; a second rep in the same territory would get one instead');
    }

    @isTest
    static void repInSameTerritorySeesTeammatesAudit_repInOtherTerritoryDoesNot() {
        User repA = [SELECT Id FROM User WHERE LastName = 'Chennai' LIMIT 1];
        User repB = [SELECT Id FROM User WHERE LastName = 'Other' LIMIT 1];
        RCPA_Audit__c audit = [SELECT Id FROM RCPA_Audit__c WHERE Chemist__r.Name = 'Test RCPA Chennai Chemist' LIMIT 1];

        // A second rep, also assigned to Chennai, must see Rep A's audit.
        User repC = testUser('RARepC', 'ChennaiToo', [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1].Id);
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert repC;
            PermissionSet mobileAccess = [SELECT Id FROM PermissionSet WHERE Name = 'Sciagen_Mobile_App_Access' LIMIT 1];
            insert new PermissionSetAssignment(AssigneeId = repC.Id, PermissionSetId = mobileAccess.Id);
        }
        Territory__c chennai = [SELECT Id FROM Territory__c WHERE Name = 'Test RCPA Chennai' LIMIT 1];
        insert new User_Territory__c(User__c = repC.Id, Territory__c = chennai.Id);

        System.runAs(repC) {
            List<RCPA_Audit__c> visible = [SELECT Id FROM RCPA_Audit__c WHERE Id = :audit.Id];
            System.assertEquals(1, visible.size(), 'A teammate assigned to the same territory must see this audit');
        }

        System.runAs(repB) {
            List<RCPA_Audit__c> visible = [SELECT Id FROM RCPA_Audit__c WHERE Id = :audit.Id];
            System.assertEquals(0, visible.size(), 'A rep assigned to a different territory must not see it');
        }

        // Rep A (the owner) always sees their own audit regardless of shares.
        System.runAs(repA) {
            List<RCPA_Audit__c> visible = [SELECT Id FROM RCPA_Audit__c WHERE Id = :audit.Id];
            System.assertEquals(1, visible.size(), 'The owner always sees their own audit');
        }
    }

    @isTest
    static void accessRevokedWhenTerritoryAssignmentDeleted() {
        RCPA_Audit__c audit = [SELECT Id FROM RCPA_Audit__c WHERE Chemist__r.Name = 'Test RCPA Chennai Chemist' LIMIT 1];

        User repC = testUser('RARepD', 'ChennaiThree', [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1].Id);
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert repC;
            PermissionSet mobileAccess = [SELECT Id FROM PermissionSet WHERE Name = 'Sciagen_Mobile_App_Access' LIMIT 1];
            insert new PermissionSetAssignment(AssigneeId = repC.Id, PermissionSetId = mobileAccess.Id);
        }
        Territory__c chennai = [SELECT Id FROM Territory__c WHERE Name = 'Test RCPA Chennai' LIMIT 1];
        insert new User_Territory__c(User__c = repC.Id, Territory__c = chennai.Id);

        System.runAs(repC) {
            System.assertEquals(1, [SELECT Id FROM RCPA_Audit__c WHERE Id = :audit.Id].size(),
                'Sanity check: sees it before the assignment is removed');
        }

        delete [SELECT Id FROM User_Territory__c WHERE User__c = :repC.Id];

        System.runAs(repC) {
            System.assertEquals(0, [SELECT Id FROM RCPA_Audit__c WHERE Id = :audit.Id].size(),
                'Removing the territory assignment must revoke visibility into the teammate\'s audit');
        }
    }
}