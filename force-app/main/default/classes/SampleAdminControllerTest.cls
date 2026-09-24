@isTest
private class SampleAdminControllerTest {

    @testSetup
    static void users() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User rep = new User(FirstName = 'Admin', LastName = 'Rep SampleAdminTest', Alias = 'sadm', Email = 'admin.rep.sample@sciagen-test.invalid',
            Username = 'admin.rep.sample@sciagen-new-dev.invalid', TimeZoneSidKey = 'Asia/Kolkata', LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US', ProfileId = p.Id, IsActive = true);
        insert rep;
        insert new PermissionSetAssignment(AssigneeId = rep.Id, PermissionSetId = [SELECT Id FROM PermissionSet WHERE Name = 'Sciagen_Mobile_App_Access'].Id);
    }

    static User rep() { return [SELECT Id, Username FROM User WHERE Username = 'admin.rep.sample@sciagen-new-dev.invalid']; }

    @isTest
    static void filtersAndLotsAreListedForTheAdmin() {
        Product__c p = SampleTestData.product('Admin SKU');
        Sample_Lot__c mine = SampleTestData.lot(p, 'AD-1', 20, 10);
        Sample_Lot__c later = SampleTestData.lot(p, 'AD-2', 20, 300);
        SampleAdminController.FilterOptions o = SampleAdminController.getFilterOptions();
        System.assertEquals(true, o.canManage);
        System.assert(!o.products.isEmpty());
        System.assertEquals(2, SampleAdminController.getLots(p.Id, null, null, null, null).size());
        System.assertEquals(1, SampleAdminController.getLots(p.Id, null, null, null, 30).size(), 'only the lot expiring within 30 days');
        System.assertEquals(2, SampleAdminController.getLots(null, UserInfo.getUserId(), null, 'Active', null).size());
        System.assertEquals(0, SampleAdminController.getLots(null, null, null, 'Recalled', null).size());
        SampleAdminController.LotRow r = SampleAdminController.getLots(p.Id, null, null, null, 30)[0];
        System.assertEquals('AD-1', r.lotNumber);
        System.assertEquals(20, r.available);
    }

    @isTest
    static void territoryFilterFollowsTheRepsInIt() {
        Product__c p = SampleTestData.product('Terr SKU');
        SampleTestData.lot(p, 'TR-1', 5, 100);
        Territory__c t = new Territory__c(Name = 'Admin North', Type__c = 'Territory');
        insert t;
        System.assertEquals(0, SampleAdminController.getLots(null, null, t.Id, null, null).size());
        insert new User_Territory__c(User__c = UserInfo.getUserId(), Territory__c = t.Id, Is_Primary__c = true);
        System.assertEquals(1, SampleAdminController.getLots(null, null, t.Id, null, null).size());
    }

    @isTest
    static void bulkRecallQuarantineAndReactivate() {
        Product__c p = SampleTestData.product('Bulk SKU');
        Sample_Lot__c a = SampleTestData.lot(p, 'BK-1', 20, 100);
        Sample_Lot__c b = SampleTestData.lot(p, 'BK-2', 20, 100);
        System.assertEquals(2, SampleAdminController.bulkSetStatus(new List<Id>{ a.Id, b.Id }, 'Recalled'));
        System.assertEquals('Recalled', [SELECT Status__c FROM Sample_Lot__c WHERE Id = :a.Id].Status__c);
        SampleAdminController.bulkSetStatus(new List<Id>{ a.Id }, 'Quarantined');
        System.assertEquals('Quarantined', [SELECT Status__c FROM Sample_Lot__c WHERE Id = :a.Id].Status__c);
        SampleAdminController.bulkSetStatus(new List<Id>{ a.Id }, 'Active');
        System.assertEquals('Active', [SELECT Status__c FROM Sample_Lot__c WHERE Id = :a.Id].Status__c);
        try { SampleAdminController.bulkSetStatus(new List<Id>{ a.Id }, 'Depleted'); System.assert(false); } catch (AuraHandledException e) { System.assert(true); }
        try { SampleAdminController.bulkSetStatus(new List<Id>(), 'Recalled'); System.assert(false); } catch (AuraHandledException e) { System.assert(true); }
    }

    @isTest
    static void bulkTransferMovesTheWholeBalanceAndLeavesItPendingForTheRecipient() {
        Product__c p = SampleTestData.product('Move SKU');
        Sample_Lot__c l = SampleTestData.lot(p, 'MV-1', 20, 100);
        Sample_Lot__c empty = SampleTestData.lot(p, 'MV-0', 5, 100);
        empty.Available_Quantity__c = 0;
        update empty;
        List<SampleAdminController.RowResult> res = SampleAdminController.bulkTransfer(new List<Id>{ l.Id, empty.Id }, rep().Id);
        Integer ok = 0;
        for (SampleAdminController.RowResult r : res) if (r.ok) ok++;
        String detail = '';
        for (SampleAdminController.RowResult r : res) detail += r.message + ' | ';
        System.assertEquals(1, ok, detail);
        System.assertEquals(0, [SELECT Available_Quantity__c FROM Sample_Lot__c WHERE Id = :l.Id].Available_Quantity__c);
        System.assertEquals(1, [SELECT COUNT() FROM Sample_Transaction__c WHERE Transaction_Type__c = 'Transfer_In' AND Status__c = 'Pending' AND To_User__c = :rep().Id]);
        System.assertEquals(1, SampleAdminController.getPendingReceipts().size());
    }

    @isTest
    static void shipmentsCreateALotAndAPendingReceiptAndReportRowProblems() {
        Product__c p = SampleTestData.product('Ship SKU');
        p.SKU_Code__c = 'SHIP-1';
        update p;
        Sample_Warehouse__c w = new Sample_Warehouse__c(Name = 'Ship Depot', Warehouse_Type__c = 'Central');
        insert w;
        SampleAdminController.ShipmentInput good = new SampleAdminController.ShipmentInput();
        good.repUsername = rep().Username; good.skuCode = 'SHIP-1'; good.lotNumber = 'SH-100'; good.batchLotId = 'BAT-100';
        good.expiry = String.valueOf(Date.today().addDays(200)); good.quantity = 25; good.warehouseName = 'Ship Depot'; good.shipmentRef = 'SHIP-001';
        SampleAdminController.ShipmentInput noRep = new SampleAdminController.ShipmentInput();
        noRep.repUsername = 'nobody@nowhere.invalid'; noRep.skuCode = 'SHIP-1'; noRep.lotNumber = 'X'; noRep.expiry = String.valueOf(Date.today().addDays(9)); noRep.quantity = 1;
        SampleAdminController.ShipmentInput pastExpiry = new SampleAdminController.ShipmentInput();
        pastExpiry.repUsername = rep().Username; pastExpiry.skuCode = 'SHIP-1'; pastExpiry.lotNumber = 'Y'; pastExpiry.expiry = '2020-01-01'; pastExpiry.quantity = 1;
        SampleAdminController.ShipmentInput noSku = new SampleAdminController.ShipmentInput();
        noSku.repUsername = rep().Username; noSku.skuCode = 'NOPE'; noSku.lotNumber = 'Z'; noSku.expiry = String.valueOf(Date.today().addDays(9)); noSku.quantity = 1;

        List<SampleAdminController.RowResult> res = SampleAdminController.createShipments(new List<SampleAdminController.ShipmentInput>{ good, noRep, pastExpiry, noSku });
        System.assertEquals(true, res[0].ok, res[0].message);
        System.assertEquals(false, res[1].ok);
        System.assert(res[1].message.contains('Rep not found'));
        System.assert(res[2].message.contains('future date'));
        System.assert(res[3].message.contains('product not found'));
        Sample_Lot__c lot = [SELECT Available_Quantity__c, Status__c, Initial_Quantity__c, OwnerId FROM Sample_Lot__c WHERE Lot_Number__c = 'SH-100'];
        System.assertEquals(0, lot.Available_Quantity__c);
        System.assertEquals(25, lot.Initial_Quantity__c);
        System.assertEquals(rep().Id, lot.OwnerId, 'the rep owns the lot');
        List<SampleAdminController.TxnRow> pending = SampleAdminController.getPendingReceipts();
        System.assertEquals(1, pending.size());
        System.assertEquals('SHIP-001', pending[0].shipmentRef);
    }

    @isTest
    static void transactionLogFiltersByTypeStatusProductAndDoctor() {
        Product__c p = SampleTestData.product('Log SKU');
        Sciagen_Account__c d = SampleTestData.doctor('Dr Log Filter');
        Sample_Lot__c l = SampleTestData.lot(p, 'LG-1', 50, 100);
        SampleTestData.given(p, l, d, 2);
        System.assertEquals(1, SampleAdminController.getTransactions('Disbursement', 'Completed', null, p.Id, 'Log Filter', String.valueOf(Date.today().addDays(-1)), String.valueOf(Date.today())).size());
        System.assertEquals(0, SampleAdminController.getTransactions('Return', null, null, null, null, null, null).size());
        SampleAdminController.TxnRow r = SampleAdminController.getTransactions(null, null, UserInfo.getUserId(), null, null, null, null)[0];
        System.assertEquals('Disbursement', r.type);
        System.assertEquals('Dr Log Filter', r.hcpName);
    }

    @isTest
    static void discrepancyReportFlagsBigCountDifferencesAndUnbookedGifts() {
        Product__c p = SampleTestData.product('Disc SKU');
        Sciagen_Account__c d = SampleTestData.doctor('Dr Disc');
        Sample_Lot__c l = SampleTestData.lot(p, 'DS-1', 20, 100);
        insert new Sample_Transaction__c(Transaction_Type__c = 'Adjustment', Status__c = 'Completed', Product__c = p.Id, Sample_Lot__c = l.Id, Quantity__c = -5,
            Adjustment_Reason__c = 'Recount', Notes__c = 'Inventory count. Counted 15, system had 20');
        insert new Sample_Transaction__c(Transaction_Type__c = 'Adjustment', Status__c = 'Completed', Product__c = p.Id, Sample_Lot__c = l.Id, Quantity__c = 1, Adjustment_Reason__c = 'Correction');
        SampleTestData.given(p, l, d, 30);   // more than the lot holds
        Map<String, SampleAdminController.Discrepancy> byKind = new Map<String, SampleAdminController.Discrepancy>();
        Integer flagged = 0;
        for (SampleAdminController.Discrepancy x : SampleAdminController.getDiscrepancies()) {
            byKind.put(x.kind, x);
            if (x.flagged) flagged++;
        }
        System.assert(byKind.containsKey('Count difference'));
        System.assertEquals(25.0, byKind.get('Count difference').percentOfLot);
        System.assertEquals(true, byKind.get('Count difference').flagged);
        System.assert(byKind.containsKey('Adjustment'));
        System.assertEquals(false, byKind.get('Adjustment').flagged, '1 of 20 is 5%');
        System.assert(byKind.containsKey('Given without stock on the books'));
        System.assertEquals(2, flagged);
    }

    @isTest
    static void managerApprovesOrRejectsHeldTransactionsAndOverrideRequests() {
        SampleLimitSeeder.seedDefaults();
        Product__c p = SampleTestData.product('Appr SKU');
        Sciagen_Account__c d = SampleTestData.doctor('Dr Approve');
        Sample_Lot__c l = SampleTestData.lot(p, 'AP-1', 50, 100);
        Sample_Transaction__c held = new Sample_Transaction__c(Transaction_Type__c = 'Disbursement', Status__c = 'Pending', Requires_Approval__c = true, Product__c = p.Id, Sample_Lot__c = l.Id,
            HCP_Account__c = d.Id, Quantity__c = 4, Override_Reason__c = 'Clinic day');
        insert held;
        Sample_Limit__c perCall = [SELECT Id FROM Sample_Limit__c WHERE Limit_Scope__c = 'Per_Call'];
        Sample_Limit_Override__c req = new Sample_Limit_Override__c(Sample_Limit__c = perCall.Id, Override_Type__c = 'Exempt', Target_Account__c = d.Id, Reason__c = 'Trial site', Status__c = 'Pending');
        insert req;
        SampleAdminController.Approvals a = SampleAdminController.getApprovals();
        System.assertEquals(1, a.heldTransactions.size());
        System.assertEquals('Clinic day', a.heldTransactions[0].note);
        System.assertEquals(1, a.overrides.size());
        System.assertEquals('Dr Approve', a.overrides[0].target);

        SampleAdminController.decideTransaction(held.Id, true);
        System.assertEquals('Completed', [SELECT Status__c FROM Sample_Transaction__c WHERE Id = :held.Id].Status__c);
        System.assertEquals(46, [SELECT Available_Quantity__c FROM Sample_Lot__c WHERE Id = :l.Id].Available_Quantity__c);
        try { SampleAdminController.decideTransaction(held.Id, true); System.assert(false); } catch (AuraHandledException e) { System.assert(true); }

        SampleAdminController.decideOverride(req.Id, true);
        System.assertEquals('Active', [SELECT Status__c FROM Sample_Limit_Override__c WHERE Id = :req.Id].Status__c);
        try { SampleAdminController.decideOverride(req.Id, false); System.assert(false); } catch (AuraHandledException e) { System.assert(true); }
        System.assertEquals(0, SampleAdminController.getApprovals().overrides.size());
    }

    @isTest
    static void rejectingAHeldTransactionLeavesStockAlone() {
        Product__c p = SampleTestData.product('Reject Held SKU');
        Sciagen_Account__c d = SampleTestData.doctor('Dr Reject Held');
        Sample_Lot__c l = SampleTestData.lot(p, 'RH-1', 30, 100);
        Sample_Transaction__c held = new Sample_Transaction__c(Transaction_Type__c = 'Disbursement', Status__c = 'Pending', Requires_Approval__c = true, Product__c = p.Id, Sample_Lot__c = l.Id,
            HCP_Account__c = d.Id, Quantity__c = 3);
        insert held;
        SampleAdminController.decideTransaction(held.Id, false);
        System.assertEquals('Rejected', [SELECT Status__c FROM Sample_Transaction__c WHERE Id = :held.Id].Status__c);
        System.assertEquals(30, [SELECT Available_Quantity__c FROM Sample_Lot__c WHERE Id = :l.Id].Available_Quantity__c);
    }
}