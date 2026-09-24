/**
 * Keeps duplicate-detection match keys current and queues a background duplicate check for
 * new or materially edited HCP/HCO records.
 */
trigger SciagenAccountDedupe on Sciagen_Account__c (before insert, before update, after insert, after update) {
    if (Trigger.isBefore) {
        DuplicateKeyService.apply(Trigger.new, Trigger.isUpdate ? Trigger.oldMap : null);
    } else {
        DuplicateTriggerHandler.afterSave(Trigger.new);
    }
}