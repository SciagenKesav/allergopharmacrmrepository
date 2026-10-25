/**
 * When a rep sets Next_Visit_Date__c on a Call Visit Report, auto-creates the
 * follow-up Planned_Call__c on My Schedule instead of leaving that as a
 * manual step. Next_Visit_Planned_Call__c both records the link and guards
 * against creating a second follow-up call on a later save of the same CVR.
 */
public without sharing class CVRNextVisitPlannedCallService {

    // The hour comes from Sciagen App Config (Follow-up Call Hour).

    public static void createFollowUpCalls(List<Call_Visit_Report__c> cvrs) {
        List<Call_Visit_Report__c> candidates = new List<Call_Visit_Report__c>();
        for (Call_Visit_Report__c c : cvrs) {
            if (c.Next_Visit_Date__c != null && c.Next_Visit_Planned_Call__c == null) {
                candidates.add(c);
            }
        }
        if (candidates.isEmpty()) return;

        // Inserted one at a time (not bulk `insert`) so a single CVR whose
        // Next Visit Date lands on a Sunday or outside business hours --
        // rejected by PlannedCallScheduleGuard -- can't roll back every other
        // CVR's follow-up call in the same trigger transaction. This is a
        // best-effort scheduling convenience; it must never block the CVR
        // save itself.
        List<Call_Visit_Report__c> cvrsToLink = new List<Call_Visit_Report__c>();
        for (Call_Visit_Report__c c : candidates) {
            Planned_Call__c nextCall = new Planned_Call__c(
                HCP__c = c.HCP__c,
                HCO__c = c.HCO__c,
                Call_DateTime__c = Datetime.newInstance(c.Next_Visit_Date__c, Time.newInstance(SciagenAppConfig.followUpCallHour(), 0, 0, 0)),
                Call_Type__c = c.Call_Type__c,
                Status__c = 'Planned'
            );
            try {
                Database.insert(nextCall, AccessLevel.USER_MODE);
                cvrsToLink.add(new Call_Visit_Report__c(Id = c.Id, Next_Visit_Planned_Call__c = nextCall.Id));
            } catch (DmlException e) {
                // Skip -- the rep can schedule the follow-up manually from My Schedule.
            }
        }
        if (!cvrsToLink.isEmpty()) {
            // System mode: Next_Visit_Planned_Call__c is a system-owned link the iPad rep has no FLS on
            // (audit H6), and a failed link must never fail the rep's call report save.
            Database.update(cvrsToLink, false);
        }
    }
}