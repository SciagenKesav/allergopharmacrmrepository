/** Per-product classes follow their segmentation's monthly lock (SegmentationLockService). */
trigger SegmentationProductMonthLock on Segmentation_Product__c (before insert, before update, before delete) {
    if (Trigger.isDelete) SegmentationLockService.guardProducts(Trigger.old, null, true);
    else SegmentationLockService.guardProducts(Trigger.new, Trigger.oldMap, false);
}