@isTest
private class SampleLotServiceTest {

    static Product__c sampleProduct() {
        Product__c p = new Product__c(Name = 'Test Sample SKU', Product_Code__c = 'SMP-LOT-TEST', Level__c = 'SKU', Is_Sample_Product__c = true, Sample_Unit_Value_INR__c = 10, Pack_Size__c = 4);
        insert p;
        return p;
    }

    static Sample_Lot__c lot(Product__c p, String lotNo, Integer initial, Integer available) {
        return new Sample_Lot__c(Product__c = p.Id, Lot_Number__c = lotNo, Expiry_Date__c = Date.today().addDays(90),
            Initial_Quantity__c = initial, Available_Quantity__c = available, Owner_User__c = UserInfo.getUserId());
    }

    @isTest
    static void keyOwnerAndStatusAreSetOnInsert() {
        Product__c p = sampleProduct();
        Sample_Lot__c a = lot(p, 'ab-1', 20, 20);
        Sample_Lot__c b = lot(p, 'ab-2', 20, 0);
        insert new List<Sample_Lot__c>{ a, b };
        a = [SELECT Lot_Key__c, Status__c, OwnerId FROM Sample_Lot__c WHERE Id = :a.Id];
        b = [SELECT Status__c FROM Sample_Lot__c WHERE Id = :b.Id];
        System.assertEquals('Active', a.Status__c);
        System.assertEquals('Depleted', b.Status__c, 'a lot with nothing on hand starts depleted until its receipt is confirmed');
        System.assert(a.Lot_Key__c.contains('AB-1'));
        System.assertEquals(UserInfo.getUserId(), a.OwnerId);
    }

    @isTest
    static void sameLotNumberCannotBeUsedTwiceByOneHolder() {
        Product__c p = sampleProduct();
        insert lot(p, 'DUP-1', 10, 10);
        Database.SaveResult r = Database.insert(lot(p, 'dup-1', 10, 10), false);
        System.assert(!r.isSuccess(), 'duplicate lot number for the same product and holder must be refused');
    }

    @isTest
    static void statusFollowsAvailableQuantity() {
        Product__c p = sampleProduct();
        Sample_Lot__c l = lot(p, 'FLIP-1', 10, 10);
        insert l;
        l.Available_Quantity__c = 0;
        update l;
        System.assertEquals('Depleted', [SELECT Status__c FROM Sample_Lot__c WHERE Id = :l.Id].Status__c);
        l.Available_Quantity__c = 5;
        update l;
        System.assertEquals('Active', [SELECT Status__c FROM Sample_Lot__c WHERE Id = :l.Id].Status__c);
    }

    @isTest
    static void validationRulesHold() {
        Product__c p = sampleProduct();
        Sample_Lot__c past = lot(p, 'OLD-1', 10, 10);
        past.Expiry_Date__c = Date.today().addDays(-1);
        System.assert(!Database.insert(past, false).isSuccess(), 'a new lot must expire in the future');
        Sample_Lot__c neg = lot(p, 'NEG-1', 10, -1);
        System.assert(!Database.insert(neg, false).isSuccess(), 'available quantity can not be negative');
        Sample_Lot__c zero = lot(p, 'ZERO-1', 0, 0);
        System.assert(!Database.insert(zero, false).isSuccess(), 'initial quantity must be positive');
    }

    @isTest
    static void expiryBatchExpiresOnlyLapsedActiveLots() {
        Product__c p = sampleProduct();
        Sample_Lot__c lapsed = lot(p, 'LAPSE-1', 10, 10);
        Sample_Lot__c fine = lot(p, 'FINE-1', 10, 10);
        insert new List<Sample_Lot__c>{ lapsed, fine };
        lapsed.Expiry_Date__c = Date.today().addDays(-2);
        update lapsed;
        Test.startTest();
        Database.executeBatch(new SampleLotExpiryBatch(), 200);
        Test.stopTest();
        System.assertEquals('Expired', [SELECT Status__c FROM Sample_Lot__c WHERE Id = :lapsed.Id].Status__c);
        System.assertEquals('Active', [SELECT Status__c FROM Sample_Lot__c WHERE Id = :fine.Id].Status__c);
    }

    @isTest
    static void expiryBatchCanBeScheduled() {
        Test.startTest();
        Id jobId = SampleLotExpiryBatch.schedule();
        Test.stopTest();
        System.assertNotEquals(null, jobId);
    }

    @isTest
    static void territoryIsStampedOnLotsAndTransactions() {
        Territory__c t = new Territory__c(Name = 'Bengaluru North', Territory_Code__c = 'BLRN', Type__c = 'Territory');
        insert t;
        insert new User_Territory__c(User__c = UserInfo.getUserId(), Territory__c = t.Id, Is_Primary__c = true);
        Product__c p = SampleTestData.product('Territory Product');
        Sample_Lot__c lot = SampleTestData.lot(p, 'TERR-1', 10, 200);
        lot = [SELECT Rep_Territory__c FROM Sample_Lot__c WHERE Id = :lot.Id];
        System.assertEquals('Bengaluru North', lot.Rep_Territory__c);

        Sample_Transaction__c txn = new Sample_Transaction__c(Transaction_Type__c = 'Disbursement', Sample_Lot__c = lot.Id, Product__c = p.Id, Quantity__c = 1,
            HCP_Account__c = SampleTestData.doctor('Dr Territory').Id, Performed_By__c = UserInfo.getUserId());
        insert txn;
        System.assertEquals('Bengaluru North', [SELECT Rep_Territory__c FROM Sample_Transaction__c WHERE Id = :txn.Id].Rep_Territory__c);
    }
}