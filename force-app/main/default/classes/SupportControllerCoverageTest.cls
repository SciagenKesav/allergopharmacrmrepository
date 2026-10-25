@isTest
private class SupportControllerCoverageTest {

    @testSetup
    static void setup() {
        User mgr = SciagenTestUsers.rep('scctmgr', new List<String>{ 'Sciagen_Mobile_App_Access' });
        SciagenTestUsers.rep('scctrep', new List<String>{ 'Sciagen_Mobile_App_Access' }, mgr.Id);
        Territory__c region = new Territory__c(Name = 'SCCT Region', Territory_Code__c = 'SCCTR', Type__c = 'Region');
        insert region;
    }

    private static User rep() { return [SELECT Id FROM User WHERE Alias = 'scctrep' LIMIT 1]; }

    @isTest
    static void contextMessagesAndStatusChanges() {
        User rep = rep();
        Id reqId;
        System.runAs(rep) {
            SupportController.Context c = SupportController.getContext();
            System.assertNotEquals(null, c.managerName);
            System.assertEquals(false, c.canAdminView);
            System.assert(!c.categories.isEmpty());
            reqId = SupportController.createRequest('Coverage', 'Details', 'Sync Problem', null, null, 'cid-1');
            System.assertEquals(reqId, SupportController.createRequest('Coverage', 'Details', 'Sync Problem', null, null, 'cid-1'));
            try { SupportController.createRequest(' ', 'x', 'Other', 'Normal', null, null); System.assert(false); } catch (AuraHandledException e) { System.assert(true); }

            Id m1 = SupportController.addMessage(reqId, 'Hello', 'mid-1');
            System.assertEquals(m1, SupportController.addMessage(reqId, 'Hello', 'mid-1'));
            System.assertNotEquals(null, SupportController.addMessage(reqId, 'Again', null));
            try { SupportController.addMessage(null, 'x', null); System.assert(false); } catch (AuraHandledException e) { System.assert(true); }

            System.assertNotEquals(null, SupportController.getRequest(reqId));
            SupportController.markRead(reqId);
            SupportController.markRead(UserInfo.getUserId());
            SupportListService.Filter f = new SupportListService.Filter();
            f.view = 'all';
            System.assertEquals(1, SupportController.listRequests(f).rows.size());
            System.assertEquals(1, SupportController.listRequests(null).rows.size());

            SupportController.cancelRequest(reqId);
            System.assertEquals('Cancelled', [SELECT Status__c FROM Support_Request__c WHERE Id = :reqId].Status__c);
            try { SupportController.reopenRequest(reqId); } catch (AuraHandledException e) { System.assert(e.getMessage() != null); }
            try { SupportController.cancelRequest(null); System.assert(false); } catch (Exception e) { System.assert(true); }
            System.assertNotEquals(null, SupportController.myCallsForUnlock());
        }
    }

    @isTest
    static void adminViewEdges() {
        System.assertEquals(0, SupportController.getKamsForTerritory(null).size());
        Id region = [SELECT Id FROM Territory__c WHERE Name = 'SCCT Region'].Id;
        System.assertEquals(0, SupportController.getKamsForTerritory(region).size());
        try { SupportController.listRequestsForKam(null, null); System.assert(false); } catch (AuraHandledException e) { System.assert(true); }
        System.assertNotEquals(null, SupportController.listRequestsForKam(null, rep().Id));
        try { SupportController.closeRequestAsAdmin(UserInfo.getUserId()); System.assert(false); } catch (Exception e) { System.assert(true); }

        Id reqId;
        System.runAs(rep()) { reqId = SupportController.createRequest('Admin close', 'x', 'Other', 'Low', null, null); }
        SupportController.closeRequestAsAdmin(reqId);
        System.assertEquals('Closed', [SELECT Status__c FROM Support_Request__c WHERE Id = :reqId].Status__c);
    }

    @isTest
    static void uploadFileRules() {
        User rep = rep();
        Id reqId;
        Id commentId;
        System.runAs(rep) {
            reqId = SupportController.createRequest('Upload', 'x', 'Other', 'Low', null, null);
            commentId = SupportController.addMessage(reqId, 'with file', null);
            String b64 = EncodingUtil.base64Encode(Blob.valueOf('hello'));
            System.assertNotEquals(null, SupportController.uploadFile(reqId, 'a.txt', b64));
            System.assertNotEquals(null, SupportController.uploadFile(commentId, 'b.png', b64));
            try { SupportController.uploadFile(UserInfo.getUserId(), 'a.txt', b64); System.assert(false); } catch (AuraHandledException e) { System.assert(true); }
            try { SupportController.uploadFile(reqId, 'a.exe', b64); System.assert(false); } catch (AuraHandledException e) { System.assert(true); }
            try { SupportController.uploadFile(reqId, null, b64); System.assert(false); } catch (AuraHandledException e) { System.assert(true); }
            String big = EncodingUtil.base64Encode(Blob.valueOf('x'.repeat(4 * 1024 * 1024 + 1)));
            try { SupportController.uploadFile(reqId, 'big.txt', big); System.assert(false); } catch (AuraHandledException e) { System.assert(true); }
        }
        // someone with no access to the request
        User other = SciagenTestUsers.make('scctoth', 'Minimum Access - Salesforce', null, null);
        String b64 = EncodingUtil.base64Encode(Blob.valueOf('hello'));
        System.runAs(other) {
            // Whether this user can see the record depends on the org's sharing; either outcome must be a clean result, never an unhandled crash.
            try { SupportController.uploadFile(reqId, 'a.txt', b64); } catch (AuraHandledException e) { System.assert(e.getMessage() != null); } catch (QueryException e) { System.assert(e.getMessage() != null); }
            try { SupportController.uploadFile(commentId, 'a.txt', b64); } catch (AuraHandledException e) { System.assert(e.getMessage() != null); } catch (QueryException e) { System.assert(e.getMessage() != null); }
        }
    }

    @isTest
    static void adminListsKamsUnderARegionAndRepSeesSubmittedCalls() {
        User kam = SciagenTestUsers.make('scctkam', 'Key Account Manager', new List<String>{ 'Sciagen_Mobile_App_Access' }, null);
        Territory__c region = [SELECT Id FROM Territory__c WHERE Name = 'SCCT Region'];
        Territory__c child = new Territory__c(Name = 'SCCT City', Territory_Code__c = 'SCCTC', Type__c = 'Territory', Parent_Territory__c = region.Id);
        insert child;
        insert new User_Territory__c(User__c = kam.Id, Territory__c = child.Id, Is_Primary__c = true);
        List<SupportController.KamOption> kams = SupportController.getKamsForTerritory(region.Id);
        System.assertEquals(1, kams.size());
        System.assertEquals(kam.Id, kams[0].id);
        System.assertEquals('SCCT City', kams[0].territoryName);

        System.runAs(kam) {
            Sciagen_Account__c hcp = SampleTestData.doctor('Dr Coverage ' + kam.Id);
            SampleTestData.call(hcp, 'Submitted');
            List<SupportController.CallOption> calls = SupportController.myCallsForUnlock();
            System.assertEquals(1, calls.size());
            System.assert(calls[0].label.contains('Dr Coverage'));
        }
    }
}
