/**
 * Phase 0 Step 8 (D4): seeds UCPMP_Tenant_Config__c (the org-default hierarchy custom
 * setting) with the sandbox's demo fixture, so disclosure/compliance-dashboard fields
 * stop rendering blank while Phase 0-6 land. Currently 0 records exist in this org.
 *
 * Demo values only — matches the fixture already used throughout the audit and this
 * build (see UCPMPComplianceServiceTest/UCPMPDisclosureControllerTest, and the sample
 * "UCPMP Disclosure FY 2026-27" PDF the user supplied, which was itself generated from
 * these same figures). Real company values (CIN, PAN, signatory details, actual
 * domestic sales) are a production-only concern for finance/compliance to provide —
 * never committed to this repo (D4).
 *
 * Idempotent: upserts the one org-default row, safe to run again.
 */
UCPMP_Tenant_Config__c cfg = UCPMP_Tenant_Config__c.getOrgDefaults();
if (cfg.Id == null) {
    cfg.SetupOwnerId = UserInfo.getOrganizationId();
}
cfg.UCPMP_Compliance_Enabled__c = true;
cfg.Enforce_Sample_Rules__c = true;
cfg.Financial_Year__c = '2026-27';
cfg.Domestic_Sales_Revenue_INR__c = 2500000000.0;   // 250 crore, demo figure. A Decimal literal (the .0) -- a bare integer literal this large doesn't compile ("Illegal integer"), and 250*10000000 as Integer*Integer overflows and silently wraps negative at runtime.
cfg.Company_Name__c = 'Allergopharma (demo)';
cfg.Company_CIN__c = 'U00000MH0000PLC000000';
cfg.Company_Address__c = 'Registered office address to be filled';
cfg.Require_Sample_Opt_In__c = false;
cfg.Sample_Opt_In_Hard_Block__c = false;
cfg.Sample_Opt_In_Months__c = 12;
// Company_Email__c/Company_PAN__c and every Signatory_*__c field are left blank on
// purpose — real values for those come from finance/compliance in production, not this
// demo seed (D4).
upsert cfg;

System.debug('UCPMP_Tenant_Config__c seeded: ' + cfg);
