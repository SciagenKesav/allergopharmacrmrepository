trigger SampleCallTrigger on Call_Visit_Report__c (before update, after insert, after update) {
    if (Trigger.isBefore) SampleDropService.beforeCallUpdate(Trigger.new, Trigger.oldMap);
    else SampleDropService.afterCallSubmit(Trigger.new, Trigger.isUpdate ? Trigger.oldMap : null);
}