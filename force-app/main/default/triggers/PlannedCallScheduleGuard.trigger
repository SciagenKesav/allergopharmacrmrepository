trigger PlannedCallScheduleGuard on Planned_Call__c (before insert, before update) {
    // Only re-validate rows where Call_DateTime__c is actually being set or
    // changed -- otherwise an unrelated update (e.g. "Mark Completed") on a
    // call that was scheduled before this rule existed would start failing
    // even though the rep isn't touching its date/time at all.
    List<Planned_Call__c> toCheck = new List<Planned_Call__c>();
    for (Planned_Call__c pc : Trigger.new) {
        Planned_Call__c old = Trigger.isInsert ? null : Trigger.oldMap.get(pc.Id);
        if (old == null || pc.Call_DateTime__c != old.Call_DateTime__c) {
            toCheck.add(pc);
        }
    }
    PlannedCallScheduleGuardService.validate(toCheck);
}