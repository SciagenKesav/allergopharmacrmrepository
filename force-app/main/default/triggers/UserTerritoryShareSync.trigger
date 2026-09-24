/**
 * Keeps Sciagen_Account__Share, Planned_Call__Share, AND RCPA_Audit__Share in
 * sync whenever a user's territory assignment changes. See
 * TerritorySharingService / PlannedCallTerritorySharingService /
 * RCPAAuditTerritorySharingService for the actual computation.
 */
trigger UserTerritoryShareSync on User_Territory__c (after insert, after update, after delete, after undelete) {
    // Resync by TERRITORY, not by user: on delete/update, Trigger.old's territory is the one
    // we need to strip access for, and by the time this fires that assignment row is already
    // gone from the database — resyncForAccounts/resyncForTerritories re-derive "who should
    // have access" fresh from current User_Territory__c rows, so passing the old territory
    // here is what makes the removed user's access actually get revoked.
    Set<Id> territoryIds = new Set<Id>();
    List<User_Territory__c> records = Trigger.isDelete ? Trigger.old : Trigger.new;
    for (User_Territory__c ta : records) {
        if (ta.Territory__c != null) territoryIds.add(ta.Territory__c);
    }
    if (Trigger.isUpdate) {
        for (User_Territory__c ta : Trigger.old) {
            if (ta.Territory__c != null) territoryIds.add(ta.Territory__c);
        }
    }
    TerritorySharingService.resyncForTerritories(territoryIds);
    PlannedCallTerritorySharingService.resyncForTerritories(territoryIds);
    RCPAAuditTerritorySharingService.resyncForTerritories(territoryIds);
}