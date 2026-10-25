// Mirrors CallVisitReportDeleteGuard: a Planned Call whose visit has already
// been written up and submitted (Resulting_CVR__c.Record_Status__c =
// 'Submitted') is the scheduling record behind a compliance audit trail --
// deleting it would let the underlying CVR resurface with no visible
// "planned" origin. Trigger.old doesn't carry the related CVR's own fields,
// so this needs its own query.
trigger PlannedCallDeleteGuard on Planned_Call__c (before delete) {
    // A Key Account Manager can't delete a Completed visit (the scheduling record behind
    // a call they've already made) -- enforced here so it holds for every entry point,
    // not just the My Schedule menu that hides Delete.
    String profileName = [SELECT Profile.Name FROM User WHERE Id = :UserInfo.getUserId() LIMIT 1].Profile.Name;
    if (profileName == 'Key Account Manager') {
        for (Planned_Call__c pc : Trigger.old) {
            if (pc.Status__c == 'Completed') {
                pc.addError('A completed call cannot be deleted.');
            }
        }
    }

    Set<Id> cvrIds = new Set<Id>();
    for (Planned_Call__c pc : Trigger.old) {
        if (pc.Resulting_CVR__c != null) {
            cvrIds.add(pc.Resulting_CVR__c);
        }
    }
    if (cvrIds.isEmpty()) {
        return;
    }

    Set<Id> submittedCvrIds = new Set<Id>();
    for (Call_Visit_Report__c cvr : [
        SELECT Id FROM Call_Visit_Report__c WHERE Id IN :cvrIds AND Record_Status__c = 'Submitted'
    ]) {
        submittedCvrIds.add(cvr.Id);
    }
    if (submittedCvrIds.isEmpty()) {
        return;
    }

    for (Planned_Call__c pc : Trigger.old) {
        if (pc.Resulting_CVR__c != null && submittedCvrIds.contains(pc.Resulting_CVR__c)) {
            pc.addError('This call\'s report has been submitted and can\'t be deleted.');
        }
    }
}