/**
 * Keeps Data_Change_Request__Share in sync whenever a DCR is created or its Subject_Account__c
 * / Related_HCO__c changes. See DCRTerritorySharingService for the actual
 * computation.
 *
 * Deletes need no handling here — Data_Change_Request__Share rows cascade-delete
 * automatically with their parent record.
 */
trigger DCRTerritoryShareSync on Data_Change_Request__c (after insert, after update, after undelete) {
    Set<Id> requestIds = new Set<Id>();
    for (Data_Change_Request__c dcr : Trigger.new) {
        requestIds.add(dcr.Id);
    }
    DCRTerritorySharingService.resyncForRequests(requestIds);
}