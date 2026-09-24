/**
 * Housekeeping for Sample_Lot__c: the per-holder unique key, ownership that
 * follows the holding rep (so the rep and their manager can see the lot), and
 * the Active / Depleted flip when the available quantity crosses zero.
 * Expiry is handled by SampleLotExpiryBatch.
 */
public with sharing class SampleLotService {

    public static void beforeSave(List<Sample_Lot__c> lots, Map<Id, Sample_Lot__c> oldMap) {
        Set<Id> repIds = new Set<Id>();
        for (Sample_Lot__c lot : lots) {
            Sample_Lot__c prior = oldMap == null ? null : oldMap.get(lot.Id);
            if (lot.Owner_User__c != null && (prior == null || prior.Owner_User__c != lot.Owner_User__c)) repIds.add(lot.Owner_User__c);
        }
        Map<Id, String> territories = SampleTerritoryService.namesFor(repIds);
        for (Sample_Lot__c lot : lots) {
            Sample_Lot__c old = oldMap == null ? null : oldMap.get(lot.Id);
            lot.Lot_Key__c = keyFor(lot);
            if (lot.Owner_User__c != null && (old == null || old.Owner_User__c != lot.Owner_User__c)) {
                lot.OwnerId = lot.Owner_User__c;
                lot.Rep_Territory__c = territories.get(lot.Owner_User__c);
            }
            Decimal available = lot.Available_Quantity__c == null ? 0 : lot.Available_Quantity__c;
            if (lot.Available_Quantity__c == null) lot.Available_Quantity__c = 0;
            if (old == null) {
                if (lot.Status__c == null || lot.Status__c == 'Active') lot.Status__c = available > 0 ? 'Active' : 'Depleted';
            } else if (old.Available_Quantity__c != lot.Available_Quantity__c) {
                if (available <= 0 && lot.Status__c == 'Active') lot.Status__c = 'Depleted';
                else if (available > 0 && lot.Status__c == 'Depleted') lot.Status__c = 'Active';
            }
        }
    }

    public static String keyFor(Sample_Lot__c lot) {
        String holder = lot.Owner_User__c != null ? 'U' + lot.Owner_User__c
            : (lot.Warehouse__c != null ? 'W' + lot.Warehouse__c : 'X');
        return (String.valueOf(lot.Product__c) + '|' + holder + '|' + (lot.Lot_Number__c == null ? '' : lot.Lot_Number__c.trim().toUpperCase())).left(180);
    }
}