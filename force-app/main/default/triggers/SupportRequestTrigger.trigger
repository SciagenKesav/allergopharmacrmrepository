trigger SupportRequestTrigger on Support_Request__c (before insert, before update, after insert, after update) {
    if (Trigger.isBefore && Trigger.isInsert) SupportRequestService.beforeInsert(Trigger.new);
    else if (Trigger.isBefore) SupportRequestService.beforeUpdate(Trigger.new, Trigger.oldMap);
    else if (Trigger.isInsert) SupportRequestService.afterInsert(Trigger.new);
    else SupportRequestService.afterUpdate(Trigger.new, Trigger.oldMap);
}