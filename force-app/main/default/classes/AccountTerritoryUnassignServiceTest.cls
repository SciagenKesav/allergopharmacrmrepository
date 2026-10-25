@isTest
private class AccountTerritoryUnassignServiceTest {

    private static Sciagen_Account__c makeAssignedHCP(Territory__c territory) {
        Sciagen_Account__c hcp = new Sciagen_Account__c(
            Type__c = 'HCP', Name = 'Dr. Unassign Me', Prefix__c = 'Dr.', First_Name__c = 'Unassign',
            Last_Name__c = 'Me', Specialty__c = 'Cardiology', HCP_Type__c = 'Physician'
        );
        insert hcp;
        delete [SELECT Id FROM Account_Territory__c WHERE Account__c = :hcp.Id];
        insert new Account_Territory__c(Name = 'Test', Account__c = hcp.Id, Territory__c = territory.Id);
        return hcp;
    }

    @isTest
    static void filesAPendingRequestWithoutTouchingTheLinkYet() {
        Territory__c mine = new Territory__c(Name = 'Mine', Territory_Code__c = 'MIN', Type__c = 'Territory');
        Territory__c other = new Territory__c(Name = 'Other', Territory_Code__c = 'OTH', Type__c = 'Territory');
        insert new List<Territory__c>{ mine, other };
        insert new User_Territory__c(User__c = UserInfo.getUserId(), Territory__c = mine.Id, Is_Primary__c = false);
        Sciagen_Account__c hcp = makeAssignedHCP(mine);
        insert new Account_Territory__c(Name = 'Other', Account__c = hcp.Id, Territory__c = other.Id);

        Test.startTest();
        Map<String, Object> result = AccountTerritoryUnassignService.unassign(hcp.Id, '  Moved out of area ', UserInfo.getUserId());
        Test.stopTest();

        System.assertEquals(true, result.get('success'));
        System.assertEquals(false, result.get('immediate'), 'The link must not be removed until a steward approves the request');
        System.assertEquals(2, [SELECT COUNT() FROM Account_Territory__c WHERE Account__c = :hcp.Id],
            'Both links (the caller\'s and the other territory\'s) must still be in place — nothing is removed at request time');

        Data_Change_Request__c dcr = [SELECT Type__c, Status__c, Summary__c, Subject_Account__c, Fields_Payload__c FROM Data_Change_Request__c WHERE Subject_Account__c = :hcp.Id];
        System.assertEquals('Territory Unassign', dcr.Type__c);
        System.assertEquals('Pending Approval', dcr.Status__c, 'Must route through review like every other DCR type, not auto-approve');
        System.assertEquals('Moved out of area', dcr.Summary__c);

        Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(dcr.Fields_Payload__c);
        List<Object> territoryIds = (List<Object>) payload.get('territoryIds');
        System.assertEquals(1, territoryIds.size(), 'Only the caller\'s own territory link, not the other one');
        System.assertEquals(mine.Id, (Id) String.valueOf(territoryIds[0]));

        System.assertEquals(1, [SELECT COUNT() FROM Sciagen_Account__c WHERE Id = :hcp.Id]);
    }

    @isTest
    static void approvingTheRequestThenRemovesOnlyThatTerritoryLink() {
        Territory__c mine = new Territory__c(Name = 'Mine', Territory_Code__c = 'MIN', Type__c = 'Territory');
        Territory__c other = new Territory__c(Name = 'Other', Territory_Code__c = 'OTH', Type__c = 'Territory');
        insert new List<Territory__c>{ mine, other };
        insert new User_Territory__c(User__c = UserInfo.getUserId(), Territory__c = mine.Id, Is_Primary__c = false);
        Sciagen_Account__c hcp = makeAssignedHCP(mine);
        insert new Account_Territory__c(Name = 'Other', Account__c = hcp.Id, Territory__c = other.Id);
        AccountTerritoryUnassignService.unassign(hcp.Id, 'Moved out of area', UserInfo.getUserId());
        Data_Change_Request__c dcr = [SELECT Id FROM Data_Change_Request__c WHERE Subject_Account__c = :hcp.Id];

        Test.startTest();
        // A different user approves — DataChangeRequestApprovalHandler already forbids a
        // steward approving their own request, exercised generically elsewhere.
        System.runAs(adminUser()) {
            update new Data_Change_Request__c(Id = dcr.Id, Status__c = 'Approved');
        }
        Test.stopTest();

        List<Account_Territory__c> remaining = [SELECT Territory__c FROM Account_Territory__c WHERE Account__c = :hcp.Id];
        System.assertEquals(1, remaining.size(), 'Only the approved territory\'s link is removed');
        System.assertEquals(other.Id, remaining[0].Territory__c);
    }

    @isTest
    static void rejectingTheRequestLeavesTheLinkInPlace() {
        Territory__c mine = new Territory__c(Name = 'Mine', Territory_Code__c = 'MIN', Type__c = 'Territory');
        insert mine;
        insert new User_Territory__c(User__c = UserInfo.getUserId(), Territory__c = mine.Id, Is_Primary__c = false);
        Sciagen_Account__c hcp = makeAssignedHCP(mine);
        AccountTerritoryUnassignService.unassign(hcp.Id, 'Moved out of area', UserInfo.getUserId());
        Data_Change_Request__c dcr = [SELECT Id FROM Data_Change_Request__c WHERE Subject_Account__c = :hcp.Id];

        Test.startTest();
        System.runAs(adminUser()) {
            update new Data_Change_Request__c(Id = dcr.Id, Status__c = 'Rejected', Rejection_Reason__c = 'Still active here');
        }
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM Account_Territory__c WHERE Account__c = :hcp.Id]);
    }

    private static User adminUser() {
        Profile adminProfile = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];
        String uniq = 'dcrsteward.' + Datetime.now().getTime();
        User u = new User(
            FirstName = 'DCR', LastName = 'Steward',
            Email = uniq + '@sciagen.invalid', Username = uniq + '@sciagen.invalid',
            Alias = 'dcrstw', TimeZoneSidKey = 'Asia/Kolkata', LocaleSidKey = 'en_IN',
            EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US', ProfileId = adminProfile.Id
        );
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert u;
        }
        return u;
    }

    @isTest
    static void rejectsABlankComment() {
        Territory__c mine = new Territory__c(Name = 'Mine', Territory_Code__c = 'MIN', Type__c = 'Territory');
        insert mine;
        insert new User_Territory__c(User__c = UserInfo.getUserId(), Territory__c = mine.Id, Is_Primary__c = false);
        Sciagen_Account__c hcp = makeAssignedHCP(mine);
        try {
            AccountTerritoryUnassignService.unassign(hcp.Id, '   ', UserInfo.getUserId());
            System.assert(false, 'Expected a blank comment to be rejected');
        } catch (AccountTerritoryUnassignService.UnassignException e) {
            System.assert(e.getMessage().contains('comment'));
        }
        System.assertEquals(1, [SELECT COUNT() FROM Account_Territory__c WHERE Account__c = :hcp.Id]);
    }

    @isTest
    static void rejectsAnAccountOutsideTheCallersTerritories() {
        Territory__c other = new Territory__c(Name = 'Other', Territory_Code__c = 'OTH', Type__c = 'Territory');
        insert other;
        Sciagen_Account__c hcp = makeAssignedHCP(other);
        try {
            AccountTerritoryUnassignService.unassign(hcp.Id, 'Not mine', UserInfo.getUserId());
            System.assert(false, 'Expected an account outside the caller\'s territories to be rejected');
        } catch (AccountTerritoryUnassignService.UnassignException e) {
            System.assert(e.getMessage().contains('not assigned to your territory'));
        }
        System.assertEquals(1, [SELECT COUNT() FROM Account_Territory__c WHERE Account__c = :hcp.Id]);
    }

    @isTest
    static void restEndpointReturns400WithMessageOnError() {
        RestContext.request = new RestRequest();
        RestContext.request.requestBody = Blob.valueOf('{"accountId":"a00000000000000","comment":""}');
        RestContext.response = new RestResponse();
        AccountTerritoryUnassignService.unassign();
        System.assertEquals(400, RestContext.response.statusCode);
        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(RestContext.response.responseBody.toString());
        System.assertEquals(false, body.get('success'));
    }
}