@isTest
private class SciagenAccountAdminScopeTest {

    @isTest
    static void aBusinessAdminWithNoTerritoryStillSeesAccountsAndEveryTerritory() {
        Profile ba = [SELECT Id FROM Profile WHERE Name = 'Business Admin' LIMIT 1];
        User admin = new User(
            Alias = 'baacct', Email = 'baacct@example.com', EmailEncodingKey = 'UTF-8', LastName = 'BaScopeTest',
            LanguageLocaleKey = 'en_US', LocaleSidKey = 'en_US', ProfileId = ba.Id, TimeZoneSidKey = 'Asia/Kolkata',
            Username = 'baacct' + System.currentTimeMillis() + '@example.com'
        );
        System.runAs(new User(Id = UserInfo.getUserId())) { insert admin; }

        Sciagen_Account__c hco = new Sciagen_Account__c(Type__c = 'HCO', Name = 'BA Scope Hospital', HCO_Type__c = 'Hospital', Speciality__c = 'Other');
        insert hco;
        Territory__c terr = new Territory__c(Name = 'BA Scope Territory', Territory_Code__c = 'BAS', Type__c = 'Territory');
        insert terr;
        insert new Account_Territory__c(Name = 'link', Account__c = hco.Id, Territory__c = terr.Id);

        // Owned by the admin so Private sharing lets them read it -- what this test pins down is the
        // *territory* rule: they have no territory, and the account sits in one that is not theirs.
        hco.OwnerId = admin.Id;
        update hco;
        System.runAs(admin) {
            List<SciagenAccountController.AccountSummary> found = SciagenAccountController.searchAccounts(
                'BA Scope', 'HCO', '', '', '', '', false, false, 'Name', true, '');
            System.assertEquals(1, found.size(), 'A Business Admin with no territory still sees the account');
            System.assert(SciagenAccountController.getTerritoryOptions().contains('BA Scope Territory'), 'and the full territory list');
        }
    }
}