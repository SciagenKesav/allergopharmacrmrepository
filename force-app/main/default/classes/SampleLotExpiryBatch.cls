/**
 * Marks lots whose expiry date has passed as Expired and tells the holder.
 * Runs daily at midnight (see schedule()). Stock in an expired lot stays on
 * the books until the rep returns or adjusts it, so nothing is lost silently.
 */
global with sharing class SampleLotExpiryBatch implements Database.Batchable<SObject>, Schedulable {

    global Database.QueryLocator start(Database.BatchableContext bc) {
        return Database.getQueryLocator([
            SELECT Id, Name, OwnerId, Owner_User__c, Lot_Number__c, Expiry_Date__c, Available_Quantity__c, Product__r.Name
            FROM Sample_Lot__c
            WHERE Status__c = 'Active' AND Expiry_Date__c < TODAY
        ]);
    }

    global void execute(Database.BatchableContext bc, List<Sample_Lot__c> lots) {
        List<Sample_Lot__c> updates = new List<Sample_Lot__c>();
        for (Sample_Lot__c lot : lots) updates.add(new Sample_Lot__c(Id = lot.Id, Status__c = 'Expired'));
        update updates;
        for (Sample_Lot__c lot : lots) {
            Id holder = lot.Owner_User__c != null ? lot.Owner_User__c : lot.OwnerId;
            String qty = lot.Available_Quantity__c == null ? '0' : String.valueOf(lot.Available_Quantity__c.intValue());
            SampleNotifier.notify(new Set<Id>{ holder }, 'Sample lot expired: ' + lot.Lot_Number__c,
                lot.Product__r.Name + ' lot ' + lot.Lot_Number__c + ' expired on ' + lot.Expiry_Date__c.format()
                + '. ' + qty + ' packs are still on hand. Return or adjust them.', lot.Id);
        }
    }

    global void finish(Database.BatchableContext bc) {}

    global void execute(SchedulableContext sc) {
        Database.executeBatch(new SampleLotExpiryBatch(), 200);
    }

    public static Id schedule() {
        for (CronTrigger t : [SELECT Id FROM CronTrigger WHERE CronJobDetail.Name = 'Sample Lot Expiry Check']) System.abortJob(t.Id);
        return System.schedule('Sample Lot Expiry Check', '0 0 0 * * ?', new SampleLotExpiryBatch());
    }
}