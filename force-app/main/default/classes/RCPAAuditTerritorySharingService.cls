/**
 * Apex-managed sharing for RCPA_Audit__c (Private OWD, no declarative sharing
 * rules — same architecture as Sciagen_Account__c/Planned_Call__c, see
 * TerritorySharingService/PlannedCallTerritorySharingService). Unlike those
 * two, RCPA_Audit__c doesn't need to derive territory through an
 * Account_Territory__c junction — it carries its own Territory__c lookup
 * directly (set from RCPAController.getTerritoryOptions() when the audit is
 * created), so a rep sees another rep's audit if and only if they have a
 * User_Territory__c row for that same Territory__c. Record ownership is
 * untouched; this only adds/removes the extra Manual share.
 *
 * An audit with no Territory__c set has nothing to derive sharing from, so
 * it's only ever visible to its owner — same fallback PlannedCallTerritory-
 * SharingService uses for a call with neither HCP__c nor HCO__c.
 *
 * `without sharing` is deliberate, same reasoning as its siblings: this
 * class IS the access-control mechanism for RCPA_Audit__c, so it must
 * compute sharing independent of whatever access the running user already
 * has.
 *
 * Walks Territory__c's Parent_Territory__c hierarchy via TerritoryHierarchyUtil, same as
 * TerritorySharingService: a manager assigned to a parent territory sees audits tagged with
 * any of its child territories too.
 *
 * See TerritorySharingService for why the final delete runs at AccessLevel.SYSTEM_MODE
 * while the final insert instead defers any INSUFFICIENT_ACCESS_ON_CROSS_REFERENCE_ENTITY
 * failure to DeferredShareInsertQueueable: that error fires whenever the parent record was
 * itself just inserted earlier in the same transaction, and SYSTEM_MODE does not bypass it.
 */
public without sharing class RCPAAuditTerritorySharingService {

    private static final String SHARE_ACCESS_LEVEL = 'Edit';
    private static final String SHARE_ROW_CAUSE = 'Manual';

    /** Recomputes shares for every RCPA_Audit__c currently assigned to any of the given territories or their descendants. */
    public static void resyncForTerritories(Set<Id> territoryIds) {
        if (territoryIds == null || territoryIds.isEmpty()) return;

        Set<Id> expandedTerritoryIds = TerritoryHierarchyUtil.withDescendants(territoryIds);
        Set<Id> auditIds = new Set<Id>();
        for (RCPA_Audit__c a : [SELECT Id FROM RCPA_Audit__c WHERE Territory__c IN :expandedTerritoryIds]) {
            auditIds.add(a.Id);
        }
        resyncForAudits(auditIds);
    }

    /**
     * Recomputes shares for a specific set of audits: works out who SHOULD
     * have access (every user assigned to that audit's Territory__c), diffs
     * that against the Apex-managed shares that already exist, and
     * inserts/deletes only the difference.
     */
    public static void resyncForAudits(Set<Id> auditIds) {
        if (auditIds == null || auditIds.isEmpty()) return;

        Map<Id, Id> territoryByAudit = new Map<Id, Id>();
        Map<Id, Id> ownerByAudit = new Map<Id, Id>();
        Set<Id> allTerritoryIds = new Set<Id>();
        for (RCPA_Audit__c a : [SELECT Id, Territory__c, OwnerId FROM RCPA_Audit__c WHERE Id IN :auditIds]) {
            ownerByAudit.put(a.Id, a.OwnerId);
            if (a.Territory__c != null) {
                territoryByAudit.put(a.Id, a.Territory__c);
                allTerritoryIds.add(a.Territory__c);
            }
        }

        // A user assigned to a PARENT territory should also see audits for every child, so
        // resolve each audit's territory to itself plus every ancestor before matching users.
        Map<Id, Set<Id>> ancestorsByTerritory = TerritoryHierarchyUtil.ancestorsByTerritory(allTerritoryIds);
        Set<Id> allRelevantTerritoryIds = new Set<Id>();
        for (Set<Id> ancestors : ancestorsByTerritory.values()) {
            allRelevantTerritoryIds.addAll(ancestors);
        }

        // territory -> set of user ids assigned to it (skip admins — Salesforce
        // rejects share rows for users who already have system-wide access via
        // their profile, same reasoning as TerritorySharingService)
        Map<Id, Set<Id>> usersByTerritory = new Map<Id, Set<Id>>();
        if (!allRelevantTerritoryIds.isEmpty()) {
            for (User_Territory__c ut : [
                SELECT Territory__c, User__c
                FROM User_Territory__c
                WHERE Territory__c IN :allRelevantTerritoryIds AND User__c != null AND User__r.IsActive = true AND User__r.Profile.PermissionsViewAllData = false
            ]) {
                if (!usersByTerritory.containsKey(ut.Territory__c)) {
                    usersByTerritory.put(ut.Territory__c, new Set<Id>());
                }
                usersByTerritory.get(ut.Territory__c).add(ut.User__c);
            }
        }

        // desired (audit, user) pairs — the audit's own owner is excluded:
        // Private OWD already grants them full access, and Salesforce rejects
        // a Manual share that would only duplicate access the owner already has.
        Set<String> desiredPairs = new Set<String>();
        for (Id auditId : auditIds) {
            Id territoryId = territoryByAudit.get(auditId);
            if (territoryId == null) continue;
            Id ownerId = ownerByAudit.get(auditId);
            for (Id relevantTerritoryId : ancestorsByTerritory.get(territoryId)) {
                Set<Id> users = usersByTerritory.get(relevantTerritoryId);
                if (users == null) continue;
                for (Id userId : users) {
                    if (userId == ownerId) continue;
                    desiredPairs.add(auditId + ':' + userId);
                }
            }
        }

        // existing Apex-managed shares (this class's own RowCause) for these audits
        List<RCPA_Audit__Share> existing = [
            SELECT Id, ParentId, UserOrGroupId
            FROM RCPA_Audit__Share
            WHERE ParentId IN :auditIds AND RowCause = :SHARE_ROW_CAUSE
        ];

        List<RCPA_Audit__Share> toDelete = new List<RCPA_Audit__Share>();
        for (RCPA_Audit__Share s : existing) {
            String pair = s.ParentId + ':' + s.UserOrGroupId;
            if (desiredPairs.contains(pair)) {
                desiredPairs.remove(pair); // already exists, nothing to insert for it
            } else {
                toDelete.add(s);
            }
        }

        List<RCPA_Audit__Share> toInsert = new List<RCPA_Audit__Share>();
        for (String pair : desiredPairs) {
            List<String> parts = pair.split(':');
            toInsert.add(new RCPA_Audit__Share(
                ParentId = parts[0],
                UserOrGroupId = parts[1],
                AccessLevel = SHARE_ACCESS_LEVEL,
                RowCause = Schema.RCPA_Audit__Share.RowCause.Manual
            ));
        }

        if (!toDelete.isEmpty()) Database.delete(toDelete, AccessLevel.SYSTEM_MODE);
        insertDeferringCrossReferenceFailures(toInsert);
    }

    /**
     * Inserts the given shares at SYSTEM_MODE; any that fail specifically with
     * INSUFFICIENT_ACCESS_ON_CROSS_REFERENCE_ENTITY are retried in a later transaction via
     * DeferredShareInsertQueueable instead of failing the caller's DML. Any other failure
     * still throws.
     */
    private static void insertDeferringCrossReferenceFailures(List<RCPA_Audit__Share> toInsert) {
        if (toInsert.isEmpty()) return;

        Database.SaveResult[] results = Database.insert(toInsert, false, AccessLevel.SYSTEM_MODE);
        List<SObject> deferred = new List<SObject>();
        for (Integer i = 0; i < results.size(); i++) {
            if (results[i].isSuccess()) continue;

            Boolean isCrossReferenceTiming = false;
            for (Database.Error err : results[i].getErrors()) {
                if (err.getStatusCode() == StatusCode.INSUFFICIENT_ACCESS_ON_CROSS_REFERENCE_ENTITY) {
                    isCrossReferenceTiming = true;
                }
            }

            if (isCrossReferenceTiming) {
                deferred.add(toInsert[i]);
            } else {
                throw new DmlException(results[i].getErrors()[0].getMessage());
            }
        }

        if (!deferred.isEmpty()) {
            System.enqueueJob(new DeferredShareInsertQueueable(deferred));
        }
    }
}