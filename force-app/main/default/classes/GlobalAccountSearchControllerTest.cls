@isTest
private with sharing class GlobalAccountSearchControllerTest {

    @TestSetup
    static void setup() {
        Territory__c chennai = new Territory__c(Name = 'Test GAS Chennai', Territory_Code__c = 'GASC', Type__c = 'Territory');
        Territory__c other = new Territory__c(Name = 'Test GAS Other', Territory_Code__c = 'GASO', Type__c = 'Territory');
        insert new List<Territory__c>{ chennai, other };

        Profile standardProfile = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User repB = testUser('GasRepB', 'Other', standardProfile.Id);
        User repNoTerritory = testUser('GasRepC', 'NoTerritory', standardProfile.Id);

        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert new List<User>{ repB, repNoTerritory };
            PermissionSet mobileAccess = [SELECT Id FROM PermissionSet WHERE Name = 'Sciagen_Mobile_App_Access' LIMIT 1];
            insert new List<PermissionSetAssignment>{
                new PermissionSetAssignment(AssigneeId = repB.Id, PermissionSetId = mobileAccess.Id),
                new PermissionSetAssignment(AssigneeId = repNoTerritory.Id, PermissionSetId = mobileAccess.Id)
            };
        }

        insert new User_Territory__c(User__c = repB.Id, Territory__c = other.Id, Is_Primary__c = true);

        Sciagen_Account__c hcp = new Sciagen_Account__c(
            Name = 'Dr. GAS Test Rao', Type__c = 'HCP', First_Name__c = 'GAS', Last_Name__c = 'Rao',
            Billing_City__c = 'Chennai'
        );
        insert hcp;
        insert new Account_Territory__c(Account__c = hcp.Id, Territory__c = chennai.Id);
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
    static void searchRequiresAtLeastOneField() {
        User repB = [SELECT Id FROM User WHERE LastName = 'Other' LIMIT 1];
        System.runAs(repB) {
            try {
                GlobalAccountSearchController.search(JSON.serialize(new GlobalAccountSearchController.SearchCriteria()));
                System.assert(false, 'Expected an exception for an empty search');
            } catch (AuraHandledException e) {
                // expected
            }
        }
    }

    @isTest
    static void searchThrowsForBlankCriteriaJson() {
        User repB = [SELECT Id FROM User WHERE LastName = 'Other' LIMIT 1];
        System.runAs(repB) {
            try {
                GlobalAccountSearchController.search('');
                System.assert(false, 'Expected an exception for blank criteria JSON');
            } catch (AuraHandledException e) {
                // expected
            }
        }
    }

    @isTest
    static void searchRejectsNameCombinedWithFirstOrLastName() {
        User repB = [SELECT Id FROM User WHERE LastName = 'Other' LIMIT 1];
        GlobalAccountSearchController.SearchCriteria criteria = new GlobalAccountSearchController.SearchCriteria();
        criteria.name = 'Rao';
        criteria.lastName = 'Rao';
        System.runAs(repB) {
            try {
                GlobalAccountSearchController.search(JSON.serialize(criteria));
                System.assert(false, 'Expected an exception when Name and Last Name are both set');
            } catch (AuraHandledException e) {
                // expected
            }
        }
    }

    @isTest
    static void searchFindsAccountOutsideRunningUsersTerritory() {
        User repB = [SELECT Id FROM User WHERE LastName = 'Other' LIMIT 1];

        System.runAs(repB) {
            // Sanity check: Rep B can't see this account through normal sharing —
            // it belongs to a different territory than the one Rep B is assigned to.
            System.assertEquals(0, [SELECT Id FROM Sciagen_Account__c WHERE Name = 'Dr. GAS Test Rao'].size(),
                'Sanity check: normal sharing should hide this account from Rep B');

            GlobalAccountSearchController.SearchCriteria criteria = new GlobalAccountSearchController.SearchCriteria();
            criteria.lastName = 'Rao';
            List<GlobalAccountSearchController.SearchResultRow> results = GlobalAccountSearchController.search(JSON.serialize(criteria));

            System.assertEquals(1, results.size(), 'Global search must find the account regardless of territory sharing');
            System.assertEquals('Dr. GAS Test Rao', results[0].name);
            System.assertEquals(false, results[0].inMyTerritory);
        }
    }

    @isTest
    static void addToMyTerritoryGrantsVisibility() {
        User repB = [SELECT Id FROM User WHERE LastName = 'Other' LIMIT 1];
        Sciagen_Account__c hcp = [SELECT Id FROM Sciagen_Account__c WHERE Name = 'Dr. GAS Test Rao' LIMIT 1];

        System.runAs(repB) {
            Test.startTest();
            GlobalAccountSearchController.addToMyTerritory(new List<Id>{ hcp.Id });
            Test.stopTest();

            System.assertEquals(1, [SELECT Id FROM Sciagen_Account__c WHERE Id = :hcp.Id].size(),
                'Adding the account to Rep B\'s territory must grant normal sharing visibility');

            GlobalAccountSearchController.SearchCriteria criteria = new GlobalAccountSearchController.SearchCriteria();
            criteria.lastName = 'Rao';
            List<GlobalAccountSearchController.SearchResultRow> results = GlobalAccountSearchController.search(JSON.serialize(criteria));
            System.assertEquals(true, results[0].inMyTerritory, 'Account should now report as in Rep B\'s territory');
        }
    }

    @isTest
    static void addToMyTerritoryDoesNothingForEmptyList() {
        User repB = [SELECT Id FROM User WHERE LastName = 'Other' LIMIT 1];
        Territory__c other = [SELECT Id FROM Territory__c WHERE Name = 'Test GAS Other' LIMIT 1];
        System.runAs(repB) {
            GlobalAccountSearchController.addToMyTerritory(new List<Id>());
            GlobalAccountSearchController.addToMyTerritory(null);
        }
        System.assertEquals(0, [SELECT Id FROM Account_Territory__c WHERE Territory__c = :other.Id].size(),
            'No territory link should have been created for an empty/null list');
    }

    @isTest
    static void addToMyTerritoryThrowsWhenUserHasNoTerritory() {
        User repNoTerritory = [SELECT Id FROM User WHERE LastName = 'NoTerritory' LIMIT 1];
        Sciagen_Account__c hcp = [SELECT Id FROM Sciagen_Account__c WHERE Name = 'Dr. GAS Test Rao' LIMIT 1];
        System.runAs(repNoTerritory) {
            try {
                GlobalAccountSearchController.addToMyTerritory(new List<Id>{ hcp.Id });
                System.assert(false, 'Expected an exception for a user with no territory assignment');
            } catch (AuraHandledException e) {
                // expected
            }
        }
    }

    @isTest
    static void addToMyTerritorySkipsAccountAlreadyLinked() {
        User repB = [SELECT Id FROM User WHERE LastName = 'Other' LIMIT 1];
        Territory__c other = [SELECT Id FROM Territory__c WHERE Name = 'Test GAS Other' LIMIT 1];
        Sciagen_Account__c hcp = [SELECT Id FROM Sciagen_Account__c WHERE Name = 'Dr. GAS Test Rao' LIMIT 1];

        System.runAs(repB) {
            GlobalAccountSearchController.addToMyTerritory(new List<Id>{ hcp.Id });
            // Calling it again for the same account must not create a duplicate link or error.
            GlobalAccountSearchController.addToMyTerritory(new List<Id>{ hcp.Id });
        }

        System.assertEquals(1, [SELECT Id FROM Account_Territory__c WHERE Account__c = :hcp.Id AND Territory__c = :other.Id].size(),
            'Adding the same account twice must not create a duplicate Account_Territory__c row for Rep B\'s territory');
    }
}