@isTest
private class BusinessAdminAccessServiceTest {

    // Uses the running user, with in-memory profile values, instead of creating new users:
    // sandboxes have a limited number of licences, and the logic only needs a real user Id.

    private static Integer assignments(Id userId) {
        return [SELECT COUNT() FROM PermissionSetAssignment WHERE AssigneeId = :userId AND PermissionSet.Name = :BusinessAdminAccessService.PERMISSION_SET_NAME];
    }

    @isTest
    static void businessAdminProfileUserGetsThePermissionSetAndLosesItWhenMovedOff() {
        Id uid = UserInfo.getUserId();
        Id baProfile = [SELECT Id FROM Profile WHERE Name = :BusinessAdminAccessService.PROFILE_NAME LIMIT 1].Id;
        Id kamProfile = [SELECT Id FROM Profile WHERE Name = 'Key Account Manager' LIMIT 1].Id;
        delete [SELECT Id FROM PermissionSetAssignment WHERE AssigneeId = :uid AND PermissionSet.Name = :BusinessAdminAccessService.PERMISSION_SET_NAME];

        User onBusinessAdmin = new User(Id = uid, ProfileId = baProfile, IsActive = true);
        User onKam = new User(Id = uid, ProfileId = kamProfile, IsActive = true);

        // Created on / moved onto the Business Admin profile: assigned (once).
        BusinessAdminAccessService.sync(new List<User>{ onBusinessAdmin }, null);
        System.assertEquals(1, assignments(uid), 'A Business Admin profile user gets the permission set');
        BusinessAdminAccessService.sync(new List<User>{ onBusinessAdmin }, new Map<Id, User>{ uid => onKam });
        System.assertEquals(1, assignments(uid), 'Re-running must not duplicate the assignment');

        // Moved off the profile: removed.
        BusinessAdminAccessService.sync(new List<User>{ onKam }, new Map<Id, User>{ uid => onBusinessAdmin });
        System.assertEquals(0, assignments(uid), 'Moving off the profile removes it');

        // Deactivated while on the profile: removed too.
        BusinessAdminAccessService.sync(new List<User>{ onBusinessAdmin }, null);
        User inactive = new User(Id = uid, ProfileId = baProfile, IsActive = false);
        BusinessAdminAccessService.sync(new List<User>{ inactive }, new Map<Id, User>{ uid => onBusinessAdmin });
        System.assertEquals(0, assignments(uid), 'Deactivating removes it');
    }

    @isTest
    static void theUserTriggerRunsOnAnOrdinaryUpdateWithoutSideEffects() {
        Id uid = UserInfo.getUserId();
        Integer before = assignments(uid);
        update new User(Id = uid, Title = 'Business admin trigger test');
        System.assertEquals(before, assignments(uid), 'An update that does not change profile or active flag leaves assignments alone');
    }
}