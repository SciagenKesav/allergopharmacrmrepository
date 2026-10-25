/**
 * Re-points references to a merged (losing) HCP/HCO to the surviving record,
 * and locks attendees of a submitted call report (CallReportLockService).
 */
trigger MergedRedirectCVRAttendee on CVR_Attendee__c (before insert, before update, before delete) {
    if (Trigger.isDelete) {
        CallReportLockService.guardChildren(Trigger.old, null);
        return;
    }
    MergedReferenceRedirectService.redirect(Trigger.new, new List<String>{ 'HCP__c' });
    if (Trigger.isUpdate) CallReportLockService.guardChildren(Trigger.new, Trigger.oldMap);
}