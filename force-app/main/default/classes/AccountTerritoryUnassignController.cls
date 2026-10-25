/**
 * Web entry point for the Account Detail page's "Unassign from Territory" button.
 *
 * The rule itself lives in AccountTerritoryUnassignService (the same code the iPad calls over
 * REST): it never deletes the account record, never touches other territories' links, and files
 * a Pending-Approval Data_Change_Request__c of Type 'Territory Unassign' holding the required
 * reason and which territory link(s) to remove. The Account_Territory__c link itself is only
 * removed once a steward approves that request (DataChangeRequestApprovalHandler) -- at which
 * point AccountTerritoryShareSync re-derives sharing and the account drops out of the caller's
 * visible list.
 *
 * This class only adapts it to Lightning: a result the LWC can read, and errors surfaced as
 * AuraHandledException so the toast shows the real message.
 */
public with sharing class AccountTerritoryUnassignController {

    public class UnassignOutcome {
        @AuraEnabled public Boolean success;
        @AuraEnabled public Boolean immediate;
        @AuraEnabled public String message;
    }

    @AuraEnabled
    public static UnassignOutcome unassignFromMyTerritory(Id accountId, String comment) {
        try {
            Map<String, Object> result = AccountTerritoryUnassignService.unassign(accountId, comment, UserInfo.getUserId());
            UnassignOutcome outcome = new UnassignOutcome();
            outcome.success = true;
            outcome.immediate = (Boolean) result.get('immediate');
            outcome.message = (String) result.get('message');
            return outcome;
        } catch (AccountTerritoryUnassignService.UnassignException e) {
            // setMessage as well, so getMessage() returns the text (not "Script-thrown exception").
            AuraHandledException ex = new AuraHandledException(e.getMessage());
            ex.setMessage(e.getMessage());
            throw ex;
        }
    }
}