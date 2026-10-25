@isTest
private class UCPMPComplianceTest {

    static void seedGiven() {
        Product__c p = SampleTestData.product('UCPMP Rpt SKU');
        Sciagen_Account__c d1 = SampleTestData.doctor('Dr Report One');
        Sciagen_Account__c d2 = SampleTestData.doctor('Dr Report Two');
        Sample_Lot__c l = SampleTestData.lot(p, 'RPT-1', 100, 300);
        SampleTestData.given(p, l, d1, 10);
        SampleTestData.given(p, l, d2, 3);
    }

    @isTest
    static void summaryTotalsSpendAgainstTheTwoPercentCap() {
        seedGiven();
        String fy = SampleLimitChecker.financialYear(Date.today());
        UCPMPComplianceService.UCPMPSummary noSales = UCPMPComplianceService.getExpenditureSummary(fy);
        System.assertEquals('No sales figure', noSales.status);
        System.assertEquals(13, noSales.packs);
        System.assertEquals(52, noSales.units);
        System.assertEquals(520, noSales.spentInr, '13 packs x 4 units x INR 10');
        System.assertEquals(2, noSales.hcpCount);

        insert new UCPMP_Tenant_Config__c(SetupOwnerId = UserInfo.getOrganizationId(), Financial_Year__c = fy, Domestic_Sales_Revenue_INR__c = 20000, UCPMP_Compliance_Enabled__c = true, Enforce_Sample_Rules__c = true);
        UCPMPComplianceService.UCPMPSummary s = UCPMPComplianceService.getExpenditureSummary(fy);
        System.assertEquals(400, s.capInr, '2% of 20,000');
        System.assertEquals('Exceeding', s.status);
        System.assertEquals(2.6, s.percentOfSales);
        System.assertEquals(130.0, s.percentOfCap);

        UCPMP_Tenant_Config__c cfg = UCPMP_Tenant_Config__c.getOrgDefaults();
        cfg.Domestic_Sales_Revenue_INR__c = 100000;
        update cfg;
        System.assertEquals('Within', UCPMPComplianceService.getExpenditureSummary(fy).status);
        cfg.Domestic_Sales_Revenue_INR__c = 30000;
        update cfg;
        System.assertEquals('Approaching', UCPMPComplianceService.getExpenditureSummary(fy).status, '520 is 86.7% of a 600 cap');
    }

    @isTest
    static void hcpReportShowsPercentOfTheTwelvePackLimit() {
        seedGiven();
        List<UCPMPComplianceService.HCPReport> rows = UCPMPComplianceService.getHCPReport(SampleLimitChecker.financialYear(Date.today()));
        System.assertEquals(2, rows.size());
        System.assertEquals('Dr Report One', rows[0].hcpName, 'largest value first');
        System.assertEquals(10, rows[0].packs);
        System.assertEquals(12, rows[0].limitPacks);
        System.assertEquals(83, rows[0].percentOfLimit);
        System.assert(rows[0].registration.startsWith('MCI-'));
    }

    @isTest
    static void financialYearListAlwaysIncludesThisYear() {
        seedGiven();
        List<String> years = UCPMPComplianceService.financialYears();
        System.assert(years.contains(SampleLimitChecker.financialYear(Date.today())));
    }

    @isTest
    static void refusedSampleAttemptsAreLoggedEvenThoughTheSaveRollsBack() {
        Product__c restricted = new Product__c(Product_Code__c = 'T-UCPMPC-1', Name = 'Sleep Log SKU', Level__c = 'SKU', Is_Sample_Product__c = true, Sample_Unit_Value_INR__c = 5,
            Is_Restricted__c = true, Restriction_Reason__c = 'Hypnotic_Sedative_Tranquillizer', Max_Packs_Per_HCP_Per_Year__c = 0);
        insert restricted;
        Sciagen_Account__c d = SampleTestData.doctor('Dr Attempt');
        Call_Visit_Report__c call = SampleTestData.call(d, 'Draft');
        Test.startTest();
        Database.SaveResult r = Database.insert(new Sample_Drop__c(Name = 'Sample Drop', CVR__c = call.Id, Product__c = restricted.Id, Qty__c = 1), false);
        Test.getEventBus().deliver();
        Test.stopTest();
        System.assert(!r.isSuccess());
        UCPMPComplianceService.RestrictedReport rep = UCPMPComplianceService.getRestrictedReport(30);
        System.assertEquals(1, rep.blockedTotal);
        System.assertEquals(1, rep.blockedRestricted);
        System.assert(rep.restrictedProducts.contains('Sleep Log SKU'));
        System.assertEquals('Restricted_Product', rep.attempts[0].reasonType);
    }

    @isTest
    static void attemptReasonsAreClassified() {
        System.assertEquals('Limit', SampleAttemptLogService.classify('UCPMP limit reached: 12/12'));
        System.assertEquals('Licence', SampleAttemptLogService.classify('HCP licence is expired'));
        System.assertEquals('Cold_Chain', SampleAttemptLogService.classify('Cold chain breach detected'));
        System.assertEquals('Signature', SampleAttemptLogService.classify('The doctor\'s signature is required'));
        System.assertEquals('Lot_Or_Stock', SampleAttemptLogService.classify('You have no active lot'));
        System.assertEquals('Other', SampleAttemptLogService.classify('something else'));
    }

    @isTest
    static void disclosureFormFillsTheAnnexureFromSettingsAndTheLedger() {
        seedGiven();
        String fy = SampleLimitChecker.financialYear(Date.today());
        insert new UCPMP_Tenant_Config__c(SetupOwnerId = UserInfo.getOrganizationId(), Financial_Year__c = fy, Domestic_Sales_Revenue_INR__c = 2500000000.00, Company_Name__c = 'Demo Pharma',
            Company_CIN__c = 'U24230MH2001PLC000000', Company_PAN__c = 'AAAAA0000A', UCPMP_Compliance_Enabled__c = true, Enforce_Sample_Rules__c = true);
        Test.setCurrentPage(Page.UCPMPDisclosureForm);
        ApexPages.currentPage().getParameters().put('fy', fy);
        UCPMPDisclosureController c = new UCPMPDisclosureController();
        System.assertEquals(fy, c.fy);
        System.assertEquals('Demo Pharma', c.companyName);
        System.assertEquals('250.0000', c.salesCrore, 'INR 250 crore');
        System.assertEquals('0.0001', c.samplesCrore, 'INR 520 is 0.000052 crore, shown to four decimals');
        System.assertEquals('2', c.hcpCount);
        System.assert(c.methodology.contains('5.1(g)'));
        System.assertEquals('1.5000', UCPMPDisclosureController.crore(15000000));
        System.assertNotEquals(null, UCPMPComplianceService.generateDisclosureForm(fy));
    }

    @isTest
    static void controllerConfigAndFileGeneration() {
        SampleAccess.testIsManager = true;
        String fy = SampleLimitChecker.financialYear(Date.today());
        UCPMPComplianceController.ConfigDTO saved = UCPMPComplianceController.saveConfig(fy, 250, 'Demo Pharma', 'CIN1', 'Mumbai', 'a@b.in', 'PAN1', 'CEO', 'DIN1', '9999999999', 'ceo@b.in');
        System.assertEquals(2500000000.00, saved.domesticSalesInr);
        System.assertEquals(250.00, saved.domesticSalesCrore);
        System.assertEquals(true, saved.canEdit);
        System.assertEquals('Demo Pharma', UCPMPComplianceController.getConfig().companyName);
        try {
            UCPMPComplianceController.saveConfig(fy, -1, null, null, null, null, null, null, null, null, null);
            System.assert(false, 'negative sales must be refused');
        } catch (AuraHandledException e) { System.assert(true); }
        UCPMPComplianceController.FileDTO f = UCPMPComplianceController.generateDisclosure(fy);
        System.assertNotEquals(null, f.documentId);
        System.assert(f.downloadPath.contains(String.valueOf(f.documentId)));
        System.assertNotEquals(null, UCPMPComplianceController.getFinancialYears());
        System.assertNotEquals(null, UCPMPComplianceController.getSummary(fy));
        System.assertNotEquals(null, UCPMPComplianceController.getHcpReport(fy));
        System.assertNotEquals(null, UCPMPComplianceController.getRestricted());
    }
}