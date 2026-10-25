trigger CVRPlannedCallLink on Call_Visit_Report__c (after insert, after update) {
    // Only reports that point at a planned call, and only when something the link
    // depends on actually changed -- an unrelated edit to an already-linked report
    // shouldn't touch its planned call again.
    List<Call_Visit_Report__c> toLink = new List<Call_Visit_Report__c>();
    for (Call_Visit_Report__c c : Trigger.new) {
        if (c.Source_Planned_Call__c == null) continue;
        Call_Visit_Report__c old = Trigger.isInsert ? null : Trigger.oldMap.get(c.Id);
        if (old == null
            || c.Source_Planned_Call__c != old.Source_Planned_Call__c
            || c.Record_Status__c != old.Record_Status__c) {
            toLink.add(c);
        }
    }
    if (!toLink.isEmpty()) {
        CVRPlannedCallLinkService.link(toLink);
    }
}