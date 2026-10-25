trigger AffiliationSync on Affiliation__c (after insert, after update, after delete, after undelete) {
    if (!Trigger.isDelete) {
        AffiliationSyncService.enforcePrimaryUniqueness(Trigger.new, Trigger.isUpdate ? Trigger.oldMap : null);
    }

    // Only a change that involves a PRIMARY affiliation can move the HCP's
    // mirrored address. Resyncing on every change cleared the address of an
    // HCP that has no primary at all as soon as a non-primary row was added.
    Set<Id> affectedHcpIds = new Set<Id>();
    List<Affiliation__c> records = Trigger.isDelete ? Trigger.old : Trigger.new;
    for (Affiliation__c a : records) {
        Affiliation__c old = Trigger.isUpdate ? Trigger.oldMap.get(a.Id) : null;
        Boolean primaryInvolved = a.Is_Primary__c == true || (old != null && old.Is_Primary__c == true);
        if (!primaryInvolved) continue;
        if (a.HCP__c != null) affectedHcpIds.add(a.HCP__c);
        if (old != null && old.HCP__c != null) affectedHcpIds.add(old.HCP__c);
    }
    AffiliationSyncService.resyncHcpAddressesForAffiliationChange(affectedHcpIds);
}