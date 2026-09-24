@isTest
private class SampleTransactionServiceTest {

    @testSetup
    static void users() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User rep2 = new User(FirstName = 'Second', LastName = 'Rep SampleTest', Alias = 'srep2', Email = 'second.rep.sample@sciagen-test.invalid',
            Username = 'second.rep.sample@sciagen-new-dev.invalid', TimeZoneSidKey = 'Asia/Kolkata', LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US', ProfileId = p.Id, IsActive = true);
        insert rep2;
        insert new PermissionSetAssignment(AssigneeId = rep2.Id, PermissionSetId = [SELECT Id FROM PermissionSet WHERE Name = 'Sciagen_Mobile_App_Access'].Id);
    }

    static User rep2() { return [SELECT Id FROM User WHERE Username = 'second.rep.sample@sciagen-new-dev.invalid']; }

    static Product__c product(String name, Boolean cold, Boolean controlled) {
        Product__c p = new Product__c(Name = name, Level__c = 'SKU', Is_Sample_Product__c = true, Sample_Unit_Value_INR__c = 10, Pack_Size__c = 4,
            Smallest_Market_Pack_Size__c = 10, Requires_Cold_Chain__c = cold, Is_Controlled_Substance__c = controlled,
            Controlled_Substance_Schedule__c = controlled ? 'H1' : null);
        insert p;
        return p;
    }

    static Sciagen_Account__c doctor() {
        Sciagen_Account__c d = new Sciagen_Account__c(Name = 'Dr. Ledger Test', Type__c = 'HCP', Speciality__c = 'Cardiology', Billing_City__c = 'Delhi');
        insert d;
        return d;
    }

    static Sample_Lot__c lot(Product__c p, String lotNo, Integer qty, Id holder) {
        Sample_Lot__c l = new Sample_Lot__c(Product__c = p.Id, Lot_Number__c = lotNo, Expiry_Date__c = Date.today().addDays(120),
            Initial_Quantity__c = qty, Available_Quantity__c = qty, Owner_User__c = holder);
        insert l;
        return l;
    }

    static Sample_Transaction__c disb(Product__c p, Sample_Lot__c l, Sciagen_Account__c d, Integer qty) {
        return new Sample_Transaction__c(Transaction_Type__c = 'Disbursement', Status__c = 'Completed', Product__c = p.Id, Sample_Lot__c = l.Id,
            HCP_Account__c = d.Id, Quantity__c = qty);
    }

    static Decimal avail(Id lotId) { return [SELECT Available_Quantity__c FROM Sample_Lot__c WHERE Id = :lotId].Available_Quantity__c; }

    static void assertRefused(Sample_Transaction__c t, String part) {
        Database.SaveResult r = Database.insert(t, false);
        System.assert(!r.isSuccess(), 'expected refusal containing: ' + part);
        System.assert(r.getErrors()[0].getMessage().containsIgnoreCase(part), r.getErrors()[0].getMessage());
    }

    @isTest
    static void receiptAddsStockOnlyWhenConfirmed() {
        Product__c p = product('Receipt SKU', false, false);
        Sample_Lot__c l = new Sample_Lot__c(Product__c = p.Id, Lot_Number__c = 'R-1', Expiry_Date__c = Date.today().addDays(90), Initial_Quantity__c = 20, Available_Quantity__c = 0, Owner_User__c = UserInfo.getUserId());
        insert l;
        System.assertEquals('Depleted', [SELECT Status__c FROM Sample_Lot__c WHERE Id = :l.Id].Status__c);
        Sample_Transaction__c rc = new Sample_Transaction__c(Transaction_Type__c = 'Receipt', Status__c = 'Pending', Product__c = p.Id, Sample_Lot__c = l.Id, Quantity__c = 20, To_User__c = UserInfo.getUserId());
        insert rc;
        System.assertEquals(0, avail(l.Id), 'nothing arrives until the rep confirms');
        rc.Status__c = 'Confirmed';
        update rc;
        System.assertEquals(20, avail(l.Id));
        System.assertEquals('Active', [SELECT Status__c FROM Sample_Lot__c WHERE Id = :l.Id].Status__c);
        update rc;   // no change
        System.assertEquals(20, avail(l.Id), 'never applied twice');
        System.assertEquals(true, [SELECT Inventory_Applied__c FROM Sample_Transaction__c WHERE Id = :rc.Id].Inventory_Applied__c);
    }

    @isTest
    static void receiptUsesTheConfirmedCount() {
        Product__c p = product('Count SKU', false, false);
        Sample_Lot__c l = new Sample_Lot__c(Product__c = p.Id, Lot_Number__c = 'C-1', Expiry_Date__c = Date.today().addDays(90), Initial_Quantity__c = 20, Available_Quantity__c = 0, Owner_User__c = UserInfo.getUserId());
        insert l;
        Sample_Transaction__c rc = new Sample_Transaction__c(Transaction_Type__c = 'Receipt', Status__c = 'Pending', Product__c = p.Id, Sample_Lot__c = l.Id, Quantity__c = 20, To_User__c = UserInfo.getUserId());
        insert rc;
        rc.Status__c = 'Confirmed';
        rc.Confirmed_Quantity__c = 18;
        update rc;
        System.assertEquals(18, avail(l.Id), 'the receiver counted 18');
    }

    @isTest
    static void disbursementDeductsSnapshotsValueAndRecordsTheDoctor() {
        Product__c p = product('Disb SKU', false, false);
        Sciagen_Account__c d = doctor();
        Sample_Lot__c l = lot(p, 'D-1', 20, UserInfo.getUserId());
        insert disb(p, l, d, 3);
        System.assertEquals(17, avail(l.Id));
        Sample_Transaction__c t = [SELECT Unit_Value_At_Transaction__c, Pack_Size_At_Transaction__c, Total_Value__c, HCP_Specialty__c, HCP_Address__c, Performed_By__c,
                                          Performed_At__c, Marked_Not_For_Sale__c, Inventory_Shortfall__c FROM Sample_Transaction__c WHERE Product__c = :p.Id];
        System.assertEquals(10, t.Unit_Value_At_Transaction__c);
        System.assertEquals(4, t.Pack_Size_At_Transaction__c);
        System.assertEquals(120, t.Total_Value__c, '3 packs x 4 units x INR 10');
        System.assertEquals('Cardiology', t.HCP_Specialty__c);
        System.assertEquals('Delhi', t.HCP_Address__c);
        System.assertEquals(UserInfo.getUserId(), t.Performed_By__c);
        System.assertNotEquals(null, t.Performed_At__c);
        System.assertEquals(true, t.Marked_Not_For_Sale__c);
        System.assertEquals(0, t.Inventory_Shortfall__c);
    }

    @isTest
    static void disbursementBeyondStockIsRecordedWithAShortfallNotRejected() {
        Product__c p = product('Short SKU', false, false);
        Sample_Lot__c l = lot(p, 'S-1', 2, UserInfo.getUserId());
        insert disb(p, l, doctor(), 5);
        System.assertEquals(0, avail(l.Id));
        System.assertEquals('Depleted', [SELECT Status__c FROM Sample_Lot__c WHERE Id = :l.Id].Status__c);
        System.assertEquals(3, [SELECT Inventory_Shortfall__c FROM Sample_Transaction__c WHERE Product__c = :p.Id].Inventory_Shortfall__c);
    }

    @isTest
    static void disbursementRulesAreEnforced() {
        Product__c p = product('Rules SKU', false, false);
        Sciagen_Account__c d = doctor();
        Sample_Lot__c l = lot(p, 'RU-1', 10, UserInfo.getUserId());
        Sample_Transaction__c noDoctor = disb(p, l, d, 1);
        noDoctor.HCP_Account__c = null;
        assertRefused(noDoctor, 'doctor');
        Product__c notSample = new Product__c(Name = 'Detail only', Level__c = 'SKU');
        insert notSample;
        assertRefused(new Sample_Transaction__c(Transaction_Type__c = 'Disbursement', Status__c = 'Completed', Product__c = notSample.Id, HCP_Account__c = d.Id, Quantity__c = 1), 'not set up as a sample');
        Sample_Lot__c old = lot(p, 'RU-OLD', 10, UserInfo.getUserId());
        old.Expiry_Date__c = Date.today().addDays(-1);
        update old;
        assertRefused(disb(p, old, d, 1), 'expired');
        Sample_Lot__c recalled = lot(p, 'RU-REC', 10, UserInfo.getUserId());
        recalled.Status__c = 'Recalled';
        update recalled;
        assertRefused(disb(p, recalled, d, 1), 'recalled');
        Product__c other = product('Other SKU', false, false);
        assertRefused(disb(other, l, d, 1), 'different product');
    }

    @isTest
    static void restrictedProductCannotBeSampled() {
        Product__c r = new Product__c(Name = 'Restricted SKU', Level__c = 'SKU', Is_Sample_Product__c = true, Sample_Unit_Value_INR__c = 5,
            Is_Restricted__c = true, Restriction_Reason__c = 'Hypnotic_Sedative_Tranquillizer', Max_Packs_Per_HCP_Per_Year__c = 0);
        insert r;
        Sample_Lot__c l = lot(r, 'RS-1', 10, UserInfo.getUserId());
        assertRefused(disb(r, l, doctor(), 1), 'restricted');
    }

    @isTest
    static void coldChainNeedsATagAndABreachBlocksDistribution() {
        Product__c p = product('Cold SKU', true, false);
        Sciagen_Account__c d = doctor();
        Sample_Lot__c l = lot(p, 'CC-1', 10, UserInfo.getUserId());
        assertRefused(disb(p, l, d, 1), 'tag number');
        Sample_Transaction__c breach = disb(p, l, d, 1);
        breach.Cold_Chain_Tag_Number__c = 'TAG-9';
        breach.Cold_Chain_Status__c = 'Breach';
        assertRefused(breach, 'breach');
        Sample_Transaction__c ok = disb(p, l, d, 1);
        ok.Cold_Chain_Tag_Number__c = 'TAG-9';
        ok.Cold_Chain_Status__c = 'Normal';
        insert ok;
        System.assertEquals(9, avail(l.Id));
    }

    @isTest
    static void controlledSubstanceNeedsASignatureAndFlagsAfterHours() {
        Product__c p = product('Controlled SKU', false, true);
        Sciagen_Account__c d = doctor();
        Sample_Lot__c l = lot(p, 'CS-1', 10, UserInfo.getUserId());
        assertRefused(disb(p, l, d, 1), 'signature');
        Sample_Transaction__c signed = disb(p, l, d, 1);
        signed.Signature_Captured__c = true;
        signed.Performed_At__c = Datetime.newInstance(Date.today().addDays(7), Time.newInstance(23, 0, 0, 0));
        insert signed;
        System.assertEquals(true, [SELECT After_Hours__c FROM Sample_Transaction__c WHERE Id = :signed.Id].After_Hours__c);
    }

    @isTest
    static void transferMovesStockToTheRecipientOnConfirmation() {
        Product__c p = product('Transfer SKU', false, false);
        User other = rep2();
        Sample_Lot__c mine = lot(p, 'T-1', 20, UserInfo.getUserId());
        Sample_Transaction__c out = new Sample_Transaction__c(Transaction_Type__c = 'Transfer_Out', Status__c = 'Completed', Product__c = p.Id,
            Sample_Lot__c = mine.Id, Quantity__c = 8, To_User__c = other.Id);
        insert out;
        System.assertEquals(12, avail(mine.Id), 'sender is deducted straight away');
        Sample_Transaction__c pending = [SELECT Id, Status__c, OwnerId, Quantity__c, To_User__c FROM Sample_Transaction__c WHERE Transaction_Type__c = 'Transfer_In'];
        System.assertEquals('Pending', pending.Status__c);
        System.assertEquals(other.Id, pending.OwnerId, 'the recipient sees and confirms it');
        System.assertEquals(0, [SELECT COUNT() FROM Sample_Lot__c WHERE Owner_User__c = :other.Id], 'no lot for the recipient until they confirm');

        pending.Status__c = 'Confirmed';
        update pending;
        Sample_Lot__c theirs = [SELECT Available_Quantity__c, Lot_Number__c, Status__c, Source_Lot__c FROM Sample_Lot__c WHERE Owner_User__c = :other.Id];
        System.assertEquals(8, theirs.Available_Quantity__c);
        System.assertEquals('T-1', theirs.Lot_Number__c);
        System.assertEquals('Active', theirs.Status__c);
        System.assertEquals(mine.Id, theirs.Source_Lot__c);

        // a second transfer of the same lot number tops up their existing lot
        insert new Sample_Transaction__c(Transaction_Type__c = 'Transfer_Out', Status__c = 'Completed', Product__c = p.Id, Sample_Lot__c = mine.Id, Quantity__c = 2, To_User__c = other.Id);
        Sample_Transaction__c second = [SELECT Id FROM Sample_Transaction__c WHERE Transaction_Type__c = 'Transfer_In' AND Status__c = 'Pending'];
        second.Status__c = 'Confirmed';
        update second;
        System.assertEquals(1, [SELECT COUNT() FROM Sample_Lot__c WHERE Owner_User__c = :other.Id]);
        System.assertEquals(10, [SELECT Available_Quantity__c FROM Sample_Lot__c WHERE Owner_User__c = :other.Id].Available_Quantity__c);
    }

    @isTest
    static void rejectedTransferGoesBackToTheSender() {
        Product__c p = product('Reject SKU', false, false);
        Sample_Lot__c mine = lot(p, 'RJ-1', 10, UserInfo.getUserId());
        insert new Sample_Transaction__c(Transaction_Type__c = 'Transfer_Out', Status__c = 'Completed', Product__c = p.Id, Sample_Lot__c = mine.Id, Quantity__c = 4, To_User__c = rep2().Id);
        System.assertEquals(6, avail(mine.Id));
        Sample_Transaction__c pending = [SELECT Id FROM Sample_Transaction__c WHERE Transaction_Type__c = 'Transfer_In'];
        pending.Status__c = 'Rejected';
        update pending;
        System.assertEquals(10, avail(mine.Id));
    }

    @isTest
    static void transferNeedsStockAndARecipient() {
        Product__c p = product('Guard SKU', false, false);
        Sample_Lot__c mine = lot(p, 'G-1', 3, UserInfo.getUserId());
        assertRefused(new Sample_Transaction__c(Transaction_Type__c = 'Transfer_Out', Status__c = 'Completed', Product__c = p.Id, Sample_Lot__c = mine.Id, Quantity__c = 9, To_User__c = rep2().Id), 'available');
        assertRefused(new Sample_Transaction__c(Transaction_Type__c = 'Transfer_Out', Status__c = 'Completed', Product__c = p.Id, Sample_Lot__c = mine.Id, Quantity__c = 1), 'going to');
    }

    @isTest
    static void returnDeductsAndNeedsAReason() {
        Product__c p = product('Return SKU', false, false);
        Sample_Lot__c l = lot(p, 'RT-1', 10, UserInfo.getUserId());
        Database.SaveResult noReason = Database.insert(new Sample_Transaction__c(Transaction_Type__c = 'Return', Status__c = 'Completed', Product__c = p.Id, Sample_Lot__c = l.Id, Quantity__c = 4), false);
        System.assert(!noReason.isSuccess());
        insert new Sample_Transaction__c(Transaction_Type__c = 'Return', Status__c = 'Completed', Product__c = p.Id, Sample_Lot__c = l.Id, Quantity__c = 4, Return_Reason__c = 'Excess', Return_To__c = 'Central Warehouse');
        System.assertEquals(6, avail(l.Id));
    }

    @isTest
    static void coldChainReturnsNeedAColdWarehouse() {
        Product__c p = product('Cold Return SKU', true, false);
        Sample_Lot__c l = lot(p, 'CR-1', 10, UserInfo.getUserId());
        Sample_Warehouse__c warm = new Sample_Warehouse__c(Name = 'Warm depot', Warehouse_Type__c = 'Regional', Has_Cold_Storage__c = false);
        Sample_Warehouse__c cold = new Sample_Warehouse__c(Name = 'Cold depot', Warehouse_Type__c = 'Central', Has_Cold_Storage__c = true);
        insert new List<Sample_Warehouse__c>{ warm, cold };
        Sample_Transaction__c toWarm = new Sample_Transaction__c(Transaction_Type__c = 'Return', Status__c = 'Completed', Product__c = p.Id, Sample_Lot__c = l.Id, Quantity__c = 2,
            Return_Reason__c = 'Damaged', To_Warehouse__c = warm.Id, Cold_Chain_Tag_Number__c = 'T', Cold_Chain_Status__c = 'Breach');
        assertRefused(toWarm, 'cold storage');
        Sample_Transaction__c toCold = new Sample_Transaction__c(Transaction_Type__c = 'Return', Status__c = 'Completed', Product__c = p.Id, Sample_Lot__c = l.Id, Quantity__c = 2,
            Return_Reason__c = 'Damaged', To_Warehouse__c = cold.Id, Cold_Chain_Tag_Number__c = 'T', Cold_Chain_Status__c = 'Breach');
        insert toCold;
        System.assertEquals(8, avail(l.Id), 'a breached lot can go back to a cold warehouse');
    }

    @isTest
    static void adjustmentsCanAddOrRemoveButNotGoBelowZero() {
        Product__c p = product('Adjust SKU', false, false);
        Sample_Lot__c l = lot(p, 'A-1', 100, UserInfo.getUserId());
        insert new Sample_Transaction__c(Transaction_Type__c = 'Adjustment', Status__c = 'Completed', Product__c = p.Id, Sample_Lot__c = l.Id, Quantity__c = -5, Adjustment_Reason__c = 'Loss');
        System.assertEquals(95, avail(l.Id));
        insert new Sample_Transaction__c(Transaction_Type__c = 'Adjustment', Status__c = 'Completed', Product__c = p.Id, Sample_Lot__c = l.Id, Quantity__c = 2, Adjustment_Reason__c = 'Recount');
        System.assertEquals(97, avail(l.Id));
        assertRefused(new Sample_Transaction__c(Transaction_Type__c = 'Adjustment', Status__c = 'Completed', Product__c = p.Id, Sample_Lot__c = l.Id, Quantity__c = -500, Adjustment_Reason__c = 'Loss'), 'below zero');
        Database.SaveResult none = Database.insert(new Sample_Transaction__c(Transaction_Type__c = 'Adjustment', Status__c = 'Completed', Product__c = p.Id, Sample_Lot__c = l.Id, Quantity__c = 0, Adjustment_Reason__c = 'Loss'), false);
        System.assert(!none.isSuccess());
        // more than 10% of the lot: still applied, and a manager alert is attempted
        insert new Sample_Transaction__c(Transaction_Type__c = 'Adjustment', Status__c = 'Completed', Product__c = p.Id, Sample_Lot__c = l.Id, Quantity__c = -20, Adjustment_Reason__c = 'Damage');
        System.assertEquals(77, avail(l.Id));
    }

    @isTest
    static void managerCanReverseADisbursementAndStockComesBack() {
        Product__c p = product('Reverse SKU', false, false);
        Sample_Lot__c l = lot(p, 'RV-1', 10, UserInfo.getUserId());
        Sample_Transaction__c t = disb(p, l, doctor(), 4);
        insert t;
        System.assertEquals(6, avail(l.Id));
        t.Status__c = 'Cancelled';
        update t;
        System.assertEquals(10, avail(l.Id));
        System.assertEquals(false, [SELECT Inventory_Applied__c FROM Sample_Transaction__c WHERE Id = :t.Id].Inventory_Applied__c);
    }

    @isTest
    static void aRepCannotRewriteAnAppliedTransaction() {
        Product__c p = product('Immutable SKU', false, false);
        Sciagen_Account__c d = doctor();
        User other = rep2();
        Sample_Lot__c l = lot(p, 'IM-1', 10, other.Id);
        Sample_Transaction__c t = disb(p, l, d, 2);
        t.OwnerId = other.Id;
        insert t;
        System.runAs(other) {
            t.Quantity__c = 1;
            Database.SaveResult r = Database.update(t, false);
            System.assert(!r.isSuccess(), 'a rep can not change a transaction that has already moved stock');
        }
        System.assertEquals(8, avail(l.Id));
    }

    @isTest
    static void heldDisbursementNeedsAManagerBeforeItMovesStock() {
        Product__c p = product('Held SKU', false, false);
        Sample_Lot__c l = lot(p, 'HD-1', 10, UserInfo.getUserId());
        Sample_Transaction__c t = disb(p, l, doctor(), 3);
        t.Status__c = 'Pending';
        t.Requires_Approval__c = true;
        insert t;
        System.assertEquals(10, avail(l.Id), 'held: nothing deducted yet');
        t.Status__c = 'Completed';
        update t;   // the running user holds Manage_Sample_Inventory
        System.assertEquals(7, avail(l.Id));
        System.assertEquals(UserInfo.getUserId(), [SELECT Approved_By__c FROM Sample_Transaction__c WHERE Id = :t.Id].Approved_By__c);
    }

    @isTest
    static void retriedOfflinePushDoesNotDuplicate() {
        Product__c p = product('Idem SKU', false, false);
        Sample_Lot__c l = lot(p, 'ID-1', 10, UserInfo.getUserId());
        Sample_Transaction__c a = disb(p, l, doctor(), 1);
        a.Client_Id__c = 'device-123';
        insert a;
        Sample_Transaction__c again = disb(p, l, doctor(), 1);
        again.Client_Id__c = 'device-123';
        System.assert(!Database.insert(again, false).isSuccess());
        System.assertEquals(9, avail(l.Id));
    }

    @isTest
    static void transferringTheWholeBalanceStillLinksTheTwoTransactions() {
        Product__c p = product('Whole SKU', false, false);
        Sample_Lot__c mine = lot(p, 'WH-1', 6, UserInfo.getUserId());
        insert new Sample_Transaction__c(Transaction_Type__c = 'Transfer_Out', Status__c = 'Completed', Product__c = p.Id, Sample_Lot__c = mine.Id, Quantity__c = 6, To_User__c = rep2().Id);
        System.assertEquals(0, avail(mine.Id));
        System.assertEquals('Depleted', [SELECT Status__c FROM Sample_Lot__c WHERE Id = :mine.Id].Status__c);
        Sample_Transaction__c out = [SELECT Paired_Transaction__c FROM Sample_Transaction__c WHERE Transaction_Type__c = 'Transfer_Out'];
        System.assertNotEquals(null, out.Paired_Transaction__c, 'the two sides are linked even though the lot is now empty');
    }
}