/**
 * Keeps Promo_Drop__c consistent with the Promotional_Item__c catalog:
 *  - Item__c (the plain-text name the iPad app reads/writes) is filled from the
 *    chosen catalog item's name, so both surfaces keep showing the same text.
 *  - The item must be Active and within its Valid From/To dates.
 *  - Qty__c can't exceed the item's Max_Qty_Per_Call__c (blank = no limit).
 * Catalog lookups use system mode on purpose: a rep may not have read access to
 * every catalog record's other fields, but the drop must still validate.
 */
public without sharing class PromoDropService {

    public static void apply(List<Promo_Drop__c> drops, Map<Id, Promo_Drop__c> oldMap) {
        Set<Id> itemIds = new Set<Id>();
        for (Promo_Drop__c d : drops) {
            if (d.Promotional_Item__c != null) itemIds.add(d.Promotional_Item__c);
        }
        if (itemIds.isEmpty()) return;

        Map<Id, Promotional_Item__c> items = new Map<Id, Promotional_Item__c>([
            SELECT Id, Name, Max_Qty_Per_Call__c, Active__c, Valid_From__c, Valid_To__c FROM Promotional_Item__c WHERE Id IN :itemIds
        ]);

        for (Promo_Drop__c d : drops) {
            Promotional_Item__c item = items.get(d.Promotional_Item__c);
            if (item == null) continue;
            Boolean itemChanged = oldMap == null || oldMap.get(d.Id).Promotional_Item__c != d.Promotional_Item__c;
            if (itemChanged) {
                Date today = Date.today();
                if (item.Active__c != true
                    || (item.Valid_From__c != null && item.Valid_From__c > today)
                    || (item.Valid_To__c != null && item.Valid_To__c < today)) {
                    d.Promotional_Item__c.addError(item.Name + ' is not currently available.');
                    continue;
                }
            }
            if (itemChanged || String.isBlank(d.Item__c)) {
                d.Item__c = item.Name.abbreviate(120);
            }
            if (item.Max_Qty_Per_Call__c != null && d.Qty__c != null && d.Qty__c > item.Max_Qty_Per_Call__c) {
                d.Qty__c.addError('Maximum ' + item.Max_Qty_Per_Call__c.intValue() + ' per call for ' + item.Name + '.');
            }
        }
    }
}