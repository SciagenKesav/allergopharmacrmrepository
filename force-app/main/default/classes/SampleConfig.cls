/**
 * Reads UCPMP_Tenant_Config__c with sensible defaults when nothing is saved yet.
 * (getOrgDefaults() returns an empty record, and custom-setting checkbox defaults
 * are not applied to it, so the defaults live here.)
 */
public without sharing class SampleConfig {
    public Boolean complianceEnabled = true;
    public Boolean enforceRules = true;
    public Boolean requireOptIn = false;
    public Boolean optInHardBlock = false;
    public Integer optInMonths = 12;
    public Decimal domesticSalesInr;
    public String financialYear;
    public UCPMP_Tenant_Config__c row;

    public static SampleConfig load() {
        SampleConfig c = new SampleConfig();
        UCPMP_Tenant_Config__c r = UCPMP_Tenant_Config__c.getOrgDefaults();
        if (r != null && r.Id != null) {
            c.row = r;
            c.complianceEnabled = r.UCPMP_Compliance_Enabled__c == true;
            c.enforceRules = r.Enforce_Sample_Rules__c == true;
            c.requireOptIn = r.Require_Sample_Opt_In__c == true;
            c.optInHardBlock = r.Sample_Opt_In_Hard_Block__c == true;
            if (r.Sample_Opt_In_Months__c != null) c.optInMonths = r.Sample_Opt_In_Months__c.intValue();
            c.domesticSalesInr = r.Domestic_Sales_Revenue_INR__c;
            c.financialYear = r.Financial_Year__c;
        }
        return c;
    }

    /** 2% of domestic sales: the UCPMP ceiling on the value of free samples per year. */
    public Decimal twoPercentCap() {
        return domesticSalesInr == null ? null : (domesticSalesInr * 0.02).setScale(2);
    }
}