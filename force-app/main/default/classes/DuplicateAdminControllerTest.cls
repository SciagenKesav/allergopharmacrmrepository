@isTest
private class DuplicateAdminControllerTest {

    private static Sciagen_Account__c hcp(String first, String last, String phone, String city, String spec) {
        return new Sciagen_Account__c(Type__c = 'HCP', Name = 'Dr. ' + first + ' ' + last, First_Name__c = first, Last_Name__c = last,
            Phone__c = phone, Billing_City__c = city, Specialty__c = spec);
    }

    private static Duplicate_Candidate__c seedPair() {
        Sciagen_Account__c a = hcp('Farhan', 'Ahmed', '9820000003', 'Noida', 'ENT');
        Sciagen_Account__c b = hcp('Farhan', 'Ahmad', '9820000003', 'Noida', 'ENT');
        b.Email__c = 'farhan@clinic.com';
        insert new List<Sciagen_Account__c>{ a, b };
        DuplicateEngine.scan(new Set<Id>{ a.Id, b.Id }, true);
        return [SELECT Id, Record_A__c, Record_B__c, Suggested_Winner__c FROM Duplicate_Candidate__c LIMIT 1];
    }

    @isTest static void nonStewardsAreRefused() {
        DuplicateAdminController.testBypass = false;
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User u = new User(Alias = 'nosteard', Email = 'nosteward@example.com', EmailEncodingKey = 'UTF-8', LastName = 'NoSteward',
            LanguageLocaleKey = 'en_US', LocaleSidKey = 'en_US', ProfileId = p.Id, TimeZoneSidKey = 'Asia/Kolkata',
            UserName = 'nosteward' + System.currentTimeMillis() + '@example.com');
        insert u;
        System.runAs(u) {
            try {
                DuplicateAdminController.getSummary();
                System.assert(false, 'expected a permission error');
            } catch (AuraHandledException e) {
                System.assert(e.getMessage().contains('Data Steward'));
            }
        }
    }

    @isTest static void summaryListsAndComparison() {
        DuplicateAdminController.testBypass = true;
        Duplicate_Candidate__c c = seedPair();

        DuplicateAdminController.SummaryDTO s = DuplicateAdminController.getSummary();
        System.assertEquals(1, s.openHcp);
        System.assertEquals(0, s.openHco);
        System.assertEquals(2, s.totalRecords);
        System.assertNotEquals(null, s.settings);

        List<DuplicateAdminController.CandidateDTO> found = DuplicateAdminController.getCandidates('HCP', 'All', 'Open', 'Farhan', 50);
        System.assertEquals(1, found.size());
        System.assertEquals(0, DuplicateAdminController.getCandidates('HCO', null, null, null, null).size());
        System.assertEquals(1, DuplicateAdminController.getCandidates(null, null, null, '9820000003', null).size());

        DuplicateAdminController.ComparisonDTO cmp = DuplicateAdminController.getComparison(c.Id);
        System.assertNotEquals(null, cmp.suggestedWinnerId);
        Boolean hasEmailRow = false, hasNameRow = false;
        for (DuplicateAdminController.FieldRow r : cmp.rows) {
            if (r.api == 'Email__c') { hasEmailRow = true; System.assertEquals(true, r.differs); }
            if (r.api == 'Name') hasNameRow = true;
        }
        System.assert(hasEmailRow && hasNameRow);
    }

    @isTest static void mergeThenUndoThroughTheController() {
        DuplicateAdminController.testBypass = true;
        Duplicate_Candidate__c c = seedPair();
        Id winner = c.Suggested_Winner__c;

        DuplicateAdminController.MergeResultDTO r = DuplicateAdminController.mergeCandidate(c.Id, winner, new Map<String, String>());
        System.assertNotEquals(null, r.logId);
        System.assertEquals('Merged', [SELECT Status__c FROM Duplicate_Candidate__c WHERE Id = :c.Id].Status__c);
        System.assertEquals(1, DuplicateAdminController.getRecentMerges(10).size());
        System.assertEquals(1, DuplicateAdminController.getSummary().merged30d);

        try {
            DuplicateAdminController.mergeCandidate(c.Id, winner, null);
            System.assert(false, 'already reviewed');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('already been reviewed'));
        }

        DuplicateAdminController.undoMerge(r.logId);
        System.assertEquals('Open', [SELECT Status__c FROM Duplicate_Candidate__c WHERE Id = :c.Id].Status__c);
        System.assertEquals(0, [SELECT COUNT() FROM Sciagen_Account__c WHERE Is_Merged__c = true]);
    }

    @isTest static void winnerMustBeOneOfThePair() {
        DuplicateAdminController.testBypass = true;
        Duplicate_Candidate__c c = seedPair();
        Sciagen_Account__c other = hcp('Someone', 'Else', '9999999999', 'Delhi', 'ENT');
        insert other;
        try {
            DuplicateAdminController.mergeCandidate(c.Id, other.Id, null);
            System.assert(false, 'expected a refusal');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('one of the two records'));
        }
    }

    @isTest static void dismissAndReopen() {
        DuplicateAdminController.testBypass = true;
        Duplicate_Candidate__c c = seedPair();
        DuplicateAdminController.markNotDuplicate(c.Id, 'Twins');
        Duplicate_Candidate__c after = [SELECT Status__c, Review_Note__c FROM Duplicate_Candidate__c WHERE Id = :c.Id];
        System.assertEquals('Not Duplicate', after.Status__c);
        System.assertEquals('Twins', after.Review_Note__c);
        System.assertEquals(1, DuplicateAdminController.getSummary().notDuplicate);
        DuplicateAdminController.reopenCandidate(c.Id);
        System.assertEquals('Open', [SELECT Status__c FROM Duplicate_Candidate__c WHERE Id = :c.Id].Status__c);
    }

    @isTest static void settingsValidateAndPersist() {
        DuplicateAdminController.testBypass = true;
        DuplicateAdminController.SettingsDTO s = DuplicateAdminController.saveSettings(true, 60, 88, true, 96);
        System.assertEquals(60, s.minScore);
        System.assertEquals(true, s.autoMerge);
        System.assertEquals(96, DuplicateEngine.loadSettings().autoMergeScore);
        for (List<Object> bad : new List<List<Object>>{ new List<Object>{ 10, 88, 96 }, new List<Object>{ 60, 50, 96 }, new List<Object>{ 60, 88, 70 } }) {
            try {
                DuplicateAdminController.saveSettings(true, Decimal.valueOf(String.valueOf(bad[0])), Decimal.valueOf(String.valueOf(bad[1])), false, Decimal.valueOf(String.valueOf(bad[2])));
                System.assert(false, 'expected validation to fail for ' + bad);
            } catch (AuraHandledException e) {
                System.assert(true);
            }
        }
    }

    @isTest static void scanAndScheduleControls() {
        DuplicateAdminController.testBypass = true;
        Test.startTest();
        System.assertNotEquals(null, DuplicateAdminController.runScan(false));
        DuplicateAdminController.scheduleNightly();
        DuplicateAdminController.scheduleNightly();   // second call is a no-op
        System.assertEquals(true, DuplicateAdminController.getSummary().scheduled);
        DuplicateAdminController.unscheduleNightly();
        System.assertEquals(false, DuplicateAdminController.getSummary().scheduled);
        Test.stopTest();
    }

    @isTest static void schedulerRunsTheBatch() {
        Test.startTest();
        new DuplicateScanScheduler().execute(null);
        Test.stopTest();
        System.assert(true);
    }

    @isTest static void changeRequestIsCheckedAgainstExistingRecords() {
        DuplicateAdminController.testBypass = true;
        Sciagen_Account__c existing = hcp('Farhan', 'Ahmed', '9820000003', 'Noida', 'ENT');
        insert existing;
        Data_Change_Request__c dcr = new Data_Change_Request__c(Type__c = 'New HCP', Subject_Name__c = 'Dr. Farhan Ahmad',
            Fields_Payload__c = '{"firstName":"Farhan","lastName":"Ahmad","phone":"98200 00003","city":"Noida","specialty":"ENT"}');
        insert dcr;
        List<DuplicateAdminController.DcrMatchDTO> matches = DuplicateAdminController.findDuplicatesForDcr(dcr.Id);
        System.assertEquals(1, matches.size());
        System.assertEquals(existing.Id, matches[0].id);
        System.assert(matches[0].reasons.contains('Same phone'));
    }
}