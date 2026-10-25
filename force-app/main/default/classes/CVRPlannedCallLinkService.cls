/**
 * Keeps Planned_Call__c.Resulting_CVR__c in step with
 * Call_Visit_Report__c.Source_Planned_Call__c.
 *
 * The web report form writes Resulting_CVR__c itself (callVisitReportDetail.js,
 * handleHeaderSave), but a report created any other way -- notably from the iPad
 * app -- only ever sets Source_Planned_Call__c on the report. The planned call was
 * then never pointed at its report, so My Schedule kept offering "Log Visit"
 * (instead of "Open Call Report"), kept the call unlocked, and left it "Planned"
 * after the visit had been submitted. Doing it here makes the link independent of
 * which client created the report.
 *
 * Rules:
 *   - Resulting_CVR__c is only filled when empty; a call that already points at a
 *     report is never re-pointed at a different one.
 *   - Once the linked report is Submitted, a still-"Planned" call becomes
 *     "Completed" (the same state the Mark Completed action sets).
 *
 * Runs without sharing and with allOrNone=false: this is bookkeeping on the rep's
 * own planned call and must never block saving the report itself.
 */
public without sharing class CVRPlannedCallLinkService {

    public static void link(List<Call_Visit_Report__c> cvrs) {
        Map<Id, Call_Visit_Report__c> bySourceCall = new Map<Id, Call_Visit_Report__c>();
        for (Call_Visit_Report__c c : cvrs) {
            if (c.Source_Planned_Call__c != null) {
                bySourceCall.put(c.Source_Planned_Call__c, c);
            }
        }
        if (bySourceCall.isEmpty()) return;

        List<Planned_Call__c> toUpdate = new List<Planned_Call__c>();
        for (Planned_Call__c pc : [
            SELECT Id, Resulting_CVR__c, Status__c FROM Planned_Call__c WHERE Id IN :bySourceCall.keySet()
        ]) {
            Call_Visit_Report__c cvr = bySourceCall.get(pc.Id);
            Boolean changed = false;
            if (pc.Resulting_CVR__c == null) {
                pc.Resulting_CVR__c = cvr.Id;
                changed = true;
            }
            if (pc.Resulting_CVR__c == cvr.Id && cvr.Record_Status__c == 'Submitted' && pc.Status__c == 'Planned') {
                pc.Status__c = 'Completed';
                changed = true;
            }
            if (changed) toUpdate.add(pc);
        }
        if (!toUpdate.isEmpty()) {
            Database.update(toUpdate, false);
        }
    }
}