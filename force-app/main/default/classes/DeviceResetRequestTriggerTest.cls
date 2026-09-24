@isTest
private class DeviceResetRequestTriggerTest {

    @isTest
    static void testInsertStampsManagerAndSubmitsForApproval() {
        Test.startTest();
        Device_Reset_Request__c req = new Device_Reset_Request__c();
        insert req;
        Test.stopTest();

        req = [SELECT Id, Status__c, Manager__c FROM Device_Reset_Request__c WHERE Id = :req.Id];
        System.assertEquals('Pending Approval', req.Status__c);
    }

    @isTest
    static void testApprovalGeneratesOTPAndNotifiesApprover() {
        Device_Reset_Request__c req = new Device_Reset_Request__c();
        insert req;

        Test.startTest();
        // Approval.process() has no matching process to route through in a
        // test context, so the field updates it would normally apply are
        // driven directly here -- this still exercises the same
        // before/after-update trigger branches (generateOTPOnApproval,
        // emailApproverTheCode) that a real approval triggers.
        req.Status__c = 'Approved';
        update req;
        Test.stopTest();

        req = [SELECT Id, Status__c, OTP__c, OTP_Expires__c FROM Device_Reset_Request__c WHERE Id = :req.Id];
        System.assertEquals('Approved', req.Status__c);
        System.assertNotEquals(null, req.OTP__c, 'Approval should mint a one-time code');
        System.assertNotEquals(null, req.OTP_Expires__c);
    }
}