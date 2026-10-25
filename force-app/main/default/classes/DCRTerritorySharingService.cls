/**
 * Apex-managed sharing for Data_Change_Request__c (Private OWD, no declarative sharing
 * rules — same architecture as Sciagen_Account__c/RCPA_Audit__c, see
 * TerritorySharingService/RCPAAuditTerritorySharingService). Unlike RCPA_Audit__c, a DCR
 * carries no Territory__c of its own — it's derived one hop further out, through whichever
 * of its two Account lookups is populated:
 *   - Subject_Account__c: the existing HCP/HCO an "Edit HCP"/"Edit HCO" request targets.
 *   - Related_HCO__c: the existing parent HCO a "New HCP" request is being added under.
 * Subject_Account__c is preferred when both happen to be set. A "New HCO" request (or any
 * request with neither populated, since the account it's about doesn't exist yet) has
 * nothing to derive sharing from, so it's only ever visible to its owner — same fallback
 * RCPAAuditTerritorySharingService uses for an audit with no Territory__c set.
 *
 * `without sharing` is deliberate, same reasoning as its siblings: this class IS the
 * access-control mechanism for Data_Change_Request__c, so it must compute sharing
 * independent of whatever access the running user already has.
 *
 * Walks Territory__c's Parent_Territory__c hierarchy via TerritoryHierarchyUtil, same as
 * TerritorySharingService: a manager assigned to a parent territory sees DCRs for every
 * child territory's accounts too.
 *
 * See TerritorySharingService for why the final delete runs at AccessLevel.SYSTEM_MODE
 * while the final insert instead defers any INSUFFICIENT_ACCESS_ON_CROSS_REFERENCE_ENTITY
 * failure to DeferredShareInsertQueueable: that error fires whenever the parent record was
 * itself just inserted earlier in the same transaction, and SYSTEM_MODE does not bypass it.
 */
public without sharing class DCRTerritorySharingService {

    private static final String SHARE_ACCESS_LEVEL = 'Edit';
    private static final String SHARE_ROW_CAUSE = 'Manual';

    /** Recomputes shares for every DCR whose derived account currently belongs to any of the given territories or their descendants. */
    public static void resyncForTerritories(Set<Id> territoryIds) {
        if (territoryIds == null || territoryIds.isEmpty()) return;

        Set<Id> expandedTerritoryIds = TerritoryHierarchyUtil.withDescendants(territoryIds);
        Set<Id> accountIds = new Set<Id>();
        for (Account_Territory__c at : [SELECT Account__c FROM Account_Territory__c WHERE Territory__c IN :expandedTerritoryIds]) {
            accountIds.add(at.Account__c);
        }
        resyncForAccounts(accountIds);
    }

    /** Recomputes shares for every DCR that references any of the given accounts, either as Subject_Account__c or Related_HCO__c. */
    public static void resyncForAccounts(Set<Id> accountIds) {
        if (accountIds == null || accountIds.isEmpty()) return;

        Set<Id> requestIds = new Set<Id>();
        for (Data_Change_Request__c dcr : [
            SELECT Id FROM Data_Change_Request__c
            WHERE Subject_Account__c IN :accountIds OR Related_HCO__c IN :accountIds
        ]) {
            requestIds.add(dcr.Id);
        }
        resyncForRequests(requestIds);
    }

    /**
     * Recomputes shares for a specific set of DCRs: derives each one's account (preferring
     * Subject_Account__c, falling back to Related_HCO__c), works out who SHOULD have access
     * (every non-admin user assigned to a territory that account belongs to, excluding the
     * DCR's own owner), diffs that against the Apex-managed shares that already exist, and
     * inserts/deletes only the difference.
     */
    public static void resyncForRequests(Set<Id> requestIds) {
        if (requestIds == null || requestIds.isEmpty()) return;

        Map<Id, Id> accountByRequest = new Map<Id, Id>();
        Map<Id, Id> ownerByRequest = new Map<Id, Id>();
        Set<Id> allAccountIds = new Set<Id>();
        for (Data_Change_Request__c dcr : [
            SELECT Id, OwnerId, Subject_Account__c, Related_HCO__c
            FROM Data_Change_Request__c
            WHERE Id IN :requestIds
        ]) {
            ownerByRequest.put(dcr.Id, dcr.OwnerId);
            Id accountId = dcr.Subject_Account__c != null ? dcr.Subject_Account__c : dcr.Related_HCO__c;
            if (accountId != null) {
                accountByRequest.put(dcr.Id, accountId);
                allAccountIds.add(accountId);
            }
        }

        // account -> set of territory ids it currently belongs to
        Map<Id, Set<Id>> territoriesByAccount = new Map<Id, Set<Id>>();
        Set<Id> allTerritoryIds = new Set<Id>();
        if (!allAccountIds.isEmpty()) {
            for (Account_Territory__c at : [SELECT Account__c, Territory__c FROM Account_Territory__c WHERE Account__c IN :allAccountIds]) {
                if (!territoriesByAccount.containsKey(at.Account__c)) {
                    territoriesByAccount.put(at.Account__c, new Set<Id>());
                }
                territoriesByAccount.get(at.Account__c).add(at.Territory__c);
                allTerritoryIds.add(at.Territory__c);
            }
        }

        // A user assigned to a PARENT territory should also see every child's DCRs, so resolve
        // each account's territory to itself plus every ancestor before matching users.
        Map<Id, Set<Id>> ancestorsByTerritory = TerritoryHierarchyUtil.ancestorsByTerritory(allTerritoryIds);
        Set<Id> allRelevantTerritoryIds = new Set<Id>();
        for (Set<Id> ancestors : ancestorsByTerritory.values()) {
            allRelevantTerritoryIds.addAll(ancestors);
        }

        // territory -> set of ACTIVE user ids assigned to it. A deactivated user left on a territory
        // (e.g. a replaced manager) made the share insert throw "operation performed with inactive
        // user" and rolled back the whole DCR, so new HCP requests under that territory never arrived.
        // (skip admins — Salesforce rejects
        // share rows for users who already have system-wide access via their profile,
        // same reasoning as TerritorySharingService/RCPAAuditTerritorySharingService)
        Map<Id, Set<Id>> usersByTerritory = new Map<Id, Set<Id>>();
        if (!allRelevantTerritoryIds.isEmpty()) {
            for (User_Territory__c ut : [
                SELECT Territory__c, User__c
                FROM User_Territory__c
                WHERE Territory__c IN :allRelevantTerritoryIds AND User__c != null AND User__r.Profile.PermissionsViewAllData = false AND User__r.IsActive = true
            ]) {
                if (!usersByTerritory.containsKey(ut.Territory__c)) {
                    usersByTerritory.put(ut.Territory__c, new Set<Id>());
                }
                usersByTerritory.get(ut.Territory__c).add(ut.User__c);
            }
        }

        // desired (request, user) pairs — the request's own owner is excluded: Private OWD
        // already grants them full access, and Salesforce rejects a Manual share that would
        // only duplicate access the owner already has.
        Set<String> desiredPairs = new Set<String>();
        for (Id requestId : requestIds) {
            Id accountId = accountByRequest.get(requestId);
            if (accountId == null) continue;
            Set<Id> territories = territoriesByAccount.get(accountId);
            if (territories == null) continue;
            Id ownerId = ownerByRequest.get(requestId);
            Set<Id> relevantTerritories = new Set<Id>();
            for (Id territoryId : territories) {
                relevantTerritories.addAll(ancestorsByTerritory.get(territoryId));
            }
            for (Id territoryId : relevantTerritories) {
                Set<Id> users = usersByTerritory.get(territoryId);
                if (users == null) continue;
                for (Id userId : users) {
                    if (userId == ownerId) continue;
                    desiredPairs.add(requestId + ':' + userId);
                }
            }
        }

        // existing Apex-managed shares (this class's own RowCause) for these requests
        List<Data_Change_Request__Share> existing = [
            SELECT Id, ParentId, UserOrGroupId
            FROM Data_Change_Request__Share
            WHERE ParentId IN :requestIds AND RowCause = :SHARE_ROW_CAUSE
        ];

        List<Data_Change_Request__Share> toDelete = new List<Data_Change_Request__Share>();
        for (Data_Change_Request__Share s : existing) {
            String pair = s.ParentId + ':' + s.UserOrGroupId;
            if (desiredPairs.contains(pair)) {
                desiredPairs.remove(pair); // already exists, nothing to insert for it
            } else {
                toDelete.add(s);
            }
        }

        List<Data_Change_Request__Share> toInsert = new List<Data_Change_Request__Share>();
        for (String pair : desiredPairs) {
            List<String> parts = pair.split(':');
            toInsert.add(new Data_Change_Request__Share(
                ParentId = parts[0],
                UserOrGroupId = parts[1],
                AccessLevel = SHARE_ACCESS_LEVEL,
                RowCause = Schema.Data_Change_Request__Share.RowCause.Manual
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
    private static void insertDeferringCrossReferenceFailures(List<Data_Change_Request__Share> toInsert) {
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