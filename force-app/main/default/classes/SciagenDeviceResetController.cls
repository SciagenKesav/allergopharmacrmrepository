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
     * Response: { "success": true } on match,
     *           { "success": false, "reason": "..." } otherwise.
     * Kept for older app builds only: it delegates to DeviceResetVerifyApi.check
     * (POST /sciagen/v1/device-reset/verify), so the same ownership, expiry,
     * 5-attempt lockout and constant-time compare apply here too.
     */
    @HttpPost
    global static void verifyOTP() {
        RestResponse res = RestContext.response;
        res.addHeader('Content-Type', 'application/json');
        String requestId;
        String enteredOTP;
        try {
            Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(
                RestContext.request.requestBody.toString()
            );
            requestId = (String) body.get('requestId');
            enteredOTP  = (String) body.get('otp');
        } catch (Exception e) {
            requestId = null;
        }
        Id id;
        try { id = String.isBlank(requestId) ? null : (Id) requestId.trim(); } catch (Exception e) { id = null; }
        if (id == null || String.isBlank(enteredOTP) || id.getSObjectType() != Device_Reset_Request__c.SObjectType) {
            res.statusCode = 400;
            res.responseBody = Blob.valueOf('{"success":false,"reason":"requestId and otp are required"}');
            return;
        }
        DeviceResetVerifyApi.Result r = DeviceResetVerifyApi.check(id, enteredOTP.trim());
        res.statusCode = 200;
        res.responseBody = Blob.valueOf(JSON.serialize(r.verified
            ? new Map<String, Object>{ 'success' => true }
            : new Map<String, Object>{ 'success' => false, 'reason' => r.message }));
    }
}