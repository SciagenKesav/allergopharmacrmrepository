// Group calls (GroupCallService): a group call's changes flow down to the
// individual calls kept for its attendees, those attendee calls can't be
// edited or deleted on their own, and deleting a group call removes them.
trigger GroupCallSync on Call_Visit_Report__c (before update, after update, before delete) {
    if (Trigger.isDelete) GroupCallService.beforeCallDelete(Trigger.old);
    else if (Trigger.isBefore) GroupCallService.guardAttendeeCalls(Trigger.new, Trigger.oldMap);
    else GroupCallService.afterCallUpdate(Trigger.new, Trigger.oldMap);
}