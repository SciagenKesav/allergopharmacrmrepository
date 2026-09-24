@isTest
private class UCPMPDisclosureControllerTest {

    /** Reproduces the exact demo fixture from the build prompt (D4): FY 2026-27,
     *  ₹250.0000 crore domestic sales, ₹0.0001 crore in free samples, 1 recipient HCP,
     *  3 packs (12 units), and the methodology text ending in the fixed attribution line. */
    @isTest
    static void reproducesTheDemoDisclosureFixtureForFY202627() {
        insert new UCPMP_Tenant_Config__c(SetupOwnerId = UserInfo.getOrganizationId(), UCPMP_Compliance_Enabled__c = true, Enforce_Sample_Rules__c = true,
            Financial_Year__c = '2026-27', Domestic_Sales_Revenue_INR__c = 250 * UCPMPComplianceService.CRORE,
            Company_Name__c = 'Allergopharma (demo)', Company_CIN__c = 'U00000MH0000PLC000000',
            Company_Address__c = 'Registered office address to be filled');
        Sciagen_Account__c hcp = SampleTestData.doctor('Dr Disclosure Demo');
        Product__c p = SampleTestData.product('Disclosure Demo SKU');
        insert new Sample_Expenditure_Tracking__c(HCP_Account__c = hcp.Id, Product__c = p.Id, Financial_Year__c = '2026-27',
            Total_Packs_Given__c = 3, Total_Units_Given__c = 12, Total_Value_INR__c = 1000, Last_Sample_Date__c = Date.today());

        Test.setCurrentPageReference(new PageReference('/apex/UCPMPDisclosureForm'));
        ApexPages.currentPage().getParameters().put('fy', '2026-27');
        UCPMPDisclosureController c = new UCPMPDisclosureController();

        System.assertEquals('2026-27', c.fy);
        System.assertEquals('U00000MH0000PLC000000', c.cin);
        System.assertEquals('Allergopharma (demo)', c.companyName);
        System.assertEquals('Registered office address to be filled', c.address);
        System.assertEquals('250.0000', c.salesCrore);
        System.assertEquals('0.0001', c.samplesCrore);
        System.assertEquals('1', c.hcpCount);
        System.assert(c.methodology.contains('Total 3 packs (12 units)'), c.methodology);
        System.assert(c.methodology.endsWith('Source: Sciagen Sample Management ledger.'), c.methodology);
        System.assertNotEquals(null, c.generatedOn);
    }

    @isTest
    static void blanksAreSafeWhenNothingIsConfiguredYet() {
        Test.setCurrentPageReference(new PageReference('/apex/UCPMPDisclosureForm'));
        UCPMPDisclosureController c = new UCPMPDisclosureController();
        System.assertEquals(SampleLimitChecker.financialYear(Date.today()), c.fy, 'no fy param falls back to the current FY');
        System.assertEquals('', c.cin);
        System.assertEquals('', c.companyName);
        System.assertEquals('', c.salesCrore, 'no sales configured -> blank, not zero, so the field reads as visibly incomplete');
        System.assertEquals('0.0000', c.samplesCrore, 'no expenditure recorded yet');
        System.assertEquals('0', c.hcpCount);
        System.assert(c.methodology.endsWith('Source: Sciagen Sample Management ledger.'));
    }

    @isTest
    static void crorePlacesFourDecimalsAndBlanksOutNull() {
        System.assertEquals('', UCPMPDisclosureController.crore(null));
        System.assertEquals('1.5000', UCPMPDisclosureController.crore(15000000));
        System.assertEquals('0.0001', UCPMPDisclosureController.crore(1000));
    }
}
