@isTest
private class DeviceResetVerifyApiTest {

    private static User manager;
    private static User rep;

    private static void users() {
        manager = SciagenTestUsers.rep('drmgr', new List<String>{ 'Sciagen_Mobile_App_Access', 'Sciagen_Manager_Access' });
        rep = SciagenTestUsers.rep('drrep', new List<String>{ 'Sciagen_Mobile_App_Access' }, manager.Id);
    }

    /** The rep raises a request and the manager approves it through the approval process. */
    private static Device_Reset_Request__c approvedRequest() {
        Device_Reset_Request__c req = new Device_Reset_Request__c(Reason__c = 'iPad replaced');
        System.runAs(rep) { insert req; }
        List<ProcessInstanceWorkitem> items = [SELECT Id FROM ProcessInstanceWorkitem WHERE ProcessInstance.TargetObjectId = :req.Id];
        System.runAs(manager) {
            if (!items.isEmpty()) {
                Approval.ProcessWorkitemRequest pwr = new Approval.ProcessWorkitemRequest();
                pwr.setWorkitemId(items[0].Id);
                pwr.setAction('Approve');
                Approval.process(pwr);
            } else {
                update new Device_Reset_Request__c(Id = req.Id, Status__c = 'Approved');
            }
        }
        return [SELECT Id, Status__c, OTP__c, OTP_Expires__c, Manager__c FROM Device_Reset_Request__c WHERE Id = :req.Id];
    }

    private static DeviceResetVerifyApi.Result verifyAs(User u, Id requestId, String code) {
        DeviceResetVerifyApi.Result r;
        System.runAs(u) { r = DeviceResetVerifyApi.check(requestId, code); }
        return r;
    }

    private static String wrong(String otp) { return otp == '000000' ? '111111' : '000000'; }

    @isTest static void correctCodeVerifiesOnceAndMarksUsed() {
        users();
        Device_Reset_Request__c req = approvedRequest();
        System.assertEquals('Approved', req.Status__c);
        System.assertEquals(manager.Id, req.Manager__c);
        System.assert(req.OTP__c != null && req.OTP__c.length() == 6 && req.OTP__c.isNumeric(), req.OTP__c);

        DeviceResetVerifyApi.Result bad = verifyAs(rep, req.Id, wrong(req.OTP__c));
        System.assertEquals(false, bad.verified);
        System.assert(bad.message.contains('4 attempts left'), bad.message);

        DeviceResetVerifyApi.Result ok = verifyAs(rep, req.Id, req.OTP__c);
        System.assertEquals(true, ok.verified, ok.message);
        Device_Reset_Request__c after = [SELECT Status__c, Verified__c, Attempts__c FROM Device_Reset_Request__c WHERE Id = :req.Id];
        System.assertEquals('Used', after.Status__c);
        System.assertEquals(true, after.Verified__c);
        System.assertEquals(1, after.Attempts__c);

        System.assertEquals(false, verifyAs(rep, req.Id, req.OTP__c).verified, 'a code unlocks one wipe only');
    }

    @isTest static void locksAfterFiveWrongCodes() {
        users();
        Device_Reset_Request__c req = approvedRequest();
        for (Integer i = 0; i < DeviceResetRequestHandler.MAX_ATTEMPTS; i++) {
            System.assertEquals(false, verifyAs(rep, req.Id, wrong(req.OTP__c)).verified);
        }
        DeviceResetVerifyApi.Result r = verifyAs(rep, req.Id, req.OTP__c);
        System.assertEquals(false, r.verified, 'the right code is refused once locked');
        System.assert(r.message.contains('Too many'), r.message);
        System.assertEquals(false, [SELECT Verified__c FROM Device_Reset_Request__c WHERE Id = :req.Id].Verified__c);
    }

    @isTest static void expiredOrSomeoneElsesRequestIsRefused() {
        users();
        Device_Reset_Request__c req = approvedRequest();
        User other = SciagenTestUsers.mobileRep('drother');
        DeviceResetVerifyApi.Result r = verifyAs(other, req.Id, req.OTP__c);
        System.assertEquals(false, r.verified);
        System.assert(r.message.contains('not found'), r.message);

        DeviceResetRequestHandler.verifying = true;   // test setup only: backdate the expiry
        update new Device_Reset_Request__c(Id = req.Id, OTP_Expires__c = System.now().addMinutes(-1));
        DeviceResetRequestHandler.verifying = false;
        r = verifyAs(rep, req.Id, req.OTP__c);
        System.assertEquals(false, r.verified);
        System.assert(r.message.contains('expired'), r.message);
    }

    @isTest static void pendingRequestCannotBeVerified() {
        users();
        Device_Reset_Request__c req = new Device_Reset_Request__c(Reason__c = 'x');
        System.runAs(rep) { insert req; }
        DeviceResetVerifyApi.Result r = verifyAs(rep, req.Id, '123456');
        System.assertEquals(false, r.verified);
        System.assert(r.message.contains('not been approved'), r.message);
    }

    @isTest static void repCannotApproveOrVerifyTheirOwnRequest() {
        // No manager: approval submission fails, so the record is not locked -- the trigger guard is what stops this.
        User loneRep = SciagenTestUsers.mobileRep('drlone');
        Device_Reset_Request__c req = new Device_Reset_Request__c(Reason__c = 'x', Manager__c = loneRep.Id);
        System.runAs(loneRep) { insert req; }
        System.assertEquals(null, [SELECT Manager__c FROM Device_Reset_Request__c WHERE Id = :req.Id].Manager__c,
            'the approver is never taken from the client');
        String error;
        System.runAs(loneRep) {
            try { update new Device_Reset_Request__c(Id = req.Id, Status__c = 'Approved'); } catch (DmlException e) { error = e.getDmlMessage(0); }
        }
        System.assert(error != null && error.contains('Only your manager'), error);
        error = null;
        System.runAs(loneRep) {
            try { update new Device_Reset_Request__c(Id = req.Id, Verified__c = true, Status__c = 'Used'); } catch (DmlException e) { error = e.getDmlMessage(0); }
        }
        System.assertNotEquals(null, error);
        Device_Reset_Request__c after = [SELECT Status__c, OTP__c, Verified__c FROM Device_Reset_Request__c WHERE Id = :req.Id];
        System.assertEquals('Pending Approval', after.Status__c);
        System.assertEquals(null, after.OTP__c, 'no code is minted for a self-approval');
        System.assertEquals(false, after.Verified__c);
    }

    @isTest static void repPermissionSetCannotReadTheCode() {
        // The rep PERMISSION SETS must not grant the one-time code or the right to mark a request verified.
        // NOTE: this checks the permission-set grants, not the user's effective access. Effective access also
        // includes the user's profile, and in this org the KAM / Manager / Business Admin / Standard Platform User
        // profiles still carry read+edit on OTP__c (default field-level security on a new field). That gap is
        // tracked separately: the current iPad build reads OTP__c directly, so profile access can only be removed
        // after the app switches to the /device-reset/verify endpoint. Tighten this test to effective access
        // (Schema ... isAccessible()) at that point.
        Integer otpReadGrants = 0;
        Integer verifiedEditGrants = 0;
        for (FieldPermissions fp : [
            SELECT Field, PermissionsRead, PermissionsEdit FROM FieldPermissions
            WHERE Parent.Name IN ('Sciagen_Mobile_App_Access', 'SciagenCrm')
              AND Field IN ('Device_Reset_Request__c.OTP__c', 'Device_Reset_Request__c.Verified__c')
        ]) {
            if (fp.Field == 'Device_Reset_Request__c.OTP__c' && fp.PermissionsRead) otpReadGrants++;
            if (fp.Field == 'Device_Reset_Request__c.Verified__c' && fp.PermissionsEdit) verifiedEditGrants++;
        }
        System.assertEquals(0, otpReadGrants, 'rep permission sets must not grant read on OTP__c');
        System.assertEquals(0, verifiedEditGrants, 'rep permission sets must not grant edit on Verified__c');

        // And the verify endpoint never hands the code back to the rep.
        users();
        Device_Reset_Request__c req = approvedRequest();
        System.runAs(rep) {
            RestResponse res = call(JSON.serialize(new Map<String, Object>{ 'requestId' => req.Id, 'code' => '000000' }));
            System.assert(!res.responseBody.toString().contains(req.OTP__c), 'the response must never contain the code');
        }
    }

    @isTest static void restContract() {
        users();
        Device_Reset_Request__c req = approvedRequest();
        System.runAs(rep) {
            System.assertEquals(400, call('not json').statusCode);
            System.assertEquals(400, call('{"requestId":"","code":"1"}').statusCode);
            System.assertEquals(400, call('{"requestId":"notanid","code":"123456"}').statusCode);
            System.assertEquals(400, call('{"requestId":"' + rep.Id + '","code":"123456"}').statusCode);
            RestResponse res = call(JSON.serialize(new Map<String, Object>{ 'requestId' => req.Id, 'code' => req.OTP__c }));
            System.assertEquals(200, res.statusCode);
            Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(res.responseBody.toString());
            System.assertEquals(true, body.get('verified'));
            System.assertNotEquals(null, body.get('message'));
            // The legacy endpoint answers through the same check.
            RestContext.request = new RestRequest();
            RestContext.response = new RestResponse();
            RestContext.request.requestBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{ 'requestId' => req.Id, 'otp' => req.OTP__c }));
            SciagenDeviceResetController.verifyOTP();
            System.assert(RestContext.response.responseBody.toString().contains('"success":false'), 'already used');
            RestContext.request.requestBody = Blob.valueOf('{"requestId":"","otp":""}');
            RestContext.response = new RestResponse();
            SciagenDeviceResetController.verifyOTP();
            System.assertEquals(400, RestContext.response.statusCode);
            RestContext.response = new RestResponse();
            SciagenDeviceResetController.checkPendingReset();
            System.assertEquals(200, RestContext.response.statusCode);
        }
    }

    private static RestResponse call(String body) {
        RestContext.request = new RestRequest();
        RestContext.request.requestURI = '/services/apexrest/sciagen/v1/device-reset/verify';
        RestContext.request.httpMethod = 'POST';
        RestContext.request.requestBody = Blob.valueOf(body);
        RestContext.response = new RestResponse();
        DeviceResetVerifyApi.verify();
        return RestContext.response;
    }

    @isTest static void codesAreSixDigits() {
        for (Integer i = 0; i < 50; i++) {
            String c = DeviceResetRequestHandler.newCode();
            System.assertEquals(6, c.length());
            System.assert(c.isNumeric(), c);
        }
        System.assert(DeviceResetVerifyApi.constantTimeEquals('123456', '123456'));
        System.assert(!DeviceResetVerifyApi.constantTimeEquals('123456', '123457'));
        System.assert(!DeviceResetVerifyApi.constantTimeEquals('123456', '1234567'));
    }
}