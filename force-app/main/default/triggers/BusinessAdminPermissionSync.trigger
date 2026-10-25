// Assigns / removes the Business_Admin_Full_Access permission set as users join or leave
// the Business Admin profile. See BusinessAdminAccessService.
trigger BusinessAdminPermissionSync on User (after insert, after update) {
    BusinessAdminAccessService.sync(Trigger.new, Trigger.isUpdate ? Trigger.oldMap : null);
}
