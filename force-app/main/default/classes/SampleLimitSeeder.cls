/**
 * Creates the default sample limits: the UCPMP regulatory ones (hard, can't be
 * deleted) and the company ones (soft, with override). Safe to run again.
 */
public without sharing class SampleLimitSeeder {

    public static Integer seedDefaults() {
        Map<String, Sample_Limit__c> wanted = new Map<String, Sample_Limit__c>();
        add(wanted, new Sample_Limit__c(Name = 'UCPMP: 12 packs per drug per doctor per FY', Limit_Scope__c = 'HCP_Product', Limit_Quantity__c = 12,
            Limit_Period__c = 'Financial_Year', Hard_Block__c = true, Is_Regulatory__c = true, Regulatory_Reference__c = SampleLimitChecker.UCPMP_REF, Warning_Threshold_Pct__c = 80));
        add(wanted, new Sample_Limit__c(Name = 'Company: 6 packs max per call', Limit_Scope__c = 'Per_Call', Limit_Quantity__c = 6,
            Limit_Period__c = 'Per_Call', Hard_Block__c = false, Warning_Threshold_Pct__c = 80));
        add(wanted, new Sample_Limit__c(Name = 'Company: 200 packs per rep per month', Limit_Scope__c = 'Rep_All', Limit_Quantity__c = 200,
            Limit_Period__c = 'Monthly', Hard_Block__c = false, Override_Requires_Manager__c = true, Warning_Threshold_Pct__c = 80));
        add(wanted, new Sample_Limit__c(Name = 'Company: 36 packs per doctor per FY, all products', Limit_Scope__c = 'HCP_All', Limit_Quantity__c = 36,
            Limit_Period__c = 'Financial_Year', Hard_Block__c = false, Warning_Threshold_Pct__c = 80));
        for (Product__c p : [SELECT Id, Name FROM Product__c WHERE Is_Restricted__c = true]) {
            add(wanted, new Sample_Limit__c(Name = 'UCPMP: restricted product ' + p.Name.left(40) + ' = 0', Limit_Scope__c = 'Product_Global', Product__c = p.Id,
                Limit_Quantity__c = 0, Limit_Period__c = 'Lifetime', Hard_Block__c = true, Is_Regulatory__c = true,
                Regulatory_Reference__c = 'UCPMP 2024 Clause 5.1(ii)(f)', Warning_Threshold_Pct__c = 100));
        }
        Set<String> have = new Set<String>();
        for (Sample_Limit__c l : [SELECT Name FROM Sample_Limit__c WHERE Name IN :wanted.keySet()]) have.add(l.Name);
        List<Sample_Limit__c> toInsert = new List<Sample_Limit__c>();
        for (String n : wanted.keySet()) if (!have.contains(n)) toInsert.add(wanted.get(n));
        insert toInsert;
        return toInsert.size();
    }

    private static void add(Map<String, Sample_Limit__c> m, Sample_Limit__c l) { m.put(l.Name.left(80), l); }
}