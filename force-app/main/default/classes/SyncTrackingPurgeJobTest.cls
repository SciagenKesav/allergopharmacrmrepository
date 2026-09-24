@isTest
private class SyncTrackingPurgeJobTest {

    @isTest
    static void purgesOnlyRecordsOlderThanRetentionWindow() {
        Sync_Tracking__c oldRecord = new Sync_Tracking__c(Record_Type__c = 'Accounts', Status__c = 'Synced', Label__c = 'Old heartbeat');
        insert oldRecord;
        Test.setCreatedDate(oldRecord.Id, DateTime.now().addDays(-(SyncTrackingPurgeJob.RETENTION_DAYS + 5)));

        Sync_Tracking__c recentRecord = new Sync_Tracking__c(Record_Type__c = 'Call Visit Report', Status__c = 'Synced', Label__c = 'Recent CVR');
        insert recentRecord;

        Test.startTest();
        Database.executeBatch(new SyncTrackingPurgeJob(), 200);
        Test.stopTest();

        List<Sync_Tracking__c> remaining = [SELECT Id FROM Sync_Tracking__c];
        System.assertEquals(1, remaining.size(), 'Only the record older than the retention window should be purged');
        System.assertEquals(recentRecord.Id, remaining[0].Id);
    }

    @isTest
    static void scheduleRegistersTheNightlyJob() {
        Test.startTest();
        String jobId = System.schedule('Test Sync Tracking Purge', '0 0 2 * * ?', new SyncTrackingPurgeJob());
        Test.stopTest();

        System.assertNotEquals(null, jobId);
    }
}