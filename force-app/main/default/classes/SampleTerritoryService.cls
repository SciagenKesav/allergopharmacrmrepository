/**
 * Territory names for a set of reps, primary territory first. Stamped onto
 * lots and transactions so native reports can filter by territory even
 * though a rep-to-territory link is many-to-many.
 */
public with sharing class SampleTerritoryService {

    public static Map<Id, String> namesFor(Set<Id> userIds) {
        Map<Id, List<String>> byUser = new Map<Id, List<String>>();
        if (userIds == null || userIds.isEmpty()) return new Map<Id, String>();
        for (User_Territory__c ut : [
            SELECT User__c, Territory__r.Name, Is_Primary__c FROM User_Territory__c
            WHERE User__c IN :userIds AND Territory__c != null
            ORDER BY Is_Primary__c DESC, Territory__r.Name
        ]) {
            if (!byUser.containsKey(ut.User__c)) byUser.put(ut.User__c, new List<String>());
            byUser.get(ut.User__c).add(ut.Territory__r.Name);
        }
        Map<Id, String> out = new Map<Id, String>();
        for (Id u : byUser.keySet()) out.put(u, String.join(byUser.get(u), '; ').left(255));
        return out;
    }
}