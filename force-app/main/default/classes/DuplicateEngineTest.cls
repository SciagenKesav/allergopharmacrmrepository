@isTest
private class DuplicateEngineTest {

    private static Sciagen_Account__c newHcp(String first, String last, String phone, String email, String city, String pin, String spec) {
        return new Sciagen_Account__c(Type__c = 'HCP', Name = 'Dr. ' + first + ' ' + last, First_Name__c = first, Last_Name__c = last,
            Phone__c = phone, Email__c = email, Billing_City__c = city, Billing_Postal_Code__c = pin, Specialty__c = spec);
    }

    @isTest static void insertComputesMatchKeys() {
        Sciagen_Account__c a = newHcp('Farhan', 'Ahmed', '+91 98200 00003', 'Farhan@Example.com', 'Noida', null, null);
        insert a;
        a = [SELECT Dedupe_Name_Key__c, Dedupe_Sound_Key__c, Dedupe_Phone_Key__c, Dedupe_Email_Key__c, Dedupe_Checked_At__c FROM Sciagen_Account__c WHERE Id = :a.Id];
        System.assertEquals('ahmed farhan', a.Dedupe_Name_Key__c);
        System.assertEquals('9820000003', a.Dedupe_Phone_Key__c);
        System.assertEquals('farhan@example.com', a.Dedupe_Email_Key__c);
        System.assertNotEquals(null, a.Dedupe_Sound_Key__c);
        System.assertEquals(null, a.Dedupe_Checked_At__c, 'a new record still needs its first duplicate check');
    }

    @isTest static void editingARelevantFieldQueuesARecheck() {
        Sciagen_Account__c a = newHcp('Farhan', 'Ahmed', '9820000003', null, 'Noida', null, null);
        insert a;
        DuplicateEngine.scan(new Set<Id>{ a.Id }, true);
        System.assertNotEquals(null, [SELECT Dedupe_Checked_At__c FROM Sciagen_Account__c WHERE Id = :a.Id].Dedupe_Checked_At__c);
        update new Sciagen_Account__c(Id = a.Id, Phone__c = '9820000099');
        Sciagen_Account__c after = [SELECT Dedupe_Checked_At__c, Dedupe_Phone_Key__c FROM Sciagen_Account__c WHERE Id = :a.Id];
        System.assertEquals(null, after.Dedupe_Checked_At__c);
        System.assertEquals('9820000099', after.Dedupe_Phone_Key__c);
    }

    @isTest static void scanFindsTheDuplicateAndNotTheLookAlike() {
        Sciagen_Account__c a = newHcp('Farhan', 'Ahmed', '9820000003', 'farhan@example.com', 'Noida', null, 'ENT');
        Sciagen_Account__c dup = newHcp('Farhan', 'Ahmad', '9820000003', null, 'Noida', null, 'ENT');
        Sciagen_Account__c other = newHcp('Rohit', 'Malhotra', '9820000006', null, 'Gurugram', '122003', 'Paediatrics');
        Sciagen_Account__c otherLike = newHcp('Rohit', 'Mehra', '9820000016', null, 'Gurugram', '122003', 'Paediatrics');
        insert new List<Sciagen_Account__c>{ a, dup, other, otherLike };

        Integer saved = DuplicateEngine.scan(new Set<Id>{ a.Id, dup.Id, other.Id, otherLike.Id }, true);
        System.assertEquals(1, saved, 'only the real duplicate should be recorded');

        Duplicate_Candidate__c c = [SELECT Record_A__c, Record_B__c, Match_Score__c, Confidence__c, Status__c, Match_Reasons__c, Suggested_Winner__c, Strong_Identifier__c, Pair_Key__c
                                    FROM Duplicate_Candidate__c];
        System.assertEquals('Open', c.Status__c);
        System.assertEquals(true, c.Strong_Identifier__c);
        System.assertEquals(new Set<Id>{ a.Id, dup.Id }, new Set<Id>{ c.Record_A__c, c.Record_B__c });
        System.assert(c.Match_Reasons__c.contains('Same phone'));
        System.assertNotEquals(null, c.Suggested_Winner__c);
        System.assertEquals(DuplicateEngine.pairKey(a.Id, dup.Id), c.Pair_Key__c);
        System.assertEquals(4, [SELECT COUNT() FROM Sciagen_Account__c WHERE Dedupe_Checked_At__c != null]);
    }

    @isTest static void rescanUpdatesOpenPairsButRespectsADismissal() {
        Sciagen_Account__c a = newHcp('Farhan', 'Ahmed', '9820000003', null, 'Noida', null, 'ENT');
        Sciagen_Account__c b = newHcp('Farhan', 'Ahmad', '9820000003', null, 'Noida', null, 'ENT');
        insert new List<Sciagen_Account__c>{ a, b };
        DuplicateEngine.scan(new Set<Id>{ a.Id, b.Id }, false);
        Duplicate_Candidate__c c = [SELECT Id FROM Duplicate_Candidate__c];
        update new Duplicate_Candidate__c(Id = c.Id, Status__c = 'Not Duplicate');
        DuplicateEngine.scan(new Set<Id>{ a.Id, b.Id }, false);
        System.assertEquals(1, [SELECT COUNT() FROM Duplicate_Candidate__c]);
        System.assertEquals('Not Duplicate', [SELECT Status__c FROM Duplicate_Candidate__c].Status__c);
    }

    @isTest static void nearbyClinicsAreFoundByLocationEvenWithDifferentSpelling() {
        Sciagen_Account__c a = new Sciagen_Account__c(Type__c = 'HCO', Name = 'Sunshine ENT & Allergy Clinic', Billing_Postal_Code__c = '110048',
            Geolocation__Latitude__s = 28.5480, Geolocation__Longitude__s = 77.2430);
        Sciagen_Account__c b = new Sciagen_Account__c(Type__c = 'HCO', Name = 'Sunshine ENT and Allergy Clinic Pvt Ltd', Billing_Postal_Code__c = '110048',
            Geolocation__Latitude__s = 28.5482, Geolocation__Longitude__s = 77.2431);
        Sciagen_Account__c far = new Sciagen_Account__c(Type__c = 'HCO', Name = 'Sunshine Hospital', Billing_Postal_Code__c = '560001',
            Geolocation__Latitude__s = 12.9716, Geolocation__Longitude__s = 77.5946);
        insert new List<Sciagen_Account__c>{ a, b, far };
        DuplicateEngine.scan(new Set<Id>{ a.Id, b.Id, far.Id }, true);
        List<Duplicate_Candidate__c> found = [SELECT Confidence__c, Object_Type__c FROM Duplicate_Candidate__c];
        System.assertEquals(1, found.size());
        System.assertEquals('High', found[0].Confidence__c);
        System.assertEquals('HCO', found[0].Object_Type__c);
    }

    @isTest static void disabledSettingStopsScanning() {
        insert new Duplicate_Setting__c(SetupOwnerId = UserInfo.getOrganizationId(), Enabled__c = false);
        Sciagen_Account__c a = newHcp('Farhan', 'Ahmed', '9820000003', null, 'Noida', null, 'ENT');
        Sciagen_Account__c b = newHcp('Farhan', 'Ahmad', '9820000003', null, 'Noida', null, 'ENT');
        insert new List<Sciagen_Account__c>{ a, b };
        System.assertEquals(0, DuplicateEngine.scan(new Set<Id>{ a.Id, b.Id }, true));
    }

    @isTest static void batchBackfillsMissingKeys() {
        Sciagen_Account__c a = newHcp('Farhan', 'Ahmed', '9820000003', null, 'Noida', null, 'ENT');
        insert a;
        // Simulate a legacy row that never had keys.
        update new Sciagen_Account__c(Id = a.Id, Dedupe_Name_Key__c = null, Dedupe_Sound_Key__c = null, Dedupe_Phone_Key__c = null);
        System.assertEquals(null, [SELECT Dedupe_Name_Key__c FROM Sciagen_Account__c WHERE Id = :a.Id].Dedupe_Name_Key__c);
        Test.startTest();
        Database.executeBatch(new DuplicateScanBatch('KEYS', false), 200);
        Test.stopTest();
        Sciagen_Account__c after = [SELECT Dedupe_Name_Key__c, Dedupe_Phone_Key__c FROM Sciagen_Account__c WHERE Id = :a.Id];
        System.assertEquals('ahmed farhan', after.Dedupe_Name_Key__c);
        System.assertEquals('9820000003', after.Dedupe_Phone_Key__c);
    }

    @isTest static void scanBatchRecordsCandidates() {
        Sciagen_Account__c a = newHcp('Farhan', 'Ahmed', '9820000003', null, 'Noida', null, 'ENT');
        Sciagen_Account__c b = newHcp('Farhan', 'Ahmad', '9820000003', null, 'Noida', null, 'ENT');
        insert new List<Sciagen_Account__c>{ a, b };
        Test.startTest();
        Database.executeBatch(new DuplicateScanBatch('SCAN', false), 50);
        Test.stopTest();
        System.assertEquals(1, [SELECT COUNT() FROM Duplicate_Candidate__c]);
    }

    @isTest static void triggerHandlerQueuesACheckForNewRecords() {
        Test.startTest();
        insert newHcp('Farhan', 'Ahmed', '9820000003', null, 'Noida', null, 'ENT');
        System.assertEquals(1, Limits.getQueueableJobs());
        Test.stopTest();
    }
}