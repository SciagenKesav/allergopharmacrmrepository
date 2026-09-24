@isTest
private class DuplicateMergeServiceTest {

    private static Sciagen_Account__c hcp(String first, String last, String phone, String email, String city, String spec) {
        return new Sciagen_Account__c(Type__c = 'HCP', Name = 'Dr. ' + first + ' ' + last, First_Name__c = first, Last_Name__c = last,
            Phone__c = phone, Email__c = email, Billing_City__c = city, Specialty__c = spec);
    }

    private static Sciagen_Account__c hco(String name, String city) {
        return new Sciagen_Account__c(Type__c = 'HCO', Name = name, Billing_City__c = city, Billing_Postal_Code__c = '110048',
            Geolocation__Latitude__s = 28.548, Geolocation__Longitude__s = 77.243);
    }

    private static Integer count(String obj, String field, Id acct) {
        return Database.countQuery('SELECT COUNT() FROM ' + obj + ' WHERE ' + field + ' = :acct');
    }

    @isTest static void movesEverythingToTheWinnerAndSoftMergesTheLoser() {
        Sciagen_Account__c w = hcp('Farhan', 'Ahmed', '9820000003', null, 'Noida', 'ENT');
        Sciagen_Account__c l = hcp('Farhan', 'Ahmad', '9820000077', 'farhan@clinic.com', 'Noida', null);
        l.License_Number__c = 'LIC-2003';
        insert new List<Sciagen_Account__c>{ w, l };
        Sciagen_Account__c h1 = hco('Sunshine ENT Clinic', 'Delhi'), h2 = hco('Little Steps Hospital', 'Gurugram');
        insert new List<Sciagen_Account__c>{ h1, h2 };

        Territory__c t1 = new Territory__c(Name = 'South Delhi', Type__c = 'Territory'), t2 = new Territory__c(Name = 'Noida', Type__c = 'Territory');
        insert new List<Territory__c>{ t1, t2 };
        insert new List<Account_Territory__c>{
            new Account_Territory__c(Account__c = w.Id, Territory__c = t1.Id),
            new Account_Territory__c(Account__c = l.Id, Territory__c = t1.Id),   // same territory: must not duplicate
            new Account_Territory__c(Account__c = l.Id, Territory__c = t2.Id)    // new territory: must move
        };
        insert new List<Affiliation__c>{
            new Affiliation__c(HCP__c = w.Id, HCO__c = h1.Id, Is_Primary__c = true),
            new Affiliation__c(HCP__c = l.Id, HCO__c = h1.Id, Is_Primary__c = false),  // same HCO: dropped
            new Affiliation__c(HCP__c = l.Id, HCO__c = h2.Id, Is_Primary__c = true)    // primary clashes with winner's: must be demoted
        };
        insert new List<Call_Visit_Report__c>{
            new Call_Visit_Report__c(HCP__c = l.Id, Visit_Date__c = Date.today()),
            new Call_Visit_Report__c(HCP__c = l.Id, Visit_Date__c = Date.today().addDays(-1)),
            new Call_Visit_Report__c(HCP__c = w.Id, Visit_Date__c = Date.today())
        };
        insert new Consent__c(HCP__c = l.Id);
        insert new Segmentation__c(HCP__c = l.Id);
        insert new Segmentation__c(HCP__c = w.Id);

        Duplicate_Candidate__c cand = new Duplicate_Candidate__c(Record_A__c = w.Id, Record_B__c = l.Id, Pair_Key__c = DuplicateEngine.pairKey(w.Id, l.Id),
            Status__c = 'Open', Object_Type__c = 'HCP', Match_Score__c = 90);
        insert cand;

        DuplicateMergeService.MergeResult res = DuplicateMergeService.mergeRecords(w.Id, l.Id, null, 'Manual', 90, cand.Id);

        // Children followed the winner.
        System.assertEquals(3, count('Call_Visit_Report__c', 'HCP__c', w.Id));
        System.assertEquals(0, count('Call_Visit_Report__c', 'HCP__c', l.Id));
        System.assertEquals(1, count('Consent__c', 'HCP__c', w.Id));
        System.assertEquals(2, count('Account_Territory__c', 'Account__c', w.Id), 'winner keeps South Delhi once and gains Noida');
        System.assertEquals(2, count('Account_Territory__c', 'Account__c', l.Id), 'the loser keeps its territory rows so its reps still see it as merged');
        System.assertEquals(2, count('Affiliation__c', 'HCP__c', w.Id), 'the shared HCO is not duplicated');
        System.assertEquals(1, [SELECT COUNT() FROM Affiliation__c WHERE HCP__c = :w.Id AND Is_Primary__c = true], 'only one primary affiliation');
        System.assertEquals(1, count('Segmentation__c', 'HCP__c', w.Id), 'winner keeps its own segmentation');
        System.assertEquals(1, count('Segmentation__c', 'HCP__c', l.Id), 'loser segmentation stays as history');

        // Loser is soft-merged.
        Sciagen_Account__c lAfter = [SELECT Is_Merged__c, Merged_Into__c, Merged_At__c, Dedupe_Name_Key__c FROM Sciagen_Account__c WHERE Id = :l.Id];
        System.assertEquals(true, lAfter.Is_Merged__c);
        System.assertEquals(w.Id, lAfter.Merged_Into__c);
        System.assertEquals(null, lAfter.Dedupe_Name_Key__c);

        // Winner filled its gaps and kept the discarded identifiers as aliases.
        Sciagen_Account__c wAfter = [SELECT Email__c, License_Number__c, Phone__c, External_Ids__c, Specialty__c FROM Sciagen_Account__c WHERE Id = :w.Id];
        System.assertEquals('farhan@clinic.com', wAfter.Email__c);
        System.assertEquals('LIC-2003', wAfter.License_Number__c);
        System.assertEquals('9820000003', wAfter.Phone__c, 'the winner\'s own phone wins');
        Map<String, Object> ext = (Map<String, Object>) JSON.deserializeUntyped(wAfter.External_Ids__c);
        System.assertEquals('9820000077', String.valueOf(ext.get('ALT_PHONE')));
        System.assert(String.valueOf(ext.get('MERGED_FROM')).contains(String.valueOf(l.Id)));

        // Audit trail and candidate.
        Merge_Log__c log = [SELECT Status__c, Winner__c, Loser__c, Method__c, Summary__c, Field_Decisions__c, Moved_Records__c FROM Merge_Log__c];
        System.assertEquals('Merged', log.Status__c);
        System.assertEquals('Manual', log.Method__c);
        System.assert(log.Moved_Records__c.contains('Call_Visit_Report__c.HCP__c'));
        System.assert(res.movedTotal >= 5);
        System.assertEquals('Merged', [SELECT Status__c FROM Duplicate_Candidate__c WHERE Id = :cand.Id].Status__c);
    }

    @isTest static void aStewardCanChooseTheLosersValueForAField() {
        Sciagen_Account__c w = hcp('Farhan', 'Ahmed', '9820000003', 'old@x.com', 'Noida', 'ENT');
        Sciagen_Account__c l = hcp('Farhan', 'Ahmad', '9820000077', 'new@x.com', 'Noida', 'ENT');
        insert new List<Sciagen_Account__c>{ w, l };
        DuplicateMergeService.mergeRecords(w.Id, l.Id, new Map<String, String>{ 'Email__c' => 'loser' }, 'Manual', 80, null);
        Sciagen_Account__c after = [SELECT Email__c, Phone__c FROM Sciagen_Account__c WHERE Id = :w.Id];
        System.assertEquals('new@x.com', after.Email__c);
        System.assertEquals('9820000003', after.Phone__c);
    }

    @isTest static void nameGroupMovesTogetherWhenTheLosersNameIsChosen() {
        Sciagen_Account__c w = hcp('Farhan', 'Ahmed', '9820000003', null, 'Noida', 'ENT');
        Sciagen_Account__c l = hcp('Farhan', 'Ahmad', '9820000077', null, 'Noida', 'ENT');
        insert new List<Sciagen_Account__c>{ w, l };
        DuplicateMergeService.mergeRecords(w.Id, l.Id, new Map<String, String>{ 'NAME' => 'loser' }, 'Manual', 80, null);
        Sciagen_Account__c after = [SELECT Name, Last_Name__c FROM Sciagen_Account__c WHERE Id = :w.Id];
        System.assertEquals('Ahmad', after.Last_Name__c);
        System.assertEquals('Dr. Farhan Ahmad', after.Name);
    }

    @isTest static void hcoMergeMovesCallsAndChildBranches() {
        Sciagen_Account__c w = hco('Sunshine ENT & Allergy Clinic', 'Delhi'), l = hco('Sunshine ENT and Allergy Clinic Pvt Ltd', 'Delhi');
        insert new List<Sciagen_Account__c>{ w, l };
        Sciagen_Account__c dept = hco('Sunshine Pharmacy', 'Delhi');
        dept.Parent_Account__c = l.Id;
        insert dept;
        Sciagen_Account__c doc = hcp('Neeraj', 'Kohli', '9820000001', null, 'Delhi', 'ENT');
        insert doc;
        insert new Affiliation__c(HCP__c = doc.Id, HCO__c = l.Id, Is_Primary__c = true);
        insert new Planned_Call__c(HCP__c = doc.Id, HCO__c = l.Id, Call_DateTime__c = System.now().addDays(2), Is_Event__c = true);

        DuplicateMergeService.mergeRecords(w.Id, l.Id, null, 'Manual', 88, null);

        System.assertEquals(w.Id, [SELECT Parent_Account__c FROM Sciagen_Account__c WHERE Id = :dept.Id].Parent_Account__c);
        System.assertEquals(1, count('Affiliation__c', 'HCO__c', w.Id));
        System.assertEquals(1, count('Planned_Call__c', 'HCO__c', w.Id));
        System.assertEquals(true, [SELECT Is_Merged__c FROM Sciagen_Account__c WHERE Id = :l.Id].Is_Merged__c);
    }

    @isTest static void mergingTwoDifferentKindsIsRefused() {
        Sciagen_Account__c w = hcp('Farhan', 'Ahmed', '9820000003', null, 'Noida', 'ENT');
        Sciagen_Account__c l = hco('Sunshine Clinic', 'Delhi');
        insert new List<Sciagen_Account__c>{ w, l };
        try {
            DuplicateMergeService.mergeRecords(w.Id, l.Id, null, 'Manual', 50, null);
            System.assert(false, 'expected a refusal');
        } catch (DuplicateMergeService.MergeException e) {
            System.assert(e.getMessage().contains('HCP can only be merged with an HCP'));
        }
        System.assertEquals(0, [SELECT COUNT() FROM Merge_Log__c]);
    }

    @isTest static void aFailedMergeRollsBackCompletely() {
        Sciagen_Account__c w = hcp('Farhan', 'Ahmed', '9820000003', null, 'Noida', 'ENT');
        insert w;
        try {
            DuplicateMergeService.mergeRecords(w.Id, w.Id, null, 'Manual', 50, null);
            System.assert(false, 'expected a refusal');
        } catch (DuplicateMergeService.MergeException e) {
            System.assert(e.getMessage().contains('two different records'));
        }
    }

    @isTest static void undoPutsEverythingBack() {
        Sciagen_Account__c w = hcp('Farhan', 'Ahmed', '9820000003', null, 'Noida', 'ENT');
        Sciagen_Account__c l = hcp('Farhan', 'Ahmad', '9820000077', 'far@x.com', 'Noida', 'ENT');
        insert new List<Sciagen_Account__c>{ w, l };
        insert new List<Call_Visit_Report__c>{ new Call_Visit_Report__c(HCP__c = l.Id, Visit_Date__c = Date.today()), new Call_Visit_Report__c(HCP__c = l.Id, Visit_Date__c = Date.today().addDays(-2)) };
        Sciagen_Account__c h1 = hco('Sunshine Clinic', 'Delhi'), h2 = hco('Other Clinic', 'Delhi');
        insert new List<Sciagen_Account__c>{ h1, h2 };
        insert new List<Affiliation__c>{ new Affiliation__c(HCP__c = w.Id, HCO__c = h1.Id, Is_Primary__c = true), new Affiliation__c(HCP__c = l.Id, HCO__c = h2.Id, Is_Primary__c = true) };
        Territory__c terr = new Territory__c(Name = 'Noida', Type__c = 'Territory');
        insert terr;
        insert new Account_Territory__c(Account__c = l.Id, Territory__c = terr.Id);
        Duplicate_Candidate__c cand = new Duplicate_Candidate__c(Record_A__c = w.Id, Record_B__c = l.Id, Pair_Key__c = DuplicateEngine.pairKey(w.Id, l.Id), Status__c = 'Open', Object_Type__c = 'HCP', Match_Score__c = 91);
        insert cand;

        DuplicateMergeService.MergeResult res = DuplicateMergeService.mergeRecords(w.Id, l.Id, null, 'Manual', 91, cand.Id);
        System.assertEquals(2, count('Call_Visit_Report__c', 'HCP__c', w.Id));
        System.assertEquals(1, count('Account_Territory__c', 'Account__c', w.Id), 'winner gained the territory');
        System.assertEquals('far@x.com', [SELECT Email__c FROM Sciagen_Account__c WHERE Id = :w.Id].Email__c);

        DuplicateMergeService.revert(res.logId);

        System.assertEquals(2, count('Call_Visit_Report__c', 'HCP__c', l.Id));
        System.assertEquals(0, count('Call_Visit_Report__c', 'HCP__c', w.Id));
        System.assertEquals(0, count('Account_Territory__c', 'Account__c', w.Id), 'the territory the winner gained is removed again');
        System.assertEquals(1, count('Account_Territory__c', 'Account__c', l.Id));
        System.assertEquals(false, [SELECT Is_Merged__c FROM Sciagen_Account__c WHERE Id = :l.Id].Is_Merged__c);
        System.assertNotEquals(null, [SELECT Dedupe_Name_Key__c FROM Sciagen_Account__c WHERE Id = :l.Id].Dedupe_Name_Key__c);
        System.assertEquals(null, [SELECT Email__c FROM Sciagen_Account__c WHERE Id = :w.Id].Email__c, 'the winner\'s pre-merge value is restored');
        System.assertEquals(1, [SELECT COUNT() FROM Affiliation__c WHERE HCP__c = :l.Id AND Is_Primary__c = true], 'loser\'s primary affiliation is primary again');
        System.assertEquals('Reverted', [SELECT Status__c FROM Merge_Log__c WHERE Id = :res.logId].Status__c);
        System.assertEquals('Open', [SELECT Status__c FROM Duplicate_Candidate__c WHERE Id = :cand.Id].Status__c);
        try {
            DuplicateMergeService.revert(res.logId);
            System.assert(false, 'second undo must be refused');
        } catch (DuplicateMergeService.MergeException e) {
            System.assert(e.getMessage().contains('already been undone'));
        }
    }

    @isTest static void newDataAimedAtAMergedRecordIsRedirectedToTheSurvivor() {
        Sciagen_Account__c w = hcp('Farhan', 'Ahmed', '9820000003', null, 'Noida', 'ENT');
        Sciagen_Account__c l = hcp('Farhan', 'Ahmad', '9820000077', null, 'Noida', 'ENT');
        insert new List<Sciagen_Account__c>{ w, l };
        DuplicateMergeService.mergeRecords(w.Id, l.Id, null, 'Manual', 80, null);
        // An iPad that has not synced yet still pushes against the old id.
        Call_Visit_Report__c cvr = new Call_Visit_Report__c(HCP__c = l.Id, Visit_Date__c = Date.today());
        insert cvr;
        Consent__c consent = new Consent__c(HCP__c = l.Id);
        insert consent;
        System.assertEquals(w.Id, [SELECT HCP__c FROM Call_Visit_Report__c WHERE Id = :cvr.Id].HCP__c);
        System.assertEquals(w.Id, [SELECT HCP__c FROM Consent__c WHERE Id = :consent.Id].HCP__c);
    }

    @isTest static void redirectCoversEveryGuardedObject() {
        Sciagen_Account__c w = hcp('Farhan', 'Ahmed', '9820000003', null, 'Noida', 'ENT');
        Sciagen_Account__c l = hcp('Farhan', 'Ahmad', '9820000077', null, 'Noida', 'ENT');
        Sciagen_Account__c hw = hco('Sunshine ENT & Allergy Clinic', 'Delhi'), hl = hco('Sunshine ENT and Allergy Clinic Pvt Ltd', 'Delhi');
        insert new List<Sciagen_Account__c>{ w, l, hw, hl };
        DuplicateMergeService.mergeRecords(w.Id, l.Id, null, 'Manual', 80, null);
        Test.startTest();   // a fresh set of governor limits for the second merge and the inserts
        DuplicateMergeService.mergeRecords(hw.Id, hl.Id, null, 'Manual', 88, null);

        Sent_Email__c mail = new Sent_Email__c(HCP__c = l.Id, Folder__c = 'Inbox');
        Segmentation__c seg = new Segmentation__c(HCP__c = l.Id);
        Account_Plan__c plan = new Account_Plan__c(Plan_Title__c = 'Plan', HCP__c = l.Id, HCO__c = hl.Id);
        Data_Change_Request__c dcr = new Data_Change_Request__c(Subject_Name__c = 'Edit', Type__c = 'Edit HCP', Subject_Account__c = l.Id, Related_HCO__c = hl.Id);
        RCPA_Audit__c audit = new RCPA_Audit__c(Chemist__c = hl.Id, Audit_Date__c = Date.today());
        Call_Visit_Report__c cvr = new Call_Visit_Report__c(HCP__c = w.Id, HCO__c = hl.Id, Visit_Date__c = Date.today());
        Custom_List__c list1 = new Custom_List__c(List_Name__c = 'My list');
        insert new List<SObject>{ mail, seg, plan, dcr, audit, cvr, list1 };
        RCPA_Line__c line = new RCPA_Line__c(Audit__c = audit.Id, Molecule__c = 'Levoflox', Prescriber__c = l.Id);
        CVR_Attendee__c att = new CVR_Attendee__c(CVR__c = cvr.Id, HCP__c = l.Id);
        Custom_List_Member__c member = new Custom_List_Member__c(List__c = list1.Id, HCP__c = l.Id);
        insert new List<SObject>{ line, att, member };

        System.assertEquals(w.Id, [SELECT HCP__c FROM Sent_Email__c WHERE Id = :mail.Id].HCP__c);
        System.assertEquals(w.Id, [SELECT HCP__c FROM Segmentation__c WHERE Id = :seg.Id].HCP__c);
        Account_Plan__c planAfter = [SELECT HCP__c, HCO__c FROM Account_Plan__c WHERE Id = :plan.Id];
        System.assertEquals(w.Id, planAfter.HCP__c);
        System.assertEquals(hw.Id, planAfter.HCO__c);
        Data_Change_Request__c dcrAfter = [SELECT Subject_Account__c, Related_HCO__c FROM Data_Change_Request__c WHERE Id = :dcr.Id];
        System.assertEquals(w.Id, dcrAfter.Subject_Account__c);
        System.assertEquals(hw.Id, dcrAfter.Related_HCO__c);
        System.assertEquals(hw.Id, [SELECT Chemist__c FROM RCPA_Audit__c WHERE Id = :audit.Id].Chemist__c);
        System.assertEquals(w.Id, [SELECT Prescriber__c FROM RCPA_Line__c WHERE Id = :line.Id].Prescriber__c);
        System.assertEquals(w.Id, [SELECT HCP__c FROM CVR_Attendee__c WHERE Id = :att.Id].HCP__c);
        System.assertEquals(w.Id, [SELECT HCP__c FROM Custom_List_Member__c WHERE Id = :member.Id].HCP__c);
        System.assertEquals(hw.Id, [SELECT HCO__c FROM Call_Visit_Report__c WHERE Id = :cvr.Id].HCO__c);
        Test.stopTest();
    }

    @isTest static void chainedMergesRedirectToTheFinalSurvivor() {
        Sciagen_Account__c a = hcp('Farhan', 'Ahmed', '9820000003', null, 'Noida', 'ENT');
        Sciagen_Account__c b = hcp('Farhan', 'Ahmad', '9820000004', null, 'Noida', 'ENT');
        Sciagen_Account__c c = hcp('Farhaan', 'Ahmed', '9820000005', null, 'Noida', 'ENT');
        insert new List<Sciagen_Account__c>{ a, b, c };
        DuplicateMergeService.mergeRecords(b.Id, a.Id, null, 'Manual', 80, null);   // a -> b
        DuplicateMergeService.mergeRecords(c.Id, b.Id, null, 'Manual', 80, null);   // b -> c
        Consent__c consent = new Consent__c(HCP__c = a.Id);
        insert consent;
        System.assertEquals(c.Id, [SELECT HCP__c FROM Consent__c WHERE Id = :consent.Id].HCP__c);
        System.assertEquals(c.Id, [SELECT Merged_Into__c FROM Sciagen_Account__c WHERE Id = :a.Id].Merged_Into__c, 'earlier losers are re-pointed at the final winner');
    }

    @isTest static void autoMergeOnlyTakesHighConfidencePairsWithAStrongIdentifier() {
        insert new Duplicate_Setting__c(SetupOwnerId = UserInfo.getOrganizationId(), Enabled__c = true, Auto_Merge_Enabled__c = true, Auto_Merge_Score__c = 90);
        Sciagen_Account__c a = hcp('Priya', 'Sharma', '9876543210', 'priya@apex.com', 'Bengaluru', 'Cardiology');
        a.License_Number__c = 'MCI-45678';
        Sciagen_Account__c b = hcp('Priya', 'Sharma', null, 'priya@apex.com', 'Bengaluru', 'Cardiology');
        b.License_Number__c = 'MCI 45678';
        Sciagen_Account__c weakA = hcp('Rajesh', 'Kumar', null, null, 'Delhi', 'ENT');
        Sciagen_Account__c weakB = hcp('Rajesh', 'Kumar', null, null, 'Delhi', 'ENT');
        weakA.Billing_Postal_Code__c = '110001'; weakB.Billing_Postal_Code__c = '110001';
        insert new List<Sciagen_Account__c>{ a, b, weakA, weakB };
        DuplicateEngine.scan(new Set<Id>{ a.Id, b.Id, weakA.Id, weakB.Id }, true);
        System.assertEquals(2, [SELECT COUNT() FROM Duplicate_Candidate__c]);

        Test.startTest();
        Database.executeBatch(new DuplicateScanBatch('AUTOMERGE', false), 1);
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM Merge_Log__c WHERE Method__c = 'Auto'], 'only the licence + email pair is auto-merged');
        System.assertEquals(1, [SELECT COUNT() FROM Duplicate_Candidate__c WHERE Status__c = 'Open']);
    }
}