trigger SampleDropTrigger on Sample_Drop__c (before insert, after insert) {
    if (Trigger.isBefore) SampleDropService.beforeInsert(Trigger.new);
    else SampleDropService.afterInsert(Trigger.new);
}