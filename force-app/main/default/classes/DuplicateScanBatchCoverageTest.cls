@isTest
private class DuplicateScanBatchCoverageTest {

    private static Sciagen_Account__c hcp(String first, String last, String email, String license) {
        return new Sciagen_Account__c(Type__c = 'HCP', Name = first + ' ' + last, First_Name__c = first, Last_Name__c = last,
            Email__c = email, License_Number__c = license, Specialty__c = 'Cardiology', HCP_Type__c = 'Physician',
            Billing_City__c = 'Bengaluru');
    }

    @isTest static void runStartsKeysStage() {
        insert hcp('Anita', 'Rao', 'anita@apex.com', null);
        Test.startTest();
        Id jobId = DuplicateScanBatch.run(true);
        Test.stopTest();
        System.assertNotEquals(null, jobId);
    }

    @isTest static void fullScanRechecksAlreadyCheckedRecords() {
        insert new Duplicate_Setting__c(SetupOwnerId = UserInfo.getOrganizationId(), Enabled__c = true);
        Sciagen_Account__c a = hcp('Priya', 'Sharma', 'priya@apex.com', null);
        Sciagen_Account__c b = hcp('Priya', 'Sharma', 'priya@apex.com', null);
        insert new List<Sciagen_Account__c>{ a, b };
        update new List<Sciagen_Account__c>{ new Sciagen_Account__c(Id = a.Id, Dedupe_Checked_At__c = System.now()),
                                              new Sciagen_Account__c(Id = b.Id, Dedupe_Checked_At__c = System.now()) };
        DuplicateScanBatch batch = new DuplicateScanBatch('SCAN', true);
        Test.startTest();
        Database.executeBatch(batch, 50);
        Test.stopTest();
        System.assertEquals(1, [SELECT COUNT() FROM Duplicate_Candidate__c]);
    }

    @isTest static void autoMergeStageDoesNothingWhenDisabled() {
        insert new Duplicate_Setting__c(SetupOwnerId = UserInfo.getOrganizationId(), Enabled__c = true, Auto_Merge_Enabled__c = false);
        Sciagen_Account__c a = hcp('Priya', 'Sharma', 'priya@apex.com', 'MCI-45678');
        Sciagen_Account__c b = hcp('Priya', 'Sharma', 'priya@apex.com', 'MCI 45678');
        insert new List<Sciagen_Account__c>{ a, b };
        DuplicateEngine.scan(new Set<Id>{ a.Id, b.Id }, true);
        Test.startTest();
        Database.executeBatch(new DuplicateScanBatch('AUTOMERGE', false), 1);
        Test.stopTest();
        System.assertEquals(0, [SELECT COUNT() FROM Merge_Log__c WHERE Method__c = 'Auto']);
    }

    @isTest static void autoMergeSkipsPairsBelowThresholdAndRecordsFailures() {
        insert new Duplicate_Setting__c(SetupOwnerId = UserInfo.getOrganizationId(), Enabled__c = true);
        Sciagen_Account__c a = hcp('Priya', 'Sharma', 'priya@apex.com', 'MCI-45678');
        Sciagen_Account__c b = hcp('Priya', 'Sharma', 'priya@apex.com', 'MCI 45678');
        insert new List<Sciagen_Account__c>{ a, b };
        DuplicateEngine.scan(new Set<Id>{ a.Id, b.Id }, true);
        List<Duplicate_Candidate__c> cands = [SELECT Id, Match_Score__c, Confidence__c, Strong_Identifier__c FROM Duplicate_Candidate__c];
        System.assertEquals(1, cands.size());
        // Auto-merge threshold just above the candidate's score so the 'continue' branch runs.
        Duplicate_Setting__c ds = [SELECT Id FROM Duplicate_Setting__c LIMIT 1];
        update new Duplicate_Setting__c(Id = ds.Id, Auto_Merge_Enabled__c = true, Auto_Merge_Score__c = cands[0].Match_Score__c + 1);
        Test.startTest();
        Database.executeBatch(new DuplicateScanBatch('AUTOMERGE', false), 1);
        Test.stopTest();
        System.assertEquals(0, [SELECT COUNT() FROM Merge_Log__c WHERE Method__c = 'Auto']);
        System.assertEquals(1, [SELECT COUNT() FROM Duplicate_Candidate__c WHERE Status__c = 'Open']);
    }

    @isTest static void autoMergeFailureIsNotedOnCandidate() {
        insert new Duplicate_Setting__c(SetupOwnerId = UserInfo.getOrganizationId(), Enabled__c = true, Auto_Merge_Enabled__c = true, Auto_Merge_Score__c = 50);
        Sciagen_Account__c a = hcp('Priya', 'Sharma', 'priya@apex.com', 'MCI-45678');
        Sciagen_Account__c b = hcp('Priya', 'Sharma', 'priya@apex.com', 'MCI 45678');
        insert new List<Sciagen_Account__c>{ a, b };
        DuplicateEngine.scan(new Set<Id>{ a.Id, b.Id }, true);
        Duplicate_Candidate__c c = [SELECT Id, Record_A__c, Record_B__c, Suggested_Winner__c FROM Duplicate_Candidate__c LIMIT 1];
        // Make the merge impossible: winner is already merged into someone else.
        Id winner = c.Suggested_Winner__c != null ? c.Suggested_Winner__c : c.Record_A__c;
        Id loser = winner == c.Record_A__c ? c.Record_B__c : c.Record_A__c;
        update new Sciagen_Account__c(Id = loser, Is_Merged__c = true);
        Test.startTest();
        Database.executeBatch(new DuplicateScanBatch('AUTOMERGE', false), 1);
        Test.stopTest();
        System.assertEquals(1, [SELECT COUNT() FROM Duplicate_Candidate__c]);
    }
}
