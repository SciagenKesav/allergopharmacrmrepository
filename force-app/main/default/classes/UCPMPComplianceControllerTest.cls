@isTest
private class UCPMPComplianceControllerTest {

    // Same pattern as SampleDropServiceTest — FeatureManagement.checkPermission()
    // doesn't reliably see a PermissionSetAssignment created in the same
    // transaction it's checked in, so these users live in @testSetup.
    @testSetup
    static void users() {
        Profile std = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        Profile sysAdmin = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];
        User rep = new User(FirstName = 'No', LastName = 'ConfigPermTest', Alias = 'noconf', Email = 'no.perm.ucpmp@sciagen-test.invalid',
            Username = 'no.perm.ucpmp@sciagen-new-dev.invalid', TimeZoneSidKey = 'Asia/Kolkata', LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US', ProfileId = std.Id, IsActive = true);
        User admin = new User(FirstName = 'Sample', LastName = 'AdminUcpmpTest', Alias = 'sadmc', Email = 'sample.admin.ucpmp@sciagen-test.invalid',
            Username = 'sample.admin.ucpmp@sciagen-new-dev.invalid', TimeZoneSidKey = 'Asia/Kolkata', LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US', ProfileId = sysAdmin.Id, IsActive = true);
        insert new List<User>{ rep, admin };
        insert new PermissionSetAssignment(AssigneeId = rep.Id, PermissionSetId = [SELECT Id FROM PermissionSet WHERE Name = 'Sciagen_Mobile_App_Access'].Id);
        insert new PermissionSetAssignment(AssigneeId = admin.Id, PermissionSetId = [SELECT Id FROM PermissionSet WHERE Name = 'Sciagen_Sample_Admin'].Id);
    }

    static User repNoPermission() { return [SELECT Id FROM User WHERE Username = 'no.perm.ucpmp@sciagen-new-dev.invalid']; }
    static User sampleAdminUser() { return [SELECT Id FROM User WHERE Username = 'sample.admin.ucpmp@sciagen-new-dev.invalid']; }

    @isTest
    static void readMethodsDelegateToTheService() {
        Sciagen_Account__c hcp = SampleTestData.doctor('Dr Controller Delegate');
        Product__c p = SampleTestData.product('Controller Delegate SKU');
        insert new Sample_Expenditure_Tracking__c(HCP_Account__c = hcp.Id, Product__c = p.Id, Financial_Year__c = SampleLimitChecker.financialYear(Date.today()),
            Total_Packs_Given__c = 2, Total_Units_Given__c = 8, Total_Value_INR__c = 200, Last_Sample_Date__c = Date.today());

        List<String> years = UCPMPComplianceController.getFinancialYears();
        System.assert(years.contains(SampleLimitChecker.financialYear(Date.today())));

        UCPMPComplianceService.UCPMPSummary summary = UCPMPComplianceController.getSummary(SampleLimitChecker.financialYear(Date.today()));
        System.assertEquals(2, summary.packs);

        List<UCPMPComplianceService.HCPReport> report = UCPMPComplianceController.getHcpReport(SampleLimitChecker.financialYear(Date.today()));
        System.assertEquals(1, report.size());
        System.assertEquals(hcp.Id, report[0].hcpId);

        UCPMPComplianceService.RestrictedReport restricted = UCPMPComplianceController.getRestricted();
        System.assertEquals(0, restricted.blockedTotal, 'nothing blocked yet');
    }

    @isTest
    static void getConfigReadsTheOrgDefaultsAndReflectsPermission() {
        UCPMP_Tenant_Config__c cfg = new UCPMP_Tenant_Config__c(SetupOwnerId = UserInfo.getOrganizationId(), UCPMP_Compliance_Enabled__c = true,
            Enforce_Sample_Rules__c = true, Financial_Year__c = '2026-27', Domestic_Sales_Revenue_INR__c = 250 * UCPMPComplianceService.CRORE,
            Company_Name__c = 'Allergopharma (demo)', Company_CIN__c = 'U00000MH0000PLC000000');
        insert cfg;

        UCPMPComplianceController.ConfigDTO adminView;
        System.runAs(sampleAdminUser()) { adminView = UCPMPComplianceController.getConfig(); }
        System.assertEquals('2026-27', adminView.financialYear);
        System.assertEquals(250.00, adminView.domesticSalesCrore);
        System.assertEquals('Allergopharma (demo)', adminView.companyName);
        System.assertEquals(true, adminView.canEdit);

        UCPMPComplianceController.ConfigDTO repView;
        System.runAs(repNoPermission()) { repView = UCPMPComplianceController.getConfig(); }
        System.assertEquals(false, repView.canEdit);
    }

    @isTest
    static void getConfigFallsBackToTheCurrentFinancialYearWhenNothingIsSaved() {
        UCPMPComplianceController.ConfigDTO d = UCPMPComplianceController.getConfig();
        System.assertEquals(SampleLimitChecker.financialYear(Date.today()), d.financialYear);
        System.assertEquals(null, d.domesticSalesInr);
    }

    @isTest
    static void saveConfigRequiresThePermissionAndRejectsNegativeSales() {
        System.runAs(repNoPermission()) {
            try {
                UCPMPComplianceController.saveConfig('2026-27', 250, 'X', null, null, null, null, null, null, null, null);
                System.assert(false, 'a rep without Manage_Sample_Inventory must not be able to save UCPMP settings');
            } catch (AuraHandledException e) {
                System.assert(e.getMessage().contains('sample manager'), e.getMessage());
            }
        }
        System.runAs(sampleAdminUser()) {
            try {
                UCPMPComplianceController.saveConfig('2026-27', -1, 'X', null, null, null, null, null, null, null, null);
                System.assert(false, 'negative domestic sales must be rejected');
            } catch (AuraHandledException e) {
                System.assert(e.getMessage().contains('negative'), e.getMessage());
            }
        }
    }

    @isTest
    static void saveConfigUpsertsTheSingletonOrgDefaultRecord() {
        UCPMPComplianceController.ConfigDTO saved;
        System.runAs(sampleAdminUser()) {
            saved = UCPMPComplianceController.saveConfig('2026-27', 250, 'Allergopharma (demo)', 'U00000MH0000PLC000000',
                'Registered office address to be filled', 'compliance@allergopharma-demo.invalid', 'ABCDE1234F',
                'Director', 'DIN12345678', '9999999999', 'signatory@allergopharma-demo.invalid');
        }
        System.assertEquals('2026-27', saved.financialYear);
        System.assertEquals(250.00, saved.domesticSalesCrore);
        System.assertEquals('Allergopharma (demo)', saved.companyName);
        UCPMP_Tenant_Config__c row = UCPMP_Tenant_Config__c.getOrgDefaults();
        System.assertEquals(250 * UCPMPComplianceService.CRORE, row.Domestic_Sales_Revenue_INR__c);
        System.assertEquals(true, row.UCPMP_Compliance_Enabled__c, 'a first-time save turns compliance tracking on');

        // A second save updates the SAME record (upsert on the org-default singleton), not a new one.
        System.runAs(sampleAdminUser()) { UCPMPComplianceController.saveConfig('2026-27', 300, 'Allergopharma (demo)', null, null, null, null, null, null, null, null); }
        System.assertEquals(1, [SELECT COUNT() FROM UCPMP_Tenant_Config__c]);
        System.assertEquals(300 * UCPMPComplianceService.CRORE, UCPMP_Tenant_Config__c.getOrgDefaults().Domestic_Sales_Revenue_INR__c);
    }

    @isTest
    static void generateDisclosureSavesAPdfFileAndReturnsWhereToDownloadIt() {
        UCPMPComplianceController.FileDTO f = UCPMPComplianceController.generateDisclosure('2026-27');
        System.assertNotEquals(null, f.documentId);
        System.assertEquals('UCPMP Disclosure FY 2026-27', f.title);
        System.assert(f.downloadPath.contains(String.valueOf(f.documentId)));
        ContentVersion cv = [SELECT Title, ContentDocumentId FROM ContentVersion WHERE ContentDocumentId = :f.documentId];
        System.assertEquals('UCPMP Disclosure FY 2026-27', cv.Title);
    }
}
