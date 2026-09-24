/**
 * Keeps Sciagen_Account__Share AND Planned_Call__Share in sync whenever an
 * account's territory assignment changes — a Planned_Call__c's own visibility
 * is derived from its HCP__c/HCO__c's territory, so it must be recomputed
 * here too. See TerritorySharingService / PlannedCallTerritorySharingService
 * for the actual computation.
 */
trigger AccountTerritoryShareSync on Account_Territory__c (after insert, after update, after delete, after undelete) {
    Set<Id> accountIds = new Set<Id>();
    List<Account_Territory__c> records = Trigger.isDelete ? Trigger.old : Trigger.new;
    for (Account_Territory__c at : records) {
        if (at.Account__c != null) accountIds.add(at.Account__c);
    }
    if (Trigger.isUpdate) {
        for (Account_Territory__c at : Trigger.old) {
            if (at.Account__c != null) accountIds.add(at.Account__c);
        }
    }
    TerritorySharingService.resyncForAccounts(accountIds);
    PlannedCallTerritorySharingService.resyncForAccounts(accountIds);
}