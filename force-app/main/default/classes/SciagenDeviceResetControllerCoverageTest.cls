@isTest
private class SciagenDeviceResetControllerCoverageTest {

    private static String call(String method, String body) {
        RestRequest req = new RestRequest();
        req.requestUri = '/services/apexrest/sciagen/device-reset';
        req.httpMethod = method;
        if (body != null) req.requestBody = Blob.valueOf(body);
        RestContext.request = req;
        RestContext.response = new RestResponse();
        if (method == 'GET') SciagenDeviceResetController.checkPendingReset(); else SciagenDeviceResetController.verifyOTP();
        return RestContext.response.responseBody.toString();
    }

    // Insert always lands on Pending Approval (trigger). The approval is simulated by an admin update, as DeviceResetRequestTriggerTest does.
    // The request is inserted as the rep so the rep owns it, then approved outside runAs.
    private static Device_Reset_Request__c approved(User rep) {
        Device_Reset_Request__c r = new Device_Reset_Request__c(Reason__c = 'Lost');
        System.runAs(rep) { insert r; }
        r.Status__c = 'Approved';
        r.OTP__c = '123456';
        r.OTP_Expires__c = Datetime.now().addHours(1);
        update r;
        return r;
    }

    private static User repWithManager(String alias) {
        User mgr = SciagenTestUsers.mobileRep(alias + 'm');
        return SciagenTestUsers.rep(alias, new List<String>{ 'Sciagen_Mobile_App_Access' }, mgr.Id);
    }

    @isTest
    static void getReportsPendingResetForOwner() {
        User rep = repWithManager('sdrcrep');
        System.runAs(rep) {
            Map<String, Object> none = (Map<String, Object>) JSON.deserializeUntyped(call('GET', null));
            System.assertEquals(false, none.get('hasPendingReset'));
            System.assertEquals(200, RestContext.response.statusCode);
        }
        approved(rep);
        System.runAs(rep) {
            Map<String, Object> some = (Map<String, Object>) JSON.deserializeUntyped(call('GET', null));
            System.assertEquals(true, some.get('hasPendingReset'));
            System.assertNotEquals(null, some.get('requestId'));
            System.assertNotEquals(null, some.get('expiresAt'));
        }
    }

    @isTest
    static void postValidatesInputAndDelegates() {
        call('POST', 'not json');
        System.assertEquals(400, RestContext.response.statusCode);
        call('POST', '{"requestId":"abc","otp":"1"}');
        System.assertEquals(400, RestContext.response.statusCode);
        call('POST', '{"requestId":"' + UserInfo.getUserId() + '","otp":"1"}');
        System.assertEquals(400, RestContext.response.statusCode);
        call('POST', '{"requestId":"' + UserInfo.getUserId() + '"}');
        System.assertEquals(400, RestContext.response.statusCode);

        User rep = repWithManager('sdrprep');
        Device_Reset_Request__c r = approved(rep);
        System.runAs(rep) {
            String bad = call('POST', '{"requestId":"' + r.Id + '","otp":"000000"}');
            System.assertEquals(200, RestContext.response.statusCode);
            System.assert(bad.contains('"success":false'));
            String good = call('POST', '{"requestId":"' + r.Id + '","otp":"123456"}');
            System.assertEquals(200, RestContext.response.statusCode);
            System.assert(good.contains('"success"'));
        }
    }
}