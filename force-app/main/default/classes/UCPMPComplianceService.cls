/**
 * UCPMP 2024 sample compliance: the year's sample expenditure against the 2%
 * ceiling, the per-doctor distribution, refused attempts, and the annual
 * disclosure form (Annexure to clauses 5.1(g) and 14.4).
 */
public with sharing class UCPMPComplianceService {

    public static final Decimal CRORE = 10000000;

    public class UCPMPSummary {
        @AuraEnabled public String financialYear;
        @AuraEnabled public Boolean salesConfigured = false;
        @AuraEnabled public Decimal domesticSalesInr;
        @AuraEnabled public Decimal capInr;
        @AuraEnabled public Decimal spentInr = 0;
        @AuraEnabled public Decimal percentOfSales;        // spent as a share of domestic sales; the cap is 2
        @AuraEnabled public Decimal percentOfCap;          // spent as a share of the cap
        @AuraEnabled public String status;                 // Within, Approaching, Exceeding, No sales figure
        @AuraEnabled public Integer hcpCount = 0;
        @AuraEnabled public Integer packs = 0;
        @AuraEnabled public Integer units = 0;
    }

    public class HCPReport {
        @AuraEnabled public Id hcpId;
        @AuraEnabled public String hcpName;
        @AuraEnabled public String registration;
        @AuraEnabled public String productName;
        @AuraEnabled public Integer packs;
        @AuraEnabled public Integer units;
        @AuraEnabled public Decimal valueInr;
        @AuraEnabled public Integer limitPacks;
        @AuraEnabled public Decimal percentOfLimit;
        @AuraEnabled public String lastSampleDate;
    }

    public class AttemptRow {
        @AuraEnabled public Id id;
        @AuraEnabled public String attemptedAt;
        @AuraEnabled public String repName;
        @AuraEnabled public String hcpName;
        @AuraEnabled public String productName;
        @AuraEnabled public Integer quantity;
        @AuraEnabled public String reasonType;
        @AuraEnabled public String reason;
    }

    public class RestrictedReport {
        @AuraEnabled public List<String> restrictedProducts = new List<String>();
        @AuraEnabled public Integer blockedTotal = 0;
        @AuraEnabled public Integer blockedRestricted = 0;
        @AuraEnabled public Map<String, Integer> byType = new Map<String, Integer>();
        @AuraEnabled public List<AttemptRow> attempts = new List<AttemptRow>();
    }

    public static UCPMPSummary getExpenditureSummary(String fy) {
        UCPMPSummary s = new UCPMPSummary();
        s.financialYear = fy;
        for (AggregateResult ar : [SELECT SUM(Total_Value_INR__c) v, SUM(Total_Packs_Given__c) p, SUM(Total_Units_Given__c) u
                                   FROM Sample_Expenditure_Tracking__c WHERE Financial_Year__c = :fy]) {
            s.spentInr = ar.get('v') == null ? 0 : (Decimal) ar.get('v');
            s.packs = ar.get('p') == null ? 0 : ((Decimal) ar.get('p')).intValue();
            s.units = ar.get('u') == null ? 0 : ((Decimal) ar.get('u')).intValue();
        }
        for (AggregateResult ar : [SELECT COUNT_DISTINCT(HCP_Account__c) c FROM Sample_Expenditure_Tracking__c WHERE Financial_Year__c = :fy AND Total_Packs_Given__c > 0]) {
            s.hcpCount = (Integer) ar.get('c');
        }
        SampleConfig cfg = SampleConfig.load();
        if (cfg.domesticSalesInr != null && cfg.domesticSalesInr > 0 && cfg.financialYear == fy) {
            s.salesConfigured = true;
            s.domesticSalesInr = cfg.domesticSalesInr;
            s.capInr = cfg.twoPercentCap();
            s.percentOfSales = (s.spentInr * 100 / cfg.domesticSalesInr).setScale(3);
            s.percentOfCap = (s.spentInr * 100 / s.capInr).setScale(1);
            s.status = s.percentOfCap >= 100 ? 'Exceeding' : (s.percentOfCap >= 80 ? 'Approaching' : 'Within');
        } else {
            s.status = 'No sales figure';
        }
        return s;
    }

    public static List<HCPReport> getHCPReport(String fy) {
        List<HCPReport> out = new List<HCPReport>();
        for (Sample_Expenditure_Tracking__c e : [
            SELECT HCP_Account__c, HCP_Name__c, HCP_Registration__c, Product__r.Name, Product__r.Max_Packs_Per_HCP_Per_Year__c,
                   Total_Packs_Given__c, Total_Units_Given__c, Total_Value_INR__c, Last_Sample_Date__c
            FROM Sample_Expenditure_Tracking__c WHERE Financial_Year__c = :fy AND Total_Packs_Given__c > 0
            ORDER BY Total_Value_INR__c DESC LIMIT 500
        ]) {
            HCPReport r = new HCPReport();
            r.hcpId = e.HCP_Account__c;
            r.hcpName = e.HCP_Name__c;
            r.registration = e.HCP_Registration__c;
            r.productName = e.Product__r.Name;
            r.packs = e.Total_Packs_Given__c.intValue();
            r.units = e.Total_Units_Given__c == null ? 0 : e.Total_Units_Given__c.intValue();
            r.valueInr = e.Total_Value_INR__c;
            Decimal lim = e.Product__r.Max_Packs_Per_HCP_Per_Year__c;
            r.limitPacks = lim == null ? null : lim.intValue();
            r.percentOfLimit = (lim == null || lim == 0) ? null : (e.Total_Packs_Given__c * 100 / lim).setScale(0);
            r.lastSampleDate = e.Last_Sample_Date__c == null ? null : String.valueOf(e.Last_Sample_Date__c);
            out.add(r);
        }
        return out;
    }

    public static RestrictedReport getRestrictedReport(Integer days) {
        RestrictedReport r = new RestrictedReport();
        for (Product__c p : [SELECT Name FROM Product__c WHERE Is_Restricted__c = true ORDER BY Name]) r.restrictedProducts.add(p.Name);
        Datetime since = System.now().addDays(-days);
        for (Sample_Blocked_Attempt__c a : [
            SELECT Name, Attempted_At__c, Rep__r.Name, HCP_Account__r.Name, Product__r.Name, Quantity__c, Reason_Type__c, Reason__c
            FROM Sample_Blocked_Attempt__c WHERE Attempted_At__c >= :since ORDER BY Attempted_At__c DESC LIMIT 200
        ]) {
            r.blockedTotal++;
            if (a.Reason_Type__c == 'Restricted_Product') r.blockedRestricted++;
            r.byType.put(a.Reason_Type__c == null ? 'Other' : a.Reason_Type__c, (r.byType.containsKey(a.Reason_Type__c == null ? 'Other' : a.Reason_Type__c) ? r.byType.get(a.Reason_Type__c == null ? 'Other' : a.Reason_Type__c) : 0) + 1);
            AttemptRow row = new AttemptRow();
            row.id = a.Id;
            row.attemptedAt = a.Attempted_At__c == null ? null : a.Attempted_At__c.format('dd MMM yyyy HH:mm');
            row.repName = a.Rep__r.Name;
            row.hcpName = a.HCP_Account__r.Name;
            row.productName = a.Product__r.Name;
            row.quantity = a.Quantity__c == null ? null : a.Quantity__c.intValue();
            row.reasonType = a.Reason_Type__c;
            row.reason = a.Reason__c;
            r.attempts.add(row);
        }
        return r;
    }

    public static List<String> financialYears() {
        Set<String> years = new Set<String>{ SampleLimitChecker.financialYear(Date.today()) };
        for (AggregateResult ar : [SELECT Financial_Year__c fy FROM Sample_Expenditure_Tracking__c GROUP BY Financial_Year__c]) years.add((String) ar.get('fy'));
        List<String> out = new List<String>(years);
        out.sort();
        List<String> newestFirst = new List<String>();
        for (Integer i = out.size() - 1; i >= 0; i--) newestFirst.add(out[i]);
        return newestFirst;
    }

    /** The Annexure form for the year, filled in, as a PDF. */
    public static Blob generateDisclosureForm(String fy) {
        PageReference page = Page.UCPMPDisclosureForm;
        page.getParameters().put('fy', fy);
        return Test.isRunningTest() ? Blob.valueOf('pdf') : page.getContentAsPDF();
    }
}