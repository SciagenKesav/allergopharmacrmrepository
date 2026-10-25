/**
 * Keeps Sciagen_Account__Share and Data_Change_Request__Share in sync whenever an account's
 * territory assignment changes. See TerritorySharingService/DataChangeRequestTerritory-
 * SharingService for the actual computation. (A DCR targeting this account — Subject_Account__c
 * or Related_HCO__c — derives its own sharing through the account's territory, one hop out, so
 * it needs the same resync the account itself gets here.)
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
    DCRTerritorySharingService.resyncForAccounts(accountIds);
    SegmentationTerritorySharingService.resyncForAccounts(accountIds);
}