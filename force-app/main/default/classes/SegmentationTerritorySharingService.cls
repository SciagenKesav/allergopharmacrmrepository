/**
 * Apex-managed sharing for Segmentation__c (Private OWD): a user who can see an
 * HCP through a territory can also see and edit that HCP's segmentation. Mirrors
 * PlannedCallTerritorySharingService / TerritorySharingService.
 *
 * Why it exists: Segmentation__c is Private and nothing shared it, so a KAM could
 * open an HCP (shared through their territory) but got INSUFFICIENT_ACCESS_OR_READONLY
 * when the iPad or web tried to change that HCP's segmentation, because most
 * segmentation rows are owned by an admin or another user.
 *
 * Rule: a segmentation row is shared (Edit, Manual) with every user assigned, through
 * User_Territory__c, to any territory its HCP__c belongs to (Account_Territory__c).
 * The row's own owner is skipped (already has access) and so are users with View All
 * Data (Salesforce rejects a share for them). `without sharing`: this class IS the
 * access mechanism.
 */
public without sharing class SegmentationTerritorySharingService {

    private static final String SHARE_ACCESS_LEVEL = 'Edit';
    private static final String SHARE_ROW_CAUSE = 'Manual';

    /** Recompute for every segmentation whose HCP belongs to any of these territories. */
    public static void resyncForTerritories(Set<Id> territoryIds) {
        if (territoryIds == null || territoryIds.isEmpty()) return;
        Set<Id> accountIds = new Set<Id>();
        for (Account_Territory__c at : [SELECT Account__c FROM Account_Territory__c WHERE Territory__c IN :territoryIds]) {
            accountIds.add(at.Account__c);
        }
        resyncForAccounts(accountIds);
    }

    /** Recompute for every segmentation of any of these HCP accounts. */
    public static void resyncForAccounts(Set<Id> accountIds) {
        if (accountIds == null || accountIds.isEmpty()) return;
        Set<Id> segIds = new Set<Id>();
        for (Segmentation__c s : [SELECT Id FROM Segmentation__c WHERE HCP__c IN :accountIds]) {
            segIds.add(s.Id);
        }
        resyncForSegmentations(segIds);
    }

    /** Recompute for specific segmentation rows: diff desired against existing Manual shares. */
    public static void resyncForSegmentations(Set<Id> segIds) {
        if (segIds == null || segIds.isEmpty()) return;

        Map<Id, Id> hcpBySeg = new Map<Id, Id>();
        Map<Id, Id> ownerBySeg = new Map<Id, Id>();
        Set<Id> hcpIds = new Set<Id>();
        for (Segmentation__c s : [SELECT Id, HCP__c, OwnerId FROM Segmentation__c WHERE Id IN :segIds]) {
            hcpBySeg.put(s.Id, s.HCP__c);
            ownerBySeg.put(s.Id, s.OwnerId);
            if (s.HCP__c != null) hcpIds.add(s.HCP__c);
        }

        Map<Id, Set<Id>> territoriesByAccount = new Map<Id, Set<Id>>();
        Set<Id> allTerritoryIds = new Set<Id>();
        if (!hcpIds.isEmpty()) {
            for (Account_Territory__c at : [SELECT Account__c, Territory__c FROM Account_Territory__c WHERE Account__c IN :hcpIds]) {
                if (!territoriesByAccount.containsKey(at.Account__c)) territoriesByAccount.put(at.Account__c, new Set<Id>());
                territoriesByAccount.get(at.Account__c).add(at.Territory__c);
                allTerritoryIds.add(at.Territory__c);
            }
        }

        Map<Id, Set<Id>> usersByTerritory = new Map<Id, Set<Id>>();
        if (!allTerritoryIds.isEmpty()) {
            for (User_Territory__c ut : [
                SELECT Territory__c, User__c FROM User_Territory__c
                WHERE Territory__c IN :allTerritoryIds AND User__c != null
                  AND User__r.IsActive = true AND User__r.Profile.PermissionsViewAllData = false
            ]) {
                if (!usersByTerritory.containsKey(ut.Territory__c)) usersByTerritory.put(ut.Territory__c, new Set<Id>());
                usersByTerritory.get(ut.Territory__c).add(ut.User__c);
            }
        }

        Set<String> desired = new Set<String>();
        for (Id segId : segIds) {
            Id hcp = hcpBySeg.get(segId);
            if (hcp == null) continue;
            Set<Id> users = new Set<Id>();
            Set<Id> terrs = territoriesByAccount.get(hcp);
            if (terrs != null) {
                for (Id t : terrs) {
                    Set<Id> tu = usersByTerritory.get(t);
                    if (tu != null) users.addAll(tu);
                }
            }
            users.remove(ownerBySeg.get(segId));
            for (Id u : users) desired.add(segId + ':' + u);
        }

        List<Segmentation__Share> existing = [
            SELECT Id, ParentId, UserOrGroupId FROM Segmentation__Share
            WHERE ParentId IN :segIds AND RowCause = :SHARE_ROW_CAUSE
        ];
        List<Segmentation__Share> toDelete = new List<Segmentation__Share>();
        for (Segmentation__Share s : existing) {
            String pair = s.ParentId + ':' + s.UserOrGroupId;
            if (desired.contains(pair)) desired.remove(pair);
            else toDelete.add(s);
        }
        List<Segmentation__Share> toInsert = new List<Segmentation__Share>();
        for (String pair : desired) {
            List<String> parts = pair.split(':');
            toInsert.add(new Segmentation__Share(
                ParentId = parts[0], UserOrGroupId = parts[1],
                AccessLevel = SHARE_ACCESS_LEVEL, RowCause = Schema.Segmentation__Share.RowCause.Manual
            ));
        }
        if (!toDelete.isEmpty()) delete toDelete;
        if (!toInsert.isEmpty()) insert toInsert;
    }
}
