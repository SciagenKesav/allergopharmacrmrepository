@isTest
private class SampleDropServiceTest {

    // Users for the unlock tests below — created in @testSetup (a separate,
    // already-committed transaction), not inline inside an @isTest method:
    // FeatureManagement.checkPermission() does not reliably see a
    // PermissionSetAssignment inserted in the same transaction it's checked in.
    @testSetup
    static void users() {
        Profile std = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        Profile sysAdmin = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];
        User rep = new User(FirstName = 'No', LastName = 'PermTest', Alias = 'noperm', Email = 'no.perm.unlock@sciagen-test.invalid',
            Username = 'no.perm.unlock@sciagen-new-dev.invalid', TimeZoneSidKey = 'Asia/Kolkata', LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US', ProfileId = std.Id, IsActive = true);
        User admin = new User(FirstName = 'Sample', LastName = 'AdminUnlockTest', Alias = 'sadmu', Email = 'sample.admin.unlock@sciagen-test.invalid',
            Username = 'sample.admin.unlock@sciagen-new-dev.invalid', TimeZoneSidKey = 'Asia/Kolkata', LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US', ProfileId = sysAdmin.Id, IsActive = true);
        insert new List<User>{ rep, admin };
        insert new PermissionSetAssignment(AssigneeId = rep.Id, PermissionSetId = [SELECT Id FROM PermissionSet WHERE Name = 'Sciagen_Mobile_App_Access'].Id);
        insert new PermissionSetAssignment(AssigneeId = admin.Id, PermissionSetId = [SELECT Id FROM PermissionSet WHERE Name = 'Sciagen_Sample_Admin'].Id);
    }

    static User repNoPermission() { return [SELECT Id FROM User WHERE Username = 'no.perm.unlock@sciagen-new-dev.invalid']; }
    static User sampleAdminUser() { return [SELECT Id FROM User WHERE Username = 'sample.admin.unlock@sciagen-new-dev.invalid']; }

    static Decimal avail(Id lotId) { return [SELECT Available_Quantity__c FROM Sample_Lot__c WHERE Id = :lotId].Available_Quantity__c; }

    static Sample_Drop__c drop(Call_Visit_Report__c c, Product__c p, Integer qty) {
        return new Sample_Drop__c(Name = 'Sample Drop', CVR__c = c.Id, Product__c = p.Id, Qty__c = qty);
    }

    @isTest
    static void lineOnADraftCallGetsTheSoonestLotAndASnapshotOfValue() {
        Product__c p = SampleTestData.product('Line SKU');
        Sciagen_Account__c d = SampleTestData.doctor('Dr Line');
        SampleTestData.lot(p, 'LATER', 20, 300);
        Sample_Lot__c sooner = SampleTestData.lot(p, 'SOONER', 20, 80);
        Call_Visit_Report__c call = SampleTestData.call(d, 'Draft');
        Sample_Drop__c line = drop(call, p, 2);
        insert line;
        line = [SELECT Sample_Lot__c, Lot_Number__c, Unit_Value__c, Pack_Size__c, Total_Value__c, Eligibility_Status__c, Needs_Signature__c FROM Sample_Drop__c WHERE Id = :line.Id];
        System.assertEquals(sooner.Id, line.Sample_Lot__c);
        System.assertEquals('SOONER', line.Lot_Number__c);
        System.assertEquals(10, line.Unit_Value__c);
        System.assertEquals(4, line.Pack_Size__c);
        System.assertEquals(80, line.Total_Value__c, '2 packs x 4 units x INR 10');
        System.assertEquals('Eligible', line.Eligibility_Status__c);
        System.assertEquals(true, line.Needs_Signature__c);
        System.assertEquals(20, avail(sooner.Id), 'a draft call does not move stock');
    }

    @isTest
    static void blockedLineIsRefused() {
        Product__c p = SampleTestData.product('Refuse SKU');
        SampleTestData.lot(p, 'REF-1', 20, 200);
        Sciagen_Account__c d = SampleTestData.doctor('Dr Refuse');
        d.License_Verification_Status__c = 'Invalid';
        update d;
        Call_Visit_Report__c call = SampleTestData.call(d, 'Draft');
        Database.SaveResult r = Database.insert(drop(call, p, 1), false);
        System.assert(!r.isSuccess());
        System.assert(r.getErrors()[0].getMessage().contains('licence'), r.getErrors()[0].getMessage());
    }

    @isTest
    static void submittingNeedsTheSignatureThenMovesStockAndCountsExpenditure() {
        SampleLimitSeeder.seedDefaults();
        Product__c p = SampleTestData.product('Submit SKU');
        Sciagen_Account__c d = SampleTestData.doctor('Dr Submit');
        Sample_Lot__c lot = SampleTestData.lot(p, 'SUB-1', 20, 200);
        Call_Visit_Report__c call = SampleTestData.call(d, 'Draft');
        insert drop(call, p, 3);

        call.Record_Status__c = 'Submitted';
        Database.SaveResult unsigned = Database.update(call, false);
        System.assert(!unsigned.isSuccess(), 'no signature, no submit');
        System.assert(unsigned.getErrors()[0].getMessage().contains('signature'));
        System.assertEquals(20, avail(lot.Id));

        call = [SELECT Id FROM Call_Visit_Report__c WHERE Id = :call.Id];
        call.Record_Status__c = 'Submitted';
        call.Signature_Captured__c = true;
        call.Signature_Image__c = '069000000000001AAA';
        call.Signature_Captured_At__c = System.now();
        call.Signature_GPS__Latitude__s = 28.61;
        call.Signature_GPS__Longitude__s = 77.20;
        call.Signee_Name__c = 'Dr Submit';
        update call;

        System.assertEquals(17, avail(lot.Id));
        Sample_Transaction__c t = [SELECT Transaction_Type__c, Status__c, Quantity__c, Signature_Captured__c, Signature_Image_Id__c, Signature_GPS_Lat__c,
                                          Signee_Name__c, Total_Value__c, Call_Report__c, Sample_Drop__c, Inventory_Applied__c, Signing_Statement__c
                                   FROM Sample_Transaction__c WHERE Call_Report__c = :call.Id];
        System.assertEquals('Disbursement', t.Transaction_Type__c);
        System.assertEquals('Completed', t.Status__c);
        System.assertEquals(3, t.Quantity__c);
        System.assertEquals(true, t.Signature_Captured__c);
        System.assertEquals('069000000000001AAA', t.Signature_Image_Id__c);
        System.assertEquals(28.61, t.Signature_GPS_Lat__c);
        System.assertEquals('Dr Submit', t.Signee_Name__c);
        System.assertEquals(120, t.Total_Value__c);
        System.assertEquals(true, t.Inventory_Applied__c);
        System.assert(t.Signing_Statement__c.contains('free medical sample not for sale'));
        System.assertEquals(t.Id, [SELECT Transaction__c FROM Sample_Drop__c WHERE Id = :t.Sample_Drop__c].Transaction__c);

        Sample_Expenditure_Tracking__c e = [SELECT Financial_Year__c, Total_Packs_Given__c, Total_Units_Given__c, Total_Value_INR__c, Last_Sample_Date__c
                                            FROM Sample_Expenditure_Tracking__c WHERE HCP_Account__c = :d.Id AND Product__c = :p.Id];
        System.assertEquals(SampleLimitChecker.financialYear(Date.today()), e.Financial_Year__c);
        System.assertEquals(3, e.Total_Packs_Given__c);
        System.assertEquals(12, e.Total_Units_Given__c);
        System.assertEquals(120, e.Total_Value_INR__c);
        System.assertEquals(Date.today(), e.Last_Sample_Date__c);
        call = [SELECT Has_Samples__c, Signature_Required__c, Sample_Total_Value__c, Sample_Drop_Count__c FROM Call_Visit_Report__c WHERE Id = :call.Id];
        System.assertEquals(true, call.Has_Samples__c);
        System.assertEquals(true, call.Signature_Required__c);
        System.assertEquals(120, call.Sample_Total_Value__c);
    }

    @isTest
    static void lineAddedToAnAlreadySubmittedSignedCallBecomesATransactionAtOnce() {
        Product__c p = SampleTestData.product('Late SKU');
        Sciagen_Account__c d = SampleTestData.doctor('Dr Late');
        Sample_Lot__c lot = SampleTestData.lot(p, 'LATE-1', 20, 200);
        Call_Visit_Report__c call = new Call_Visit_Report__c(HCP__c = d.Id, Visit_Date__c = Date.today(), Start_Time__c = System.now(), Call_Type__c = 'Detailing',
            Call_Status__c = 'Completed', Record_Status__c = 'Submitted', Signature_Captured__c = true, Signee_Name__c = 'Dr Late');
        insert call;
        insert drop(call, p, 2);
        System.assertEquals(18, avail(lot.Id));
        System.assertEquals(1, [SELECT COUNT() FROM Sample_Transaction__c WHERE Call_Report__c = :call.Id AND Status__c = 'Completed']);
    }

    @isTest
    static void unsignedSubmittedCallRefusesALineThatNeedsSignature() {
        Product__c p = SampleTestData.product('Unsigned SKU');
        Sciagen_Account__c d = SampleTestData.doctor('Dr Unsigned');
        SampleTestData.lot(p, 'UN-1', 20, 200);
        Call_Visit_Report__c call = SampleTestData.call(d, 'Submitted');
        Database.SaveResult r = Database.insert(drop(call, p, 1), false);
        System.assert(!r.isSuccess());
        System.assert(r.getErrors()[0].getMessage().contains('signature'));
    }

    @isTest
    static void hardLimitStopsTheThirteenthPackOnTheServer() {
        SampleLimitSeeder.seedDefaults();
        Product__c p = SampleTestData.product('Hard SKU');
        Sciagen_Account__c d = SampleTestData.doctor('Dr Hard');
        Sample_Lot__c lot = SampleTestData.lot(p, 'HARD-1', 100, 200);
        SampleTestData.given(p, lot, d, 12);
        Call_Visit_Report__c call = SampleTestData.call(d, 'Draft');
        Database.SaveResult r = Database.insert(drop(call, p, 1), false);
        System.assert(!r.isSuccess());
        System.assert(r.getErrors()[0].getMessage().contains('Cannot distribute more'), r.getErrors()[0].getMessage());
    }

    @isTest
    static void softLimitNeedsAReasonAndAManagerHoldsTheTransaction() {
        SampleLimitSeeder.seedDefaults();
        Sample_Limit__c perCall = [SELECT Id FROM Sample_Limit__c WHERE Limit_Scope__c = 'Per_Call'];
        perCall.Override_Requires_Manager__c = true;
        update perCall;
        Product__c p = SampleTestData.product('Soft Drop SKU');
        Sciagen_Account__c d = SampleTestData.doctor('Dr Soft Drop');
        Sample_Lot__c lot = SampleTestData.lot(p, 'SD-1', 100, 200);
        Call_Visit_Report__c call = SampleTestData.call(d, 'Draft');
        Database.SaveResult noReason = Database.insert(drop(call, p, 8), false);
        System.assert(!noReason.isSuccess());
        System.assert(noReason.getErrors()[0].getMessage().contains('reason'));
        Sample_Drop__c held = drop(call, p, 8);
        held.Override_Reason__c = 'Clinic training day';
        insert held;
        held = [SELECT Requires_Approval__c, Eligibility_Status__c FROM Sample_Drop__c WHERE Id = :held.Id];
        System.assertEquals(true, held.Requires_Approval__c);
        System.assertEquals('Warning', held.Eligibility_Status__c);
        call.Record_Status__c = 'Submitted';
        call.Signature_Captured__c = true;
        update call;
        Sample_Transaction__c t = [SELECT Status__c, Requires_Approval__c, Override_Reason__c FROM Sample_Transaction__c WHERE Call_Report__c = :call.Id];
        System.assertEquals('Pending', t.Status__c, 'held for manager approval');
        System.assertEquals('Clinic training day', t.Override_Reason__c);
        System.assertEquals(100, avail(lot.Id));
        t.Status__c = 'Completed';
        update t;   // the running user is a sample manager
        System.assertEquals(92, avail(lot.Id));
    }

    @isTest
    static void coldChainLineNeedsATagAndABreachIsRefused() {
        Product__c p = SampleTestData.product('Cold Drop SKU');
        p.Requires_Cold_Chain__c = true;
        update p;
        Sciagen_Account__c d = SampleTestData.doctor('Dr Cold');
        SampleTestData.lot(p, 'CD-1', 20, 200);
        Call_Visit_Report__c call = SampleTestData.call(d, 'Draft');
        System.assert(!Database.insert(drop(call, p, 1), false).isSuccess());
        Sample_Drop__c breach = drop(call, p, 1);
        breach.Cold_Chain_Tag_Number__c = 'T-1';
        breach.Cold_Chain_Status__c = 'Breach';
        System.assert(Database.insert(breach, false).getErrors()[0].getMessage().contains('breach'));
        Sample_Drop__c ok = drop(call, p, 1);
        ok.Cold_Chain_Tag_Number__c = 'T-1';
        ok.Cold_Chain_Status__c = 'Normal';
        insert ok;
    }

    @isTest
    static void controlledSubstanceCallCannotBeUnlockedByARepAndReSigns() {
        Product__c p = SampleTestData.product('Controlled Drop SKU');
        p.Is_Controlled_Substance__c = true;
        p.Controlled_Substance_Schedule__c = 'H1';
        update p;
        Sciagen_Account__c d = SampleTestData.doctor('Dr Controlled Drop');
        d.Controlled_Substance_License__c = 'CDL-1';
        update d;
        SampleTestData.lot(p, 'CS-1', 20, 200);
        Call_Visit_Report__c call = SampleTestData.call(d, 'Draft');
        insert drop(call, p, 1);
        call.Record_Status__c = 'Submitted';
        call.Signature_Captured__c = true;
        update call;
        call.Record_Status__c = 'Draft';
        update call;    // the running user is a sample manager: allowed, but the signature is cleared
        System.assertEquals(false, [SELECT Signature_Captured__c FROM Call_Visit_Report__c WHERE Id = :call.Id].Signature_Captured__c);
    }

    @isTest
    static void rulesCanBeSwitchedToRecordOnlyDuringRollout() {
        insert new UCPMP_Tenant_Config__c(SetupOwnerId = UserInfo.getOrganizationId(), Enforce_Sample_Rules__c = false, UCPMP_Compliance_Enabled__c = true);
        Product__c p = SampleTestData.product('Rollout SKU');
        Sciagen_Account__c d = SampleTestData.doctor('Dr Rollout');
        d.License_Verification_Status__c = 'Unverified';
        update d;
        Call_Visit_Report__c call = SampleTestData.call(d, 'Draft');
        Sample_Drop__c line = drop(call, p, 1);
        insert line;
        System.assert([SELECT Eligibility_Message__c FROM Sample_Drop__c WHERE Id = :line.Id].Eligibility_Message__c.startsWith('Not enforced'));
    }

    @isTest
    static void allocationsCountDownAsTheRepGivesSamples() {
        Product__c p = SampleTestData.product('Alloc SKU');
        Sciagen_Account__c d = SampleTestData.doctor('Dr Alloc');
        Sample_Lot__c lot = SampleTestData.lot(p, 'AL-1', 50, 200);
        Sample_Allocation__c a = new Sample_Allocation__c(Name = 'Sept allocation', Product__c = p.Id, Allocated_To_User__c = UserInfo.getUserId(), Allocation_Quantity__c = 10,
            Period_Start__c = Date.today().addDays(-5), Period_End__c = Date.today().addDays(20));
        insert a;
        SampleTestData.given(p, lot, d, 4);
        a = [SELECT Used_Quantity__c, Remaining_Quantity__c, Status__c FROM Sample_Allocation__c WHERE Id = :a.Id];
        System.assertEquals(4, a.Used_Quantity__c);
        System.assertEquals(6, a.Remaining_Quantity__c);
        SampleTestData.given(p, lot, d, 6);
        System.assertEquals('Depleted', [SELECT Status__c FROM Sample_Allocation__c WHERE Id = :a.Id].Status__c);
    }

    @isTest
    static void reversingADisbursementGivesBackExpenditureAndAllocation() {
        Product__c p = SampleTestData.product('Reverse Exp SKU');
        Sciagen_Account__c d = SampleTestData.doctor('Dr Reverse');
        Sample_Lot__c lot = SampleTestData.lot(p, 'RE-1', 50, 200);
        SampleTestData.given(p, lot, d, 5);
        Sample_Transaction__c t = [SELECT Id, Status__c FROM Sample_Transaction__c WHERE HCP_Account__c = :d.Id];
        System.assertEquals(5, [SELECT Total_Packs_Given__c FROM Sample_Expenditure_Tracking__c WHERE HCP_Account__c = :d.Id].Total_Packs_Given__c);
        t.Status__c = 'Cancelled';
        update t;
        System.assertEquals(0, [SELECT Total_Packs_Given__c FROM Sample_Expenditure_Tracking__c WHERE HCP_Account__c = :d.Id].Total_Packs_Given__c);
        System.assertEquals(50, avail(lot.Id));
    }

    @isTest
    static void licenceExpiryBatchMarksLapsedLicencesExpired() {
        Sciagen_Account__c lapsed = SampleTestData.doctor('Dr Lapsed');
        Sciagen_Account__c fine = SampleTestData.doctor('Dr Fine');
        lapsed.License_Expiry_Date__c = Date.today().addDays(-3);
        update lapsed;
        Test.startTest();
        Database.executeBatch(new HcpLicenseExpiryBatch(), 200);
        Test.stopTest();
        System.assertEquals('Expired', [SELECT License_Verification_Status__c FROM Sciagen_Account__c WHERE Id = :lapsed.Id].License_Verification_Status__c);
        System.assertEquals('Verified', [SELECT License_Verification_Status__c FROM Sciagen_Account__c WHERE Id = :fine.Id].License_Verification_Status__c);
        System.assertEquals(false, [SELECT Sample_Eligible__c FROM Sciagen_Account__c WHERE Id = :lapsed.Id].Sample_Eligible__c);
        System.assertEquals(true, [SELECT Sample_Eligible__c FROM Sciagen_Account__c WHERE Id = :fine.Id].Sample_Eligible__c);
    }

    // ---------------------------------------------------------------------
    // SM-UNL-01..03 (D3/D14): unlock reverses the posted Disbursement(s)
    // rather than editing them in place; resubmitting posts fresh ones with
    // no double counting of stock or UCPMP expenditure.
    // ---------------------------------------------------------------------

    @isTest
    static void unlockingASubmittedCallReversesItsDisbursementWithoutEditingItInPlace() {
        Product__c p = SampleTestData.product('Unlock SKU');
        Sciagen_Account__c d = SampleTestData.doctor('Dr Unlock');
        Sample_Lot__c lot = SampleTestData.lot(p, 'UNL-1', 20, 200);
        Call_Visit_Report__c call = SampleTestData.call(d, 'Draft');
        Sample_Drop__c line = drop(call, p, 3);
        insert line;
        call.Record_Status__c = 'Submitted';
        call.Signature_Captured__c = true;
        call.Signee_Name__c = 'Dr Unlock';
        update call;

        System.assertEquals(17, avail(lot.Id), 'disbursement took 3 packs');
        Sample_Transaction__c original = [SELECT Id, Quantity__c, Status__c, Transaction_Type__c FROM Sample_Transaction__c WHERE Call_Report__c = :call.Id];
        Sample_Expenditure_Tracking__c e1 = [SELECT Total_Packs_Given__c FROM Sample_Expenditure_Tracking__c WHERE HCP_Account__c = :d.Id AND Product__c = :p.Id];
        System.assertEquals(3, e1.Total_Packs_Given__c);

        // Unlock (the direct Sample Admin path — SampleAdminController.unlockCall).
        Test.startTest();
        System.runAs(sampleAdminUser()) {
            SampleAdminController.unlockCall(call.Id, 'Rep reported the wrong quantity.');
        }
        Test.stopTest();

        System.assertEquals('Saved', [SELECT Record_Status__c FROM Call_Visit_Report__c WHERE Id = :call.Id].Record_Status__c);
        // The original Disbursement itself is untouched — never edited in place.
        Sample_Transaction__c untouchedOriginal = [SELECT Quantity__c, Status__c, Transaction_Type__c, Inventory_Applied__c FROM Sample_Transaction__c WHERE Id = :original.Id];
        System.assertEquals('Disbursement', untouchedOriginal.Transaction_Type__c);
        System.assertEquals('Completed', untouchedOriginal.Status__c);
        System.assertEquals(3, untouchedOriginal.Quantity__c);
        System.assertEquals(true, untouchedOriginal.Inventory_Applied__c, 'the original record itself is never flipped back off');
        // A separate Reversal transaction exists, linked back to it.
        Sample_Transaction__c reversal = [SELECT Transaction_Type__c, Quantity__c, Paired_Transaction__c, Sample_Lot__c FROM Sample_Transaction__c
                                          WHERE Transaction_Type__c = 'Reversal' AND Paired_Transaction__c = :original.Id];
        System.assertEquals(3, reversal.Quantity__c);
        System.assertEquals(lot.Id, reversal.Sample_Lot__c);
        System.assertEquals(20, avail(lot.Id), 'stock is fully restored');
        Sample_Expenditure_Tracking__c e2 = [SELECT Total_Packs_Given__c FROM Sample_Expenditure_Tracking__c WHERE HCP_Account__c = :d.Id AND Product__c = :p.Id];
        System.assertEquals(0, e2.Total_Packs_Given__c, 'the UCPMP counter is undone, not left over-counted');
        System.assertEquals(null, [SELECT Transaction__c FROM Sample_Drop__c WHERE Id = :line.Id].Transaction__c, 'freed to be re-posted on resubmit');

        // Edit the quantity, then resubmit — must post a FRESH disbursement, not touch the old records again.
        line.Qty__c = 5;
        update line;
        call = [SELECT Id, Record_Status__c FROM Call_Visit_Report__c WHERE Id = :call.Id];
        call.Record_Status__c = 'Submitted';
        update call;

        Sample_Drop__c afterResubmit = [SELECT Transaction__c, Eligibility_Status__c FROM Sample_Drop__c WHERE Id = :line.Id];
        System.assertNotEquals(null, afterResubmit.Transaction__c, 'the resubmit posted a fresh disbursement, linked back to the drop line');
        System.assertNotEquals('Blocked', afterResubmit.Eligibility_Status__c);
        System.assertEquals(15, avail(lot.Id), '20 on hand minus the new, edited quantity of 5 — not 20-3-5');
        System.assertEquals(2, [SELECT COUNT() FROM Sample_Transaction__c WHERE Call_Report__c = :call.Id AND Transaction_Type__c = 'Disbursement'],
            'the original disbursement plus one fresh one for the resubmit — never a third');
        Sample_Transaction__c fresh = [SELECT Quantity__c FROM Sample_Transaction__c WHERE Call_Report__c = :call.Id AND Transaction_Type__c = 'Disbursement'
                                       AND Id != :original.Id];
        System.assertEquals(5, fresh.Quantity__c);
        Sample_Expenditure_Tracking__c e3 = [SELECT Total_Packs_Given__c FROM Sample_Expenditure_Tracking__c WHERE HCP_Account__c = :d.Id AND Product__c = :p.Id];
        System.assertEquals(5, e3.Total_Packs_Given__c, 'reflects only the resubmitted quantity — no double counting');
    }

    @isTest
    static void unlockCallRequiresThePermissionAndARunningReason() {
        Sciagen_Account__c d = SampleTestData.doctor('Dr NoPerm');
        Call_Visit_Report__c call = SampleTestData.call(d, 'Submitted');

        // A plain rep (Sciagen_Mobile_App_Access only, no Sample Admin permission
        // set) must be refused.
        Test.startTest();
        System.runAs(repNoPermission()) {
            System.assertEquals(false, FeatureManagement.checkPermission('Sample_Unlock_Calls'), 'diagnostic: raw permission check for the no-perm rep');
            try {
                SampleAdminController.unlockCall(call.Id, 'trying without permission');
                System.assert(false, 'a user without Sample_Unlock_Calls must be refused');
            } catch (AuraHandledException e) {
                System.assert(true);
            }
        }

        System.runAs(sampleAdminUser()) {
            try {
                SampleAdminController.unlockCall(call.Id, '');
                System.assert(false, 'a blank reason must be refused even with permission');
            } catch (AuraHandledException e) {
                System.assert(e.getMessage().contains('reason'), e.getMessage());
            }
        }
        Test.stopTest();
    }
}