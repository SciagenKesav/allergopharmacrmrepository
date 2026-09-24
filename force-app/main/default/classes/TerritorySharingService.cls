/**
 * Apex-managed sharing for Sciagen_Account__c (Private OWD, no declarative sharing rules —
 * see architecture doc §5/§19). A rep sees an account if and only if they have a
 * User_Territory__c row for a Territory__c that also has an Account_Territory__c row
 * linking it to that account. This class keeps Sciagen_Account__Share in sync with both
 * junctions; it does not touch record ownership.
 *
 * Exact-territory match only — deliberately does not walk Territory__c's Parent_Territory__c
 * hierarchy, since nothing in the current requirements calls for a rep on a parent Region to
 * see every child Territory's accounts.
 *
 * `without sharing` is deliberate: this class IS the access-control mechanism for
 * Sciagen_Account__c, so it must compute sharing independent of whatever access the running
 * user (e.g. the rep whose own trigger context invoked it) happens to already have.
 */
public without sharing class TerritorySharingService {

    private static final String SHARE_ACCESS_LEVEL = 'Edit';
    private static final String SHARE_ROW_CAUSE = 'Manual';

    /** Recomputes shares for every account currently linked to any of the given territories. */
    public static void resyncForTerritories(Set<Id> territoryIds) {
        if (territoryIds == null || territoryIds.isEmpty()) return;

        Set<Id> accountIds = new Set<Id>();
        for (Account_Territory__c at : [SELECT Account__c FROM Account_Territory__c WHERE Territory__c IN :territoryIds]) {
            accountIds.add(at.Account__c);
        }
        resyncForAccounts(accountIds);
    }

    /**
     * Recomputes shares for a specific set of accounts: works out who SHOULD have access
     * (every user assigned to any territory that account currently belongs to), diffs that
     * against the Apex-managed shares that already exist, and inserts/deletes only the
     * difference.
     */
    public static void resyncForAccounts(Set<Id> accountIds) {
        if (accountIds == null || accountIds.isEmpty()) return;

        // account -> set of territory ids it currently belongs to
        Map<Id, Set<Id>> territoriesByAccount = new Map<Id, Set<Id>>();
        Set<Id> allTerritoryIds = new Set<Id>();
        for (Account_Territory__c at : [SELECT Account__c, Territory__c FROM Account_Territory__c WHERE Account__c IN :accountIds]) {
            if (!territoriesByAccount.containsKey(at.Account__c)) {
                territoriesByAccount.put(at.Account__c, new Set<Id>());
            }
            territoriesByAccount.get(at.Account__c).add(at.Territory__c);
            allTerritoryIds.add(at.Territory__c);
        }

        // territory -> set of user ids assigned to it (User__c is optional on User_Territory__c,
        // so a placeholder territory row with no user yet is skipped rather than granting a share to null)
        Map<Id, Set<Id>> usersByTerritory = new Map<Id, Set<Id>>();
        if (!allTerritoryIds.isEmpty()) {
            // Skip admins (PermissionsViewAllData = true) — Salesforce rejects share rows
            // for users who already have system-wide access via their profile.
            for (User_Territory__c ta : [SELECT Territory__c, User__c FROM User_Territory__c WHERE Territory__c IN :allTerritoryIds AND User__c != null AND User__r.Profile.PermissionsViewAllData = false]) {
                if (!usersByTerritory.containsKey(ta.Territory__c)) {
                    usersByTerritory.put(ta.Territory__c, new Set<Id>());
                }
                usersByTerritory.get(ta.Territory__c).add(ta.User__c);
            }
        }

        // desired (account, user) pairs
        Set<String> desiredPairs = new Set<String>();
        for (Id accountId : accountIds) {
            Set<Id> territories = territoriesByAccount.get(accountId);
            if (territories == null) continue;
            for (Id territoryId : territories) {
                Set<Id> users = usersByTerritory.get(territoryId);
                if (users == null) continue;
                for (Id userId : users) {
                    desiredPairs.add(accountId + ':' + userId);
                }
            }
        }

        // existing Apex-managed shares (this class's own RowCause) for these accounts
        List<Sciagen_Account__Share> existing = [
            SELECT Id, ParentId, UserOrGroupId
            FROM Sciagen_Account__Share
            WHERE ParentId IN :accountIds AND RowCause = :SHARE_ROW_CAUSE
        ];

        List<Sciagen_Account__Share> toDelete = new List<Sciagen_Account__Share>();
        for (Sciagen_Account__Share s : existing) {
            String pair = s.ParentId + ':' + s.UserOrGroupId;
            if (desiredPairs.contains(pair)) {
                desiredPairs.remove(pair); // already exists, nothing to insert for it
            } else {
                toDelete.add(s);
            }
        }

        List<Sciagen_Account__Share> toInsert = new List<Sciagen_Account__Share>();
        for (String pair : desiredPairs) {
            List<String> parts = pair.split(':');
            Sciagen_Account__Share share = new Sciagen_Account__Share(
                ParentId = parts[0],
                UserOrGroupId = parts[1],
                AccessLevel = SHARE_ACCESS_LEVEL,
                RowCause = Schema.Sciagen_Account__Share.RowCause.Manual
            );
            toInsert.add(share);
        }

        if (!toDelete.isEmpty()) delete toDelete;
        if (!toInsert.isEmpty()) insert toInsert;
    }
}