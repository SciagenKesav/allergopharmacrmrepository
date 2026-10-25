/**
 * POST /services/apexrest/sciagen/v1/account-territory-unassign
 * Body: {"accountId": "...", "comment": "..."}
 *
 * The iPad Account Detail page's "Unassign from Territory" action — the same code the web
 * Account Detail page calls too, via AccountTerritoryUnassignController.
 *
 * Files a Data_Change_Request__c of Type 'Territory Unassign' (Status 'Pending Approval')
 * for a data steward to review, exactly like a New/Edit HCP/HCO request — it does NOT touch
 * the Account_Territory__c link itself. The link is only actually removed once a steward
 * approves the request; see DataChangeRequestApprovalHandler.applyApprovedTerritoryUnassign,
 * which reads the territory ids this class stashes in Fields_Payload__c.
 *
 * (Earlier behaviour applied the removal immediately and only logged an already-Approved
 * DCR as an after-the-fact audit trail — that skipped review entirely, unlike every other
 * DCR type. Fixed to route through the same governance gate as New/Edit HCP/HCO.)
 *
 * Responses: 200 {"success":true,"immediate":false,"message":...}, or 400
 * {"success":false,"message":...} when the comment is blank or the account
 * isn't in any of the caller's territories.
 */
@RestResource(urlMapping='/sciagen/v1/account-territory-unassign')
global without sharing class AccountTerritoryUnassignService {

    public class UnassignException extends Exception {}

    @HttpPost
    global static void unassign() {
        RestResponse res = RestContext.response;
        res.addHeader('Content-Type', 'application/json');
        Map<String, Object> result;
        try {
            Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(RestContext.request.requestBody.toString());
            result = unassign((String) body.get('accountId'), (String) body.get('comment'), UserInfo.getUserId());
            res.statusCode = 200;
        } catch (Exception e) {
            res.statusCode = 400;
            result = new Map<String, Object>{ 'success' => false, 'message' => e.getMessage() };
        }
        res.responseBody = Blob.valueOf(JSON.serialize(result));
    }

    public static Map<String, Object> unassign(String accountId, String comment, Id userId) {
        if (String.isBlank(accountId)) {
            throw new UnassignException('An account is required.');
        }
        if (String.isBlank(comment)) {
            throw new UnassignException('Please add a comment explaining why this account is being unassigned.');
        }
        Set<Id> myTerritoryIds = new Set<Id>();
        for (User_Territory__c ut : [SELECT Territory__c FROM User_Territory__c WHERE User__c = :userId]) {
            myTerritoryIds.add(ut.Territory__c);
        }
        List<Account_Territory__c> links = [
            SELECT Id, Account__r.Name, Territory__c
            FROM Account_Territory__c
            WHERE Account__c = :accountId AND Territory__c IN :myTerritoryIds
        ];
        if (links.isEmpty()) {
            throw new UnassignException('This account is not assigned to your territory.');
        }
        String accountName = links[0].Account__r.Name;
        List<Id> territoryIdsToUnassign = new List<Id>();
        for (Account_Territory__c link : links) {
            territoryIdsToUnassign.add(link.Territory__c);
        }

        insert new Data_Change_Request__c(
            Type__c = 'Territory Unassign',
            Status__c = 'Pending Approval',
            Subject_Account__c = accountId,
            Subject_Name__c = accountName,
            Summary__c = comment.trim(),
            Fields_Payload__c = JSON.serialize(new Map<String, Object>{ 'territoryIds' => territoryIdsToUnassign }),
            Submitted_By__c = userId,
            Submitted_At__c = System.now()
        );

        return new Map<String, Object>{
            'success' => true,
            'immediate' => false,
            'message' => accountName + ' — territory removal submitted for review.'
        };
    }
}