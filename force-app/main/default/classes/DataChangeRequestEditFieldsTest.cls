@isTest
private class DataChangeRequestEditFieldsTest {
    @isTest
    static void approvingEditHCP_appliesWebFormFieldsOnlyOnApproval() {
        Sciagen_Account__c hcp = new Sciagen_Account__c(Name = 'Dr. Edit Test', Type__c = 'HCP', First_Name__c = 'Edit', Last_Name__c = 'Test', Billing_City__c = 'Delhi');
        insert hcp;
        Data_Change_Request__c dcr = new Data_Change_Request__c(
            Type__c = 'Edit HCP', Status__c = 'Pending Approval', Subject_Account__c = hcp.Id, Subject_Name__c = hcp.Name,
            Fields_Payload__c = JSON.serialize(new Map<String, Object>{
                'city' => new Map<String, Object>{ 'current' => 'Delhi', 'requested' => 'Pune' },
                'street' => new Map<String, Object>{ 'current' => '', 'requested' => '12 MG Road' },
                'licenseNumber' => new Map<String, Object>{ 'current' => '', 'requested' => 'LIC-77' }
            }),
            Submitted_At__c = Datetime.now());
        insert dcr;
        System.assertEquals('Delhi', [SELECT Billing_City__c FROM Sciagen_Account__c WHERE Id = :hcp.Id].Billing_City__c, 'Nothing changes before approval');

        dcr.Status__c = 'Approved';
        update dcr;
        Sciagen_Account__c after = [SELECT Billing_City__c, Billing_Street__c, License_Number__c FROM Sciagen_Account__c WHERE Id = :hcp.Id];
        System.assertEquals('Pune', after.Billing_City__c);
        System.assertEquals('12 MG Road', after.Billing_Street__c);
        System.assertEquals('LIC-77', after.License_Number__c);
    }
}