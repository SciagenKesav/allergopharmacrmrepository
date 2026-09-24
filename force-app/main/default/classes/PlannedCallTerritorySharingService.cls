/**
 * Apex-managed sharing for Planned_Call__c (Private OWD, no declarative sharing
 * rules) — mirrors TerritorySharingService's Sciagen_Account__c model exactly,
 * but for the calendar: a rep sees another rep's Planned_Call__c if they have a
 * User_Territory__c row for a Territory__c that also has an Account_Territory__c
 * row linking it to that call's HCP__c OR HCO__c (either is enough — most calls
 * carry both, but either alone is a valid link). This is what makes "My
 * Schedule" show every rep's calls for a shared territory, not just the
 * logged-in rep's own — see SciagenScheduleController.getMyPlannedCalls().
 *
 * A call with neither HCP__c nor HCO__c set (a standalone/venue-only event)
 * has nothing to derive territory from, so it's only ever visible to its
 * owner — same as before this class existed.
 *
 * `without sharing` is deliberate, same reasoning as TerritorySharingService:
 * this class IS the access-control mechanism, so it must compute sharing
 * independent of whatever access the running user already has.
 */
public without sharing class PlannedCallTerritorySharingService {

    private static final String SHARE_ACCESS_LEVEL = 'Edit';
    private static final String SHARE_ROW_CAUSE = 'Manual';

    /** Recomputes shares for every Planned_Call__c currently linked (via HCP__c
     * or HCO__c) to any account in the given territories. */
    public static void resyncForTerritories(Set<Id> territoryIds) {
        if (territoryIds == null || territoryIds.isEmpty()) return;

        Set<Id> accountIds = new Set<Id>();
        for (Account_Territory__c at : [SELECT Account__c FROM Account_Territory__c WHERE Territory__c IN :territoryIds]) {
            accountIds.add(at.Account__c);
        }
        resyncForAccounts(accountIds);
    }

    /** Recomputes shares for every Planned_Call__c referencing any of the given
     * accounts (as HCP__c or HCO__c). */
    public static void resyncForAccounts(Set<Id> accountIds) {
        if (accountIds == null || accountIds.isEmpty()) return;

        Set<Id> callIds = new Set<Id>();
        for (Planned_Call__c pc : [
            SELECT Id FROM Planned_Call__c WHERE HCP__c IN :accountIds OR HCO__c IN :accountIds
        ]) {
            callIds.add(pc.Id);
        }
        resyncForPlannedCalls(callIds);
    }

    /**
     * Recomputes shares for a specific set of Planned_Call__c rows: works out
     * who SHOULD have access (every user assigned to any territory the call's
     * HCP__c or HCO__c currently belongs to), diffs that against the
     * Apex-managed shares that already exist, and inserts/deletes only the
     * difference.
     */
    public static void resyncForPlannedCalls(Set<Id> callIds) {
        if (callIds == null || callIds.isEmpty()) return;

        Map<Id, Set<Id>> accountIdsByCall = new Map<Id, Set<Id>>();
        Map<Id, Id> ownerIdByCall = new Map<Id, Id>();
        Set<Id> allAccountIds = new Set<Id>();
        for (Planned_Call__c pc : [SELECT Id, HCP__c, HCO__c, OwnerId FROM Planned_Call__c WHERE Id IN :callIds]) {
            Set<Id> accts = new Set<Id>();
            if (pc.HCP__c != null) accts.add(pc.HCP__c);
            if (pc.HCO__c != null) accts.add(pc.HCO__c);
            accountIdsByCall.put(pc.Id, accts);
            ownerIdByCall.put(pc.Id, pc.OwnerId);
            allAccountIds.addAll(accts);
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

        // territory -> set of user ids assigned to it (skip admins — same
        // reasoning as TerritorySharingService: Salesforce rejects share rows
        // for users who already have system-wide access via their profile)
        Map<Id, Set<Id>> usersByTerritory = new Map<Id, Set<Id>>();
        if (!allTerritoryIds.isEmpty()) {
            for (User_Territory__c ta : [SELECT Territory__c, User__c FROM User_Territory__c WHERE Territory__c IN :allTerritoryIds AND User__c != null AND User__r.Profile.PermissionsViewAllData = false]) {
                if (!usersByTerritory.containsKey(ta.Territory__c)) {
                    usersByTerritory.put(ta.Territory__c, new Set<Id>());
                }
                usersByTerritory.get(ta.Territory__c).add(ta.User__c);
            }
        }

        // desired (call, user) pairs — union of both the HCP's and the HCO's
        // territory-assigned users, since either linked account is enough.
        // The call's own owner is excluded: Private OWD already grants them
        // full access, and Salesforce rejects a Manual share that would only
        // duplicate access the owner already has.
        Set<String> desiredPairs = new Set<String>();
        for (Id callId : callIds) {
            Set<Id> accts = accountIdsByCall.get(callId);
            if (accts == null || accts.isEmpty()) continue;
            Id ownerId = ownerIdByCall.get(callId);
            Set<Id> users = new Set<Id>();
            for (Id acctId : accts) {
                Set<Id> territories = territoriesByAccount.get(acctId);
                if (territories == null) continue;
                for (Id territoryId : territories) {
                    Set<Id> territoryUsers = usersByTerritory.get(territoryId);
                    if (territoryUsers != null) users.addAll(territoryUsers);
                }
            }
            users.remove(ownerId);
            for (Id userId : users) {
                desiredPairs.add(callId + ':' + userId);
            }
        }

        // existing Apex-managed shares (this class's own RowCause) for these calls
        List<Planned_Call__Share> existing = [
            SELECT Id, ParentId, UserOrGroupId
            FROM Planned_Call__Share
            WHERE ParentId IN :callIds AND RowCause = :SHARE_ROW_CAUSE
        ];

        List<Planned_Call__Share> toDelete = new List<Planned_Call__Share>();
        for (Planned_Call__Share s : existing) {
            String pair = s.ParentId + ':' + s.UserOrGroupId;
            if (desiredPairs.contains(pair)) {
                desiredPairs.remove(pair); // already exists, nothing to insert for it
            } else {
                toDelete.add(s);
            }
        }

        List<Planned_Call__Share> toInsert = new List<Planned_Call__Share>();
        for (String pair : desiredPairs) {
            List<String> parts = pair.split(':');
            toInsert.add(new Planned_Call__Share(
                ParentId = parts[0],
                UserOrGroupId = parts[1],
                AccessLevel = SHARE_ACCESS_LEVEL,
                RowCause = Schema.Planned_Call__Share.RowCause.Manual
            ));
        }

        if (!toDelete.isEmpty()) delete toDelete;
        if (!toInsert.isEmpty()) insert toInsert;
    }
}