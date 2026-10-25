/**
 * Keeps Sciagen_Account__Share, RCPA_Audit__Share and Data_Change_Request__Share in sync
 * whenever a user's territory assignment changes. See TerritorySharingService/
 * RCPAAuditTerritorySharingService/DCRTerritorySharingService for the actual
 * computation. (Each object's own *TerritoryShareSync trigger only resyncs when that record
 * itself changes -- a rep or KAM newly joining or leaving a territory needs this trigger to
 * pick up every account, audit and DCR already tagged with that territory.)
 */
trigger UserTerritoryShareSync on User_Territory__c (after insert, after update, after delete, after undelete) {
    // Resync by TERRITORY, not by user: on delete/update, Trigger.old's territory is the one
    // we need to strip access for, and by the time this fires that assignment row is already
    // gone from the database — resyncForAccounts re-derives "who should have access" fresh
    // from current User_Territory__c rows, so passing the old territory here is what
    // makes the removed user's access actually get revoked.
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
    RCPAAuditTerritorySharingService.resyncForTerritories(territoryIds);
    DCRTerritorySharingService.resyncForTerritories(territoryIds);
    SegmentationTerritorySharingService.resyncForTerritories(territoryIds);
}