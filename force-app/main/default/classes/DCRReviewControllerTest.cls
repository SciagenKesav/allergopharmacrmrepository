@isTest
private class DCRReviewControllerTest {

    @testSetup
    static void setup() {
        Sciagen_Account__c hco = new Sciagen_Account__c(
            Type__c = 'HCO', Name = 'DCR Test Hospital', HCO_Type__c = 'Hospital', Speciality__c = 'Other',
            Billing_City__c = 'New Delhi'
        );
        insert hco;

        Datetime submittedAt = Datetime.now();

        Map<String, Object> newHcpFields = new Map<String, Object>{
            'prefix' => 'Dr.', 'firstName' => 'Amit', 'lastName' => 'Gupta',
            'specialty' => 'Cardiology', 'hcpType' => 'Physician',
            'email' => 'amit.gupta@example.com', 'phone' => '9876500001', 'degree1' => 'MD'
        };
        Data_Change_Request__c newHcp = new Data_Change_Request__c(
            Type__c = 'New HCP', Status__c = 'Pending Approval', Subject_Name__c = 'Dr. Amit Gupta',
            Related_HCO__c = hco.Id, Submitted_By__c = 'Test Rep', Submitted_At__c = submittedAt,
            Fields_Payload__c = JSON.serialize(newHcpFields)
        );

        Map<String, Object> editHcoDiff = new Map<String, Object>{
            'phone' => new Map<String, Object>{ 'current' => '9111100000', 'requested' => '9222200000' },
            'city' => new Map<String, Object>{ 'current' => 'Old Delhi', 'requested' => 'New Delhi' }
        };
        Data_Change_Request__c editHco = new Data_Change_Request__c(
            Type__c = 'Edit HCO', Status__c = 'Pending Approval', Subject_Name__c = 'DCR Test Hospital',
            Subject_Account__c = hco.Id, Submitted_By__c = 'Test Rep', Submitted_At__c = submittedAt.addMinutes(-5),
            Fields_Payload__c = JSON.serialize(editHcoDiff)
        );

        Data_Change_Request__c alreadyApproved = new Data_Change_Request__c(
            Type__c = 'Edit HCP', Status__c = 'Approved', Subject_Name__c = 'Already Approved',
            Submitted_By__c = 'Test Rep', Submitted_At__c = submittedAt.addMinutes(-10)
        );
        Data_Change_Request__c alreadyRejected = new Data_Change_Request__c(
            Type__c = 'New HCO', Status__c = 'Rejected', Subject_Name__c = 'Already Rejected',
            Submitted_By__c = 'Test Rep', Submitted_At__c = submittedAt.addMinutes(-15),
            Rejection_Reason__c = 'Duplicate of an existing record'
        );

        insert new List<Data_Change_Request__c>{ newHcp, editHco, alreadyApproved, alreadyRejected };
    }

    @isTest
    static void testGetDCRQueueReturnsAllRequestsWithExpectedFields() {
        Test.startTest();
        List<DCRReviewController.DCRQueueItem> queue = DCRReviewController.getDCRQueue();
        Test.stopTest();

        System.assertEquals(4, queue.size());
        Map<String, DCRReviewController.DCRQueueItem> byName = new Map<String, DCRReviewController.DCRQueueItem>();
        for (DCRReviewController.DCRQueueItem item : queue) byName.put(item.subjectName, item);

        System.assertEquals('New HCP', byName.get('Dr. Amit Gupta').type);
        System.assertEquals('Pending Approval', byName.get('Dr. Amit Gupta').status);
        System.assertEquals('Approved', byName.get('Already Approved').status);
        System.assertEquals('Rejected', byName.get('Already Rejected').status);
    }

    @isTest
    static void testGetDCRDetailForNewHCPReturnsFlatLabeledFields() {
        Data_Change_Request__c newHcp = [SELECT Id FROM Data_Change_Request__c WHERE Subject_Name__c = 'Dr. Amit Gupta' LIMIT 1];

        Test.startTest();
        DCRReviewController.DCRDetail detail = DCRReviewController.getDCRDetail(newHcp.Id);
        Test.stopTest();

        System.assertEquals(false, detail.isDiff);
        System.assertEquals(0, detail.diffFields.size());
        Map<String, String> valueByLabel = new Map<String, String>();
        for (DCRReviewController.FlatField f : detail.flatFields) valueByLabel.put(f.label, f.value);

        System.assertEquals('Amit', valueByLabel.get('First Name'));
        System.assertEquals('Gupta', valueByLabel.get('Last Name'));
        System.assertEquals('Physician', valueByLabel.get('HCP Type'));
        System.assertEquals('MD', valueByLabel.get('Degree'), 'degree1 must map to the "Degree" label, matching DCRView.swift diffLabels');
    }

    @isTest
    static void testGetDCRDetailForEditHCOReturnsDiffFieldsWithCurrentAndRequested() {
        Data_Change_Request__c editHco = [SELECT Id FROM Data_Change_Request__c WHERE Subject_Name__c = 'DCR Test Hospital' LIMIT 1];

        Test.startTest();
        DCRReviewController.DCRDetail detail = DCRReviewController.getDCRDetail(editHco.Id);
        Test.stopTest();

        System.assertEquals(true, detail.isDiff);
        System.assertEquals(0, detail.flatFields.size());
        System.assertEquals(2, detail.diffFields.size());

        Map<String, DCRReviewController.DiffField> byLabel = new Map<String, DCRReviewController.DiffField>();
        for (DCRReviewController.DiffField d : detail.diffFields) byLabel.put(d.label, d);

        System.assertEquals('9111100000', byLabel.get('Phone').current);
        System.assertEquals('9222200000', byLabel.get('Phone').requested);
        System.assertEquals('Old Delhi', byLabel.get('City').current);
        System.assertEquals('New Delhi', byLabel.get('City').requested);
    }

    @isTest
    static void testApproveDCRForNewHCPFlipsStatusAndTriggerCreatesAccount() {
        Data_Change_Request__c newHcp = [SELECT Id FROM Data_Change_Request__c WHERE Subject_Name__c = 'Dr. Amit Gupta' LIMIT 1];

        Test.startTest();
        DCRReviewController.approveDCR(newHcp.Id);
        Test.stopTest();

        Data_Change_Request__c updated = [
            SELECT Status__c, Subject_Account__c FROM Data_Change_Request__c WHERE Id = :newHcp.Id
        ];
        System.assertEquals('Approved', updated.Status__c);
        System.assertNotEquals(null, updated.Subject_Account__c, 'The existing trigger must have created the Account');

        Sciagen_Account__c created = [SELECT Name, Type__c, HCP_Type__c FROM Sciagen_Account__c WHERE Id = :updated.Subject_Account__c];
        System.assertEquals('HCP', created.Type__c);
        System.assertEquals('Physician', created.HCP_Type__c);
    }

    @isTest
    static void testApproveDCRForEditHCODoesNotAutoApplyDiffToAccount() {
        Sciagen_Account__c hco = [SELECT Id, Phone__c, Billing_City__c FROM Sciagen_Account__c WHERE Name = 'DCR Test Hospital' LIMIT 1];
        Data_Change_Request__c editHco = [SELECT Id FROM Data_Change_Request__c WHERE Subject_Name__c = 'DCR Test Hospital' LIMIT 1];

        Test.startTest();
        DCRReviewController.approveDCR(editHco.Id);
        Test.stopTest();

        Data_Change_Request__c updated = [SELECT Status__c FROM Data_Change_Request__c WHERE Id = :editHco.Id];
        System.assertEquals('Approved', updated.Status__c);

        Sciagen_Account__c unchanged = [SELECT Phone__c, Billing_City__c FROM Sciagen_Account__c WHERE Id = :hco.Id];
        System.assertEquals(hco.Phone__c, unchanged.Phone__c, 'Edit approval must not auto-write the requested phone onto the Account');
        System.assertEquals(hco.Billing_City__c, unchanged.Billing_City__c, 'Edit approval must not auto-write the requested city onto the Account');
    }

    @isTest
    static void testRejectDCRSetsStatusAndReason() {
        Data_Change_Request__c newHcp = [SELECT Id FROM Data_Change_Request__c WHERE Subject_Name__c = 'Dr. Amit Gupta' LIMIT 1];

        Test.startTest();
        DCRReviewController.rejectDCR(newHcp.Id, 'Missing valid license number');
        Test.stopTest();

        Data_Change_Request__c updated = [SELECT Status__c, Rejection_Reason__c FROM Data_Change_Request__c WHERE Id = :newHcp.Id];
        System.assertEquals('Rejected', updated.Status__c);
        System.assertEquals('Missing valid license number', updated.Rejection_Reason__c);
    }

    @isTest
    static void testRejectDCRThrowsWhenReasonIsBlank() {
        Data_Change_Request__c newHcp = [SELECT Id FROM Data_Change_Request__c WHERE Subject_Name__c = 'Dr. Amit Gupta' LIMIT 1];

        Test.startTest();
        try {
            DCRReviewController.rejectDCR(newHcp.Id, '');
            System.assert(false, 'Expected AuraHandledException for a blank reason');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @isTest
    static void testApproveDCRThrowsForAlreadyDecidedRequest() {
        Data_Change_Request__c approved = [SELECT Id FROM Data_Change_Request__c WHERE Subject_Name__c = 'Already Approved' LIMIT 1];

        Test.startTest();
        try {
            DCRReviewController.approveDCR(approved.Id);
            System.assert(false, 'Expected AuraHandledException — request is already decided');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @isTest
    static void testApproveAndRejectThrowForUnknownId() {
        Test.startTest();
        try {
            DCRReviewController.approveDCR(UserInfo.getUserId()); // a valid Id of the wrong sObject type
            System.assert(false, 'Expected AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
        try {
            DCRReviewController.rejectDCR(UserInfo.getUserId(), 'reason');
            System.assert(false, 'Expected AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    // MARK: - Comments

    @isTest
    static void testGetCommentsReturnsThreadInChronologicalOrderWithRollup() {
        Data_Change_Request__c newHcp = [SELECT Id FROM Data_Change_Request__c WHERE Subject_Name__c = 'Dr. Amit Gupta' LIMIT 1];
        insert new DCR_Comment__c(
            Data_Change_Request__c = newHcp.Id, Author__c = UserInfo.getUserId(),
            Author_Role__c = 'Requester', Body__c = 'Please review — rep left the territory.'
        );

        Test.startTest();
        DCRReviewController.addComment(newHcp.Id, 'Approved on the strength of the note above.');
        List<DCRReviewController.CommentItem> thread = DCRReviewController.getComments(newHcp.Id);
        Test.stopTest();

        System.assertEquals(2, thread.size());
        System.assertEquals('Requester', thread[0].authorRole);
        System.assertEquals('Please review — rep left the territory.', thread[0].body);
        System.assertEquals('Business Admin', thread[1].authorRole);
        System.assertEquals('Approved on the strength of the note above.', thread[1].body);

        List<DCRReviewController.DCRQueueItem> queue = DCRReviewController.getDCRQueue();
        for (DCRReviewController.DCRQueueItem item : queue) {
            if (item.id == newHcp.Id) {
                System.assertEquals(2, item.commentCount, 'Comment_Count__c roll-up must reflect both comments');
            }
        }
    }

    @isTest
    static void testAddCommentThrowsWhenBodyIsBlank() {
        Data_Change_Request__c newHcp = [SELECT Id FROM Data_Change_Request__c WHERE Subject_Name__c = 'Dr. Amit Gupta' LIMIT 1];

        Test.startTest();
        try {
            DCRReviewController.addComment(newHcp.Id, '   ');
            System.assert(false, 'Expected AuraHandledException for a blank reply');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @isTest
    static void testAddCommentThrowsForUnknownDcr() {
        Test.startTest();
        try {
            DCRReviewController.addComment(UserInfo.getUserId(), 'reply'); // a valid Id of the wrong sObject type
            System.assert(false, 'Expected AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
        Test.stopTest();
    }
}