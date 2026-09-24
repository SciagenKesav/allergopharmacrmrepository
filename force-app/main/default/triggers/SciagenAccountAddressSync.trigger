// Keeps Sciagen_Account__c address/geolocation data consistent in both
// directions:
//   1. An HCO's billing address changing (or being set for the first time)
//      enqueues HCOGeocodingQueueable to turn it into coordinates — Apex
//      triggers can't make synchronous callouts, so this has to be async.
//      Insert is handled too (a brand-new HCO with an address needs
//      geocoding), not just update.
//   2. An HCO's address OR geolocation changing (from either a rep's edit
//      or the geocoding job's own update landing) cascades to every HCP
//      whose primary affiliation points at it, via AffiliationSyncService.
//      AffiliationSync.trigger handles the other half of that cascade — the
//      affiliation itself, or which row is primary, changing.
trigger SciagenAccountAddressSync on Sciagen_Account__c (after insert, after update) {
    Set<Id> hcoIdsToGeocode = new Set<Id>();
    Set<Id> hcoIdsToCascade = new Set<Id>();

    for (Sciagen_Account__c acc : Trigger.new) {
        if (acc.Type__c != 'HCO') continue;
        Sciagen_Account__c old = Trigger.isInsert ? null : Trigger.oldMap.get(acc.Id);

        Boolean billingChanged = old == null
            ? String.isNotBlank(acc.Billing_Street__c) || String.isNotBlank(acc.Billing_City__c)
                || String.isNotBlank(acc.Billing_State__c) || String.isNotBlank(acc.Billing_Postal_Code__c)
                || String.isNotBlank(acc.Billing_Country__c)
            : acc.Billing_Street__c != old.Billing_Street__c
                || acc.Billing_City__c != old.Billing_City__c
                || acc.Billing_State__c != old.Billing_State__c
                || acc.Billing_Postal_Code__c != old.Billing_Postal_Code__c
                || acc.Billing_Country__c != old.Billing_Country__c;

        if (billingChanged) {
            hcoIdsToGeocode.add(acc.Id);
            hcoIdsToCascade.add(acc.Id);
        } else if (old != null
            && (acc.Geolocation__Latitude__s != old.Geolocation__Latitude__s
                || acc.Geolocation__Longitude__s != old.Geolocation__Longitude__s)) {
            hcoIdsToCascade.add(acc.Id);
        }
    }

    if (!hcoIdsToGeocode.isEmpty()) {
        System.enqueueJob(new HCOGeocodingQueueable(hcoIdsToGeocode));
    }
    if (!hcoIdsToCascade.isEmpty()) {
        AffiliationSyncService.resyncHcpAddressesForHcoChange(hcoIdsToCascade);
    }
}