@isTest
private class RCPAControllerCoverageTest {

    @TestSetup
    static void setup() {
        Sciagen_Account__c chemist = new Sciagen_Account__c(
            Type__c = 'HCO', Name = 'RCPACov Chemist', HCO_Type__c = 'Chemist Shop', Speciality__c = 'Other');
        Sciagen_Account__c prescriber = new Sciagen_Account__c(
            Type__c = 'HCP', Name = 'Dr. RCPACov Rao', First_Name__c = 'Anita', Last_Name__c = 'Rao',
            Specialty__c = 'Cardiology', HCP_Type__c = 'Physician');
        insert new List<Sciagen_Account__c>{ chemist, prescriber };
        Territory__c terr = new Territory__c(Name = 'RCPACov Terr', Territory_Code__c = 'RCV', Type__c = 'Territory');
        insert terr;
        RCPA_Audit__c audit = new RCPA_Audit__c(Chemist__c = chemist.Id, Territory__c = terr.Id,
            Audit_Date__c = Date.today(), Status__c = 'Draft', Rep__c = 'Cov Rep');
        insert audit;
        RCPA_Line__c line = new RCPA_Line__c(Audit__c = audit.Id, Prescriber__c = prescriber.Id, Molecule__c = 'Metformin',
            Own_Brand__c = 'Glaritus', Own_Units_Per_Week__c = 12, Trend__c = 'Growing', Remarks__c = 'Loyal');
        insert line;
        insert new RCPA_Competitor__c(Line__c = line.Id, Company__c = 'Rival', Brand__c = 'RivalMet', Units_Per_Week__c = 5);
    }

    @isTest
    static void priorLineReturnsNullForBlankInputs() {
        Sciagen_Account__c p = [SELECT Id FROM Sciagen_Account__c WHERE Type__c = 'HCP' LIMIT 1];
        System.assertEquals(null, RCPAController.getPriorLineForPrescriber(null, 'Metformin'));
        System.assertEquals(null, RCPAController.getPriorLineForPrescriber(p.Id, ''));
        System.assertEquals(null, RCPAController.getPriorLineForPrescriber(p.Id, null));
    }

    @isTest
    static void priorLineReturnsNullWhenNoMatch() {
        Sciagen_Account__c p = [SELECT Id FROM Sciagen_Account__c WHERE Type__c = 'HCP' LIMIT 1];
        System.assertEquals(null, RCPAController.getPriorLineForPrescriber(p.Id, 'NoSuchMolecule'));
    }

    @isTest
    static void priorLineReturnsPriorValuesAndCompetitors() {
        Sciagen_Account__c p = [SELECT Id FROM Sciagen_Account__c WHERE Type__c = 'HCP' LIMIT 1];
        RCPAController.LineItem li = RCPAController.getPriorLineForPrescriber(p.Id, 'Metformin');
        System.assertNotEquals(null, li);
        System.assertEquals('Dr. RCPACov Rao', li.prescriberName);
        System.assertEquals('Metformin', li.molecule);
        System.assertEquals('Glaritus', li.ownBrand);
        System.assertEquals(12, li.ownUnitsPerWeek);
        System.assertEquals('Growing', li.trend);
        System.assertEquals('Loyal', li.remarks);
        System.assertEquals(1, li.competitors.size());
        System.assertEquals('Rival', li.competitors[0].company);
        System.assertEquals('RivalMet', li.competitors[0].brand);
        System.assertEquals(5, li.competitors[0].unitsPerWeek);
    }

    @isTest
    static void createAuditWrapsDmlFailureInAuraException() {
        // A Territory Id is not a valid Sciagen_Account__c reference -> DmlException inside createAudit.
        Territory__c terr = [SELECT Id FROM Territory__c LIMIT 1];
        try {
            RCPAController.createAudit(terr.Id, terr.Id, null);
            System.assert(false, 'Expected AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
    }
}
