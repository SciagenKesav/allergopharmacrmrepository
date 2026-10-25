/**
 * QA-31: the sample ledger can't be moved around the UCPMP limit engine or the
 * manager approval, and the iPad's own flows (drop, transfer, return, adjust,
 * count, receipt / transfer-in confirmation) still work for a rep.
 */
@isTest
private class SampleLedgerGuardTest {

    private static Decimal avail(Id lotId) { return [SELECT Available_Quantity__c FROM Sample_Lot__c WHERE Id = :lotId].Available_Quantity__c; }

    private static Sample_Lot__c repLot(Product__c p, User rep, String lotNo, Integer qty) {
        Sample_Lot__c l = new Sample_Lot__c(Product__c = p.Id, Lot_Number__c = lotNo, Expiry_Date__c = Date.today().addDays(200),
            Initial_Quantity__c = qty, Available_Quantity__c = qty, Owner_User__c = rep.Id);
        insert l;
        return l;
    }

    private static String insertAs(User u, Sample_Transaction__c t) {
        String error;
        System.runAs(u) {
            Database.SaveResult r = Database.insert(t, false);
            if (!r.isSuccess()) error = r.getErrors()[0].getMessage();
        }
        return error;
    }

    private static String updateAs(User u, Sample_Transaction__c t) {
        String error;
        System.runAs(u) {
            Database.SaveResult r = Database.update(t, false);
            if (!r.isSuccess()) error = r.getErrors()[0].getMessage();
        }
        return error;
    }

    @isTest static void repCannotInsertADisbursementDirectly() {
        User rep = SciagenTestUsers.mobileRep('sgrep1');
        Product__c p = SampleTestData.product('Guard SKU');
        Sample_Lot__c lot = repLot(p, rep, 'G-1', 20);
        Sciagen_Account__c d;
        System.runAs(rep) { d = SampleTestData.doctor('Dr Guard'); }
        String error = insertAs(rep, new Sample_Transaction__c(Transaction_Type__c = 'Disbursement', Status__c = 'Completed',
            Product__c = p.Id, Sample_Lot__c = lot.Id, HCP_Account__c = d.Id, Quantity__c = 50));
        System.assertEquals(SampleTransactionService.DIRECT_DISBURSEMENT, error);
        System.assertEquals(20, avail(lot.Id));
        System.assertEquals(0, [SELECT COUNT() FROM Sample_Transaction__c WHERE HCP_Account__c = :d.Id]);
    }

    @isTest static void dropOnASubmittedCallStillCreatesTheDisbursementForARep() {
        User rep = SciagenTestUsers.mobileRep('sgrep2');
        Product__c p = SampleTestData.product('Drop SKU');
        Sample_Lot__c lot = repLot(p, rep, 'D-1', 20);
        Test.startTest();
        System.runAs(rep) {
            Sciagen_Account__c d = SampleTestData.doctor('Dr Drop');
            Call_Visit_Report__c call = SampleTestData.call(d, 'Draft');
            insert new Sample_Drop__c(Name = 'Sample Drop', CVR__c = call.Id, Product__c = p.Id, Qty__c = 3);
            update new Call_Visit_Report__c(Id = call.Id, Record_Status__c = 'Submitted', Signature_Captured__c = true);
        }
        Test.stopTest();
        Sample_Transaction__c t = [SELECT Transaction_Type__c, Status__c, Quantity__c, Inventory_Applied__c FROM Sample_Transaction__c WHERE Sample_Lot__c = :lot.Id];
        System.assertEquals('Disbursement', t.Transaction_Type__c);
        System.assertEquals('Completed', t.Status__c);
        System.assertEquals(true, t.Inventory_Applied__c);
        System.assertEquals(17, avail(lot.Id));
    }

    @isTest static void repCannotLiftAnApprovalHold() {
        User rep = SciagenTestUsers.mobileRep('sgrep3');
        Product__c p = SampleTestData.product('Hold SKU');
        Sample_Lot__c lot = repLot(p, rep, 'H-1', 20);
        Sciagen_Account__c d = SampleTestData.doctor('Dr Hold');
        // A held hand-out, as SampleDropService writes it when a limit needs a manager.
        Sample_Transaction__c held = new Sample_Transaction__c(Transaction_Type__c = 'Disbursement', Status__c = 'Pending', Requires_Approval__c = true,
            Product__c = p.Id, Sample_Lot__c = lot.Id, HCP_Account__c = d.Id, Quantity__c = 5, Performed_By__c = rep.Id, OwnerId = rep.Id);
        insert held;
        String error = updateAs(rep, new Sample_Transaction__c(Id = held.Id, Requires_Approval__c = false));
        System.assertNotEquals(null, error, 'clearing the hold must be refused');
        System.assert(error.contains('approval hold'), error);
        error = updateAs(rep, new Sample_Transaction__c(Id = held.Id, Status__c = 'Completed'));
        System.assert(error != null && error.contains('held for manager approval'), error);
        System.assertEquals(20, avail(lot.Id));
        System.assertEquals(true, [SELECT Requires_Approval__c FROM Sample_Transaction__c WHERE Id = :held.Id].Requires_Approval__c);
    }

    @isTest static void repAddingStockIsHeldForAManager() {
        User rep = SciagenTestUsers.mobileRep('sgrep4');
        User manager = SciagenTestUsers.rep('sgmgr4', new List<String>{ 'Sciagen_Mobile_App_Access', 'Sciagen_Sample_Admin' });
        Product__c p = SampleTestData.product('Adjust SKU');
        Sample_Lot__c lot = repLot(p, rep, 'A-1', 20);
        // iPad count that found 5 more packs.
        Sample_Transaction__c up = new Sample_Transaction__c(Transaction_Type__c = 'Adjustment', Status__c = 'Completed', Product__c = p.Id,
            Sample_Lot__c = lot.Id, Quantity__c = 5, Adjustment_Reason__c = 'Recount', Notes__c = 'Inventory count.', Device_Type__c = 'iPad', Client_Id__c = 'CNT-1');
        System.assertEquals(null, insertAs(rep, up), 'the iPad push itself must still succeed');
        Sample_Transaction__c saved = [SELECT Status__c, Requires_Approval__c, Inventory_Applied__c FROM Sample_Transaction__c WHERE Id = :up.Id];
        System.assertEquals('Pending', saved.Status__c);
        System.assertEquals(true, saved.Requires_Approval__c);
        System.assertEquals(20, avail(lot.Id), 'no stock until a manager approves');
        // A negative count difference applies straight away.
        System.assertEquals(null, insertAs(rep, new Sample_Transaction__c(Transaction_Type__c = 'Adjustment', Status__c = 'Completed', Product__c = p.Id,
            Sample_Lot__c = lot.Id, Quantity__c = -2, Adjustment_Reason__c = 'Recount')));
        System.assertEquals(18, avail(lot.Id));
        // The manager approves the addition (SampleAdminController.decideTransaction does the same update).
        System.assertEquals(null, updateAs(manager, new Sample_Transaction__c(Id = up.Id, Status__c = 'Completed')));
        System.assertEquals(23, avail(lot.Id));
    }

    @isTest static void repFlowsTransferReturnAndConfirmStillWork() {
        User rep = SciagenTestUsers.mobileRep('sgrep5');
        User rep2 = SciagenTestUsers.mobileRep('sgrep6');
        Product__c p = SampleTestData.product('Flow SKU');
        Sample_Lot__c lot = repLot(p, rep, 'F-1', 20);
        Sample_Warehouse__c wh = new Sample_Warehouse__c(Name = 'Depot', Warehouse_Type__c = 'Regional');
        insert wh;

        Sample_Transaction__c out = new Sample_Transaction__c(Transaction_Type__c = 'Transfer_Out', Status__c = 'Completed', Product__c = p.Id,
            Sample_Lot__c = lot.Id, Quantity__c = 4, To_User__c = rep2.Id, Device_Type__c = 'iPad', Client_Id__c = 'TO-1');
        System.assertEquals(null, insertAs(rep, out));
        System.assertEquals(16, avail(lot.Id));
        Sample_Transaction__c tin = [SELECT Id, Status__c, Quantity__c FROM Sample_Transaction__c WHERE Paired_Transaction__c = :out.Id];
        System.assertEquals('Pending', tin.Status__c);

        // The recipient can't confirm more than was sent, and only the recipient can confirm.
        String error = updateAs(rep2, new Sample_Transaction__c(Id = tin.Id, Status__c = 'Confirmed', Confirmed_Quantity__c = 40));
        System.assert(error != null && error.contains('at most'), error);
        error = updateAs(rep, new Sample_Transaction__c(Id = tin.Id, Status__c = 'Confirmed', Confirmed_Quantity__c = 4));
        System.assertNotEquals(null, error);
        System.assertEquals(null, updateAs(rep2, new Sample_Transaction__c(Id = tin.Id, Status__c = 'Confirmed', Confirmed_Quantity__c = 4)));
        Sample_Lot__c landed = [SELECT Available_Quantity__c FROM Sample_Lot__c WHERE Owner_User__c = :rep2.Id AND Lot_Number__c = 'F-1'];
        System.assertEquals(4, landed.Available_Quantity__c);

        System.assertEquals(null, insertAs(rep, new Sample_Transaction__c(Transaction_Type__c = 'Return', Status__c = 'Completed', Product__c = p.Id,
            Sample_Lot__c = lot.Id, Quantity__c = 1, Return_Reason__c = 'Excess', Return_To__c = 'Depot', To_Warehouse__c = wh.Id)));
        System.assertEquals(15, avail(lot.Id));

        // Not from someone else's lot.
        error = insertAs(rep2, new Sample_Transaction__c(Transaction_Type__c = 'Adjustment', Status__c = 'Completed', Product__c = p.Id,
            Sample_Lot__c = lot.Id, Quantity__c = -1, Adjustment_Reason__c = 'Loss'));
        System.assertNotEquals(null, error);
    }

    @isTest static void receiptsComeFromManagersAndRepsConfirmAtMostWhatWasSent() {
        User rep = SciagenTestUsers.mobileRep('sgrep7');
        Product__c p = SampleTestData.product('Receipt SKU');
        Sample_Lot__c lot = repLot(p, rep, 'R-1', 5);
        String error = insertAs(rep, new Sample_Transaction__c(Transaction_Type__c = 'Receipt', Status__c = 'Confirmed', Product__c = p.Id,
            Sample_Lot__c = lot.Id, Quantity__c = 100, To_User__c = rep.Id));
        System.assertNotEquals(null, error, 'a rep can not receipt stock into existence');

        Sample_Transaction__c rc = new Sample_Transaction__c(Transaction_Type__c = 'Receipt', Status__c = 'Pending', Product__c = p.Id,
            Sample_Lot__c = lot.Id, Quantity__c = 10, To_User__c = rep.Id);
        insert rc;   // shipment created by the sample admin (here: the admin running the test)
        error = updateAs(rep, new Sample_Transaction__c(Id = rc.Id, Quantity__c = 100));
        System.assertNotEquals(null, error, 'the rep can not raise the shipped quantity');
        error = updateAs(rep, new Sample_Transaction__c(Id = rc.Id, Status__c = 'Confirmed', Confirmed_Quantity__c = 11));
        System.assertNotEquals(null, error);
        System.assertEquals(null, updateAs(rep, new Sample_Transaction__c(Id = rc.Id, Status__c = 'Confirmed', Confirmed_Quantity__c = 9)));
        System.assertEquals(14, avail(lot.Id));
    }

    @isTest static void clientCanNotForgeLedgerBookkeeping() {
        User rep = SciagenTestUsers.mobileRep('sgrep8');
        Product__c p = SampleTestData.product('Forge SKU');
        Sample_Lot__c lot = repLot(p, rep, 'X-1', 20);
        Sample_Transaction__c t = new Sample_Transaction__c(Transaction_Type__c = 'Adjustment', Status__c = 'Cancelled', Product__c = p.Id,
            Sample_Lot__c = lot.Id, Quantity__c = -1, Adjustment_Reason__c = 'Loss', Inventory_Applied__c = true, Inventory_Effect__c = 500);
        System.assertEquals(null, insertAs(rep, t));
        System.assertEquals(20, avail(lot.Id));
        System.assertEquals(false, [SELECT Inventory_Applied__c FROM Sample_Transaction__c WHERE Id = :t.Id].Inventory_Applied__c);
    }

    @isTest static void mergeMovesSampleHistoryAndSumsExpenditure() {
        Product__c p = SampleTestData.product('Merge SKU');
        Sample_Lot__c lot = SampleTestData.lot(p, 'M-1', 50, 200);
        Sciagen_Account__c winner = SampleTestData.doctor('Dr Winner');
        Sciagen_Account__c loser = SampleTestData.doctor('Dr Loser');
        SampleTestData.given(p, lot, winner, 2);
        SampleTestData.given(p, lot, loser, 3);
        Product__c p2 = SampleTestData.product('Merge SKU 2');
        Sample_Lot__c lot2 = SampleTestData.lot(p2, 'M-2', 50, 200);
        SampleTestData.given(p2, lot2, loser, 1);          // only the loser has this product: row is re-keyed
        insert new Sample_Blocked_Attempt__c(HCP_Account__c = loser.Id, Product__c = p.Id, Quantity__c = 9, Reason_Type__c = 'Limit', Reason__c = 'Over the limit');
        Sample_Limit__c lim = new Sample_Limit__c(Name = 'per call', Limit_Scope__c = 'HCP_Product', Product__c = p.Id, Limit_Quantity__c = 5, Limit_Period__c = 'Per_Call', Hard_Block__c = false);
        insert lim;
        Sample_Limit_Override__c ov = new Sample_Limit_Override__c(Sample_Limit__c = lim.Id, Override_Type__c = 'Exempt', Target_Account__c = loser.Id, Reason__c = 'Trial', Status__c = 'Pending');
        insert ov;
        String fy = [SELECT Financial_Year__c FROM Sample_Expenditure_Tracking__c WHERE HCP_Account__c = :winner.Id LIMIT 1].Financial_Year__c;

        Test.startTest();
        DuplicateMergeService.MergeResult res = DuplicateMergeService.mergeRecords(winner.Id, loser.Id, null, 'Manual', null, null);
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM Sample_Transaction__c WHERE HCP_Account__c = :loser.Id]);
        System.assertEquals(3, [SELECT COUNT() FROM Sample_Transaction__c WHERE HCP_Account__c = :winner.Id]);
        System.assertEquals(winner.Id, [SELECT HCP_Account__c FROM Sample_Blocked_Attempt__c LIMIT 1].HCP_Account__c);
        System.assertEquals(winner.Id, [SELECT Target_Account__c FROM Sample_Limit_Override__c WHERE Id = :ov.Id].Target_Account__c);
        Sample_Expenditure_Tracking__c w1 = [SELECT Total_Packs_Given__c FROM Sample_Expenditure_Tracking__c
                                             WHERE Tracking_Key__c = :SampleExpenditureService.keyFor(fy, winner.Id, p.Id)];
        System.assertEquals(5, w1.Total_Packs_Given__c, 'the winner carries both doctors\' packs for the year');
        Sample_Expenditure_Tracking__c w2 = [SELECT HCP_Account__c, Total_Packs_Given__c FROM Sample_Expenditure_Tracking__c
                                             WHERE Tracking_Key__c = :SampleExpenditureService.keyFor(fy, winner.Id, p2.Id)];
        System.assertEquals(1, w2.Total_Packs_Given__c);
        System.assertEquals(0, [SELECT COUNT() FROM Sample_Expenditure_Tracking__c WHERE HCP_Account__c = :loser.Id AND Total_Packs_Given__c > 0]);

        DuplicateMergeService.revert(res.logId);
        System.assertEquals(2, [SELECT COUNT() FROM Sample_Transaction__c WHERE HCP_Account__c = :loser.Id]);
        System.assertEquals(2, [SELECT Total_Packs_Given__c FROM Sample_Expenditure_Tracking__c
                                WHERE Tracking_Key__c = :SampleExpenditureService.keyFor(fy, winner.Id, p.Id)].Total_Packs_Given__c);
        System.assertEquals(3, [SELECT Total_Packs_Given__c FROM Sample_Expenditure_Tracking__c
                                WHERE Tracking_Key__c = :SampleExpenditureService.keyFor(fy, loser.Id, p.Id)].Total_Packs_Given__c);
        System.assertEquals(1, [SELECT Total_Packs_Given__c FROM Sample_Expenditure_Tracking__c
                                WHERE Tracking_Key__c = :SampleExpenditureService.keyFor(fy, loser.Id, p2.Id)].Total_Packs_Given__c);
    }
}