@isTest
private class AccountTerritoryAutoAssignServiceTest {

    @isTest
    static void newAccountIsAutoAssignedToOwnersPrimaryTerritory() {
        Territory__c territory = new Territory__c(Name = 'Auto Assign Territory', Territory_Code__c = 'AAT', Type__c = 'Territory');
        insert territory;
        insert new User_Territory__c(User__c = UserInfo.getUserId(), Territory__c = territory.Id, Is_Primary__c = true);

        Test.startTest();
        Sciagen_Account__c hcp = new Sciagen_Account__c(
            Type__c = 'HCP', Name = 'Dr. Auto Assign', Prefix__c = 'Dr.', First_Name__c = 'Auto',
            Last_Name__c = 'Assign', Specialty__c = 'Cardiology', HCP_Type__c = 'Physician'
        );
        insert hcp;
        Test.stopTest();

        List<Account_Territory__c> links = [SELECT Territory__c FROM Account_Territory__c WHERE Account__c = :hcp.Id];
        System.assertEquals(1, links.size());
        System.assertEquals(territory.Id, links[0].Territory__c);
    }

    @isTest
    static void newAccountIsSkippedWhenOwnerHasNoPrimaryTerritory() {
        Test.startTest();
        Sciagen_Account__c hco = new Sciagen_Account__c(
            Type__c = 'HCO', Name = 'No Territory Hospital', HCO_Type__c = 'Hospital', Speciality__c = 'Other'
        );
        insert hco;
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM Account_Territory__c WHERE Account__c = :hco.Id]);
    }

    @isTest
    static void onlyThePrimaryTerritoryIsUsedWhenOwnerHasMultiple() {
        Territory__c primary = new Territory__c(Name = 'Primary Territory', Territory_Code__c = 'PRI', Type__c = 'Territory');
        Territory__c secondary = new Territory__c(Name = 'Secondary Territory', Territory_Code__c = 'SEC', Type__c = 'Territory');
        insert new List<Territory__c>{ primary, secondary };
        insert new User_Territory__c(User__c = UserInfo.getUserId(), Territory__c = secondary.Id, Is_Primary__c = false);
        insert new User_Territory__c(User__c = UserInfo.getUserId(), Territory__c = primary.Id, Is_Primary__c = true);

        Test.startTest();
        Sciagen_Account__c hco = new Sciagen_Account__c(
            Type__c = 'HCO', Name = 'Multi Territory Hospital', HCO_Type__c = 'Hospital', Speciality__c = 'Other'
        );
        insert hco;
        Test.stopTest();

        List<Account_Territory__c> links = [SELECT Territory__c FROM Account_Territory__c WHERE Account__c = :hco.Id];
        System.assertEquals(1, links.size());
        System.assertEquals(primary.Id, links[0].Territory__c);
    }
}