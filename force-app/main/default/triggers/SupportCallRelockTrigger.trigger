trigger SupportCallRelockTrigger on Call_Visit_Report__c (after update) {
    SupportUnlockService.afterCallSubmit(Trigger.new, Trigger.oldMap);
}