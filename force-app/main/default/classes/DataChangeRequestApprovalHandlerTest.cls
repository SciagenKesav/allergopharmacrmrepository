@isTest
private class DataChangeRequestApprovalHandlerTest {

    @isTest
    static void approvingNewHCP_createsAccountWithDegreeAndCarriesProofPhoto() {
        Sciagen_Account__c hco = new Sciagen_Account__c(Name = 'Test Approval HCO', Type__c = 'HCO');
        insert hco;

        Map<String, String> fields = new Map<String, String>{
            'prefix' => 'Dr.', 'firstName' => 'Approval', 'lastName' => 'Test',
            'specialty' => 'Cardiology', 'degree1' => 'MBBS'
        };
        Data_Change_Request__c dcr = new Data_Change_Request__c(
            Type__c = 'New HCP',
            Status__c = 'Pending Approval',
            Subject_Name__c = 'Dr. Approval Test',
            Related_HCO__c = hco.Id,
            Fields_Payload__c = JSON.serialize(fields),
            Submitted_By__c = UserInfo.getUserId(),
            Submitted_At__c = Datetime.now()
        );
        insert dcr;

        ContentVersion cv = new ContentVersion(
            Title = 'proof.jpg',
            PathOnClient = 'proof.jpg',
            VersionData = Blob.valueOf('fake-photo-bytes'),
            FirstPublishLocationId = dcr.Id
        );
        insert cv;
        Id contentDocumentId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;

        Test.startTest();
        dcr.Status__c = 'Approved';
        update dcr;
        Test.stopTest();

        dcr = [SELECT Subject_Account__c FROM Data_Change_Request__c WHERE Id = :dcr.Id];
        System.assertNotEquals(null, dcr.Subject_Account__c, 'Approval should auto-create the Account');

        Sciagen_Account__c acc = [
            SELECT Degree_1__c, First_Name__c, Last_Name__c
            FROM Sciagen_Account__c WHERE Id = :dcr.Subject_Account__c
        ];
        System.assertEquals('MBBS', acc.Degree_1__c);
        System.assertEquals('Approval', acc.First_Name__c);

        List<Affiliation__c> affiliations = [SELECT HCP__c, HCO__c FROM Affiliation__c WHERE HCP__c = :acc.Id];
        System.assertEquals(1, affiliations.size());
        System.assertEquals(hco.Id, affiliations[0].HCO__c);

        List<ContentDocumentLink> accountLinks = [
            SELECT Id FROM ContentDocumentLink
            WHERE LinkedEntityId = :acc.Id AND ContentDocumentId = :contentDocumentId
        ];
        System.assertEquals(1, accountLinks.size(), 'Proof photo should carry over to the new Account');
    }

    @isTest
    static void approvingNewHCO_withOverlongCity_truncatesInsteadOfFailing() {
        // Reproduces a real production failure: the rep typed a full
        // landmark-based address into the "City" field (no dedicated street-
        // address field exists on the form) — long enough to have exceeded
        // Billing_City__c's old 80-char cap and thrown STRING_TOO_LONG,
        // blocking the whole approval outright.
        String overlongCity = 'Hales Clinics, Near Pizza Hut, Road No 25, Alkapur Township, Manikonda, Hyderabad 500, this part should get clipped off since it runs well past two hundred fifty five characters once you keep adding more filler text onto the end of it purely to push the total length over the limit for this test';
        System.assert(overlongCity.length() > 255, 'Test fixture must actually exceed the field length to prove truncation');

        Map<String, String> fields = new Map<String, String>{
            'name' => 'Manikonda Ortho Clinic', 'type' => 'Clinic',
            'city' => overlongCity, 'state' => 'Telangana', 'pincode' => '500089', 'phone' => '+91-40-1234567'
        };
        Data_Change_Request__c dcr = new Data_Change_Request__c(
            Type__c = 'New HCO',
            Status__c = 'Pending Approval',
            Subject_Name__c = 'Manikonda Ortho Clinic',
            Fields_Payload__c = JSON.serialize(fields),
            Submitted_By__c = UserInfo.getUserId(),
            Submitted_At__c = Datetime.now()
        );
        insert dcr;

        Test.startTest();
        dcr.Status__c = 'Approved';
        update dcr;
        Test.stopTest();

        dcr = [SELECT Subject_Account__c FROM Data_Change_Request__c WHERE Id = :dcr.Id];
        System.assertNotEquals(null, dcr.Subject_Account__c, 'Approval should still succeed, with the city clipped rather than failing');

        Sciagen_Account__c acc = [SELECT Billing_City__c, Billing_State__c FROM Sciagen_Account__c WHERE Id = :dcr.Subject_Account__c];
        System.assertEquals(255, acc.Billing_City__c.length());
        System.assertEquals(overlongCity.substring(0, 255), acc.Billing_City__c);
        System.assertEquals('Telangana', acc.Billing_State__c);
    }

    @isTest
    static void approvingNewHCP_withoutPhoto_stillCreatesAccount() {
        Sciagen_Account__c hco = new Sciagen_Account__c(Name = 'Test Approval HCO No Photo', Type__c = 'HCO');
        insert hco;

        Map<String, String> fields = new Map<String, String>{ 'firstName' => 'NoPhoto', 'lastName' => 'Test' };
        Data_Change_Request__c dcr = new Data_Change_Request__c(
            Type__c = 'New HCP',
            Status__c = 'Pending Approval',
            Subject_Name__c = 'Dr. No Photo Test',
            Related_HCO__c = hco.Id,
            Fields_Payload__c = JSON.serialize(fields),
            Submitted_By__c = UserInfo.getUserId(),
            Submitted_At__c = Datetime.now()
        );
        insert dcr;

        Test.startTest();
        dcr.Status__c = 'Approved';
        update dcr;
        Test.stopTest();

        dcr = [SELECT Subject_Account__c FROM Data_Change_Request__c WHERE Id = :dcr.Id];
        System.assertNotEquals(null, dcr.Subject_Account__c, 'Approval should still create the Account with no photo attached');
    }

    @isTest
    static void rejectingNewHCP_withReason_createsNoAccountAndKeepsReason() {
        Sciagen_Account__c hco = new Sciagen_Account__c(Name = 'Test Rejection HCO', Type__c = 'HCO');
        insert hco;

        Map<String, String> fields = new Map<String, String>{ 'firstName' => 'Rejected', 'lastName' => 'Test' };
        Data_Change_Request__c dcr = new Data_Change_Request__c(
            Type__c = 'New HCP',
            Status__c = 'Pending Approval',
            Subject_Name__c = 'Dr. Rejected Test',
            Related_HCO__c = hco.Id,
            Fields_Payload__c = JSON.serialize(fields),
            Submitted_By__c = UserInfo.getUserId(),
            Submitted_At__c = Datetime.now()
        );
        insert dcr;

        Test.startTest();
        dcr.Status__c = 'Rejected';
        dcr.Rejection_Reason__c = 'Duplicate of existing HCP';
        update dcr;
        Test.stopTest();

        dcr = [SELECT Subject_Account__c, Rejection_Reason__c FROM Data_Change_Request__c WHERE Id = :dcr.Id];
        System.assertEquals(null, dcr.Subject_Account__c, 'Rejection should never auto-create an Account');
        System.assertEquals('Duplicate of existing HCP', dcr.Rejection_Reason__c);
        System.assertEquals(0, [SELECT COUNT() FROM Sciagen_Account__c WHERE Name = 'Dr. Rejected Test']);
    }

    @isTest
    static void approvingEditHCP_withDiffPayload_appliesRequestedValuesToExistingAccount() {
        Sciagen_Account__c hcp = new Sciagen_Account__c(
            Name = 'Dr. Edit Target', Type__c = 'HCP', First_Name__c = 'Edit', Last_Name__c = 'Target', Phone__c = '9110000001'
        );
        insert hcp;

        Map<String, Object> diff = new Map<String, Object>{
            'phone' => new Map<String, Object>{ 'current' => '9110000001', 'requested' => '9110000002' }
        };
        Data_Change_Request__c dcr = new Data_Change_Request__c(
            Type__c = 'Edit HCP',
            Status__c = 'Pending Approval',
            Subject_Name__c = 'Dr. Edit Target',
            Subject_Account__c = hcp.Id,
            Fields_Payload__c = JSON.serialize(diff),
            Summary__c = '• Phone: 9110000001 → 9110000002',
            Submitted_By__c = UserInfo.getUserId(),
            Submitted_At__c = Datetime.now()
        );
        insert dcr;

        Test.startTest();
        dcr.Status__c = 'Approved';
        update dcr;
        Test.stopTest();

        Sciagen_Account__c reloaded = [SELECT Phone__c FROM Sciagen_Account__c WHERE Id = :hcp.Id];
        System.assertEquals('9110000002', reloaded.Phone__c, 'Approving an Edit HCP should write the requested value onto the existing Account');
        System.assertEquals(0, [SELECT COUNT() FROM Sciagen_Account__c WHERE Name = 'Dr. Edit Target' AND Id != :hcp.Id],
            'Approving an edit must never create a second Account');
    }

    @isTest
    static void approvingEditHCO_withDiffPayload_appliesRequestedValuesToExistingAccount() {
        Sciagen_Account__c hco = new Sciagen_Account__c(
            Name = 'Old Clinic Name', Type__c = 'HCO', Billing_City__c = 'Old City'
        );
        insert hco;

        Map<String, Object> diff = new Map<String, Object>{
            'name' => new Map<String, Object>{ 'current' => 'Old Clinic Name', 'requested' => 'New Clinic Name' },
            'city' => new Map<String, Object>{ 'current' => 'Old City', 'requested' => 'New City' }
        };
        Data_Change_Request__c dcr = new Data_Change_Request__c(
            Type__c = 'Edit HCO',
            Status__c = 'Pending Approval',
            Subject_Name__c = 'Old Clinic Name',
            Subject_Account__c = hco.Id,
            Fields_Payload__c = JSON.serialize(diff),
            Summary__c = '• Name: Old Clinic Name → New Clinic Name',
            Submitted_By__c = UserInfo.getUserId(),
            Submitted_At__c = Datetime.now()
        );
        insert dcr;

        Test.startTest();
        dcr.Status__c = 'Approved';
        update dcr;
        Test.stopTest();

        Sciagen_Account__c reloaded = [SELECT Name, Billing_City__c FROM Sciagen_Account__c WHERE Id = :hco.Id];
        System.assertEquals('New Clinic Name', reloaded.Name);
        System.assertEquals('New City', reloaded.Billing_City__c);
    }

    @isTest
    static void approvingEditHCP_withAffiliationChange_repointsPrimaryAffiliation() {
        Sciagen_Account__c oldHCO = new Sciagen_Account__c(Name = 'Old Affiliated HCO', Type__c = 'HCO');
        Sciagen_Account__c newHCO = new Sciagen_Account__c(Name = 'New Affiliated HCO', Type__c = 'HCO');
        insert new List<Sciagen_Account__c>{ oldHCO, newHCO };

        Sciagen_Account__c hcp = new Sciagen_Account__c(
            Name = 'Dr. Affiliation Target', Type__c = 'HCP', First_Name__c = 'Affiliation', Last_Name__c = 'Target'
        );
        insert hcp;
        insert new Affiliation__c(HCP__c = hcp.Id, HCO__c = oldHCO.Id, Is_Primary__c = true);

        Map<String, Object> diff = new Map<String, Object>{
            'affiliationHCO' => new Map<String, Object>{ 'current' => 'Old Affiliated HCO', 'requested' => 'New Affiliated HCO' }
        };
        Data_Change_Request__c dcr = new Data_Change_Request__c(
            Type__c = 'Edit HCP',
            Status__c = 'Pending Approval',
            Subject_Name__c = 'Dr. Affiliation Target',
            Subject_Account__c = hcp.Id,
            Fields_Payload__c = JSON.serialize(diff),
            Summary__c = '• Affiliation (HCO): Old Affiliated HCO → New Affiliated HCO',
            Submitted_By__c = UserInfo.getUserId(),
            Submitted_At__c = Datetime.now()
        );
        insert dcr;

        Test.startTest();
        dcr.Status__c = 'Approved';
        update dcr;
        Test.stopTest();

        List<Affiliation__c> affiliations = [SELECT HCO__c, Is_Primary__c FROM Affiliation__c WHERE HCP__c = :hcp.Id];
        System.assertEquals(1, affiliations.size(), 'Should still have exactly one primary affiliation, re-pointed rather than duplicated');
        System.assertEquals(newHCO.Id, affiliations[0].HCO__c);
        System.assertEquals(true, affiliations[0].Is_Primary__c);
    }
}