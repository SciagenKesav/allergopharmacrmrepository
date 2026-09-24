/**
 * Lets ANY user unassign a Sciagen_Account__c from their own territory
 * WITHOUT deleting the Account record itself — removes only the
 * Account_Territory__c junction row(s) linking it to the caller's own
 * territory(ies). AccountTerritoryShareSync.trigger then picks that up and
 * re-derives sharing fresh (TerritorySharingService.resyncForAccounts),
 * which automatically revokes the caller's Sciagen_Account__Share for that
 * account — so it simply drops out of their visible accounts. The Account
 * itself, and any OTHER territory's link to it, are left untouched.
 *
 * Governance: a Business Unit Head's own request applies immediately (they
 * ARE the approver). Everyone else's request instead creates a
 * "Unassign HCP"/"Unassign HCO" Data_Change_Request__c — nothing is removed
 * until a Business Unit Head reviews and approves it (see
 * DataChangeRequestApprovalHandler.applyUnassignForApprovedDcr). Vivek
 * Narang, the only Business Unit Head today, is also System Administrator
 * profile, so no extra DCR-review permission grant was needed for him to see
 * it; a future non-admin Business Unit Head would need the same DCR review
 * access Sciagen_Zonal_Manager_Access already grants.
 *
 * `without sharing`, and doUnassign's/applyImmediateUnassign's DML
 * deliberately omit AccessLevel.USER_MODE, for the same reason
 * AffiliationSyncService and DataChangeRequestApprovalHandler do: most
 * callers don't (and shouldn't) have raw Delete permission on
 * Account_Territory__c — this method IS the access-control mechanism, via
 * "only a link to one of MY OWN territories" plus the Business-Unit-Head
 * governance split above, not object-level CRUD.
 *
 * Two entry points, one shared implementation:
 *  - unassignFromMyTerritory (@AuraEnabled) — the web Account Detail page's
 *    Unassign button.
 *  - POST /services/apexrest/sciagen/v1/account-territory-unassign
 *    { "accountId": "a0B...", "comment": "..." } — the iPad app's Actions menu.
 *
 * A comment is required either way (why the rep is unassigning it) — it's
 * filed as the first DCR_Comment__c on the resulting Data_Change_Request__c
 * (Author_Role__c = 'Requester'), even on the Business-Unit-Head "immediate"
 * path, where a DCR is still created — pre-Approved — purely so the comment
 * has somewhere durable to live and a Business Admin can read/reply to it
 * from the DCR Review Queue (see DCRReviewController.getComments/addComment).
 */
@RestResource(urlMapping='/sciagen/v1/account-territory-unassign')
global without sharing class SciagenAccountTerritoryController {

    public class UnassignOutcome {
        @AuraEnabled public Boolean success;
        /// true = actually removed now; false = a Business-Unit-Head-approval
        /// DCR was submitted instead and the Account is still assigned.
        @AuraEnabled public Boolean immediate;
        @AuraEnabled public String message;
    }

    @AuraEnabled
    public static UnassignOutcome unassignFromMyTerritory(Id accountId, String comment) {
        UnassignOutcome outcome = doUnassign(accountId, comment);
        if (!outcome.success) {
            throw new AuraHandledException(outcome.message);
        }
        return outcome;
    }

    @HttpPost
    global static void unassignFromMyTerritoryRest() {
        RestResponse res = RestContext.response;
        res.addHeader('Content-Type', 'application/json');
        try {
            Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(
                RestContext.request.requestBody.toString()
            );
            Id accountId = String.isBlank((String) body.get('accountId')) ? null : (Id) (String) body.get('accountId');
            String comment = (String) body.get('comment');
            UnassignOutcome outcome = doUnassign(accountId, comment);
            res.statusCode = outcome.success ? 200 : 400;
            res.responseBody = Blob.valueOf(JSON.serialize(outcome));
        } catch (Exception e) {
            res.statusCode = 500;
            res.responseBody = Blob.valueOf('{"success":false,"reason":' + JSON.serialize(e.getMessage()) + '}');
        }
    }

    /** Shared implementation. */
    private static UnassignOutcome doUnassign(Id accountId, String comment) {
        UnassignOutcome outcome = new UnassignOutcome();
        outcome.success = false;
        outcome.immediate = false;

        if (accountId == null) {
            outcome.message = 'accountId is required.';
            return outcome;
        }
        if (String.isBlank(comment)) {
            outcome.message = 'A comment explaining the unassignment is required.';
            return outcome;
        }
        Set<Id> myTerritoryIds = new Set<Id>();
        for (User_Territory__c ut : [
            SELECT Territory__c
            FROM User_Territory__c
            WHERE User__c = :UserInfo.getUserId() AND Territory__c != null
            WITH USER_MODE
        ]) {
            myTerritoryIds.add(ut.Territory__c);
        }
        if (myTerritoryIds.isEmpty()) {
            outcome.message = 'You are not assigned to any territory.';
            return outcome;
        }

        List<Account_Territory__c> links = [
            SELECT Id, Territory__c, Territory__r.Name
            FROM Account_Territory__c
            WHERE Account__c = :accountId AND Territory__c IN :myTerritoryIds
            WITH USER_MODE
        ];
        if (links.isEmpty()) {
            outcome.message = 'This record is not assigned to your territory.';
            return outcome;
        }

        if (isBusinessUnitHead()) {
            // Still files a (pre-Approved) DCR so the comment has somewhere
            // to live — DataChangeRequestTrigger only fires on UPDATE, so
            // inserting straight in at Status__c = 'Approved' does NOT
            // re-trigger applyUnassignForApprovedDcr and double-delete these
            // same links; see class doc comment.
            fileUnassignDcr(accountId, links, 'Approved', comment);
            // No AccessLevel.USER_MODE here — see class doc comment.
            delete links;
            outcome.success = true;
            outcome.immediate = true;
            outcome.message = 'Removed from your territory.';
            return outcome;
        }

        return submitUnassignDcr(accountId, links, comment);
    }

    private static Boolean isBusinessUnitHead() {
        List<User> matches = [
            SELECT UserRole.Name FROM User WHERE Id = :UserInfo.getUserId() WITH USER_MODE LIMIT 1
        ];
        return !matches.isEmpty() && matches[0].UserRole != null && matches[0].UserRole.Name == 'Business Unit Head';
    }

    /// Everyone except a Business Unit Head: instead of deleting the
    /// Account_Territory__c link directly, files a DCR carrying the
    /// territory Id(s) to remove on approval — see
    /// DataChangeRequestApprovalHandler.applyUnassignForApprovedDcr.
    private static UnassignOutcome submitUnassignDcr(Id accountId, List<Account_Territory__c> links, String comment) {
        UnassignOutcome outcome = new UnassignOutcome();
        Data_Change_Request__c dcr = fileUnassignDcr(accountId, links, 'Pending Approval', comment);
        if (dcr == null) {
            outcome.success = false;
            outcome.message = 'Account not found.';
            return outcome;
        }

        outcome.success = true;
        outcome.immediate = false;
        outcome.message = 'Submitted for approval — a Business Unit Head will review this before it’s removed.';
        return outcome;
    }

    /// Shared by both governance paths: builds and inserts the
    /// "Unassign HCP"/"Unassign HCO" Data_Change_Request__c (at whatever
    /// Status__c the caller is entitled to — 'Approved' for a Business Unit
    /// Head's own immediate removal, 'Pending Approval' for everyone else),
    /// then files the caller's required comment as the thread's first
    /// DCR_Comment__c. Returns null if the Account itself can't be found.
    private static Data_Change_Request__c fileUnassignDcr(Id accountId, List<Account_Territory__c> links, String status, String comment) {
        List<Sciagen_Account__c> accounts = [
            SELECT Id, Name, Type__c FROM Sciagen_Account__c WHERE Id = :accountId WITH USER_MODE LIMIT 1
        ];
        if (accounts.isEmpty()) {
            return null;
        }
        Sciagen_Account__c acc = accounts[0];

        List<String> territoryIds = new List<String>();
        List<String> territoryNames = new List<String>();
        for (Account_Territory__c link : links) {
            territoryIds.add(link.Territory__c);
            territoryNames.add(link.Territory__r.Name);
        }

        Data_Change_Request__c dcr = new Data_Change_Request__c(
            Type__c = acc.Type__c == 'HCO' ? 'Unassign HCO' : 'Unassign HCP',
            Status__c = status,
            Subject_Account__c = acc.Id,
            Subject_Name__c = acc.Name,
            Summary__c = 'Unassign ' + acc.Type__c + ' · ' + acc.Name + ' · from ' + String.join(territoryNames, ', '),
            Fields_Payload__c = JSON.serialize(new Map<String, Object>{ 'territoryIds' => territoryIds }),
            Submitted_By__c = UserInfo.getUserId(),
            Submitted_At__c = Datetime.now()
        );
        // No AccessLevel.USER_MODE here — see class doc comment.
        insert dcr;

        insert new DCR_Comment__c(
            Data_Change_Request__c = dcr.Id,
            Author__c = UserInfo.getUserId(),
            Author_Role__c = 'Requester',
            Body__c = comment
        );

        return dcr;
    }
}
