@isTest
private class HcpLicenseExpiryBatchCoverageTest {

    private static Sciagen_Account__c hcp(String name, String status, Integer expiryOffset) {
        return new Sciagen_Account__c(Name = name, Type__c = 'HCP', Speciality__c = 'Cardiology',
            License_Verification_Status__c = status, License_Expiry_Date__c = Date.today().addDays(expiryOffset), Can_Prescribe__c = true);
    }

    @isTest
    static void batchExpiresLapsedVerifiedHcpsOnly() {
        Sciagen_Account__c lapsed = hcp('Dr CovLapsed', 'Verified', -1);
        Sciagen_Account__c fine = hcp('Dr CovFine', 'Verified', 30);
        insert new List<Sciagen_Account__c>{ lapsed, fine };
        Test.startTest();
        Database.executeBatch(new HcpLicenseExpiryBatch(), 200);
        Test.stopTest();
        System.assertEquals('Expired', [SELECT License_Verification_Status__c FROM Sciagen_Account__c WHERE Id = :lapsed.Id].License_Verification_Status__c);
        System.assertEquals('Verified', [SELECT License_Verification_Status__c FROM Sciagen_Account__c WHERE Id = :fine.Id].License_Verification_Status__c);
    }

    @isTest
    static void schedulableExecuteStartsTheBatch() {
        Sciagen_Account__c lapsed = hcp('Dr CovSched', 'Verified', -3);
        insert lapsed;
        Test.startTest();
        new HcpLicenseExpiryBatch().execute((SchedulableContext) null);
        Test.stopTest();
        System.assertEquals('Expired', [SELECT License_Verification_Status__c FROM Sciagen_Account__c WHERE Id = :lapsed.Id].License_Verification_Status__c);
    }

    @isTest
    static void scheduleReplacesPriorJob() {
        Test.startTest();
        Id a = HcpLicenseExpiryBatch.schedule();
        Id b = HcpLicenseExpiryBatch.schedule();
        Test.stopTest();
        System.assertNotEquals(null, a);
        System.assertNotEquals(a, b);
        System.assertEquals(1, [SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name = 'HCP Licence Expiry Check']);
    }
}