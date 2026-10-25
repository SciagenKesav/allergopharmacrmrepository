/**
 * Server-side lock on a submitted Call Visit Report (QA-30 / H3).
 *
 * Once Record_Status__c = 'Submitted' the report is a compliance record:
 * before update, any change to a business field, or moving the status off
 * Submitted, is rejected. Identical re-saves (the iPad re-PATCHes the whole
 * report on a retry) pass, because only real value changes count.
 *
 * Allowed through:
 *   (a) The support unlock flow. SupportUnlockService.unlock() sets
 *       `unlocking` around its own update, which moves the call back to Saved
 *       and stamps Unlocked_At__c / Unlocked_By__c / Unlock_Request__c /
 *       Unlock_Count__c. From Saved the rep edits freely and re-submits;
 *       SupportCallRelockTrigger then closes the request.
 *   (b) System/automation fields in AUTOMATION_FIELDS (follow-up planned call
 *       link, account-plan link, owner transfer, roll-ups), and merge
 *       re-pointing of HCP__c / HCO__c / Signee_Account__c — either inside a
 *       DuplicateMergeService merge/undo (SciagenAccess.mergeInProgress) or when the old
 *       and new value are a merged record and its survivor (the
 *       MergedRedirect trigger, whichever order the triggers run in).
 *   (c) Users with Modify All Data (administrators, data fixes).
 *   (d) GroupCallService keeping attendee calls in line with their group call.
 */
public without sharing class CallReportLockService {

    public static final String SUBMITTED = 'Submitted';

    /** Set only by SupportUnlockService.unlock() around its update. */
    public static Boolean unlocking = false;

    @TestVisible
    private static final Set<String> AUTOMATION_FIELDS = new Set<String>{
        'next_visit_planned_call__c',   // CVRNextVisitPlannedCallService links the follow-up call it created
        'plan__c',                      // AccountPlanController link/unlink of a call to an account plan
        'ownerid',                      // record transfer (e.g. a rep leaves); needs Transfer Record anyway
        'sample_drop_count__c', 'sample_total_value__c', 'signature_required_count__c'  // roll-up summaries
    };
    private static final Set<String> ACCOUNT_REFERENCES = new Set<String>{ 'hcp__c', 'hco__c', 'signee_account__c' };

    private static List<Schema.DescribeFieldResult> comparedFields;

    public static void beforeUpdate(List<Call_Visit_Report__c> news, Map<Id, Call_Visit_Report__c> oldMap) {
        // GroupCallService mirrors a group call onto its attendee calls (and flags the group call).
        if (unlocking || GroupCallService.syncing) return;
        List<Call_Visit_Report__c> locked = new List<Call_Visit_Report__c>();
        for (Call_Visit_Report__c c : news) {
            if (oldMap.get(c.Id).Record_Status__c == SUBMITTED) locked.add(c);
        }
        if (locked.isEmpty()) return;

        // First pass: which locked rows change anything, and which account re-points need a merge check.
        Map<Id, List<String>> changedByRow = new Map<Id, List<String>>();
        Set<Id> accountIds = new Set<Id>();
        for (Call_Visit_Report__c c : locked) {
            Call_Visit_Report__c o = oldMap.get(c.Id);
            List<String> changed = new List<String>();
            for (Schema.DescribeFieldResult d : fields()) {
                String key = d.getName().toLowerCase();
                if (AUTOMATION_FIELDS.contains(key)) continue;
                if (!differs(d, c.get(d.getName()), o.get(d.getName()))) continue;
                if (ACCOUNT_REFERENCES.contains(key)) {
                    if (SciagenAccess.mergeInProgress) continue;
                    if (c.get(d.getName()) != null) accountIds.add((Id) c.get(d.getName()));
                    if (o.get(d.getName()) != null) accountIds.add((Id) o.get(d.getName()));
                }
                changed.add(d.getName());
            }
            if (!changed.isEmpty()) changedByRow.put(c.Id, changed);
        }
        if (changedByRow.isEmpty()) return;
        if (SciagenAccess.hasModifyAllData()) return;

        Map<Id, Sciagen_Account__c> accounts = accountIds.isEmpty() ? new Map<Id, Sciagen_Account__c>()
            : new Map<Id, Sciagen_Account__c>([SELECT Id, Is_Merged__c, Merged_Into__c FROM Sciagen_Account__c WHERE Id IN :accountIds]);
        for (Call_Visit_Report__c c : locked) {
            List<String> changed = changedByRow.get(c.Id);
            if (changed == null) continue;
            Call_Visit_Report__c o = oldMap.get(c.Id);
            List<String> blocked = new List<String>();
            for (String f : changed) {
                if (ACCOUNT_REFERENCES.contains(f.toLowerCase()) && isMergeRedirect(accounts, (Id) o.get(f), (Id) c.get(f))) continue;
                blocked.add(f);
            }
            if (blocked.isEmpty()) continue;
            if (c.Record_Status__c != SUBMITTED) {
                c.addError('This call report has been submitted and is locked. Ask Business Admin to unlock it through a Help & Support request.');
            } else {
                c.addError('This call report has been submitted and is locked, so it can\'t be changed (' +
                    String.join(blocked, ', ').abbreviate(150) + '). Ask Business Admin to unlock it through a Help & Support request.');
            }
        }
    }

    // ------------------------------------------------------------------ children of a submitted report

    // Per child object, fields automation may still write on a submitted report.
    private static final Map<String, Set<String>> CHILD_AUTOMATION_FIELDS = new Map<String, Set<String>>{
        'Key_Message__c' => new Set<String>{ 'locked__c' },  // SciagenCVRController locks key messages on submit
        'CVR_Attendee__c' => new Set<String>{ 'child_call__c' }  // GroupCallService links the attendee's own call
    };
    private static Map<String, List<Schema.DescribeFieldResult>> childFields = new Map<String, List<Schema.DescribeFieldResult>>();

    /**
     * Before update / before delete on Key_Message__c, Promo_Drop__c, Sample_Drop__c, CVR_Attendee__c,
     * CVR_Internal_Attendee__c and CVR_Detail_Priority__c: once the parent report is Submitted its children are locked too -- a real
     * change or a delete is rejected (identical re-saves pass). Inserts stay allowed, because the iPad
     * pushes a submitted report first and its children right after. Same exemptions as the report:
     * the unlock flow, merge re-pointing, Modify All Data. Pass oldMap = null for a delete.
     */
    public static void guardChildren(List<SObject> rows, Map<Id, SObject> oldMap) {
        if (unlocking || rows == null || rows.isEmpty()) return;
        Boolean isDelete = oldMap == null;
        String objectName = rows[0].getSObjectType().getDescribe().getName();
        Set<String> allowed = CHILD_AUTOMATION_FIELDS.containsKey(objectName) ? CHILD_AUTOMATION_FIELDS.get(objectName) : new Set<String>();

        List<SObject> candidates = new List<SObject>();
        Map<Id, List<String>> changedByRow = new Map<Id, List<String>>();
        Set<Id> parentIds = new Set<Id>();
        for (SObject r : rows) {
            if (!isDelete) {
                SObject o = oldMap.get(r.Id);
                List<String> changed = new List<String>();
                for (Schema.DescribeFieldResult d : fieldsOf(r.getSObjectType())) {
                    String key = d.getName().toLowerCase();
                    if (allowed.contains(key)) continue;
                    if (key == 'hcp__c' && SciagenAccess.mergeInProgress) continue;
                    if (differs(d, r.get(d.getName()), o.get(d.getName()))) changed.add(d.getName());
                }
                if (changed.isEmpty()) continue;
                changedByRow.put(r.Id, changed);
            }
            candidates.add(r);
            if (r.get('CVR__c') != null) parentIds.add((Id) r.get('CVR__c'));
        }
        if (candidates.isEmpty()) return;
        // (Apex names are case-insensitive: a local called "submitted" would shadow SUBMITTED.)
        Set<Id> lockedParents = new Set<Id>();
        for (Call_Visit_Report__c c : [SELECT Id FROM Call_Visit_Report__c WHERE Id IN :parentIds AND Record_Status__c = :SUBMITTED]) lockedParents.add(c.Id);
        if (lockedParents.isEmpty()) return;
        if (SciagenAccess.hasModifyAllData()) return;

        // An attendee re-sent with a merged doctor's old id is redirected, not a change.
        Set<Id> accountIds = new Set<Id>();
        for (SObject r : candidates) {
            List<String> changed = changedByRow.get(r.Id);
            if (changed != null && changed.size() == 1 && changed[0] == 'HCP__c') {
                if (r.get('HCP__c') != null) accountIds.add((Id) r.get('HCP__c'));
                if (oldMap.get(r.Id).get('HCP__c') != null) accountIds.add((Id) oldMap.get(r.Id).get('HCP__c'));
            }
        }
        Map<Id, Sciagen_Account__c> accounts = accountIds.isEmpty() ? new Map<Id, Sciagen_Account__c>()
            : new Map<Id, Sciagen_Account__c>([SELECT Id, Is_Merged__c, Merged_Into__c FROM Sciagen_Account__c WHERE Id IN :accountIds]);
        for (SObject r : candidates) {
            if (!lockedParents.contains((Id) r.get('CVR__c'))) continue;
            if (isDelete) {
                r.addError('This call report has been submitted, so its details can\'t be deleted. Ask Business Admin to unlock it through a Help & Support request.');
                continue;
            }
            List<String> changed = changedByRow.get(r.Id);
            if (changed.size() == 1 && changed[0] == 'HCP__c'
                    && isMergeRedirect(accounts, (Id) oldMap.get(r.Id).get('HCP__c'), (Id) r.get('HCP__c'))) continue;
            r.addError('This call report has been submitted and is locked, so its details can\'t be changed (' +
                String.join(changed, ', ').abbreviate(150) + '). Ask Business Admin to unlock it through a Help & Support request.');
        }
    }

    private static List<Schema.DescribeFieldResult> fieldsOf(Schema.SObjectType t) {
        String key = String.valueOf(t);
        if (!childFields.containsKey(key)) {
            List<Schema.DescribeFieldResult> out = new List<Schema.DescribeFieldResult>();
            for (Schema.SObjectField f : t.getDescribe().fields.getMap().values()) {
                Schema.DescribeFieldResult d = f.getDescribe();
                if (!d.isCustom() && d.getName() != 'Name') continue;
                if (d.isCalculated() || d.isAutoNumber()) continue;
                if (d.getType() == Schema.DisplayType.LOCATION || d.getType() == Schema.DisplayType.ADDRESS) continue;
                out.add(d);
            }
            childFields.put(key, out);
        }
        return childFields.get(key);
    }

    /** One side is a merged record whose survivor is the other side. */
    private static Boolean isMergeRedirect(Map<Id, Sciagen_Account__c> accounts, Id oldId, Id newId) {
        if (oldId == null || newId == null) return false;
        Sciagen_Account__c o = accounts.get(oldId), n = accounts.get(newId);
        return (o != null && o.Is_Merged__c == true && o.Merged_Into__c == newId)
            || (n != null && n.Is_Merged__c == true && n.Merged_Into__c == oldId);
    }

    /** Custom fields plus Name; formula, auto-number and compound (Location) fields are skipped (their parts are compared). */
    private static List<Schema.DescribeFieldResult> fields() {
        if (comparedFields != null) return comparedFields;
        comparedFields = new List<Schema.DescribeFieldResult>();
        for (Schema.SObjectField f : Schema.SObjectType.Call_Visit_Report__c.fields.getMap().values()) {
            Schema.DescribeFieldResult d = f.getDescribe();
            String n = d.getName();
            if (!d.isCustom() && n != 'Name' && n != 'OwnerId') continue;
            if (d.isCalculated() || d.isAutoNumber()) continue;
            if (d.getType() == Schema.DisplayType.LOCATION || d.getType() == Schema.DisplayType.ADDRESS) continue;
            comparedFields.add(d);
        }
        return comparedFields;
    }

    /** A real change: tolerant of null vs blank text, number scale and sub-second datetime noise from clients. */
    @TestVisible
    private static Boolean differs(Schema.DescribeFieldResult d, Object a, Object b) {
        if (a instanceof String || b instanceof String) {
            String sa = (String) a, sb = (String) b;
            if (String.isBlank(sa) && String.isBlank(sb)) return false;
            if (sa == null || sb == null) return true;
            return !sa.equals(sb);   // case-sensitive: Apex == on strings ignores case
        }
        if (a == null || b == null) return a != b;
        if (a instanceof Decimal && b instanceof Decimal) {
            Integer scale = d.getScale() == null ? 2 : d.getScale();
            return ((Decimal) a).setScale(scale, RoundingMode.HALF_UP) != ((Decimal) b).setScale(scale, RoundingMode.HALF_UP);
        }
        if (a instanceof Double && b instanceof Double) {
            Integer scale = d.getScale() == null ? 2 : d.getScale();
            return Decimal.valueOf((Double) a).setScale(scale, RoundingMode.HALF_UP) != Decimal.valueOf((Double) b).setScale(scale, RoundingMode.HALF_UP);
        }
        if (a instanceof Datetime && b instanceof Datetime) {
            return ((Datetime) a).getTime() / 1000 != ((Datetime) b).getTime() / 1000;
        }
        return a != b;
    }
}