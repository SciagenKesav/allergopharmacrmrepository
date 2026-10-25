trigger PlannedCallOriginCapture on Planned_Call__c (before insert, before update) {
    PlannedCallOriginService.capture(Trigger.new, Trigger.isUpdate ? Trigger.oldMap : null);
}