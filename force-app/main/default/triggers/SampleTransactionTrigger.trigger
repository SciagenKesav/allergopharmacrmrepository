trigger SampleTransactionTrigger on Sample_Transaction__c (before insert, before update, after insert, after update) {
    if (Trigger.isBefore) {
        SampleTransactionService.beforeSave(Trigger.new, Trigger.isUpdate ? Trigger.oldMap : null);
    } else {
        SampleTransactionService.afterSave(Trigger.new, Trigger.isUpdate ? Trigger.oldMap : null);
    }
}