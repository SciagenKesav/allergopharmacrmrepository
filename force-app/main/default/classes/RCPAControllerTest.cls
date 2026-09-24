@isTest
private class RCPAControllerTest {

    @testSetup
    static void setup() {
        Sciagen_Account__c chemist = new Sciagen_Account__c(
            Type__c = 'HCO', Name = 'Verify Chemist', HCO_Type__c = 'Chemist Shop', Speciality__c = 'Other',
            Billing_City__c = 'New Delhi', Phone__c = '9999999999'
        );
        Sciagen_Account__c prescriber = new Sciagen_Account__c(
            Type__c = 'HCP', Name = 'Dr. Anita Rao', Prefix__c = 'Dr.', First_Name__c = 'Anita', Last_Name__c = 'Rao',
            Specialty__c = 'Cardiology', HCP_Type__c = 'Physician'
        );
        insert new List<Sciagen_Account__c>{ chemist, prescriber };

        Territory__c territory = new Territory__c(Name = 'North Delhi', Territory_Code__c = 'ND', Type__c = 'Territory');
        insert territory;

        RCPA_Audit__c audit = new RCPA_Audit__c(
            Chemist__c = chemist.Id, Territory__c = territory.Id, Audit_Date__c = Date.newInstance(2026, 1, 15),
            Status__c = 'Draft', Rep__c = 'Verify Rep', POB_Units__c = 40,
            Chemist_Signer_Name__c = 'Chemist Owner', Chemist_OTP_Verified__c = true,
            Competitor_Activity__c = 'Competitor sampling seen', Stock_Issues__c = 'None',
            General_Remarks__c = 'Routine audit'
        );
        insert audit;

        RCPA_Line__c line = new RCPA_Line__c(
            Audit__c = audit.Id, Prescriber__c = prescriber.Id, Molecule__c = 'Metformin',
            Own_Brand__c = 'Glaritus', Own_Units_Per_Week__c = 12, Trend__c = 'Growing', Remarks__c = 'Loyal prescriber'
        );
        insert line;

        insert new RCPA_Competitor__c(
            Line__c = line.Id, Company__c = 'Rival Pharma', Brand__c = 'RivalMet', Units_Per_Week__c = 5
        );
    }

    @isTest
    static void testSearchAuditsMatchesByChemistName() {
        Test.startTest();
        List<RCPAController.AuditSummary> results = RCPAController.searchAudits('Verify Chemist', null, null);
        Test.stopTest();

        System.assertEquals(1, results.size(), 'Expected exactly one audit matching "Verify Chemist"');
        System.assertEquals('Verify Chemist', results[0].chemistName);
        System.assertEquals('New Delhi', results[0].chemistArea);
        System.assertEquals('North Delhi', results[0].territory);
        System.assertEquals('Draft', results[0].status);
        System.assertEquals(40, results[0].pobUnits);
    }

    @isTest
    static void testSearchAuditsFilteredByStatus() {
        Test.startTest();
        List<RCPAController.AuditSummary> draftResults = RCPAController.searchAudits('', 'Draft', null);
        List<RCPAController.AuditSummary> submittedResults = RCPAController.searchAudits('', 'Submitted', null);
        Test.stopTest();

        System.assertEquals(1, draftResults.size());
        System.assertEquals(0, submittedResults.size());
    }

    @isTest
    static void testSearchAuditsFilteredByTerritory() {
        Test.startTest();
        List<RCPAController.AuditSummary> results = RCPAController.searchAudits('', null, 'North Delhi');
        Test.stopTest();

        System.assertEquals(1, results.size());
    }

    @isTest
    static void testSearchAuditsNoMatchReturnsEmpty() {
        Test.startTest();
        List<RCPAController.AuditSummary> results = RCPAController.searchAudits('NoSuchChemist', null, null);
        Test.stopTest();

        System.assertEquals(0, results.size());
    }

    @isTest
    static void testGetAuditDetailIncludesLinesAndCompetitors() {
        RCPA_Audit__c audit = [SELECT Id FROM RCPA_Audit__c LIMIT 1];

        Test.startTest();
        RCPAController.AuditDetail detail = RCPAController.getAuditDetail(audit.Id);
        Test.stopTest();

        System.assertEquals('Verify Chemist', detail.chemistName);
        System.assertEquals('New Delhi', detail.chemistArea);
        System.assertEquals('9999999999', detail.chemistPhone);
        System.assertEquals('North Delhi', detail.territory);
        System.assertEquals('Draft', detail.status);
        System.assertEquals(true, detail.chemistOtpVerified);
        System.assertEquals(1, detail.lines.size());
        System.assertEquals('Dr. Anita Rao', detail.lines[0].prescriberName);
        System.assertEquals('Metformin', detail.lines[0].molecule);
        System.assertEquals('Growing', detail.lines[0].trend);
        System.assertEquals(1, detail.lines[0].competitors.size());
        System.assertEquals('Rival Pharma', detail.lines[0].competitors[0].company);
        System.assertEquals('RivalMet', detail.lines[0].competitors[0].brand);
    }

    @isTest
    static void testGetAuditDetailThrowsForInvalidId() {
        Sciagen_Account__c chemist = [SELECT Id FROM Sciagen_Account__c WHERE Type__c = 'HCO' LIMIT 1];
        Territory__c territory = [SELECT Id FROM Territory__c LIMIT 1];
        RCPA_Audit__c doomed = new RCPA_Audit__c(
            Chemist__c = chemist.Id, Territory__c = territory.Id, Audit_Date__c = Date.newInstance(2026, 1, 1)
        );
        insert doomed;
        delete doomed;

        Test.startTest();
        try {
            RCPAController.getAuditDetail(doomed.Id);
            System.assert(false, 'Expected AuraHandledException for a deleted audit id');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @isTest
    static void testGetTerritoryOptionsReturnsAllTerritories() {
        Test.startTest();
        List<String> options = RCPAController.getTerritoryOptions();
        Test.stopTest();

        System.assertEquals(1, options.size());
        System.assertEquals('North Delhi', options[0]);
    }

    @isTest
    static void testGetSKUCatalogReturnsOnlyActiveSKUsLabeledWithSKUCode() {
        insert new List<Product__c>{
            new Product__c(Name = 'Emrok 200mg Strip', Product_Code__c = 'RCPA-TEST-ACTIVE', SKU__c = 'BB', Level__c = 'SKU', Active__c = true),
            new Product__c(Name = 'Discontinued SKU', Product_Code__c = 'RCPA-TEST-INACTIVE', Level__c = 'SKU', Active__c = false),
            new Product__c(Name = 'Emrok', Product_Code__c = 'RCPA-TEST-MOLECULE', Level__c = 'Molecule', Active__c = true)
        };

        Test.startTest();
        List<RCPAController.SKUOption> options = RCPAController.getSKUCatalog();
        Test.stopTest();

        System.assertEquals(1, options.size(), 'Expected only the active SKU-level product');
        System.assertEquals('Emrok 200mg Strip-BB', options[0].name, 'Display name must be SKUCode__c (Name & "-" & SKU__c), not the plain Name');
    }
}