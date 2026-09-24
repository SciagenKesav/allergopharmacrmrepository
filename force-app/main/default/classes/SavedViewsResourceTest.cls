@isTest
private class SavedViewsResourceTest {

    @isTest
    static void testGetReturnsTheAuthenticatedUsersOwnAndBusinessAdminViews() {
        Profile businessAdmin = [SELECT Id FROM Profile WHERE Name = 'Business Admin' LIMIT 1];
        Profile standardUser = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User admin = new User(FirstName = 'Ops', LastName = 'Admin SavedViewsResourceTest', Alias = 'opsad2', Email = 'ops.admin.svr@sciagen-test.invalid',
            Username = 'ops.admin.svr@sciagen-new-dev.invalid', TimeZoneSidKey = 'Asia/Kolkata', LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US', ProfileId = businessAdmin.Id, IsActive = true);
        User rep = new User(FirstName = 'Field', LastName = 'Rep SavedViewsResourceTest', Alias = 'fldrp2', Email = 'field.rep.svr@sciagen-test.invalid',
            Username = 'field.rep.svr@sciagen-new-dev.invalid', TimeZoneSidKey = 'Asia/Kolkata', LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US', ProfileId = standardUser.Id, IsActive = true);
        insert new List<User>{ admin, rep };
        Id mobileAccessId = [SELECT Id FROM PermissionSet WHERE Name = 'Sciagen_Mobile_App_Access'].Id;
        insert new List<PermissionSetAssignment>{
            new PermissionSetAssignment(AssigneeId = admin.Id, PermissionSetId = mobileAccessId),
            new PermissionSetAssignment(AssigneeId = rep.Id, PermissionSetId = mobileAccessId)
        };

        System.runAs(admin) {
            SciagenAccountController.saveView(null, 'Org Standard - Oncology', '{"specialties":["Oncology"]}', 'Name', true, 'List');
        }

        Test.startTest();
        String body;
        System.runAs(rep) {
            RestRequest req = new RestRequest();
            req.requestURI = '/services/apexrest/sciagen/v1/savedViews';
            req.httpMethod = 'GET';
            RestContext.request = req;
            RestContext.response = new RestResponse();

            SavedViewsResource.getSavedViews();
            body = RestContext.response.responseBody.toString();
        }
        Test.stopTest();

        System.assert(body.contains('Org Standard - Oncology'),
            'The REST endpoint should surface the Business Admin\'s shared view to a non-admin rep, same as the web CRM does: ' + body);
    }

    // Matches the iPad app's own ISO8601DateFormatter(.withInternetDateTime)
    // output exactly (e.g. "2026-09-24T11:52:00Z") — what the `since` query
    // param actually looks like in real traffic, not Apex's default
    // Datetime.toString() format (which JSON.deserialize can't parse as one).
    private static String isoUtc(Datetime dt) {
        return dt.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');
    }

    @isTest
    static void testSinceParamFiltersOutViewsNotRecentlyModified() {
        Id viewId = SciagenAccountController.saveView(null, 'Delta Sync Test View', '{"specialties":["Neurology"]}', 'Name', true, 'List');

        Test.startTest();
        RestRequest futureReq = new RestRequest();
        futureReq.requestURI = '/services/apexrest/sciagen/v1/savedViews';
        futureReq.httpMethod = 'GET';
        futureReq.params.put('since', isoUtc(Datetime.now().addDays(1)));
        RestContext.request = futureReq;
        RestContext.response = new RestResponse();
        SavedViewsResource.getSavedViews();
        String futureBody = RestContext.response.responseBody.toString();

        RestRequest pastReq = new RestRequest();
        pastReq.requestURI = '/services/apexrest/sciagen/v1/savedViews';
        pastReq.httpMethod = 'GET';
        pastReq.params.put('since', isoUtc(Datetime.now().addDays(-1)));
        RestContext.request = pastReq;
        RestContext.response = new RestResponse();
        SavedViewsResource.getSavedViews();
        String pastBody = RestContext.response.responseBody.toString();
        Test.stopTest();

        System.assert(!futureBody.contains('Delta Sync Test View'),
            'A "since" a day in the future should exclude a view last modified before that: ' + futureBody);
        System.assert(pastBody.contains('Delta Sync Test View'),
            'A "since" a day in the past should still include a view modified since then: ' + pastBody);
    }
}
