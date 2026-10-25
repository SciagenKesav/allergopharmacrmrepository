/**
 * POST /services/apexrest/sciagen/v1/monthly-plan
 * Body: { "action": "freeze", "month": "2026-10-01" }   (any day of the month)
 *
 * Freezes the calling rep's plan for that month (MonthlyCallPlanService).
 * Always answers JSON: success, message, planId, status, frozenAt, callCount,
 * hcpCount, emptyDays. 400 for a bad request, 200 otherwise (success=false
 * when the plan can't be frozen, with the reason in message).
 */
@RestResource(urlMapping='/sciagen/v1/monthly-plan')
global with sharing class MonthlyCallPlanApi {

    @HttpPost
    global static void post() {
        RestResponse res = RestContext.response;
        res.addHeader('Content-Type', 'application/json');
        String action;
        Date month;
        try {
            Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(
                RestContext.request.requestBody == null ? '' : RestContext.request.requestBody.toString());
            action = (String) body.get('action');
            month = Date.valueOf((String) body.get('month'));
        } catch (Exception e) {
            respond(res, 400, failure('Send a JSON body with action and month (yyyy-MM-dd).'));
            return;
        }
        if (action != 'freeze' || month == null) {
            respond(res, 400, failure('Unknown action.'));
            return;
        }
        respond(res, 200, MonthlyCallPlanService.freeze(UserInfo.getUserId(), month));
    }

    private static MonthlyCallPlanService.FreezeResult failure(String message) {
        MonthlyCallPlanService.FreezeResult r = new MonthlyCallPlanService.FreezeResult();
        r.message = message;
        return r;
    }

    private static void respond(RestResponse res, Integer status, MonthlyCallPlanService.FreezeResult r) {
        res.statusCode = status;
        res.responseBody = Blob.valueOf(JSON.serialize(r));
    }
}