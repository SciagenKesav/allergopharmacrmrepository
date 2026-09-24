/**
 * Copies the requester's manager in by sharing the request with them (edit
 * access, so the manager can reply). The requester owns the request, and
 * Business Admins see everything through their permission set.
 */
public without sharing class SupportSharingService {

    public static final String REASON = 'Manager_CC__c';

    public static void sync(List<Support_Request__c> rows, Map<Id, Support_Request__c> oldMap) {
        Set<Id> changed = new Set<Id>();
        for (Support_Request__c r : rows) {
            Support_Request__c o = oldMap == null ? null : oldMap.get(r.Id);
            if (o == null || o.Manager__c != r.Manager__c || o.OwnerId != r.OwnerId) changed.add(r.Id);
        }
        if (changed.isEmpty()) return;

        Map<Id, Support_Request__Share> existing = new Map<Id, Support_Request__Share>();
        List<Support_Request__Share> stale = new List<Support_Request__Share>();
        for (Support_Request__Share s : [SELECT Id, ParentId, UserOrGroupId FROM Support_Request__Share WHERE ParentId IN :changed AND RowCause = :REASON]) {
            existing.put(s.ParentId, s);
        }
        List<Support_Request__Share> add = new List<Support_Request__Share>();
        for (Support_Request__c r : rows) {
            if (!changed.contains(r.Id)) continue;
            Support_Request__Share have = existing.get(r.Id);
            Boolean want = r.Manager__c != null && r.Manager__c != r.OwnerId;
            if (have != null && (!want || have.UserOrGroupId != r.Manager__c)) { stale.add(have); have = null; }
            if (want && have == null) {
                add.add(new Support_Request__Share(ParentId = r.Id, UserOrGroupId = r.Manager__c, AccessLevel = 'Edit', RowCause = REASON));
            }
        }
        if (!stale.isEmpty()) delete stale;
        if (!add.isEmpty()) Database.insert(add, false);
    }
}