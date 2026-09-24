@isTest
private class UCPMPComplianceServiceTest {

    static UCPMP_Tenant_Config__c config(Decimal salesInr) {
        UCPMP_Tenant_Config__c c = new UCPMP_Tenant_Config__c(SetupOwnerId = UserInfo.getOrganizationId(), UCPMP_Compliance_Enabled__c = true,
            Enforce_Sample_Rules__c = true, Financial_Year__c = '2026-27', Domestic_Sales_Revenue_INR__c = salesInr);
        insert c;
        return c;
    }

    @isTest
    static void expenditureSummaryComputesPercentagesAndStatusAsSpendGrows() {
        config(10000000);                                          // 1 crore sales -> 2% cap = 200,000 INR
        Sciagen_Account__c hcp = SampleTestData.doctor('Dr Summary');
        Product__c p = SampleTestData.product('Summary SKU');
        Sample_Expenditure_Tracking__c e = new Sample_Expenditure_Tracking__c(
            HCP_Account__c = hcp.Id, Product__c = p.Id, Financial_Year__c = '2026-27', Total_Packs_Given__c = 10, Total_Units_Given__c = 40,
            Total_Value_INR__c = 100000, Last_Sample_Date__c = Date.today());
        insert e;

        UCPMPComplianceService.UCPMPSummary within = UCPMPComplianceService.getExpenditureSummary('2026-27');
        System.assertEquals(true, within.salesConfigured);
        System.assertEquals(10000000, within.domesticSalesInr);
        System.assertEquals(200000, within.capInr, '2% of 1 crore');
        System.assertEquals(100000, within.spentInr);
        System.assertEquals(1, within.hcpCount);
        System.assertEquals(10, within.packs);
        System.assertEquals(40, within.units);
        System.assertEquals(1.000, within.percentOfSales, '100,000 / 10,000,000 x 100');
        System.assertEquals(50.0, within.percentOfCap, '100,000 / 200,000 x 100');
        System.assertEquals('Within', within.status);

        e.Total_Value_INR__c = 170000;                              // 85% of the cap
        update e;
        System.assertEquals('Approaching', UCPMPComplianceService.getExpenditureSummary('2026-27').status);

        e.Total_Value_INR__c = 250000;                              // 125% of the cap
        update e;
        System.assertEquals('Exceeding', UCPMPComplianceService.getExpenditureSummary('2026-27').status);
    }

    @isTest
    static void expenditureSummaryWithoutSalesConfiguredSaysSo() {
        UCPMPComplianceService.UCPMPSummary s = UCPMPComplianceService.getExpenditureSummary('2026-27');
        System.assertEquals(false, s.salesConfigured);
        System.assertEquals('No sales figure', s.status);
        System.assertEquals(0, s.spentInr, 'no expenditure rows exist for this FY either');
    }

    @isTest
    static void expenditureSummaryIgnoresConfigForADifferentFinancialYear() {
        config(10000000);                                           // configured for 2026-27 only
        System.assertEquals(false, UCPMPComplianceService.getExpenditureSummary('2025-26').salesConfigured);
    }

    @isTest
    static void hcpReportComputesPercentOfLimitAndSortsByValueDescending() {
        Product__c p = SampleTestData.product('Report SKU');
        p.Max_Packs_Per_HCP_Per_Year__c = 12;
        update p;
        Sciagen_Account__c d1 = SampleTestData.doctor('Dr Report One');
        Sciagen_Account__c d2 = SampleTestData.doctor('Dr Report Two');
        insert new Sample_Expenditure_Tracking__c(HCP_Account__c = d1.Id, Product__c = p.Id, Financial_Year__c = '2026-27',
            Total_Packs_Given__c = 6, Total_Units_Given__c = 24, Total_Value_INR__c = 500, Last_Sample_Date__c = Date.today());
        insert new Sample_Expenditure_Tracking__c(HCP_Account__c = d2.Id, Product__c = p.Id, Financial_Year__c = '2026-27',
            Total_Packs_Given__c = 3, Total_Units_Given__c = 12, Total_Value_INR__c = 900, Last_Sample_Date__c = Date.today());

        List<UCPMPComplianceService.HCPReport> rows = UCPMPComplianceService.getHCPReport('2026-27');
        System.assertEquals(2, rows.size());
        System.assertEquals(d2.Id, rows[0].hcpId, 'higher value first');
        System.assertEquals(900, rows[0].valueInr);
        System.assertEquals(d1.Id, rows[1].hcpId);
        System.assertEquals(12, rows[1].limitPacks);
        System.assertEquals(50, rows[1].percentOfLimit, '6/12 = 50%');
        System.assertEquals(d1.Name, rows[1].hcpName);
    }

    @isTest
    static void restrictedReportCountsAndGroupsBlockedAttemptsWithinTheWindow() {
        Product__c restricted = new Product__c(Name = 'Restricted Sample', Product_Code__c = 'RESTRICT-1', Is_Restricted__c = true, Is_Sample_Product__c = true);
        insert restricted;
        Sciagen_Account__c hcp = SampleTestData.doctor('Dr Restricted Report');
        insert new Sample_Blocked_Attempt__c(Product__c = restricted.Id, HCP_Account__c = hcp.Id, Rep__c = UserInfo.getUserId(), Quantity__c = 2,
            Reason__c = 'restricted and can not be sampled', Reason_Type__c = 'Restricted_Product', Attempted_At__c = System.now());
        insert new Sample_Blocked_Attempt__c(Product__c = restricted.Id, HCP_Account__c = hcp.Id, Rep__c = UserInfo.getUserId(), Quantity__c = 1,
            Reason__c = 'Limit reached', Reason_Type__c = 'Limit', Attempted_At__c = System.now());
        insert new Sample_Blocked_Attempt__c(Product__c = restricted.Id, HCP_Account__c = hcp.Id, Rep__c = UserInfo.getUserId(), Quantity__c = 1,
            Reason__c = 'old one', Reason_Type__c = 'Limit', Attempted_At__c = System.now().addDays(-100));   // outside the 90-day window

        UCPMPComplianceService.RestrictedReport r = UCPMPComplianceService.getRestrictedReport(90);
        System.assertEquals(1, r.restrictedProducts.size());
        System.assertEquals('Restricted Sample', r.restrictedProducts[0]);
        System.assertEquals(2, r.blockedTotal, 'the 100-day-old attempt is outside the window');
        System.assertEquals(1, r.blockedRestricted);
        System.assertEquals(1, r.byType.get('Restricted_Product'));
        System.assertEquals(1, r.byType.get('Limit'));
        System.assertEquals(2, r.attempts.size());
    }

    @isTest
    static void financialYearsPutsTheCurrentOneFirstAlongsideAnyThatHaveData() {
        Sciagen_Account__c hcp = SampleTestData.doctor('Dr FY List');
        Product__c p = SampleTestData.product('FY List SKU');
        insert new Sample_Expenditure_Tracking__c(HCP_Account__c = hcp.Id, Product__c = p.Id, Financial_Year__c = '2024-25', Total_Packs_Given__c = 1,
            Total_Units_Given__c = 1, Total_Value_INR__c = 10, Last_Sample_Date__c = Date.today());
        List<String> years = UCPMPComplianceService.financialYears();
        System.assertEquals(SampleLimitChecker.financialYear(Date.today()), years[0], 'the current FY sorts first');
        System.assert(years.contains('2024-25'));
    }

    @isTest
    static void generateDisclosureFormReturnsAPdfBlobInTestContext() {
        // Page.getContentAsPDF() isn't available in a test context, so
        // generateDisclosureForm() falls back to a placeholder blob there —
        // this just proves that fallback is wired up; UCPMPDisclosureControllerTest
        // covers the actual page content (VisualforceController).
        Blob pdf = UCPMPComplianceService.generateDisclosureForm('2026-27');
        System.assertNotEquals(null, pdf);
    }
}
