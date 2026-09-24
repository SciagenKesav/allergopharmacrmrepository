trigger DeviceResetRequestTrigger on Device_Reset_Request__c (before insert, after insert, before update, after update) {
    if (Trigger.isBefore && Trigger.isInsert) {
        // Stamp Manager__c before save so the Approval Process can route to it.
        DeviceResetRequestHandler.stampManager(Trigger.new);
    }
    if (Trigger.isAfter && Trigger.isInsert) {
        DeviceResetRequestHandler.submitForApproval(Trigger.new);
    }
    if (Trigger.isBefore && Trigger.isUpdate) {
        DeviceResetRequestHandler.generateOTPOnApproval(Trigger.new, Trigger.oldMap);
    }
    if (Trigger.isAfter && Trigger.isUpdate) {
        DeviceResetRequestHandler.emailApproverTheCode(Trigger.new, Trigger.oldMap);
    }
}