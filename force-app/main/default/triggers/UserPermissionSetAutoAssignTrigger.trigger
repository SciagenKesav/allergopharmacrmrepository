trigger UserPermissionSetAutoAssignTrigger on User (after insert, after update) {
    UserPermissionSetAutoAssign.afterUserSave(Trigger.new, Trigger.isUpdate ? Trigger.oldMap : null);
}
