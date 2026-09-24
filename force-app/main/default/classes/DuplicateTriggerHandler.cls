public without sharing class DuplicateTriggerHandler {
    /** Queue a scan for records that still need comparing. Bulk loads and background jobs are left to the scheduled scan. */
    public static void afterSave(List<Sciagen_Account__c> records) {
        if (System.isBatch() || System.isQueueable() || System.isFuture()) return;
        Set<Id> ids = new Set<Id>();
        for (Sciagen_Account__c a : records) {
            if (a.Is_Merged__c != true && a.Dedupe_Checked_At__c == null && ids.size() < 100) ids.add(a.Id);
        }
        if (ids.isEmpty() || !DuplicateEngine.loadSettings().enabled) return;
        if (Limits.getQueueableJobs() >= Limits.getLimitQueueableJobs()) return;
        System.enqueueJob(new DuplicateScanQueueable(ids));
    }
}