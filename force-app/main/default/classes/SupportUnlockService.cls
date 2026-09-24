/**
 * Unlocking a submitted call for a rep. Only a Business Admin holding the
 * Support Unlock Calls permission can do it. The call goes back to Saved,
 * which the iPad already pulls, so the rep can edit it and submit it again;
 * when they do, the request is resolved automatically.
 */
public without sharing class SupportUnlockService {

    public class UnlockException extends Exception {}

    private static Support_Request__c loadRequest(Id requestId) {
        List<Support_Request__c> rows = [
            SELECT Id, Name, Subject__c, Category__c, Status__c, Requester__c, Manager__c, Call_Visit_Report__c
            FROM Support_Request__c WHERE Id = :requestId LIMIT 1 FOR UPDATE
        ];
        if (rows.isEmpty()) throw new UnlockException('That request was not found.');
        if (rows[0].Category__c != SupportRequestService.CAT_UNLOCK || rows[0].Call_Visit_Report__c == null) {
            throw new UnlockException('This request is not about unlocking a call.');
        }
        if (!SupportRequestService.OPEN_STATUSES.contains(rows[0].Status__c)) throw new UnlockException('This request is already closed.');
        return rows[0];
    }

    private static void requireRight() {
        if (!SupportRequestService.isAgent() || !FeatureManagement.checkPermission('Support_Unlock_Calls')) {
            throw new UnlockException('You do not have permission to unlock calls.');
        }
    }

    public static void unlock(Id requestId, String note) {
        requireRight();
        Support_Request__c req = loadRequest(requestId);
        List<Call_Visit_Report__c> calls = [SELECT Id, Record_Status__c, Unlock_Count__c FROM Call_Visit_Report__c WHERE Id = :req.Call_Visit_Report__c LIMIT 1 FOR UPDATE];
        if (calls.isEmpty()) throw new UnlockException('The call no longer exists.');
        Call_Visit_Report__c call = calls[0];
        if (call.Record_Status__c != 'Submitted') throw new UnlockException('This call is already open for editing.');

        List<Key_Message__c> keyMessages = [SELECT Id FROM Key_Message__c WHERE CVR__c = :call.Id AND Locked__c = true];
        for (Key_Message__c k : keyMessages) k.Locked__c = false;

        call.Record_Status__c = 'Saved';
        call.Unlocked_At__c = Datetime.now();
        call.Unlocked_By__c = UserInfo.getUserId();
        call.Unlock_Request__c = req.Id;
        call.Unlock_Count__c = (call.Unlock_Count__c == null ? 0 : call.Unlock_Count__c) + 1;
        try {
            update call;
            if (!keyMessages.isEmpty()) update keyMessages;
        } catch (DmlException e) {
            // e.g. calls that handed out controlled substances need the sample inventory manager
            throw new UnlockException(e.getDmlMessage(0));
        }

        Support_Request__c u = new Support_Request__c(Id = req.Id, Unlock_Outcome__c = 'Unlocked', Status__c = 'Waiting on Rep', Assigned_To__c = UserInfo.getUserId());
        SupportRequestService.updateInternally(new List<Support_Request__c>{ u }, false);
        addMessage(req.Id, String.isBlank(note)
            ? 'I have unlocked your call. Open it, make your corrections and submit it again. This request will close by itself when you do.'
            : note.trim());
    }

    public static void decline(Id requestId, String reason) {
        requireRight();
        if (String.isBlank(reason)) throw new UnlockException('Tell the rep why the call cannot be unlocked.');
        Support_Request__c req = loadRequest(requestId);
        Support_Request__c u = new Support_Request__c(Id = req.Id, Unlock_Outcome__c = 'Declined', Resolution_Type__c = 'Declined', Status__c = 'Resolved');
        SupportRequestService.updateInternally(new List<Support_Request__c>{ u }, false);
        addMessage(req.Id, reason.trim());
    }

    /** A message from support, sent as the running admin. */
    private static void addMessage(Id requestId, String body) {
        insert new Support_Comment__c(Support_Request__c = requestId, Body__c = body, Sent_Via__c = 'Web');
    }

    // ------------------------------------------------------------------ the rep submits the call again

    public static void afterCallSubmit(List<Call_Visit_Report__c> rows, Map<Id, Call_Visit_Report__c> oldMap) {
        Set<Id> requestIds = new Set<Id>();
        for (Call_Visit_Report__c c : rows) {
            Call_Visit_Report__c o = oldMap.get(c.Id);
            if (c.Record_Status__c == 'Submitted' && o.Record_Status__c != 'Submitted' && c.Unlock_Request__c != null) requestIds.add(c.Unlock_Request__c);
        }
        if (requestIds.isEmpty()) return;
        List<Support_Request__c> updates = new List<Support_Request__c>();
        List<Support_Comment__c> events = new List<Support_Comment__c>();
        for (Support_Request__c r : [SELECT Id FROM Support_Request__c WHERE Id IN :requestIds AND Is_Open__c = true AND Category__c = :SupportRequestService.CAT_UNLOCK]) {
            updates.add(new Support_Request__c(Id = r.Id, Status__c = 'Resolved', Resolution_Type__c = 'Unlocked'));
            events.add(SupportCommentService.event(r.Id, 'The call was corrected and submitted again.'));
        }
        SupportRequestService.updateInternally(updates, true);
        SupportCommentService.insertEvents(events);
    }
}