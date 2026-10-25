// Adding, changing or removing an HCP attendee creates, re-points or removes
// that attendee's individual call (GroupCallService).
trigger GroupCallAttendeeSync on CVR_Attendee__c (after insert, after update, after delete, after undelete) {
    GroupCallService.afterAttendeeChange(Trigger.new, Trigger.old);
}