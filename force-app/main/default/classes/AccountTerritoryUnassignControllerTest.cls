@isTest
private class AccountTerritoryUnassignControllerTest {

    private static Sciagen_Account__c makeAssigned(Territory__c territory) {
        Sciagen_Account__c hcp = new Sciagen_Account__c(
            Type__c = 'HCP', Name = 'Dr. Web Unassign', Prefix__c = 'Dr.', First_Name__c = 'Web',
            Last_Name__c = 'Unassign', Specialty__c = 'Cardiology', HCP_Type__c = 'Physician'
        );
        insert hcp;
        delete [SELECT Id FROM Account_Territory__c WHERE Account__c = :hcp.Id];
        insert new Account_Territory__c(Name = 'Test', Account__c = hcp.Id, Territory__c = territory.Id);
        return hcp;
    }

    @isTest
    static void unassigningFilesAPendingRequestKeepsTheLinkAndTheAccount() {
        Territory__c mine = new Territory__c(Name = 'Web Mine', Territory_Code__c = 'WMN', Type__c = 'Territory');
        insert mine;
        insert new User_Territory__c(User__c = UserInfo.getUserId(), Territory__c = mine.Id, Is_Primary__c = false);
        Sciagen_Account__c hcp = makeAssigned(mine);

        Test.startTest();
        AccountTerritoryUnassignController.UnassignOutcome outcome =
            AccountTerritoryUnassignController.unassignFromMyTerritory(hcp.Id, 'Moved out of area');
        Test.stopTest();

        System.assertEquals(true, outcome.success);
        System.assertEquals(false, outcome.immediate, 'Must go through review, not remove the link on the spot');
        System.assert(outcome.message.contains('submitted for review'), 'Got: ' + outcome.message);
        System.assertEquals(1, [SELECT COUNT() FROM Account_Territory__c WHERE Account__c = :hcp.Id],
            'The link stays in place until a steward approves the request');
        System.assertEquals(1, [SELECT COUNT() FROM Sciagen_Account__c WHERE Id = :hcp.Id], 'The account itself must never be deleted');
        Data_Change_Request__c dcr = [SELECT Type__c, Status__c FROM Data_Change_Request__c WHERE Subject_Account__c = :hcp.Id];
        System.assertEquals('Territory Unassign', dcr.Type__c);
        System.assertEquals('Pending Approval', dcr.Status__c);
    }

    @isTest
    static void aBlankReasonIsRejectedWithAReadableMessage() {
        Territory__c mine = new Territory__c(Name = 'Web Mine', Territory_Code__c = 'WMN', Type__c = 'Territory');
        insert mine;
        insert new User_Territory__c(User__c = UserInfo.getUserId(), Territory__c = mine.Id, Is_Primary__c = false);
        Sciagen_Account__c hcp = makeAssigned(mine);

        try {
            AccountTerritoryUnassignController.unassignFromMyTerritory(hcp.Id, '  ');
            System.assert(false, 'Expected a blank reason to be rejected');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('comment'), 'Got: ' + e.getMessage());
        }
        System.assertEquals(1, [SELECT COUNT() FROM Account_Territory__c WHERE Account__c = :hcp.Id]);
    }

    @isTest
    static void anAccountOutsideTheCallersTerritoriesIsRejected() {
        Territory__c other = new Territory__c(Name = 'Web Other', Territory_Code__c = 'WOT', Type__c = 'Territory');
        insert other;
        Sciagen_Account__c hcp = makeAssigned(other);

        try {
            AccountTerritoryUnassignController.unassignFromMyTerritory(hcp.Id, 'Not mine');
            System.assert(false, 'Expected an account outside my territory to be rejected');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('not assigned to your territory'), 'Got: ' + e.getMessage());
        }
        System.assertEquals(1, [SELECT COUNT() FROM Account_Territory__c WHERE Account__c = :hcp.Id]);
    }
}