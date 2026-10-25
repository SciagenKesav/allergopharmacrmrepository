/**
 * POST /services/apexrest/sciagen/v1/device-reset/verify
 *
 * Checks the one-time code a rep typed into the iPad's Reset Local Data gate
 * (QA-34). The code itself (Device_Reset_Request__c.OTP__c) is never readable
 * by reps; only this endpoint compares it.
 *
 * Request:  { "requestId": "<Device_Reset_Request__c Id>", "code": "<entered code>" }
 * Response: 200 { "verified": true|false, "message": "..." }
 *           400 { "verified": false, "message": "..." } for a malformed body
 *
 * verified = true only when the request is the caller's own (OwnerId), its
 * Status__c is Approved, OTP_Expires__c hasn't passed, fewer than 5 wrong codes
 * were entered, and the code matches (constant-time compare). Success marks
 * the request Verified__c = true, Status__c = 'Used', so the code can't unlock
 * a second wipe. Each wrong code counts toward Attempts__c; after 5 the request
 * is locked and the rep must raise a new one.
 *
 * Without sharing: it reads OTP__c, which reps have no FLS on. It only ever
 * answers for a request the caller owns and never returns the code.
 */
@RestResource(urlMapping='/sciagen/v1/device-reset/verify')
global without sharing class DeviceResetVerifyApi {

    global class Result {
        public Boolean verified = false;
        public String message;
        Result(Boolean verified, String message) { this.verified = verified; this.message = message; }
    }

    @HttpPost
    global static void verify() {
        RestResponse res = RestContext.response;
        res.addHeader('Content-Type', 'application/json');
        String requestId;
        String code;
        try {
            Object parsed = JSON.deserializeUntyped(RestContext.request.requestBody == null ? '' : RestContext.request.requestBody.toString());
            Map<String, Object> body = (Map<String, Object>) parsed;
            requestId = (String) body.get('requestId');
            code = (String) body.get('code');
        } catch (Exception e) {
            respond(res, 400, new Result(false, 'Send a JSON body with requestId and code.'));
            return;
        }
        if (String.isBlank(requestId) || String.isBlank(code)) {
            respond(res, 400, new Result(false, 'requestId and code are required.'));
            return;
        }
        Id id;
        try {
            id = (Id) requestId.trim();
        } catch (Exception e) {
            respond(res, 400, new Result(false, 'requestId is not a valid record id.'));
            return;
        }
        if (id.getSObjectType() != Device_Reset_Request__c.SObjectType) {
            respond(res, 400, new Result(false, 'requestId is not a device reset request.'));
            return;
        }
        respond(res, 200, check(id, code.trim()));
    }

    /** The check itself, callable from tests without a REST context. */
    public static Result check(Id requestId, String code) {
        List<Device_Reset_Request__c> rows = [
            SELECT Id, OwnerId, Status__c, OTP__c, OTP_Expires__c, Verified__c, Attempts__c
            FROM Device_Reset_Request__c WHERE Id = :requestId LIMIT 1 FOR UPDATE
        ];
        // Someone else's request looks exactly like a missing one.
        if (rows.isEmpty() || rows[0].OwnerId != UserInfo.getUserId()) return new Result(false, 'Reset request not found.');
        Device_Reset_Request__c r = rows[0];
        Integer attempts = r.Attempts__c == null ? 0 : r.Attempts__c.intValue();

        if (r.Verified__c == true || r.Status__c == 'Used') return new Result(false, 'This code has already been used.');
        if (r.Status__c != 'Approved') return new Result(false, 'This request has not been approved yet.');
        if (attempts >= DeviceResetRequestHandler.MAX_ATTEMPTS) {
            return new Result(false, 'Too many incorrect codes. Raise a new reset request.');
        }
        if (r.OTP_Expires__c == null || r.OTP_Expires__c < System.now() || String.isBlank(r.OTP__c)) {
            return new Result(false, 'This code has expired. Raise a new reset request.');
        }

        Device_Reset_Request__c u = new Device_Reset_Request__c(Id = r.Id);
        Result out;
        if (constantTimeEquals(r.OTP__c, code)) {
            u.Verified__c = true;
            u.Status__c = 'Used';
            out = new Result(true, 'Code accepted.');
        } else {
            attempts++;
            u.Attempts__c = attempts;
            Integer left = DeviceResetRequestHandler.MAX_ATTEMPTS - attempts;
            out = new Result(false, left > 0
                ? 'Incorrect code. ' + left + (left == 1 ? ' attempt' : ' attempts') + ' left.'
                : 'Too many incorrect codes. Raise a new reset request.');
        }
        save(u);
        return out;
    }

    private static void save(Device_Reset_Request__c u) {
        // An approved request is locked by the approval process (finalApprovalRecordLock).
        // Unlock when the org allows Apex lock/unlock; otherwise the system-mode update below still applies.
        try {
            if (Approval.isLocked(u.Id)) Approval.unlock(u.Id);
        } catch (Exception e) {
            System.debug(LoggingLevel.INFO, 'Approval lock API not available: ' + e.getMessage());
        }
        DeviceResetRequestHandler.verifying = true;
        try {
            update u;
        } finally {
            DeviceResetRequestHandler.verifying = false;
        }
    }

    /** Compares every character regardless of where the first difference is. */
    @TestVisible
    private static Boolean constantTimeEquals(String expected, String actual) {
        if (expected == null || actual == null) return false;
        Integer diff = expected.length() ^ actual.length();
        Integer n = Math.max(expected.length(), actual.length());
        for (Integer i = 0; i < n; i++) {
            Integer a = i < expected.length() ? expected.charAt(i) : 0;
            Integer b = i < actual.length() ? actual.charAt(i) : 0;
            diff |= (a ^ b);
        }
        return diff == 0;
    }

    private static void respond(RestResponse res, Integer status, Result r) {
        res.statusCode = status;
        res.responseBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{ 'verified' => r.verified, 'message' => r.message }));
    }
}