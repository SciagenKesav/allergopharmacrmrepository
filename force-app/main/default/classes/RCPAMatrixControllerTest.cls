@isTest
private class RCPAMatrixControllerTest {

    @testSetup
    static void setup() {
        Sciagen_Account__c chemist = new Sciagen_Account__c(
            Type__c = 'HCO', Name = 'Matrix Test Chemist', HCO_Type__c = 'Chemist Shop', Speciality__c = 'Other',
            Billing_City__c = 'New Delhi'
        );
        Sciagen_Account__c doctorA = new Sciagen_Account__c(
            Type__c = 'HCP', Name = 'Dr. Matrix A', Prefix__c = 'Dr.', First_Name__c = 'Matrix', Last_Name__c = 'A',
            Specialty__c = 'Cardiology', HCP_Type__c = 'Physician'
        );
        Sciagen_Account__c doctorB = new Sciagen_Account__c(
            Type__c = 'HCP', Name = 'Dr. Matrix B', Prefix__c = 'Dr.', First_Name__c = 'Matrix', Last_Name__c = 'B',
            Specialty__c = 'General Physician', HCP_Type__c = 'Physician'
        );
        insert new List<Sciagen_Account__c>{ chemist, doctorA, doctorB };

        insert new Segmentation__c(HCP__c = doctorA.Id, Classification__c = 'A');
        // doctorB intentionally left without a Segmentation__c record -> should default to 'Unclassified'.

        Territory__c territory = new Territory__c(Name = 'Matrix Territory', Territory_Code__c = 'MT', Type__c = 'Territory');
        insert territory;

        RCPA_Audit__c earlierAudit = new RCPA_Audit__c(
            Chemist__c = chemist.Id, Territory__c = territory.Id, Audit_Date__c = Date.newInstance(2026, 1, 5),
            Status__c = 'Submitted', Rep__c = 'Matrix Rep'
        );
        RCPA_Audit__c laterAudit = new RCPA_Audit__c(
            Chemist__c = chemist.Id, Territory__c = territory.Id, Audit_Date__c = Date.newInstance(2026, 2, 10),
            Status__c = 'Submitted', Rep__c = 'Matrix Rep'
        );
        insert new List<RCPA_Audit__c>{ earlierAudit, laterAudit };

        // Dr. A, same molecule, two audits (builds a 2-point trail + accumulated matrix qty).
        RCPA_Line__c lineA1 = new RCPA_Line__c(
            Audit__c = earlierAudit.Id, Prescriber__c = doctorA.Id, Molecule__c = 'Insulin Glargine',
            Own_Brand__c = 'Glaritus', Own_Units_Per_Week__c = 10, Trend__c = 'Growing'
        );
        RCPA_Line__c lineA2 = new RCPA_Line__c(
            Audit__c = laterAudit.Id, Prescriber__c = doctorA.Id, Molecule__c = 'Insulin Glargine',
            Own_Brand__c = 'Glaritus', Own_Units_Per_Week__c = 16, Trend__c = 'Growing'
        );
        // Dr. B, a different molecule, one audit.
        RCPA_Line__c lineB1 = new RCPA_Line__c(
            Audit__c = laterAudit.Id, Prescriber__c = doctorB.Id, Molecule__c = 'Levonadifloxacin',
            Own_Brand__c = 'Emrok', Own_Units_Per_Week__c = 5, Trend__c = 'Stable'
        );
        insert new List<RCPA_Line__c>{ lineA1, lineA2, lineB1 };

        insert new RCPA_Competitor__c(Line__c = lineA1.Id, Company__c = 'Sanofi', Brand__c = 'Lantus', Units_Per_Week__c = 4);
        insert new RCPA_Competitor__c(Line__c = lineA2.Id, Company__c = 'Sanofi', Brand__c = 'Lantus', Units_Per_Week__c = 6);

        // Product__c master data backing getMoleculeCatalog() — one active SKU
        // per molecule, Parent_Molecule__c matching the exact RCPA_Line__c
        // .Molecule__c strings captured above, Name standing in for "own brand"
        // (Parent_Molecule__c/Name are 1:1 per molecule on this org's real
        // catalog — see getMoleculeCatalog's own doc comment).
        insert new List<Product__c>{
            new Product__c(Name = 'Emrok', Product_Code__c = 'RCPA-TEST-EMROK', Active__c = true, Parent_Molecule__c = 'Levonadifloxacin',
                Parent_Therapy__c = 'Cardiology', Unit_Value_Per_Strip__c = 42),
            new Product__c(Name = 'Glaritus', Product_Code__c = 'RCPA-TEST-GLARITUS', Active__c = true, Parent_Molecule__c = 'Insulin Glargine',
                Parent_Therapy__c = 'Diabetes', Unit_Value_Per_Strip__c = 850)
        };
    }

    @isTest
    static void testGetDoctorOptionsReturnsDistinctPrescribersWithMoleculeCounts() {
        Test.startTest();
        List<RCPAMatrixController.DoctorOption> options = RCPAMatrixController.getDoctorOptions();
        Test.stopTest();

        System.assertEquals(2, options.size(), 'Expected exactly Dr. A and Dr. B');
        Map<String, Integer> countByName = new Map<String, Integer>();
        for (RCPAMatrixController.DoctorOption o : options) countByName.put(o.name, o.moleculeCount);
        System.assertEquals(1, countByName.get('Dr. Matrix A'), 'Dr. A only has one distinct molecule across both audits');
        System.assertEquals(1, countByName.get('Dr. Matrix B'));
    }

    @isTest
    static void testGetDoctorMatrixAggregatesAcrossAuditsAndBuildsTrail() {
        Sciagen_Account__c doctorA = [SELECT Id FROM Sciagen_Account__c WHERE Name = 'Dr. Matrix A' LIMIT 1];

        Test.startTest();
        RCPAMatrixController.DoctorMatrix matrix = RCPAMatrixController.getDoctorMatrix(doctorA.Id);
        Test.stopTest();

        System.assertEquals('Dr. Matrix A', matrix.name);
        System.assertEquals('Cardiology', matrix.specialty);
        System.assertEquals('Matrix Rep', matrix.rep);
        System.assertEquals(2, matrix.auditCount);
        System.assertEquals(1, matrix.rows.size(), 'Only one molecule was captured for Dr. A');

        RCPAMatrixController.MoleculeRow row = matrix.rows[0];
        System.assertEquals('Insulin Glargine', row.molecule);
        System.assertEquals(2, row.brands.size(), 'Own brand + one competitor');
        System.assertEquals('Glaritus', row.brands[0].brand, 'Own brand must sort first');
        System.assertEquals(true, row.brands[0].isOwn);
        System.assertEquals(26, row.brands[0].qty, 'Own qty summed across both audits: 10 + 16');
        System.assertEquals('Lantus', row.brands[1].brand);
        System.assertEquals(10, row.brands[1].qty, 'Competitor qty summed across both audits: 4 + 6');
        System.assertEquals(36, row.total);

        System.assertEquals(1, matrix.trails.size());
        RCPAMatrixController.MoleculeTrail trail = matrix.trails[0];
        System.assertEquals(2, trail.points.size(), 'One point per audit, chronologically ordered');
        System.assertEquals(10, trail.points[0].ownUnits, 'Earlier audit first');
        System.assertEquals(16, trail.points[1].ownUnits, 'Later audit last');
    }

    @isTest
    static void testGetDoctorMatrixThrowsForUnknownPrescriber() {
        Test.startTest();
        try {
            RCPAMatrixController.getDoctorMatrix(UserInfo.getUserId()); // a valid Id of the wrong sObject type
            System.assert(false, 'Expected AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @isTest
    static void testGetRxObservationsResolvesClassificationAndDefaultsUnclassified() {
        Test.startTest();
        List<RCPAMatrixController.RxObservation> observations = RCPAMatrixController.getRxObservations();
        Test.stopTest();

        Map<String, String> classificationByDoctor = new Map<String, String>();
        for (RCPAMatrixController.RxObservation o : observations) classificationByDoctor.put(o.doctorName, o.classification);

        System.assertEquals('A', classificationByDoctor.get('Dr. Matrix A'));
        System.assertEquals('Unclassified', classificationByDoctor.get('Dr. Matrix B'), 'No Segmentation__c record exists for Dr. B');
        // 2 own-brand rows (one per audit, same molecule) + 2 competitor rows for Dr. A, + 1 own-brand row for Dr. B.
        System.assertEquals(5, observations.size());
    }

    @isTest
    static void testGetMoleculeCatalogReturnsCorrectedReferenceData() {
        Test.startTest();
        List<RCPAMatrixController.MoleculeCatalogItem> catalog = RCPAMatrixController.getMoleculeCatalog();
        Test.stopTest();

        System.assertEquals(2, catalog.size());
        Map<String, RCPAMatrixController.MoleculeCatalogItem> byMolecule = new Map<String, RCPAMatrixController.MoleculeCatalogItem>();
        for (RCPAMatrixController.MoleculeCatalogItem item : catalog) byMolecule.put(item.molecule, item);

        RCPAMatrixController.MoleculeCatalogItem insulin = byMolecule.get('Insulin Glargine');
        System.assertNotEquals(null, insulin, 'Product__c.Parent_Molecule__c must match the exact string captured on RCPA_Line__c.Molecule__c');
        System.assertEquals('Glaritus', insulin.ownBrand);
        System.assertEquals(850, insulin.unitValuePerStrip);
        System.assertEquals('Diabetes', insulin.therapyArea);

        RCPAMatrixController.MoleculeCatalogItem antibiotic = byMolecule.get('Levonadifloxacin');
        System.assertNotEquals(null, antibiotic);
        System.assertEquals('Emrok', antibiotic.ownBrand);
        System.assertEquals(42, antibiotic.unitValuePerStrip);
        System.assertEquals('Cardiology', antibiotic.therapyArea);
    }

    @isTest
    static void testSaveRCPATargetUpsertsInPlaceNotDuplicated() {
        Test.startTest();
        RCPAMatrixController.saveRCPATarget('Insulin Glargine', 100);
        RCPAMatrixController.saveRCPATarget('Insulin Glargine', 150);
        Map<String, Decimal> targets = RCPAMatrixController.getRCPATargets();
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM RCPA_Target__c], 'Second save must update the same row, not insert a new one');
        System.assertEquals(150, targets.get('Insulin Glargine'));
    }
}