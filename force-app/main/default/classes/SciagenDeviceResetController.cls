/**
 * REST endpoint used by the iPad app to:
 *   GET  /services/apexrest/sciagen/device-reset  → check if the logged-in
 *        rep has an approved, unexpired reset request waiting
 *   POST /services/apexrest/sciagen/device-reset  → verify the one-time
 *        code the rep typed in; on success marks the request as Used so the
 *        same code can't unlock a second wipe.
 *
 * The app calls GET during its sync cycle (so it always knows whether to
 * show the "Enter reset code" prompt) and POST when the rep taps Confirm in
 * the Settings > Reset Local Data sheet.
 */
@RestResource(urlMapping='/sciagen/device-reset')
global with sharing class SciagenDeviceResetController {

    /** Returns the first approved, unexpired reset request for the running user.
     * Response shape:
     *   { "hasPendingReset": true/false,
     *     "requestId": "a0B...",   // only when hasPendingReset = true
     *     "requestName": "DRR-0001",
     *     "expiresAt": "2026-09-03T14:00:00Z" }
     */
    @HttpGet
    global static void checkPendingReset() {
        RestResponse res = RestContext.response;
        res.addHeader('Content-Type', 'application/json');
        try {
            Id userId = UserInfo.getUserId();
            String soql1 = 'SELECT Id, Name, OTP_Expires__c FROM Device_Reset_Request__c'
                         + ' WHERE OwnerId = :userId'
                         + ' AND Status__c = \'Approved\''
                         + ' AND Verified__c = false'
                         + ' AND OTP_Expires__c > :now'
                         + ' ORDER BY CreatedDate DESC LIMIT 1';
            Datetime now = System.now();
            List<Device_Reset_Request__c> pending = Database.queryWithBinds(
                soql1,
                new Map<String, Object>{ 'userId' => userId, 'now' => now },
                AccessLevel.USER_MODE
            );
            Map<String, Object> result = new Map<String, Object>();
            if (pending.isEmpty()) {
                result.put('hasPendingReset', false);
            } else {
                Device_Reset_Request__c r = pending[0];
                result.put('hasPendingReset', true);
                result.put('requestId', r.Id);
                result.put('requestName', r.Name);
                result.put('expiresAt', r.OTP_Expires__c.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\''));
            }
            res.statusCode = 200;
            res.responseBody = Blob.valueOf(JSON.serialize(result));
        } catch (Exception e) {
            res.statusCode = 500;
            res.responseBody = Blob.valueOf('{"error":' + JSON.serialize(e.getMessage()) + '}');
        }
    }

    /** Verifies the one-time code the rep entered in the app.
     * Request body: { "requestId": "a0B...", "otp": "482910" }
     * Response: { "success": true } on match + unexpired,
     *           { "success": false, "reason": "..." } on mismatch/expired/already-used.
     * On success: marks Verified__c = true and Status__c = 'Used' so the same
     * code can't unlock a second wipe.
     */
    @HttpPost
    global static void verifyOTP() {
        RestResponse res = RestContext.response;
        res.addHeader('Content-Type', 'application/json');
        try {
            Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(
                RestContext.request.requestBody.toString()
            );
            String requestId = (String) body.get('requestId');
            String enteredOTP  = (String) body.get('otp');

            if (String.isBlank(requestId) || String.isBlank(enteredOTP)) {
                res.statusCode = 400;
                res.responseBody = Blob.valueOf('{"success":false,"reason":"requestId and otp are required"}');
                return;
            }

            Id userId = UserInfo.getUserId();
            String soql2 = 'SELECT Id, OTP__c, OTP_Expires__c, Status__c, Verified__c'
                         + ' FROM Device_Reset_Request__c'
                         + ' WHERE Id = :requestId AND OwnerId = :userId LIMIT 1';
            List<Device_Reset_Request__c> requests = Database.queryWithBinds(
                soql2,
                new Map<String, Object>{ 'requestId' => (Id) requestId, 'userId' => userId },
                AccessLevel.USER_MODE
            );

            if (requests.isEmpty()) {
                res.statusCode = 404;
                res.responseBody = Blob.valueOf('{"success":false,"reason":"Request not found"}');
                return;
            }

            Device_Reset_Request__c r = requests[0];

            if (r.Verified__c || r.Status__c == 'Used') {
                res.statusCode = 200;
                res.responseBody = Blob.valueOf('{"success":false,"reason":"Code already used"}');
                return;
            }
            if (r.OTP_Expires__c == null || r.OTP_Expires__c < System.now()) {
                res.statusCode = 200;
                res.responseBody = Blob.valueOf('{"success":false,"reason":"Code expired — ask your manager to re-approve"}');
                return;
            }
            if (r.OTP__c != enteredOTP.trim()) {
                res.statusCode = 200;
                res.responseBody = Blob.valueOf('{"success":false,"reason":"Incorrect code"}');
                return;
            }

            // Code matches and is unexpired — mark used so it can't be reused.
            r.Verified__c = true;
            r.Status__c   = 'Used';
            update r;

            res.statusCode = 200;
            res.responseBody = Blob.valueOf('{"success":true}');
        } catch (Exception e) {
            res.statusCode = 500;
            res.responseBody = Blob.valueOf('{"success":false,"reason":' + JSON.serialize(e.getMessage()) + '}');
        }
    }
}