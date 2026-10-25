trigger SentEmailSend on Sent_Email__c (before insert, after insert, after update) {
    if (Trigger.isBefore) {
        // Delivery state is server-authoritative: the iPad cannot set (or FLS-write) Status__c,
        // a Sent-folder email always starts Queued and only SentEmailSendService moves it on.
        SentEmailSendService.markNewSentEmailsQueued(Trigger.new);
    } else {
        SentEmailSendService.enqueueQueued(Trigger.new, Trigger.isUpdate ? Trigger.oldMap : null);
    }
}