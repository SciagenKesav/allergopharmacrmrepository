/**
 * Keeps Segmentation__Share in sync when a segmentation row is created, re-pointed to
 * another HCP, or restored. See SegmentationTerritorySharingService. Deletes need no
 * handling: share rows cascade-delete with their parent.
 */
trigger SegmentationTerritoryShareSync on Segmentation__c (after insert, after update, after undelete) {
    Set<Id> segIds = new Set<Id>();
    for (Segmentation__c s : Trigger.new) {
        if (Trigger.isUpdate && Trigger.oldMap.get(s.Id).HCP__c == s.HCP__c && Trigger.oldMap.get(s.Id).OwnerId == s.OwnerId) continue;
        segIds.add(s.Id);
    }
    SegmentationTerritorySharingService.resyncForSegmentations(segIds);
}
