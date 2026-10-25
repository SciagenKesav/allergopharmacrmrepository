trigger CVRNextVisitPlannedCall on Call_Visit_Report__c (after insert, after update) {
    List<Call_Visit_Report__c> toCheck = new List<Call_Visit_Report__c>();
    for (Call_Visit_Report__c c : Trigger.new) {
        Call_Visit_Report__c old = Trigger.isInsert ? null : Trigger.oldMap.get(c.Id);
        if (c.Next_Visit_Date__c != null && (old == null || c.Next_Visit_Date__c != old.Next_Visit_Date__c)) {
            toCheck.add(c);
        }
    }
    if (!toCheck.isEmpty()) {
        CVRNextVisitPlannedCallService.createFollowUpCalls(toCheck);
    }
}