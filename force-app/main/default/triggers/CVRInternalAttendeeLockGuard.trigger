/** Children of a submitted Call Visit Report are locked with it (CallReportLockService.guardChildren). */
trigger CVRInternalAttendeeLockGuard on CVR_Internal_Attendee__c (before update, before delete) {
    CallReportLockService.guardChildren(Trigger.isDelete ? Trigger.old : Trigger.new, Trigger.isDelete ? null : Trigger.oldMap);
}