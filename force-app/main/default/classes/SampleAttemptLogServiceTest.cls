@isTest
private class SampleAttemptLogServiceTest {

    @isTest
    static void classifiesReasonTextIntoTheRightCategory() {
        System.assertEquals('Restricted_Product', SampleAttemptLogService.classify('Foo is restricted and can not be sampled.'));
        System.assertEquals('Restricted_Product', SampleAttemptLogService.classify('a hypnotic, sedative or tranquillizer'));
        System.assertEquals('Limit', SampleAttemptLogService.classify('Limit reached: 12/12 packs this FY.'));
        System.assertEquals('Licence', SampleAttemptLogService.classify('HCP licence is unverified.'));
        System.assertEquals('Licence', SampleAttemptLogService.classify('not qualified to prescribe'));
        System.assertEquals('Cold_Chain', SampleAttemptLogService.classify('Cold chain breach detected.'));
        System.assertEquals('Signature', SampleAttemptLogService.classify('The doctor\'s signature is required.'));
        System.assertEquals('Lot_Or_Stock', SampleAttemptLogService.classify('You have no active lot to give from.'));
        System.assertEquals('Lot_Or_Stock', SampleAttemptLogService.classify('Lot X-1 has expired.'));
        System.assertEquals('Other', SampleAttemptLogService.classify('Enter a quantity above zero.'));
        System.assertEquals('Other', SampleAttemptLogService.classify(null));
    }

    @isTest
    static void publishCreatesABlockedAttemptRecordThroughTheEventTrigger() {
        Product__c p = SampleTestData.product('Attempt SKU');
        Sciagen_Account__c hcp = SampleTestData.doctor('Dr Attempt');
        Call_Visit_Report__c call = SampleTestData.call(hcp, 'Draft');
        Test.startTest();
        SampleAttemptLogService.publish(p.Id, hcp.Id, UserInfo.getUserId(), call.Id, 5, 'Limit reached: 12/12 packs this FY. Cannot distribute more.');
        Test.stopTest();

        Sample_Blocked_Attempt__c row = [SELECT Product__c, HCP_Account__c, Rep__c, Call_Report__c, Quantity__c, Reason__c, Reason_Type__c
                                          FROM Sample_Blocked_Attempt__c WHERE Call_Report__c = :call.Id];
        System.assertEquals(p.Id, row.Product__c);
        System.assertEquals(hcp.Id, row.HCP_Account__c);
        System.assertEquals(UserInfo.getUserId(), row.Rep__c);
        System.assertEquals(5, row.Quantity__c);
        System.assertEquals('Limit', row.Reason_Type__c);
        System.assert(row.Reason__c.startsWith('Limit reached'), row.Reason__c);
    }

    @isTest
    static void logSkipsInvalidIdsWithoutThrowing() {
        Sample_Attempt__e e = new Sample_Attempt__e(Product_Id__c = null, HCP_Id__c = 'not-a-real-id', Rep_Id__c = UserInfo.getUserId(),
            Call_Id__c = null, Quantity__c = 1, Reason__c = 'test', Reason_Type__c = 'Other');
        SampleAttemptLogService.log(new List<Sample_Attempt__e>{ e });
        Sample_Blocked_Attempt__c row = [SELECT Product__c, HCP_Account__c, Rep__c FROM Sample_Blocked_Attempt__c WHERE Rep__c = :UserInfo.getUserId() LIMIT 1];
        System.assertEquals(null, row.Product__c);
        System.assertEquals(null, row.HCP_Account__c, 'an invalid Id string must not throw, just come through as null');
        System.assertEquals(UserInfo.getUserId(), row.Rep__c);
    }
}
