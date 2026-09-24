/**
 * Keeps Planned_Call__Share in sync whenever a call's HCP__c/HCO__c changes
 * (including on insert, e.g. a rep scheduling a new call). See
 * PlannedCallTerritorySharingService for the actual computation.
 *
 * Deletes need no handling here — Planned_Call__Share rows cascade-delete
 * automatically with their parent record.
 */
trigger PlannedCallTerritoryShareSync on Planned_Call__c (after insert, after update, after undelete) {
    Set<Id> callIds = new Set<Id>();
    for (Planned_Call__c pc : Trigger.new) {
        callIds.add(pc.Id);
    }
    PlannedCallTerritorySharingService.resyncForPlannedCalls(callIds);
}