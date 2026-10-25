@isTest
private class SciagenAccountRegionFilterTest {
    @isTest
    static void pickingARegionReturnsTheAccountsOfItsChildTerritories() {
        Territory__c region = new Territory__c(Name = 'TST Region', Territory_Code__c = 'TSTR', Type__c = 'Region');
        insert region;
        Territory__c child = new Territory__c(Name = 'TST Child', Territory_Code__c = 'TSTC', Type__c = 'Territory', Parent_Territory__c = region.Id);
        Territory__c other = new Territory__c(Name = 'TST Other', Territory_Code__c = 'TSTO', Type__c = 'Territory');
        insert new List<Territory__c>{ child, other };
        Sciagen_Account__c inChild = new Sciagen_Account__c(Name = 'Dr. Region Child', Type__c = 'HCP');
        Sciagen_Account__c inOther = new Sciagen_Account__c(Name = 'Dr. Region Other', Type__c = 'HCP');
        insert new List<Sciagen_Account__c>{ inChild, inOther };
        delete [SELECT Id FROM Account_Territory__c WHERE Account__c IN :new List<Id>{ inChild.Id, inOther.Id }];
        insert new List<Account_Territory__c>{
            new Account_Territory__c(Account__c = inChild.Id, Territory__c = child.Id),
            new Account_Territory__c(Account__c = inOther.Id, Territory__c = other.Id)
        };
        Test.startTest();
        List<SciagenAccountController.AccountSummary> viaRegion = SciagenAccountController.searchAccounts('Region', null, 'TST Region', null, null, null, false, false, null, true, null);
        List<SciagenAccountController.AccountSummary> viaChild = SciagenAccountController.searchAccounts('Region', null, 'TST Child', null, null, null, false, false, null, true, null);
        List<SciagenAccountController.AccountSummary> viaOther = SciagenAccountController.searchAccounts('Region', null, 'TST Region', null, null, null, false, false, null, true, null);
        Test.stopTest();
        System.assertEquals(1, viaRegion.size(), 'the region returns its child territory accounts');
        System.assertEquals('Dr. Region Child', viaRegion[0].name);
        System.assertEquals(1, viaChild.size());
        System.assertEquals(1, viaOther.size(), 'an account in an unrelated territory is not included');
        // an HCO and an HCP in the same territory must both come back (HCO names sort before "Dr." HCPs)
        Sciagen_Account__c hco = new Sciagen_Account__c(Name = 'AAA Test Hospital', Type__c = 'HCO');
        insert hco;
        delete [SELECT Id FROM Account_Territory__c WHERE Account__c = :hco.Id];
        insert new Account_Territory__c(Account__c = hco.Id, Territory__c = child.Id);
        List<SciagenAccountController.AccountSummary> both = SciagenAccountController.searchAccounts('', null, 'TST Child', null, null, null, false, false, null, true, null);
        Set<String> types = new Set<String>(); for (SciagenAccountController.AccountSummary a : both) types.add(a.type);
        System.assert(types.contains('HCP') && types.contains('HCO'), 'both HCP and HCO are returned for the territory: ' + types);
        System.assertEquals(new Set<String>{ 'TST Region', 'TST Child' }, SciagenAccountController.territoryNamesWithChildren('TST Region'));
        System.assertEquals(new Set<String>{ 'TST Other' }, SciagenAccountController.territoryNamesWithChildren('TST Other'));
    }
}