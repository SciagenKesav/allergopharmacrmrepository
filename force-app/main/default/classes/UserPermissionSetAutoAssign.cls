/**
 * Gives every user the permission sets mapped to their profile (Profile_Permission_Set_Map__mdt):
 * a Key Account Manager gets the KAM set, a Manager the Manager set, a Business Admin the Business
 * Admin set, plus the Sciagen Reports sets. Runs when a user is created, reactivated or moved to a
 * different profile (trigger UserPermissionSetAutoAssignTrigger) and can be run for existing users
 * with assignForAllActiveUsers().
 *
 * Additive only: it never removes a permission set, so a user moved to another profile keeps the
 * old profile's sets until an admin removes them. Assigning is done in a queueable so it never
 * collides with other DML in the transaction that saved the user (setup / non-setup mixed DML).
 */
public without sharing class UserPermissionSetAutoAssign implements Queueable {

    @TestVisible private static Boolean enableInTests = false;

    private Set<Id> userIds;

    public UserPermissionSetAutoAssign(Set<Id> userIds) { this.userIds = userIds; }

    public void execute(QueueableContext ctx) { assign(userIds); }

    /** Trigger entry point: queue the work for new / reactivated / re-profiled users. */
    public static void afterUserSave(List<User> newList, Map<Id, User> oldMap) {
        if (Test.isRunningTest() && !enableInTests) return;
        Set<Id> ids = new Set<Id>();
        for (User u : newList) {
            if (!u.IsActive) continue;
            User old = oldMap == null ? null : oldMap.get(u.Id);
            if (old == null || old.ProfileId != u.ProfileId || old.IsActive != u.IsActive) ids.add(u.Id);
        }
        if (ids.isEmpty()) return;
        if (System.isFuture() || System.isBatch() || Limits.getQueueableJobs() >= Limits.getLimitQueueableJobs()) {
            // can't queue from here; the nightly/one-off backfill (assignForAllActiveUsers) covers it
            return;
        }
        System.enqueueJob(new UserPermissionSetAutoAssign(ids));
    }

    /** Active mapping rows: profile name -> permission set API names. */
    @TestVisible
    private static Map<String, Set<String>> activeMap() {
        Map<String, Set<String>> m = new Map<String, Set<String>>();
        for (Profile_Permission_Set_Map__mdt r : Profile_Permission_Set_Map__mdt.getAll().values()) {
            if (r.Is_Active__c != true || String.isBlank(r.Profile_Name__c) || String.isBlank(r.Permission_Set_Name__c)) continue;
            if (!m.containsKey(r.Profile_Name__c)) m.put(r.Profile_Name__c, new Set<String>());
            m.get(r.Profile_Name__c).add(r.Permission_Set_Name__c);
        }
        return m;
    }

    /** Assigns whatever mapped permission sets the given active users are missing. Returns how many were added. */
    public static Integer assign(Set<Id> userIds) {
        if (userIds == null || userIds.isEmpty()) return 0;
        Map<String, Set<String>> rules = activeMap();
        if (rules.isEmpty()) return 0;

        Set<String> setNames = new Set<String>();
        for (Set<String> s : rules.values()) setNames.addAll(s);
        Map<String, Id> setIdByName = new Map<String, Id>();
        for (PermissionSet ps : [SELECT Id, Name FROM PermissionSet WHERE Name IN :setNames AND IsOwnedByProfile = false]) setIdByName.put(ps.Name, ps.Id);

        Set<String> have = new Set<String>();
        for (PermissionSetAssignment a : [SELECT AssigneeId, PermissionSetId FROM PermissionSetAssignment WHERE AssigneeId IN :userIds]) {
            have.add(a.AssigneeId + '|' + a.PermissionSetId);
        }

        List<PermissionSetAssignment> toAdd = new List<PermissionSetAssignment>();
        for (User u : [SELECT Id, Profile.Name FROM User WHERE Id IN :userIds AND IsActive = true]) {
            Set<String> wanted = rules.get(u.Profile.Name);
            if (wanted == null) continue;
            for (String n : wanted) {
                Id psId = setIdByName.get(n);
                if (psId != null && !have.contains(u.Id + '|' + psId)) toAdd.add(new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = psId));
            }
        }
        if (toAdd.isEmpty()) return 0;
        Integer added = 0;
        for (Database.SaveResult r : Database.insert(toAdd, false)) if (r.isSuccess()) added++;
        return added;
    }

    /** One-off / scheduled backfill: every active standard user whose profile is in the map. */
    public static Integer assignForAllActiveUsers() {
        Set<String> profiles = activeMap().keySet();
        Set<Id> ids = new Map<Id, User>([SELECT Id FROM User WHERE IsActive = true AND UserType = 'Standard' AND Profile.Name IN :profiles]).keySet();
        return assign(ids);
    }
}