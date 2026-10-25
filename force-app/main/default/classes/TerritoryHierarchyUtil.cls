/**
 * Walks the Territory__c hierarchy (Parent_Territory__c) for the three sharing services
 * (TerritorySharingService / DCRTerritorySharingService / RCPAAuditTerritorySharingService).
 * A manager assigned to a parent territory (e.g. the "North" zone) should see every record
 * tagged with any of its child territories, without a User_Territory__c row for each child.
 *
 * The org's whole territory tree is small (a few dozen rows), so it's loaded once per
 * transaction and held in memory rather than walked with per-level SOQL.
 */
public without sharing class TerritoryHierarchyUtil {
    private static Map<Id, Id> parentByTerritory;
    private static Map<Id, Set<Id>> childrenByTerritory;

    private static void loadIfNeeded() {
        if (parentByTerritory != null) return;
        parentByTerritory = new Map<Id, Id>();
        childrenByTerritory = new Map<Id, Set<Id>>();
        for (Territory__c t : [SELECT Id, Parent_Territory__c FROM Territory__c]) {
            parentByTerritory.put(t.Id, t.Parent_Territory__c);
            if (t.Parent_Territory__c != null) {
                if (!childrenByTerritory.containsKey(t.Parent_Territory__c)) {
                    childrenByTerritory.put(t.Parent_Territory__c, new Set<Id>());
                }
                childrenByTerritory.get(t.Parent_Territory__c).add(t.Id);
            }
        }
    }

    /** Each id plus every territory reached by walking UP Parent_Territory__c from it (itself included). */
    public static Set<Id> withAncestors(Set<Id> territoryIds) {
        loadIfNeeded();
        Set<Id> result = new Set<Id>();
        for (Id territoryId : territoryIds) {
            Id current = territoryId;
            while (current != null && !result.contains(current)) {
                result.add(current);
                current = parentByTerritory.get(current);
            }
        }
        return result;
    }

    /** Each id plus every territory reached by walking DOWN Parent_Territory__c from it (itself included). */
    public static Set<Id> withDescendants(Set<Id> territoryIds) {
        loadIfNeeded();
        Set<Id> result = new Set<Id>();
        List<Id> frontier = new List<Id>(territoryIds);
        while (!frontier.isEmpty()) {
            List<Id> nextFrontier = new List<Id>();
            for (Id id : frontier) {
                if (result.contains(id)) continue;
                result.add(id);
                Set<Id> children = childrenByTerritory.get(id);
                if (children != null) nextFrontier.addAll(children);
            }
            frontier = nextFrontier;
        }
        return result;
    }

    /** For each given territory id, a set containing itself plus every ancestor. */
    public static Map<Id, Set<Id>> ancestorsByTerritory(Set<Id> territoryIds) {
        loadIfNeeded();
        Map<Id, Set<Id>> result = new Map<Id, Set<Id>>();
        for (Id territoryId : territoryIds) {
            result.put(territoryId, withAncestors(new Set<Id>{ territoryId }));
        }
        return result;
    }

    /** Test-only: forces the next call to reload, since the org's territories may have changed mid-test. */
    @TestVisible
    private static void reset() {
        parentByTerritory = null;
        childrenByTerritory = null;
    }
}