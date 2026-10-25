/**
 * Keeps Sample_Allocation__c.Used_Quantity__c in step with disbursements: a rep's
 * own allocation first, then their territory's, for the product and period.
 */
public without sharing class SampleAllocationService {

    public static void applyDisbursements(List<Sample_Transaction__c> txns, Integer sign) {
        if (txns == null || txns.isEmpty()) return;
        Set<Id> users = new Set<Id>();
        Set<Id> products = new Set<Id>();
        for (Sample_Transaction__c t : txns) {
            if (t.Transaction_Type__c != 'Disbursement' || t.Performed_By__c == null) continue;
            users.add(t.Performed_By__c);
            products.add(t.Product__c);
        }
        if (users.isEmpty()) return;
        Map<Id, Set<Id>> territoriesOf = new Map<Id, Set<Id>>();
        Set<Id> allTerritories = new Set<Id>();
        for (User_Territory__c ut : [SELECT User__c, Territory__c FROM User_Territory__c WHERE User__c IN :users AND Territory__c != null]) {
            if (!territoriesOf.containsKey(ut.User__c)) territoriesOf.put(ut.User__c, new Set<Id>());
            territoriesOf.get(ut.User__c).add(ut.Territory__c);
            allTerritories.add(ut.Territory__c);
        }
        List<Sample_Allocation__c> allocations = [
            SELECT Id, Product__c, Allocated_To_User__c, Allocated_To_Territory__c, Allocation_Quantity__c, Used_Quantity__c, Period_Start__c, Period_End__c, Status__c
            FROM Sample_Allocation__c
            WHERE Product__c IN :products AND (Status__c = 'Active' OR (Status__c = 'Depleted' AND Used_Quantity__c > 0))
              AND (Allocated_To_User__c IN :users OR Allocated_To_Territory__c IN :allTerritories)
            FOR UPDATE
        ];
        Map<Id, Sample_Allocation__c> touched = new Map<Id, Sample_Allocation__c>();
        for (Sample_Transaction__c t : txns) {
            if (t.Transaction_Type__c != 'Disbursement' || t.Performed_By__c == null) continue;
            Date givenOn = (t.Performed_At__c == null ? System.now() : t.Performed_At__c).date();
            Sample_Allocation__c hit = null;
            for (Sample_Allocation__c a : allocations) {
                if (a.Product__c != t.Product__c) continue;
                if (a.Period_Start__c != null && a.Period_Start__c > givenOn) continue;
                if (a.Period_End__c != null && a.Period_End__c < givenOn) continue;
                if (a.Allocated_To_User__c == t.Performed_By__c) { hit = a; break; }
                if (hit == null && a.Allocated_To_Territory__c != null && territoriesOf.containsKey(t.Performed_By__c)
                    && territoriesOf.get(t.Performed_By__c).contains(a.Allocated_To_Territory__c)) hit = a;
            }
            if (hit == null) continue;
            Decimal used = (hit.Used_Quantity__c == null ? 0 : hit.Used_Quantity__c) + sign * t.Quantity__c;
            hit.Used_Quantity__c = Math.max(0, used);
            if (hit.Used_Quantity__c >= hit.Allocation_Quantity__c) hit.Status__c = 'Depleted';
            else if (hit.Status__c == 'Depleted') hit.Status__c = 'Active';
            touched.put(hit.Id, hit);
        }
        if (!touched.isEmpty()) update touched.values();
    }
}