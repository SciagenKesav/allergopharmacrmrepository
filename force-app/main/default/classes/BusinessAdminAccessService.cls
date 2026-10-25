/**
 * Keeps every active user on the "Business Admin" profile assigned to the
 * Business_Admin_Full_Access permission set, so the full access follows the profile
 * without anyone having to remember to assign it:
 *   - a user created on (or moved to) the Business Admin profile, or reactivated on it,
 *     gets the permission set;
 *   - a user moved off the profile loses it.
 * Called from BusinessAdminPermissionSync (User, after insert / after update).
 * Assignment failures never block saving the user (partial-success DML).
 */
public without sharing class BusinessAdminAccessService {

    public static final String PROFILE_NAME = 'Business Admin';
    public static final String PERMISSION_SET_NAME = 'Business_Admin_Full_Access';

    public static void sync(List<User> news, Map<Id, User> oldMap) {
        List<PermissionSet> ps = [SELECT Id FROM PermissionSet WHERE Name = :PERMISSION_SET_NAME LIMIT 1];
        List<Profile> prof = [SELECT Id FROM Profile WHERE Name = :PROFILE_NAME LIMIT 1];
        if (ps.isEmpty() || prof.isEmpty()) return;
        Id psId = ps[0].Id;
        Id profileId = prof[0].Id;

        Set<Id> shouldHave = new Set<Id>();
        Set<Id> shouldNotHave = new Set<Id>();
        for (User u : news) {
            User old = oldMap == null ? null : oldMap.get(u.Id);
            Boolean isBA = u.ProfileId == profileId && u.IsActive;
            Boolean wasBA = old != null && old.ProfileId == profileId && old.IsActive;
            if (isBA && !wasBA) shouldHave.add(u.Id);
            else if (!isBA && wasBA) shouldNotHave.add(u.Id);
        }
        if (shouldHave.isEmpty() && shouldNotHave.isEmpty()) return;

        Set<Id> touched = new Set<Id>(shouldHave);
        touched.addAll(shouldNotHave);
        Set<Id> alreadyAssigned = new Set<Id>();
        List<PermissionSetAssignment> toRemove = new List<PermissionSetAssignment>();
        for (PermissionSetAssignment a : [
            SELECT Id, AssigneeId FROM PermissionSetAssignment
            WHERE PermissionSetId = :psId AND AssigneeId IN :touched
        ]) {
            if (shouldHave.contains(a.AssigneeId)) alreadyAssigned.add(a.AssigneeId);
            if (shouldNotHave.contains(a.AssigneeId)) toRemove.add(a);
        }

        List<PermissionSetAssignment> toAdd = new List<PermissionSetAssignment>();
        for (Id uid : shouldHave) {
            if (!alreadyAssigned.contains(uid)) toAdd.add(new PermissionSetAssignment(AssigneeId = uid, PermissionSetId = psId));
        }
        if (!toAdd.isEmpty()) Database.insert(toAdd, false);
        if (!toRemove.isEmpty()) Database.delete(toRemove, false);
    }
}
