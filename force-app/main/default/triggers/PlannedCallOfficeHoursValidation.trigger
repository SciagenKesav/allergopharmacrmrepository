/**
 * Blocks a Planned_Call__c from being saved outside office hours — see
 * PlannedCallOfficeHoursValidator and Office_Hours_Setting__mdt (Default
 * record) for the actual window and comparison logic.
 */
trigger PlannedCallOfficeHoursValidation on Planned_Call__c (before insert, before update) {
    PlannedCallOfficeHoursValidator.validate(Trigger.new, Trigger.isUpdate ? Trigger.oldMap : null);
}
