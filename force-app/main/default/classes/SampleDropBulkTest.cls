/**
 * QA-49 / H8: sample lines are checked in bulk. 20 lines in one insert, across several doctors,
 * calls and products with the default UCPMP / company limits active, stay within a small fixed
 * number of queries, and the answers match the single-line path.
 */
@isTest
private class SampleDropBulkTest {

    @isTest static void twentyLinesInOneInsertUseAFixedNumberOfQueries() {
        SampleLimitSeeder.seedDefaults();
        insert new Sample_Limit__c(Name = 'rep per product per month', Limit_Scope__c = 'Rep_Product', Limit_Quantity__c = 500,
            Limit_Period__c = 'Monthly', Hard_Block__c = true);
        List<Product__c> products = new List<Product__c>();
        for (Integer i = 0; i < 4; i++) products.add(SampleTestData.product('Bulk SKU ' + i));
        for (Product__c p : products) SampleTestData.lot(p, 'BULK-' + p.Id, 500, 200);
        List<Call_Visit_Report__c> calls = new List<Call_Visit_Report__c>();
        for (Integer i = 0; i < 5; i++) {
            Sciagen_Account__c d = SampleTestData.doctor('Dr Bulk ' + i);
            calls.add(new Call_Visit_Report__c(HCP__c = d.Id, Visit_Date__c = Date.today(), Start_Time__c = System.now(),
                Call_Type__c = 'Detailing', Call_Status__c = 'Completed', Record_Status__c = 'Draft'));
        }
        insert calls;
        // One doctor already had 11 of their 12 FY packs of product 0: the 13th must be refused in bulk too.
        Sample_Lot__c lot0 = [SELECT Id FROM Sample_Lot__c WHERE Product__c = :products[0].Id LIMIT 1];
        SampleTestData.given(products[0], lot0, new Sciagen_Account__c(Id = calls[0].HCP__c), 11);

        List<Sample_Drop__c> lines = new List<Sample_Drop__c>();
        for (Integer c = 0; c < calls.size(); c++) {
            for (Integer p = 0; p < products.size(); p++) {
                lines.add(new Sample_Drop__c(Name = 'Sample Drop', CVR__c = calls[c].Id, Product__c = products[p].Id, Qty__c = 1));
            }
        }
        System.assertEquals(20, lines.size());
        lines[0].Qty__c = 2;   // call 0 / product 0: 11 given + 2 > 12

        Test.startTest();
        Integer before = Limits.getQueries();
        List<Database.SaveResult> results = Database.insert(lines, false);
        Integer used = Limits.getQueries() - before;
        Test.stopTest();

        System.assert(used <= 30, 'bulk check should use a fixed number of queries, used ' + used);
        System.assertEquals(false, results[0].isSuccess(), 'UCPMP 12-pack limit still enforced in bulk');
        System.assert(results[0].getErrors()[0].getMessage().contains('UCPMP'), results[0].getErrors()[0].getMessage());
        for (Integer i = 1; i < results.size(); i++) System.assert(results[i].isSuccess(), String.valueOf(results[i].getErrors()));
        System.assertEquals(19, [SELECT COUNT() FROM Sample_Drop__c WHERE Eligibility_Status__c != 'Blocked']);
        for (Sample_Drop__c d : [SELECT Sample_Lot__c, Unit_Value__c FROM Sample_Drop__c]) {
            System.assertNotEquals(null, d.Sample_Lot__c, 'each line got its lot');
        }
    }
}