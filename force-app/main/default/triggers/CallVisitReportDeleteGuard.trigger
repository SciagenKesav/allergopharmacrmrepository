// A Submitted Call Visit Report is a compliance/audit record of a rep's
// visit -- once submitted it must not be deletable by anyone, the same way
// the report itself and its Key_Message__c children lock for editing on
// submit (see SciagenCVRController.submitCallReport). Without this guard,
// the only thing stopping a rep from deleting one was the client apps
// simply not offering a Delete button -- trivially bypassable via the API,
// Data Loader, or a future UI that adds one without knowing this rule exists.
//
// Before update: the same record is also locked for editing on the server
// (CallReportLockService) -- business fields and the status can't change
// once submitted, except through the Help & Support unlock flow, a small
// allow-list of automation fields, merge re-pointing, or Modify All Data.
// The lock only compares old vs new values and treats merge re-pointing in
// either direction as allowed, so it is safe whichever order it runs in
// relative to MergedRedirectCallVisitReport and SampleCallTrigger.
trigger CallVisitReportDeleteGuard on Call_Visit_Report__c (before update, before delete) {
    if (Trigger.isUpdate) {
        CallReportLockService.beforeUpdate(Trigger.new, Trigger.oldMap);
        return;
    }
    if (GroupCallService.syncing) return;   // removing an attendee's call along with the attendee
    for (Call_Visit_Report__c cvr : Trigger.old) {
        if (cvr.Record_Status__c == 'Submitted') {
            cvr.addError('This call report has been submitted and can\'t be deleted.');
        }
    }
}