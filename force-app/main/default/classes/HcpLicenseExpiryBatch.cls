/**
 * Marks HCPs whose verified licence has lapsed as Expired, so the status agrees
 * with the expiry date. (Sample_Eligible__c already stops sampling on the date
 * itself; this keeps the visible status honest.) Runs daily.
 */
global with sharing class HcpLicenseExpiryBatch implements Database.Batchable<SObject>, Schedulable {

    global Database.QueryLocator start(Database.BatchableContext bc) {
        return Database.getQueryLocator([
            SELECT Id FROM Sciagen_Account__c
            WHERE Type__c = 'HCP' AND License_Verification_Status__c = 'Verified' AND License_Expiry_Date__c < TODAY
        ]);
    }

    global void execute(Database.BatchableContext bc, List<Sciagen_Account__c> hcps) {
        List<Sciagen_Account__c> updates = new List<Sciagen_Account__c>();
        for (Sciagen_Account__c a : hcps) updates.add(new Sciagen_Account__c(Id = a.Id, License_Verification_Status__c = 'Expired'));
        Database.update(updates, false);
    }

    global void finish(Database.BatchableContext bc) {}

    global void execute(SchedulableContext sc) {
        Database.executeBatch(new HcpLicenseExpiryBatch(), 200);
    }

    public static Id schedule() {
        for (CronTrigger t : [SELECT Id FROM CronTrigger WHERE CronJobDetail.Name = 'HCP Licence Expiry Check']) System.abortJob(t.Id);
        return System.schedule('HCP Licence Expiry Check', '0 30 0 * * ?', new HcpLicenseExpiryBatch());
    }
}