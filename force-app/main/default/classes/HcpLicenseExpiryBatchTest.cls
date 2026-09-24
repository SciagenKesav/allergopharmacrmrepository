@isTest
private class HcpLicenseExpiryBatchTest {

    @isTest
    static void batchExpiresOnlyVerifiedHcpsPastTheirLicenceExpiry() {
        Sciagen_Account__c lapsed = new Sciagen_Account__c(Name = 'Dr Lapsed', Type__c = 'HCP', Speciality__c = 'Cardiology',
            License_Verification_Status__c = 'Verified', License_Expiry_Date__c = Date.today().addDays(-1), Can_Prescribe__c = true);
        Sciagen_Account__c fine = new Sciagen_Account__c(Name = 'Dr Fine', Type__c = 'HCP', Speciality__c = 'Cardiology',
            License_Verification_Status__c = 'Verified', License_Expiry_Date__c = Date.today().addDays(30), Can_Prescribe__c = true);
        Sciagen_Account__c unverified = new Sciagen_Account__c(Name = 'Dr Unverified', Type__c = 'HCP', Speciality__c = 'Cardiology',
            License_Verification_Status__c = 'Unverified', License_Expiry_Date__c = Date.today().addDays(-1), Can_Prescribe__c = true);
        insert new List<Sciagen_Account__c>{ lapsed, fine, unverified };

        Test.startTest();
        Database.executeBatch(new HcpLicenseExpiryBatch(), 200);
        Test.stopTest();

        System.assertEquals('Expired', [SELECT License_Verification_Status__c FROM Sciagen_Account__c WHERE Id = :lapsed.Id].License_Verification_Status__c);
        System.assertEquals('Verified', [SELECT License_Verification_Status__c FROM Sciagen_Account__c WHERE Id = :fine.Id].License_Verification_Status__c,
            'expiry is 30 days out, not lapsed yet');
        System.assertEquals('Unverified', [SELECT License_Verification_Status__c FROM Sciagen_Account__c WHERE Id = :unverified.Id].License_Verification_Status__c,
            'was never Verified in the first place, so left alone');
    }

    @isTest
    static void scheduledRunMarksLapsedLicencesToo() {
        Sciagen_Account__c lapsed = new Sciagen_Account__c(Name = 'Dr Scheduled Lapsed', Type__c = 'HCP', Speciality__c = 'Cardiology',
            License_Verification_Status__c = 'Verified', License_Expiry_Date__c = Date.today().addDays(-5), Can_Prescribe__c = true);
        insert lapsed;
        Test.startTest();
        new HcpLicenseExpiryBatch().execute(null);   // the Schedulable entry point, not the Batchable one
        Test.stopTest();
        System.assertEquals('Expired', [SELECT License_Verification_Status__c FROM Sciagen_Account__c WHERE Id = :lapsed.Id].License_Verification_Status__c);
    }

    @isTest
    static void batchCanBeScheduledAndReschedulingReplacesThePriorJob() {
        Test.startTest();
        Id first = HcpLicenseExpiryBatch.schedule();
        Id second = HcpLicenseExpiryBatch.schedule();
        Test.stopTest();
        System.assertNotEquals(null, first);
        System.assertNotEquals(null, second);
        System.assertEquals(1, [SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name = 'HCP Licence Expiry Check'],
            'rescheduling must abort the prior job, not stack a second one');
    }
}
