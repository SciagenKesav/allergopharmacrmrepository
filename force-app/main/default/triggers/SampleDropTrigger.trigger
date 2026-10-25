trigger SampleDropTrigger on Sample_Drop__c (before insert, before update, before delete, after insert) {
    if (Trigger.isBefore && Trigger.isInsert) SampleDropService.beforeInsert(Trigger.new);
    else if (Trigger.isBefore && Trigger.isUpdate) SampleDropService.beforeUpdate(Trigger.new, Trigger.oldMap);
    else if (Trigger.isBefore && Trigger.isDelete) SampleDropService.beforeDelete(Trigger.old);
    else SampleDropService.afterInsert(Trigger.new);
}