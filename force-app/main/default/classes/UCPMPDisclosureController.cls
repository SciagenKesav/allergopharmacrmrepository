/**
 * Fills the fields of the UCPMP disclosure Annexure (clauses 5.1(g) and 14.4)
 * from the company settings and the year's sample expenditure. Only the free
 * samples line is produced by Sample Management; education programme lines
 * are left for the company to complete.
 */
public with sharing class UCPMPDisclosureController {
    public String fy { get; private set; }
    public String cin { get; private set; }
    public String companyName { get; private set; }
    public String address { get; private set; }
    public String email { get; private set; }
    public String pan { get; private set; }
    public String salesCrore { get; private set; }
    public String samplesCrore { get; private set; }
    public String hcpCount { get; private set; }
    public String methodology { get; private set; }
    public String designation { get; private set; }
    public String dinOrPan { get; private set; }
    public String mobile { get; private set; }
    public String signEmail { get; private set; }
    public String generatedOn { get; private set; }

    public UCPMPDisclosureController() {
        String requested = ApexPages.currentPage() == null ? null : ApexPages.currentPage().getParameters().get('fy');
        fy = String.isBlank(requested) ? SampleLimitChecker.financialYear(Date.today()) : requested;
        UCPMP_Tenant_Config__c c = UCPMP_Tenant_Config__c.getOrgDefaults();
        cin = blank(c.Company_CIN__c);
        companyName = blank(c.Company_Name__c);
        address = blank(c.Company_Address__c);
        email = blank(c.Company_Email__c);
        pan = blank(c.Company_PAN__c);
        designation = blank(c.Signatory_Designation__c);
        dinOrPan = blank(c.Signatory_DIN_or_PAN__c);
        mobile = blank(c.Signatory_Mobile__c);
        signEmail = blank(c.Signatory_Email__c);
        UCPMPComplianceService.UCPMPSummary s = UCPMPComplianceService.getExpenditureSummary(fy);
        salesCrore = s.salesConfigured ? crore(s.domesticSalesInr) : '';
        samplesCrore = crore(s.spentInr);
        hcpCount = String.valueOf(s.hcpCount);
        methodology = 'Free samples are valued on a per-unit basis (tablet, capsule, vial, gram or ml) at the price charged to the stockist for the same dosage form and strength, '
            + 'or at the purchase price for products bought from another supplier (UCPMP 2024 clause 5.1(g)). Value of each hand-out = packs x units per pack x per-unit value, '
            + 'captured at the time of supply. Recipient healthcare professionals are the distinct doctors given at least one sample pack in the financial year. '
            + 'Total ' + s.packs + ' packs (' + s.units + ' units). Source: Sciagen Sample Management ledger.';
        generatedOn = System.now().format('dd MMM yyyy HH:mm');
    }

    private static String blank(String v) { return v == null ? '' : v; }

    /** Rupees to crore, four decimals. */
    public static String crore(Decimal inr) {
        if (inr == null) return '';
        return (inr / UCPMPComplianceService.CRORE).setScale(4).toPlainString();
    }
}