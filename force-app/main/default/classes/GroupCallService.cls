/**
 * Group calls: one call report, many HCPs.
 *
 * The rep records a single Call Visit Report for the primary HCP and adds the
 * other doctors present as CVR_Attendee__c rows (iPad "Add Attendees", web
 * CRM). For reach/frequency and each doctor's call history every attendee
 * must also have a call of their own, so this service keeps, for each
 * attendee other than the primary HCP, an individual child Call Visit Report:
 *
 *   group call (parent)   Is_Group_Call__c = true, Parent_Call__c blank
 *   attendee call (child) Is_Group_Call__c = true, Parent_Call__c = group call,
 *                         HCP__c = the attendee, fields mirrored from the group
 *                         call (MIRRORED_FIELDS); CVR_Attendee__c.Child_Call__c
 *                         points at it.
 *
 * Both carry Group_Attendee_Count__c (HCPs on the call, primary included).
 *
 * The group call stays the only record anyone edits: its changes (details,
 * Saved -> Submitted, a Help & Support unlock) flow down to the attendee
 * calls, an attendee removed from it loses their call, and the attendee
 * calls themselves reject direct edits and deletes (guardAttendeeCalls).
 * Only the call itself is mirrored -- samples, key messages, signatures,
 * check-in and the follow-up visit stay on the group call, so nothing is
 * counted twice (sample ledger, plan vs actual, follow-up planned calls).
 *
 * Runs without sharing: the rep may not see an attendee's other records,
 * and the lock on a submitted call is bypassed only while `syncing`.
 */
public without sharing class GroupCallService {

    /** True while this service writes; the lock and the guards below let those writes through. */
    public static Boolean syncing = false;

    /** Copied from the group call onto every attendee call: Sciagen App Config →
     *  Group Call Mirrored Fields (SciagenAppConfig.groupCallMirroredFields). */
    @TestVisible
    private static List<String> MIRRORED_FIELDS { get { return SciagenAppConfig.groupCallMirroredFields(); } }

    /** Attendee-call fields that only this service may change. */
    private static final List<String> MANAGED_FIELDS = new List<String>{
        'HCP__c', 'Parent_Call__c', 'Is_Group_Call__c', 'Group_Attendee_Count__c'
    };

    // ------------------------------------------------------------------ triggers

    /** CVR_Attendee__c after insert / update / delete / undelete. */
    public static void afterAttendeeChange(List<CVR_Attendee__c> news, List<CVR_Attendee__c> olds) {
        if (syncing || !SciagenAppConfig.groupCallsEnabled()) return;
        Set<Id> groupCallIds = new Set<Id>();
        for (List<CVR_Attendee__c> rows : new List<List<CVR_Attendee__c>>{ news, olds }) {
            if (rows == null) continue;
            for (CVR_Attendee__c a : rows) if (a.CVR__c != null) groupCallIds.add(a.CVR__c);
        }
        sync(groupCallIds);
    }

    /** Call_Visit_Report__c after update: push group-call changes down to the attendee calls. */
    public static void afterCallUpdate(List<Call_Visit_Report__c> news, Map<Id, Call_Visit_Report__c> oldMap) {
        if (syncing || !SciagenAppConfig.groupCallsEnabled()) return;
        Set<Id> groupCallIds = new Set<Id>();
        for (Call_Visit_Report__c c : news) {
            if (c.Parent_Call__c != null) continue;
            Call_Visit_Report__c o = oldMap.get(c.Id);
            if (c.Is_Group_Call__c != true && o.Is_Group_Call__c != true) continue;
            if (mirroredChanged(c, o) || c.HCP__c != o.HCP__c) groupCallIds.add(c.Id);
        }
        sync(groupCallIds);
    }

    /** Call_Visit_Report__c before update: attendee calls follow their group call only. */
    public static void guardAttendeeCalls(List<Call_Visit_Report__c> news, Map<Id, Call_Visit_Report__c> oldMap) {
        if (syncing || SciagenAccess.mergeInProgress) return;
        List<Call_Visit_Report__c> blocked = new List<Call_Visit_Report__c>();
        for (Call_Visit_Report__c c : news) {
            Call_Visit_Report__c o = oldMap.get(c.Id);
            if (o.Parent_Call__c == null) continue;
            if (mirroredChanged(c, o) || managedChanged(c, o)) blocked.add(c);
        }
        if (blocked.isEmpty() || SciagenAccess.hasModifyAllData()) return;
        for (Call_Visit_Report__c c : blocked) {
            c.addError('This call was created for an attendee of a group call. Edit the group call instead; this call follows it.');
        }
    }

    /**
     * Call_Visit_Report__c before delete: a group call takes its attendee calls
     * with it; an attendee call can't be deleted on its own (remove the
     * attendee from the group call instead).
     */
    public static void beforeCallDelete(List<Call_Visit_Report__c> olds) {
        if (syncing) return;
        Set<Id> groupCallIds = new Set<Id>();
        Boolean admin = null;
        for (Call_Visit_Report__c c : olds) {
            if (c.Parent_Call__c != null) {
                if (admin == null) admin = SciagenAccess.hasModifyAllData();
                if (!admin) c.addError('This call belongs to a group call. Remove the attendee from the group call instead.');
            } else if (c.Is_Group_Call__c == true) {
                groupCallIds.add(c.Id);
            }
        }
        if (groupCallIds.isEmpty()) return;
        List<Call_Visit_Report__c> children = [SELECT Id FROM Call_Visit_Report__c WHERE Parent_Call__c IN :groupCallIds];
        if (children.isEmpty()) return;
        syncing = true;
        try { delete children; } finally { syncing = false; }
    }

    // ------------------------------------------------------------------ sync

    /** Brings the attendee calls of the given group calls in line with their attendees and fields. */
    public static void sync(Set<Id> groupCallIds) {
        groupCallIds.remove(null);
        if (groupCallIds.isEmpty()) return;

        String soql = 'SELECT Id, OwnerId, HCP__c, Parent_Call__c, Is_Group_Call__c, Group_Attendee_Count__c, '
            + String.join(MIRRORED_FIELDS, ', ')
            + ', (SELECT Id, HCP__c, Child_Call__c FROM Attendees__r ORDER BY CreatedDate, Id)'
            + ' FROM Call_Visit_Report__c WHERE Id IN :groupCallIds AND Parent_Call__c = null';
        List<Call_Visit_Report__c> groupCalls = Database.query(soql);
        if (groupCalls.isEmpty()) return;

        Map<Id, Map<Id, Call_Visit_Report__c>> childrenByGroup = new Map<Id, Map<Id, Call_Visit_Report__c>>();
        String childSoql = 'SELECT Id, OwnerId, HCP__c, Parent_Call__c, Is_Group_Call__c, Group_Attendee_Count__c, '
            + String.join(MIRRORED_FIELDS, ', ') + ' FROM Call_Visit_Report__c WHERE Parent_Call__c IN :groupCallIds';
        List<Call_Visit_Report__c> extraChildren = new List<Call_Visit_Report__c>();
        for (Call_Visit_Report__c child : (List<Call_Visit_Report__c>) Database.query(childSoql)) {
            if (!childrenByGroup.containsKey(child.Parent_Call__c)) {
                childrenByGroup.put(child.Parent_Call__c, new Map<Id, Call_Visit_Report__c>());
            }
            Map<Id, Call_Visit_Report__c> byHcp = childrenByGroup.get(child.Parent_Call__c);
            if (child.HCP__c == null || byHcp.containsKey(child.HCP__c)) extraChildren.add(child);
            else byHcp.put(child.HCP__c, child);
        }

        List<Call_Visit_Report__c> parentUpdates = new List<Call_Visit_Report__c>();
        List<Call_Visit_Report__c> childUpserts = new List<Call_Visit_Report__c>();
        List<Call_Visit_Report__c> childDeletes = new List<Call_Visit_Report__c>(extraChildren);
        // attendee rows still to point at their child call, resolved after the upsert
        List<CVR_Attendee__c> links = new List<CVR_Attendee__c>();
        List<Call_Visit_Report__c> linkTargets = new List<Call_Visit_Report__c>();
        List<CVR_Attendee__c> unlinks = new List<CVR_Attendee__c>();

        for (Call_Visit_Report__c g : groupCalls) {
            // Distinct attendee HCPs other than the primary, in the order they were added.
            List<Id> others = new List<Id>();
            Set<Id> seen = new Set<Id>{ g.HCP__c };
            Map<Id, List<CVR_Attendee__c>> rowsByHcp = new Map<Id, List<CVR_Attendee__c>>();
            for (CVR_Attendee__c a : g.Attendees__r) {
                if (a.HCP__c == null) continue;
                if (!rowsByHcp.containsKey(a.HCP__c)) rowsByHcp.put(a.HCP__c, new List<CVR_Attendee__c>());
                rowsByHcp.get(a.HCP__c).add(a);
                if (seen.add(a.HCP__c)) others.add(a.HCP__c);
            }
            Boolean isGroup = !others.isEmpty();
            Integer count = isGroup ? others.size() + 1 : null;
            if (g.Is_Group_Call__c != isGroup || g.Group_Attendee_Count__c != count) {
                parentUpdates.add(new Call_Visit_Report__c(Id = g.Id, Is_Group_Call__c = isGroup, Group_Attendee_Count__c = count));
            }

            Map<Id, Call_Visit_Report__c> existing = childrenByGroup.containsKey(g.Id)
                ? childrenByGroup.get(g.Id) : new Map<Id, Call_Visit_Report__c>();
            for (Id hcpId : others) {
                Call_Visit_Report__c child = existing.remove(hcpId);
                Call_Visit_Report__c desired = childFor(g, hcpId, count, child);
                if (child == null || differsFrom(desired, child)) childUpserts.add(desired);
                for (CVR_Attendee__c a : rowsByHcp.get(hcpId)) {
                    if (child == null || a.Child_Call__c != child.Id) { links.add(a); linkTargets.add(desired); }
                }
            }
            // The primary HCP (also listed as an attendee) has the group call itself.
            if (rowsByHcp.containsKey(g.HCP__c)) {
                for (CVR_Attendee__c a : rowsByHcp.get(g.HCP__c)) {
                    if (a.Child_Call__c != null) unlinks.add(new CVR_Attendee__c(Id = a.Id, Child_Call__c = null));
                }
            }
            childDeletes.addAll(existing.values());   // attendees no longer on the call
        }

        syncing = true;
        try {
            if (!parentUpdates.isEmpty()) update parentUpdates;
            if (!childUpserts.isEmpty()) upsert childUpserts;
            List<CVR_Attendee__c> attendeeUpdates = new List<CVR_Attendee__c>(unlinks);
            for (Integer i = 0; i < links.size(); i++) {
                attendeeUpdates.add(new CVR_Attendee__c(Id = links[i].Id, Child_Call__c = linkTargets[i].Id));
            }
            if (!attendeeUpdates.isEmpty()) update attendeeUpdates;
            if (!childDeletes.isEmpty()) delete childDeletes;
        } finally {
            syncing = false;
        }
    }

    // ------------------------------------------------------------------ helpers

    private static Call_Visit_Report__c childFor(Call_Visit_Report__c g, Id hcpId, Integer count, Call_Visit_Report__c existing) {
        Call_Visit_Report__c c = existing == null
            ? new Call_Visit_Report__c(Parent_Call__c = g.Id, HCP__c = hcpId, OwnerId = g.OwnerId)
            : new Call_Visit_Report__c(Id = existing.Id);
        for (String f : MIRRORED_FIELDS) c.put(f, g.get(f));
        c.Is_Group_Call__c = true;
        c.Group_Attendee_Count__c = count;
        return c;
    }

    private static Boolean differsFrom(Call_Visit_Report__c desired, Call_Visit_Report__c current) {
        for (String f : MIRRORED_FIELDS) if (desired.get(f) != current.get(f)) return true;
        return current.Is_Group_Call__c != true || current.Group_Attendee_Count__c != desired.Group_Attendee_Count__c;
    }

    private static Boolean mirroredChanged(Call_Visit_Report__c a, Call_Visit_Report__c b) {
        for (String f : MIRRORED_FIELDS) if (a.get(f) != b.get(f)) return true;
        return false;
    }

    private static Boolean managedChanged(Call_Visit_Report__c a, Call_Visit_Report__c b) {
        for (String f : MANAGED_FIELDS) if (a.get(f) != b.get(f)) return true;
        return false;
    }
}