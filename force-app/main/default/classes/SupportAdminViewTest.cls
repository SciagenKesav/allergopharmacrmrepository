@isTest
private class SupportAdminViewTest {

    @testSetup
    static void setup() {
        Profile kamProfile = [SELECT Id FROM Profile WHERE Name = 'Key Account Manager' LIMIT 1];
        User kam = new User(FirstName = 'Support', LastName = 'AdminViewKam', Alias = 'sadvk', Email = 'sadv.kam@sciagen-test.invalid',
            Username = 'sadv.kam@sciagen-new-dev.invalid', TimeZoneSidKey = 'Asia/Kolkata', LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US', ProfileId = kamProfile.Id, IsActive = true);
        // User / permission-set rows are setup objects: a runAs block keeps them out of the transaction that
        // inserts the territories below (otherwise MIXED_DML_OPERATION).
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert kam;
            Id mobile = [SELECT Id FROM PermissionSet WHERE Name = 'Sciagen_Mobile_App_Access'].Id;
            insert new PermissionSetAssignment(AssigneeId = kam.Id, PermissionSetId = mobile);
        }

        Territory__c region = new Territory__c(Name = 'SAV Region', Territory_Code__c = 'SAVR', Type__c = 'Region');
        insert region;
        Territory__c child = new Territory__c(Name = 'SAV City', Territory_Code__c = 'SAVC', Type__c = 'Territory', Parent_Territory__c = region.Id);
        insert child;
        insert new User_Territory__c(User__c = kam.Id, Territory__c = child.Id, Is_Primary__c = true);
    }

    private static User kam() { return [SELECT Id FROM User WHERE Username = 'sadv.kam@sciagen-new-dev.invalid']; }

    private static Id raise(User rep) {
        Id id;
        System.runAs(rep) { id = SupportController.createRequest('Admin view test', 'Details', 'Sync Problem', 'Normal', null, null); }
        return id;
    }

    @isTest
    static void adminPicksTerritoryThenKamThenSeesRequestsAndCanCloseIt() {
        User kam = kam();
        Id reqId = raise(kam);

        // The test runs as a System Administrator.
        System.assertEquals(true, SupportController.getContext().canAdminView);

        Set<String> parents = new Set<String>();
        for (SupportController.TerritoryOption t : SupportController.getParentTerritories()) parents.add(t.name);
        System.assert(parents.contains('SAV Region'), 'The region (parent territory) is offered');
        System.assert(!parents.contains('SAV City'), 'A child territory is not offered');

        List<SupportController.KamOption> kams = SupportController.getKamsForTerritory([SELECT Id FROM Territory__c WHERE Name = 'SAV Region'].Id);
        Boolean found = false;
        for (SupportController.KamOption k : kams) if (k.id == kam.Id) found = true;
        System.assert(found, 'A KAM in a child territory is listed under the parent territory');

        SupportListService.Filter f = new SupportListService.Filter();
        f.view = 'all';
        SupportListService.ListPage page = SupportController.listRequestsForKam(f, kam.Id);
        System.assertEquals(1, page.rows.size());
        System.assertEquals(reqId, page.rows[0].id);

        SupportController.closeRequestAsAdmin(reqId);
        System.assertEquals('Closed', [SELECT Status__c FROM Support_Request__c WHERE Id = :reqId].Status__c);
        try {
            SupportController.closeRequestAsAdmin(reqId);
            System.assert(false, 'Closing twice should be rejected');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('already closed') || e.getMessage().contains('Script-thrown'));
        }
    }

    @isTest
    static void aKamCannotUseTheAdminViewOrSeeSomeoneElsesList() {
        User kam = kam();
        raise(kam);
        System.runAs(kam) {
            System.assertEquals(false, SupportController.getContext().canAdminView);
            try { SupportController.getParentTerritories(); System.assert(false, 'blocked'); } catch (AuraHandledException e) { System.assert(true); }
            try { SupportController.closeRequestAsAdmin(null); System.assert(false, 'blocked'); } catch (AuraHandledException e) { System.assert(true); }
            // A rep's normal list ignores any requester the client tries to pass.
            SupportListService.Filter f = new SupportListService.Filter();
            f.view = 'all';
            f.requesterId = String.valueOf(UserInfo.getUserId());
            System.assertEquals(1, SupportController.listRequests(f).rows.size());
        }
    }
}