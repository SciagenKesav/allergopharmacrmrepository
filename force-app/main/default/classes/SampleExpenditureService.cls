/**
 * UCPMP expenditure tracking: one Sample_Expenditure_Tracking__c row per
 * financial year + doctor + product, kept in step with completed disbursements.
 * Value of a disbursement = packs x units per pack x per-unit value, the basis
 * UCPMP 2024 clause 5.1(ii)(g) prescribes for the annual disclosure.
 */
public without sharing class SampleExpenditureService {

    public static String keyFor(String fy, Id hcp, Id product) { return fy + '|' + hcp + '|' + product; }

    /** sign +1 when disbursements are applied. Also takes sign -1 for either the old
     *  in-place-reversal path (a Disbursement's own Inventory_Applied__c flipping back
     *  off) or a new, separate Transaction_Type__c = 'Reversal' row (SM-UNL-03) — both
     *  represent "undo what a Disbursement already added to this counter". */
    public static void applyDisbursements(List<Sample_Transaction__c> disbursements, Integer sign) {
        if (disbursements == null || disbursements.isEmpty()) return;
        Map<String, Sample_Expenditure_Tracking__c> delta = new Map<String, Sample_Expenditure_Tracking__c>();
        for (Sample_Transaction__c t : disbursements) {
            if ((t.Transaction_Type__c != 'Disbursement' && t.Transaction_Type__c != 'Reversal') || t.HCP_Account__c == null || t.Product__c == null) continue;
            Date givenOn = (t.Performed_At__c == null ? System.now() : t.Performed_At__c).date();
            String fy = SampleLimitChecker.financialYear(givenOn);
            String key = keyFor(fy, t.HCP_Account__c, t.Product__c);
            Decimal packs = t.Quantity__c;
            Decimal size = t.Pack_Size_At_Transaction__c == null ? 1 : t.Pack_Size_At_Transaction__c;
            Decimal unit = t.Unit_Value_At_Transaction__c == null ? 0 : t.Unit_Value_At_Transaction__c;
            Sample_Expenditure_Tracking__c d = delta.get(key);
            if (d == null) {
                d = new Sample_Expenditure_Tracking__c(Tracking_Key__c = key, Financial_Year__c = fy, HCP_Account__c = t.HCP_Account__c, Product__c = t.Product__c,
                    Total_Packs_Given__c = 0, Total_Units_Given__c = 0, Total_Value_INR__c = 0);
                delta.put(key, d);
            }
            d.Total_Packs_Given__c += sign * packs;
            d.Total_Units_Given__c += sign * packs * size;
            d.Total_Value_INR__c += sign * packs * size * unit;
            if (sign > 0 && (d.Last_Sample_Date__c == null || d.Last_Sample_Date__c < givenOn)) d.Last_Sample_Date__c = givenOn;
        }
        if (delta.isEmpty()) return;
        Map<String, Sample_Expenditure_Tracking__c> existing = new Map<String, Sample_Expenditure_Tracking__c>();
        for (Sample_Expenditure_Tracking__c e : [
            SELECT Id, Tracking_Key__c, Total_Packs_Given__c, Total_Units_Given__c, Total_Value_INR__c, Last_Sample_Date__c
            FROM Sample_Expenditure_Tracking__c WHERE Tracking_Key__c IN :delta.keySet() FOR UPDATE
        ]) existing.put(e.Tracking_Key__c, e);
        List<Sample_Expenditure_Tracking__c> upserts = new List<Sample_Expenditure_Tracking__c>();
        for (String key : delta.keySet()) {
            Sample_Expenditure_Tracking__c d = delta.get(key);
            Sample_Expenditure_Tracking__c e = existing.get(key);
            if (e == null) {
                d.Total_Packs_Given__c = Math.max(0, d.Total_Packs_Given__c);
                d.Total_Units_Given__c = Math.max(0, d.Total_Units_Given__c);
                d.Total_Value_INR__c = Math.max(0, d.Total_Value_INR__c);
                upserts.add(d);
            } else {
                e.Total_Packs_Given__c = Math.max(0, nz(e.Total_Packs_Given__c) + d.Total_Packs_Given__c);
                e.Total_Units_Given__c = Math.max(0, nz(e.Total_Units_Given__c) + d.Total_Units_Given__c);
                e.Total_Value_INR__c = Math.max(0, nz(e.Total_Value_INR__c) + d.Total_Value_INR__c);
                if (d.Last_Sample_Date__c != null && (e.Last_Sample_Date__c == null || e.Last_Sample_Date__c < d.Last_Sample_Date__c)) e.Last_Sample_Date__c = d.Last_Sample_Date__c;
                upserts.add(e);
            }
        }
        upsert upserts;
    }

    private static Decimal nz(Decimal d) { return d == null ? 0 : d; }
}