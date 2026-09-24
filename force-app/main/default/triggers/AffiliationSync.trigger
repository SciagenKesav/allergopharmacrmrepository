trigger AffiliationSync on Affiliation__c (after insert, after update, after delete, after undelete) {
    if (!Trigger.isDelete) {
        AffiliationSyncService.enforcePrimaryUniqueness(Trigger.new, Trigger.isUpdate ? Trigger.oldMap : null);
    }

    Set<Id> affectedHcpIds = new Set<Id>();
    List<Affiliation__c> records = Trigger.isDelete ? Trigger.old : Trigger.new;
    for (Affiliation__c a : records) {
        if (a.HCP__c != null) affectedHcpIds.add(a.HCP__c);
    }
    if (Trigger.isUpdate) {
        for (Affiliation__c a : Trigger.old) {
            if (a.HCP__c != null) affectedHcpIds.add(a.HCP__c);
        }
    }
    AffiliationSyncService.resyncHcpAddressesForAffiliationChange(affectedHcpIds);
}