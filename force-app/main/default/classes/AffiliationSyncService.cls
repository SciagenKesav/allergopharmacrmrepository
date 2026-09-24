/**
 * Enforces two invariants for Affiliation__c (the HCP<->HCO junction):
 *
 * 1. At most one Is_Primary__c = true row per HCP__c — when a row is saved
 *    with Is_Primary__c = true, any other primary row for the same HCP is
 *    automatically demoted (not rejected — a rep picking a new primary
 *    shouldn't hit a validation error, the old one should just lose the flag).
 *
 * 2. An HCP's own billing address and Geolocation__c fields always mirror its current
 *    primary affiliated HCO's — kept in sync from both directions: when the
 *    affiliation (or which row is primary) changes, and when the HCO's own
 *    address changes later. See AffiliationSync.trigger and
 *    SciagenAccountAddressSync.trigger.
 */
public without sharing class AffiliationSyncService {

    // Recursion guard: the demotion DML below re-fires AffiliationSync.trigger
    // for the demoted rows — without this it would try to demote again.
    private static Boolean isEnforcingPrimary = false;

    public static void enforcePrimaryUniqueness(List<Affiliation__c> newRows, Map<Id, Affiliation__c> oldMap) {
        if (isEnforcingPrimary) return;

        Set<Id> hcpIdsWithNewPrimary = new Set<Id>();
        for (Affiliation__c row : newRows) {
            if (row.Is_Primary__c != true || row.HCP__c == null) continue;
            Affiliation__c old = oldMap == null ? null : oldMap.get(row.Id);
            Boolean wasAlreadyPrimary = old != null && old.Is_Primary__c == true;
            if (!wasAlreadyPrimary) {
                hcpIdsWithNewPrimary.add(row.HCP__c);
            }
        }
        if (hcpIdsWithNewPrimary.isEmpty()) return;

        Set<Id> newRowIds = new Set<Id>();
        for (Affiliation__c row : newRows) newRowIds.add(row.Id);

        List<Affiliation__c> toDemote = new List<Affiliation__c>();
        for (Affiliation__c existing : [
            SELECT Id FROM Affiliation__c
            WHERE HCP__c IN :hcpIdsWithNewPrimary AND Is_Primary__c = true
        ]) {
            if (!newRowIds.contains(existing.Id)) {
                toDemote.add(new Affiliation__c(Id = existing.Id, Is_Primary__c = false));
            }
        }
        if (!toDemote.isEmpty()) {
            isEnforcingPrimary = true;
            try {
                update toDemote;
            } finally {
                isEnforcingPrimary = false;
            }
        }
    }

    public static void resyncHcpAddressesForAffiliationChange(Set<Id> hcpIds) {
        resyncHcpAddresses(hcpIds);
    }

    // An HCO's own address changed — find every HCP whose PRIMARY affiliation
    // points at one of these HCOs and re-mirror onto them.
    public static void resyncHcpAddressesForHcoChange(Set<Id> hcoIds) {
        if (hcoIds == null || hcoIds.isEmpty()) return;
        Set<Id> hcpIds = new Set<Id>();
        for (Affiliation__c aff : [
            SELECT HCP__c FROM Affiliation__c
            WHERE HCO__c IN :hcoIds AND Is_Primary__c = true AND HCP__c != null
        ]) {
            hcpIds.add(aff.HCP__c);
        }
        resyncHcpAddresses(hcpIds);
    }

    private static void resyncHcpAddresses(Set<Id> hcpIds) {
        if (hcpIds == null || hcpIds.isEmpty()) return;

        Map<Id, Affiliation__c> primaryByHcpId = new Map<Id, Affiliation__c>();
        for (Affiliation__c aff : [
            SELECT HCP__c, HCO__r.Billing_Street__c, HCO__r.Billing_City__c, HCO__r.Billing_State__c,
                   HCO__r.Billing_Postal_Code__c, HCO__r.Billing_Country__c,
                   HCO__r.Geolocation__Latitude__s, HCO__r.Geolocation__Longitude__s
            FROM Affiliation__c
            WHERE HCP__c IN :hcpIds AND Is_Primary__c = true AND HCO__c != null
        ]) {
            primaryByHcpId.put(aff.HCP__c, aff);
        }

        List<Sciagen_Account__c> toUpdate = new List<Sciagen_Account__c>();
        for (Id hcpId : hcpIds) {
            Affiliation__c primary = primaryByHcpId.get(hcpId);
            Sciagen_Account__c hcp = new Sciagen_Account__c(Id = hcpId);
            if (primary != null) {
                hcp.Billing_Street__c = primary.HCO__r.Billing_Street__c;
                hcp.Billing_City__c = primary.HCO__r.Billing_City__c;
                hcp.Billing_State__c = primary.HCO__r.Billing_State__c;
                hcp.Billing_Postal_Code__c = primary.HCO__r.Billing_Postal_Code__c;
                hcp.Billing_Country__c = primary.HCO__r.Billing_Country__c;
                hcp.Geolocation__Latitude__s = primary.HCO__r.Geolocation__Latitude__s;
                hcp.Geolocation__Longitude__s = primary.HCO__r.Geolocation__Longitude__s;
            } else {
                // No primary affiliation left to mirror — clear rather than
                // leave a stale address from a since-removed affiliation.
                hcp.Billing_Street__c = null;
                hcp.Billing_City__c = null;
                hcp.Billing_State__c = null;
                hcp.Billing_Postal_Code__c = null;
                hcp.Billing_Country__c = null;
                hcp.Geolocation__Latitude__s = null;
                hcp.Geolocation__Longitude__s = null;
            }
            toUpdate.add(hcp);
        }
        if (!toUpdate.isEmpty()) {
            Database.update(toUpdate, false);
        }
    }
}