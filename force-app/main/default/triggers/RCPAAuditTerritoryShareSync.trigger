/**
 * Keeps RCPA_Audit__Share in sync whenever an audit's Territory__c changes
 * (including on insert, e.g. a rep starting a new audit). See
 * RCPAAuditTerritorySharingService for the actual computation.
 *
 * Deletes need no handling here — RCPA_Audit__Share rows cascade-delete
 * automatically with their parent record.
 */
trigger RCPAAuditTerritoryShareSync on RCPA_Audit__c (after insert, after update, after undelete) {
    Set<Id> auditIds = new Set<Id>();
    for (RCPA_Audit__c a : Trigger.new) {
        auditIds.add(a.Id);
    }
    RCPAAuditTerritorySharingService.resyncForAudits(auditIds);
}