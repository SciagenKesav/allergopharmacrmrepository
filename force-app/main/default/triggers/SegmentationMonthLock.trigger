/** Segmentation is locked for the month once the rep's plan is frozen (SegmentationLockService). */
trigger SegmentationMonthLock on Segmentation__c (before insert, before update, before delete) {
    if (Trigger.isDelete) SegmentationLockService.guardSegments(Trigger.old, null, true);
    else SegmentationLockService.guardSegments(Trigger.new, Trigger.oldMap, false);
}