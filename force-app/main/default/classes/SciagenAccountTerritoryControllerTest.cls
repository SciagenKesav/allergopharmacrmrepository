@isTest
private class SciagenAccountTerritoryControllerTest {

    @testSetup
    static void setup() {
        UserRole buhRole = [SELECT Id FROM UserRole WHERE Name = 'Business Unit Head' LIMIT 1];
        Profile mobileProfile = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        // System Administrator, not Standard User, for the approver — mirrors
        // the ACTUAL current reality (see class doc comment: "Vivek Narang,
        // the only Business Unit Head today, is also System Administrator
        // profile"). This isn't just convenience: Account_Territory__c's
        // Account__c/Territory__c are required Lookups, and Salesforce's
        // Metadata API refuses to let ANY profile or permission set grant
        // them explicit FLS ("You cannot deploy to a required field") — their
        // accessibility instead comes purely from System Administrator's
        // blanket implicit access, which Sciagen_Zonal_Manager_Access alone
        // (paired with Standard User) cannot reproduce for a non-admin
        // approver. That's a real, separate platform-level gap, not
        // something this test works around.
        Profile adminProfile = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];
        Id mobileAccessId = [SELECT Id FROM PermissionSet WHERE Name = 'Sciagen_Mobile_App_Access'].Id;
        Id zonalManagerAccessId = [SELECT Id FROM PermissionSet WHERE Name = 'Sciagen_Zonal_Manager_Access'].Id;

        User buh = new User(
            FirstName = 'Buh', LastName = 'Territory Test', Alias = 'buhtt', Email = 'buh.territory@sciagen-test.invalid',
            Username = 'buh.territory@sciagen-new-dev.invalid', TimeZoneSidKey = 'Asia/Kolkata', LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US', ProfileId = mobileProfile.Id, IsActive = true,
            UserRoleId = buhRole.Id
        );
        User rep = new User(
            FirstName = 'Rep', LastName = 'Territory Test', Alias = 'reptt', Email = 'rep.territory@sciagen-test.invalid',
            Username = 'rep.territory@sciagen-new-dev.invalid', TimeZoneSidKey = 'Asia/Kolkata', LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US', ProfileId = mobileProfile.Id, IsActive = true
        );
        User approver = new User(
            FirstName = 'Zonal', LastName = 'Territory Test', Alias = 'zonltt', Email = 'zonal.territory@sciagen-test.invalid',
            Username = 'zonal.territory@sciagen-new-dev.invalid', TimeZoneSidKey = 'Asia/Kolkata', LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US', ProfileId = adminProfile.Id, IsActive = true
        );
        // Setup-object DML (User, PermissionSetAssignment) must be isolated in
        // its own System.runAs — even runAs'ing the current user — or the
        // subsequent regular-object DML below throws MIXED_DML_OPERATION.
        // This restriction applies regardless of which kind of DML comes
        // first; wrapping in runAs is the standard fix, not reordering.
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert new List<User>{ buh, rep, approver };
            insert new List<PermissionSetAssignment>{
                new PermissionSetAssignment(AssigneeId = buh.Id, PermissionSetId = mobileAccessId),
                new PermissionSetAssignment(AssigneeId = rep.Id, PermissionSetId = mobileAccessId),
                new PermissionSetAssignment(AssigneeId = approver.Id, PermissionSetId = zonalManagerAccessId)
            };
        }

        Territory__c territory = new Territory__c(Name = 'Unassign Test Territory', Territory_Code__c = 'UTT', Type__c = 'Territory');
        insert territory;

        Sciagen_Account__c hcp = new Sciagen_Account__c(
            Type__c = 'HCP', Name = 'Dr. Unassign Target', Prefix__c = 'Dr.', First_Name__c = 'Unassign',
            Last_Name__c = 'Target', Specialty__c = 'Cardiology', HCP_Type__c = 'Physician', Phone__c = '9000000099'
        );
        insert hcp;
        insert new Account_Territory__c(Name = 'Assignment', Account__c = hcp.Id, Territory__c = territory.Id);

        insert new List<User_Territory__c>{
            new User_Territory__c(User__c = buh.Id, Territory__c = territory.Id),
            new User_Territory__c(User__c = rep.Id, Territory__c = territory.Id)
        };
    }

    @isTest
    static void testBusinessUnitHeadUnassignsImmediatelyAndFilesApprovedDcrWithComment() {
        User buh = [SELECT Id FROM User WHERE Username = 'buh.territory@sciagen-new-dev.invalid'];
        Sciagen_Account__c hcp = [SELECT Id FROM Sciagen_Account__c WHERE Name = 'Dr. Unassign Target'];

        SciagenAccountTerritoryController.UnassignOutcome outcome;
        System.runAs(buh) {
            Test.startTest();
            outcome = SciagenAccountTerritoryController.unassignFromMyTerritory(hcp.Id, 'Rep moved to a different region.');
            Test.stopTest();
        }

        System.assertEquals(true, outcome.success);
        System.assertEquals(true, outcome.immediate);

        List<Account_Territory__c> remainingLinks = [SELECT Id FROM Account_Territory__c WHERE Account__c = :hcp.Id];
        System.assertEquals(0, remainingLinks.size(), 'A Business Unit Head\'s own request removes the link immediately');

        Data_Change_Request__c dcr = [
            SELECT Id, Status__c, Type__c FROM Data_Change_Request__c WHERE Subject_Account__c = :hcp.Id
        ];
        System.assertEquals('Approved', dcr.Status__c, 'Even the immediate path files a pre-Approved DCR so the comment has somewhere to live');
        System.assertEquals('Unassign HCP', dcr.Type__c);

        List<DCR_Comment__c> comments = [SELECT Author_Role__c, Body__c FROM DCR_Comment__c WHERE Data_Change_Request__c = :dcr.Id];
        System.assertEquals(1, comments.size());
        System.assertEquals('Requester', comments[0].Author_Role__c);
        System.assertEquals('Rep moved to a different region.', comments[0].Body__c);
    }

    @isTest
    static void testNonBusinessUnitHeadFilesPendingDcrAndLinkStaysUntilApproved() {
        User rep = [SELECT Id FROM User WHERE Username = 'rep.territory@sciagen-new-dev.invalid'];
        Sciagen_Account__c hcp = [SELECT Id FROM Sciagen_Account__c WHERE Name = 'Dr. Unassign Target'];

        SciagenAccountTerritoryController.UnassignOutcome outcome;
        System.runAs(rep) {
            Test.startTest();
            outcome = SciagenAccountTerritoryController.unassignFromMyTerritory(hcp.Id, 'Duplicate assignment, please review.');
            Test.stopTest();
        }

        System.assertEquals(true, outcome.success);
        System.assertEquals(false, outcome.immediate);

        List<Account_Territory__c> stillLinked = [SELECT Id FROM Account_Territory__c WHERE Account__c = :hcp.Id];
        System.assertEquals(1, stillLinked.size(), 'Nothing is removed until a Business Unit Head approves the DCR');

        Data_Change_Request__c dcr = [
            SELECT Id, Status__c, Type__c FROM Data_Change_Request__c WHERE Subject_Account__c = :hcp.Id
        ];
        System.assertEquals('Pending Approval', dcr.Status__c);
        System.assertEquals('Unassign HCP', dcr.Type__c);

        List<DCR_Comment__c> comments = [SELECT Author_Role__c, Body__c FROM DCR_Comment__c WHERE Data_Change_Request__c = :dcr.Id];
        System.assertEquals(1, comments.size());
        System.assertEquals('Requester', comments[0].Author_Role__c);
        System.assertEquals('Duplicate assignment, please review.', comments[0].Body__c);

        // Approving it afterwards must still remove the link, unchanged from before
        // this feature — done by an actual approver (Sciagen_Zonal_Manager_Access),
        // not the submitting rep, matching how this is really reviewed in production.
        User approver = [SELECT Id FROM User WHERE Username = 'zonal.territory@sciagen-new-dev.invalid'];
        System.runAs(approver) {
            DCRReviewController.approveDCR(dcr.Id);
        }
        List<Account_Territory__c> afterApproval = [SELECT Id FROM Account_Territory__c WHERE Account__c = :hcp.Id];
        System.assertEquals(0, afterApproval.size(), 'Approving the DCR must still remove the territory link');
    }

    @isTest
    static void testUnassignThrowsWhenCommentIsBlank() {
        User rep = [SELECT Id FROM User WHERE Username = 'rep.territory@sciagen-new-dev.invalid'];
        Sciagen_Account__c hcp = [SELECT Id FROM Sciagen_Account__c WHERE Name = 'Dr. Unassign Target'];

        System.runAs(rep) {
            Test.startTest();
            try {
                SciagenAccountTerritoryController.unassignFromMyTerritory(hcp.Id, '   ');
                System.assert(false, 'Expected AuraHandledException for a blank comment');
            } catch (AuraHandledException e) {
                System.assert(true);
            }
            Test.stopTest();
        }

        List<Account_Territory__c> stillLinked = [SELECT Id FROM Account_Territory__c WHERE Account__c = :hcp.Id];
        System.assertEquals(1, stillLinked.size(), 'A rejected (blank-comment) request must not remove anything');
        System.assertEquals(0, [SELECT COUNT() FROM Data_Change_Request__c], 'No DCR should be filed when the comment is blank');
    }

    @isTest
    static void testRestEndpointRequiresCommentAndReturns400OnFailure() {
        User rep = [SELECT Id FROM User WHERE Username = 'rep.territory@sciagen-new-dev.invalid'];
        Sciagen_Account__c hcp = [SELECT Id FROM Sciagen_Account__c WHERE Name = 'Dr. Unassign Target'];

        System.runAs(rep) {
            RestRequest req = new RestRequest();
            req.requestURI = '/services/apexrest/sciagen/v1/account-territory-unassign';
            req.httpMethod = 'POST';
            req.requestBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{ 'accountId' => hcp.Id }));
            RestContext.request = req;
            RestContext.response = new RestResponse();

            Test.startTest();
            SciagenAccountTerritoryController.unassignFromMyTerritoryRest();
            Test.stopTest();

            System.assertEquals(400, RestContext.response.statusCode);
            String body = RestContext.response.responseBody.toString();
            System.assert(body.contains('comment'), 'Error message should explain the comment is required: ' + body);
        }
    }

    @isTest
    static void testRestEndpointSucceedsWithComment() {
        User rep = [SELECT Id FROM User WHERE Username = 'rep.territory@sciagen-new-dev.invalid'];
        Sciagen_Account__c hcp = [SELECT Id FROM Sciagen_Account__c WHERE Name = 'Dr. Unassign Target'];

        System.runAs(rep) {
            RestRequest req = new RestRequest();
            req.requestURI = '/services/apexrest/sciagen/v1/account-territory-unassign';
            req.httpMethod = 'POST';
            req.requestBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{
                'accountId' => hcp.Id, 'comment' => 'Filed from the iPad app.'
            }));
            RestContext.request = req;
            RestContext.response = new RestResponse();

            Test.startTest();
            SciagenAccountTerritoryController.unassignFromMyTerritoryRest();
            Test.stopTest();

            System.assertEquals(200, RestContext.response.statusCode);
        }

        Data_Change_Request__c dcr = [SELECT Id FROM Data_Change_Request__c WHERE Subject_Account__c = :hcp.Id];
        List<DCR_Comment__c> comments = [SELECT Body__c FROM DCR_Comment__c WHERE Data_Change_Request__c = :dcr.Id];
        System.assertEquals(1, comments.size());
        System.assertEquals('Filed from the iPad app.', comments[0].Body__c);
    }
}
