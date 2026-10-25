/**
 * Auto-assigns a brand-new Sciagen_Account__c to its owner's primary
 * territory, so every account has at least one Account_Territory__c row the
 * moment it's created instead of relying on a rep to remember to add one via
 * Global Account Search's "Add to Territory" action.
 *
 * Silently no-ops for an owner with no primary User_Territory__c — there's
 * no reasonable territory to guess, and this must never block account
 * creation itself.
 */
public without sharing class AccountTerritoryAutoAssignService {

    public static void assignTerritories(List<Sciagen_Account__c> newAccounts) {
        Set<Id> ownerIds = new Set<Id>();
        for (Sciagen_Account__c acc : newAccounts) {
            if (acc.OwnerId != null) ownerIds.add(acc.OwnerId);
        }
        if (ownerIds.isEmpty()) return;

        Map<Id, Id> primaryTerritoryByOwner = new Map<Id, Id>();
        List<User_Territory__c> assignments = [
            SELECT User__c, Territory__c
            FROM User_Territory__c
            WHERE User__c IN :ownerIds AND Is_Primary__c = true
            WITH SYSTEM_MODE
        ];
        for (User_Territory__c ut : assignments) {
            if (!primaryTerritoryByOwner.containsKey(ut.User__c)) {
                primaryTerritoryByOwner.put(ut.User__c, ut.Territory__c);
            }
        }
        if (primaryTerritoryByOwner.isEmpty()) return;

        List<Account_Territory__c> toInsert = new List<Account_Territory__c>();
        for (Sciagen_Account__c acc : newAccounts) {
            Id territoryId = primaryTerritoryByOwner.get(acc.OwnerId);
            if (territoryId != null) {
                toInsert.add(new Account_Territory__c(
                    Name = 'Auto-Assigned',
                    Account__c = acc.Id,
                    Territory__c = territoryId
                ));
            }
        }
        if (!toInsert.isEmpty()) {
            insert toInsert;
        }
    }
}