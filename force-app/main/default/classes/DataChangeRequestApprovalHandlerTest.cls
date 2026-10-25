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
    static void approvingEditHCP_withDiffPayload_appliesTheRequestedValueToTheAccount() {
        // Regression test for a real production bug: an approved Edit HCP/HCO showed
        // Status = Approved but the Account's actual field value never changed, because
        // approval never wrote it anywhere — a steward had to separately, manually
        // replicate the edit by hand, and nothing enforced that they did.
        Sciagen_Account__c hcp = new Sciagen_Account__c(
            Name = 'Dr. Edit Target', Type__c = 'HCP', First_Name__c = 'Edit', Last_Name__c = 'Target', Phone__c = '111'
        );
        insert hcp;

        Map<String, Object> diff = new Map<String, Object>{
            'phone' => new Map<String, Object>{ 'current' => '111', 'requested' => '222' }
        };
        Data_Change_Request__c dcr = new Data_Change_Request__c(
            Type__c = 'Edit HCP',
            Status__c = 'Pending Approval',
            Subject_Name__c = 'Dr. Edit Target',
            Subject_Account__c = hcp.Id,
            Fields_Payload__c = JSON.serialize(diff),
            Summary__c = '• Phone: 111 → 222',
            Submitted_By__c = UserInfo.getUserId(),
            Submitted_At__c = Datetime.now()
        );
        insert dcr;

        Test.startTest();
        dcr.Status__c = 'Approved';
        update dcr;
        Test.stopTest();

        Sciagen_Account__c reloaded = [SELECT Phone__c FROM Sciagen_Account__c WHERE Id = :hcp.Id];
        System.assertEquals('222', reloaded.Phone__c, 'Approving the edit must write the requested value onto the Account');
        System.assertEquals(0, [SELECT COUNT() FROM Sciagen_Account__c WHERE Name = 'Dr. Edit Target' AND Id != :hcp.Id],
            'Approving an edit must never create a second Account');
    }

    @isTest
    static void approvingEditHCP_renamesFromPartialNameFields() {
        // Only lastName changed — prefix/firstName aren't in the diff at all — so the
        // rebuilt Name must still incorporate the Account's EXISTING prefix/firstName,
        // not just the one field that was actually edited.
        Sciagen_Account__c hcp = new Sciagen_Account__c(
            Name = 'Dr. Edit Old', Type__c = 'HCP', Prefix__c = 'Dr.', First_Name__c = 'Edit', Last_Name__c = 'Old'
        );
        insert hcp;

        Map<String, Object> diff = new Map<String, Object>{
            'lastName' => new Map<String, Object>{ 'current' => 'Old', 'requested' => 'New' }
        };
        Data_Change_Request__c dcr = new Data_Change_Request__c(
            Type__c = 'Edit HCP', Status__c = 'Pending Approval', Subject_Name__c = 'Dr. Edit Old',
            Subject_Account__c = hcp.Id, Fields_Payload__c = JSON.serialize(diff),
            Submitted_By__c = UserInfo.getUserId(), Submitted_At__c = Datetime.now()
        );
        insert dcr;

        Test.startTest();
        dcr.Status__c = 'Approved';
        update dcr;
        Test.stopTest();

        Sciagen_Account__c reloaded = [SELECT Name, Last_Name__c FROM Sciagen_Account__c WHERE Id = :hcp.Id];
        System.assertEquals('New', reloaded.Last_Name__c);
        System.assertEquals('Dr. Edit New', reloaded.Name, 'Name must be rebuilt from the existing prefix/firstName plus the new lastName');
    }

    @isTest
    static void approvingEditHCO_withInvalidPicklistValue_leavesExistingValueInPlace() {
        Sciagen_Account__c hco = new Sciagen_Account__c(Name = 'Test Edit HCO', Type__c = 'HCO', HCO_Type__c = 'Hospital');
        insert hco;

        Map<String, Object> diff = new Map<String, Object>{
            'type' => new Map<String, Object>{ 'current' => 'Hospital', 'requested' => 'Not A Real Type' },
            'phone' => new Map<String, Object>{ 'current' => '', 'requested' => '9998887777' }
        };
        Data_Change_Request__c dcr = new Data_Change_Request__c(
            Type__c = 'Edit HCO', Status__c = 'Pending Approval', Subject_Name__c = 'Test Edit HCO',
            Subject_Account__c = hco.Id, Fields_Payload__c = JSON.serialize(diff),
            Submitted_By__c = UserInfo.getUserId(), Submitted_At__c = Datetime.now()
        );
        insert dcr;

        Test.startTest();
        dcr.Status__c = 'Approved';
        update dcr;
        Test.stopTest();

        Sciagen_Account__c reloaded = [SELECT HCO_Type__c, Phone__c FROM Sciagen_Account__c WHERE Id = :hco.Id];
        System.assertEquals('Hospital', reloaded.HCO_Type__c, 'An unrecognized picklist value must be skipped, not blank the existing one out');
        System.assertEquals('9998887777', reloaded.Phone__c, 'A plain text field in the same diff must still apply');
    }

    @isTest
    static void approvingEditHCP_withAffiliationHCOChange_repointsTheAffiliation() {
        Sciagen_Account__c oldHco = new Sciagen_Account__c(Name = 'Old Affiliated HCO', Type__c = 'HCO');
        Sciagen_Account__c newHco = new Sciagen_Account__c(Name = 'New Affiliated HCO', Type__c = 'HCO');
        insert new List<Sciagen_Account__c>{ oldHco, newHco };
        Sciagen_Account__c hcp = new Sciagen_Account__c(Name = 'Dr. Affiliation Change', Type__c = 'HCP');
        insert hcp;
        insert new Affiliation__c(HCP__c = hcp.Id, HCO__c = oldHco.Id);

        Map<String, Object> diff = new Map<String, Object>{
            'affiliationHCO' => new Map<String, Object>{ 'current' => oldHco.Id, 'requested' => newHco.Id }
        };
        Data_Change_Request__c dcr = new Data_Change_Request__c(
            Type__c = 'Edit HCP', Status__c = 'Pending Approval', Subject_Name__c = 'Dr. Affiliation Change',
            Subject_Account__c = hcp.Id, Fields_Payload__c = JSON.serialize(diff),
            Submitted_By__c = UserInfo.getUserId(), Submitted_At__c = Datetime.now()
        );
        insert dcr;

        Test.startTest();
        dcr.Status__c = 'Approved';
        update dcr;
        Test.stopTest();

        List<Affiliation__c> affiliations = [SELECT HCO__c FROM Affiliation__c WHERE HCP__c = :hcp.Id];
        System.assertEquals(1, affiliations.size(), 'The existing Affiliation must be updated in place, not duplicated');
        System.assertEquals(newHco.Id, affiliations[0].HCO__c);
    }

    @isTest
    static void approvingNewHCP_assignsTheHCOsTerritoryAndOwnsItToTheSubmitter() {
        // Regression test for a real production bug: a newly-approved Account had zero
        // Account_Territory__c rows and was owned by whichever admin clicked Approve —
        // Private OWD made it invisible to the rep who'd actually submitted the request,
        // which is exactly what "the change isn't reflecting" looked like for them.
        Sciagen_Account__c hco = new Sciagen_Account__c(Name = 'Territory-Linked HCO', Type__c = 'HCO');
        insert hco;

        // Admin profile deliberately, not Standard User: this test only proves the
        // *ownership* fix (the actual bug) and that the pre-existing
        // AccountTerritoryAutoAssign trigger picks up correctly once OwnerId is right —
        // it deliberately does not also exercise the resulting Manual-share grant
        // (covered instead by approvingNewHCP_asNonAdminApprover_doesNotThrowOnShareGrant
        // below, plus TerritorySharingServiceTest/DCRTerritorySharingServiceTest).
        // An admin owner here sidesteps TerritorySharingService's own
        // PermissionsViewAllData=false filter, which used to be load-bearing: granting a
        // brand-new Share from deep inside this trigger's nested DML chain threw
        // INSUFFICIENT_ACCESS_ON_CROSS_REFERENCE_ENTITY for any real (non-admin) approving
        // user — a genuine production bug (Salesforce's *Share DML enforces the running
        // user's access to the parent record, which `without sharing` doesn't cover, and
        // the parent Account here was inserted earlier in the same transaction). Fixed by
        // running that DML at AccessLevel.SYSTEM_MODE in TerritorySharingService /
        // DCRTerritorySharingService / RCPAAuditTerritorySharingService.
        Territory__c territory = new Territory__c(Name = 'Test Approval Territory', Territory_Code__c = 'TAT', Type__c = 'Territory');
        insert territory;
        Profile adminProfile = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];
        User rep = testUser('ApprovalOwner', 'Rep', adminProfile.Id);
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert rep;
            insert new User_Territory__c(User__c = rep.Id, Territory__c = territory.Id, Is_Primary__c = true);
        }

        Map<String, String> fields = new Map<String, String>{ 'firstName' => 'Territory', 'lastName' => 'Test' };
        Data_Change_Request__c dcr = new Data_Change_Request__c(
            Type__c = 'New HCP', Status__c = 'Pending Approval', Subject_Name__c = 'Dr. Territory Test',
            Related_HCO__c = hco.Id, Fields_Payload__c = JSON.serialize(fields),
            Submitted_By__c = rep.Id, Submitted_At__c = Datetime.now()
        );
        insert dcr;

        Test.startTest();
        dcr.Status__c = 'Approved';
        update dcr;
        Test.stopTest();

        dcr = [SELECT Subject_Account__c FROM Data_Change_Request__c WHERE Id = :dcr.Id];
        Sciagen_Account__c acc = [SELECT OwnerId FROM Sciagen_Account__c WHERE Id = :dcr.Subject_Account__c];
        System.assertEquals(rep.Id, acc.OwnerId, 'The submitter, not the approving steward, should own the new Account');

        List<Account_Territory__c> links = [SELECT Territory__c FROM Account_Territory__c WHERE Account__c = :acc.Id];
        System.assertEquals(1, links.size(), 'The pre-existing AccountTerritoryAutoAssign trigger should now fire correctly against the real owner');
        System.assertEquals(territory.Id, links[0].Territory__c);
    }

    @isTest
    static void approvingNewHCO_alsoOwnedBySubmitter_getsTheirTerritoryTheSameWay() {
        Territory__c territory = new Territory__c(Name = 'Test Submitter Territory', Territory_Code__c = 'TST', Type__c = 'Territory');
        insert territory;
        Profile adminProfile = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];
        User rep = testUser('SubmitterTerritory', 'Rep', adminProfile.Id);
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert rep;
            insert new User_Territory__c(User__c = rep.Id, Territory__c = territory.Id, Is_Primary__c = true);
        }

        Map<String, String> fields = new Map<String, String>{ 'name' => 'Brand New Clinic' };
        Data_Change_Request__c dcr = new Data_Change_Request__c(
            Type__c = 'New HCO', Status__c = 'Pending Approval', Subject_Name__c = 'Brand New Clinic',
            Fields_Payload__c = JSON.serialize(fields),
            Submitted_By__c = rep.Id, Submitted_At__c = Datetime.now()
        );
        insert dcr;

        Test.startTest();
        dcr.Status__c = 'Approved';
        update dcr;
        Test.stopTest();

        dcr = [SELECT Subject_Account__c FROM Data_Change_Request__c WHERE Id = :dcr.Id];
        List<Account_Territory__c> links = [SELECT Territory__c FROM Account_Territory__c WHERE Account__c = :dcr.Subject_Account__c];
        System.assertEquals(1, links.size(), 'A New HCO gets the same owner-driven auto-assignment as a New HCP');
        System.assertEquals(territory.Id, links[0].Territory__c);
    }

    /**
     * Reproduces the real production bug: a non-admin approver (a Manager, same as any
     * real KAM/steward) approving a "New HCP" DCR whose submitter is assigned to a
     * territory that the approver is ALSO assigned to. That overlap is exactly what makes
     * TerritorySharingService attempt to grant the approver a Manual share on the
     * brand-new Sciagen_Account__c from inside the same nested trigger chain the approval
     * itself runs in — the scenario that used to throw
     * INSUFFICIENT_ACCESS_ON_CROSS_REFERENCE_ENTITY before the AccessLevel.SYSTEM_MODE fix.
     */
    @isTest
    static void approvingNewHCP_asNonAdminApprover_doesNotThrowOnShareGrant() {
        Sciagen_Account__c hco = new Sciagen_Account__c(Name = 'Share Grant Test HCO', Type__c = 'HCO');
        insert hco;

        Territory__c territory = new Territory__c(Name = 'Share Grant Territory', Territory_Code__c = 'SGT', Type__c = 'Territory');
        insert territory;
        // Links the HCO to the territory so DCRTerritorySharingService can derive DCR
        // sharing for the approver through Related_HCO__c -> Territory -> User_Territory__c
        // — the same path that makes a real DCR visible/actionable to a KAM in production.
        insert new Account_Territory__c(Name = 'Test Link', Account__c = hco.Id, Territory__c = territory.Id);

        Profile managerProfile = [SELECT Id FROM Profile WHERE Name = 'Manager' LIMIT 1];
        User submitter = testUser('ShareGrant', 'Submitter', managerProfile.Id);
        User approver = testUser('ShareGrant', 'Approver', managerProfile.Id);
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert new List<User>{ submitter, approver };
            insert new List<User_Territory__c>{
                new User_Territory__c(User__c = submitter.Id, Territory__c = territory.Id, Is_Primary__c = true),
                new User_Territory__c(User__c = approver.Id, Territory__c = territory.Id, Is_Primary__c = true)
            };
            insert new PermissionSetAssignment(AssigneeId = approver.Id, PermissionSetId = [
                SELECT Id FROM PermissionSet WHERE Name = 'Sciagen_Data_Steward' LIMIT 1
            ].Id);
        }

        Map<String, String> fields = new Map<String, String>{ 'firstName' => 'Share', 'lastName' => 'Grant' };
        Data_Change_Request__c dcr = new Data_Change_Request__c(
            Type__c = 'New HCP', Status__c = 'Pending Approval', Subject_Name__c = 'Dr. Share Grant',
            Related_HCO__c = hco.Id, Fields_Payload__c = JSON.serialize(fields),
            Submitted_By__c = submitter.Id, Submitted_At__c = Datetime.now()
        );
        insert dcr;

        System.runAs(approver) {
            Test.startTest();
            DCRReviewController.approveDCR(dcr.Id, null);
            Test.stopTest();
        }

        dcr = [SELECT Status__c, Subject_Account__c FROM Data_Change_Request__c WHERE Id = :dcr.Id];
        System.assertEquals('Approved', dcr.Status__c);

        List<Sciagen_Account__Share> shares = [
            SELECT UserOrGroupId FROM Sciagen_Account__Share
            WHERE ParentId = :dcr.Subject_Account__c AND RowCause = 'Manual'
        ];
        Set<Id> sharedWith = new Set<Id>();
        for (Sciagen_Account__Share s : shares) sharedWith.add(s.UserOrGroupId);
        System.assert(sharedWith.contains(approver.Id), 'The approver, sharing the submitter\'s territory, should have been granted a Manual share on the new account');
    }

    private static User testUser(String firstName, String lastName, Id profileId) {
        String uniq = firstName.toLowerCase() + '.' + lastName.toLowerCase() + '.' + Datetime.now().getTime();
        return new User(
            FirstName = firstName, LastName = lastName,
            Email = uniq + '@sciagen.invalid', Username = uniq + '@sciagen.invalid',
            Alias = firstName.left(1).toLowerCase() + lastName.left(4).toLowerCase(),
            TimeZoneSidKey = 'Asia/Kolkata', LocaleSidKey = 'en_IN',
            EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US', ProfileId = profileId
        );
    }

    @isTest
    static void repWithoutStewardPermissionCannotApproveOwnRequest() {
        Profile prof = [SELECT Id FROM Profile WHERE Name = 'Standard Platform User' LIMIT 1];
        User rep = new User(
            Alias = 'dcrrep', Email = 'dcr.rep@example.com', EmailEncodingKey = 'UTF-8',
            LastName = 'Rep', LanguageLocaleKey = 'en_US', LocaleSidKey = 'en_IN', ProfileId = prof.Id,
            TimeZoneSidKey = 'Asia/Kolkata', Username = 'dcr.rep.' + System.currentTimeMillis() + '@example.com'
        );
        // Setup-object DML (User, PermissionSetAssignment) runs in its own
        // runAs block so it can't collide with the DCR insert below (MIXED_DML).
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert rep;
            insert new PermissionSetAssignment(
                AssigneeId = rep.Id,
                PermissionSetId = [SELECT Id FROM PermissionSet WHERE Name = 'SciagenCrm' LIMIT 1].Id
            );
        }
        Data_Change_Request__c dcr = new Data_Change_Request__c(
            Type__c = 'New HCO', Status__c = 'Pending Approval', Subject_Name__c = 'Self Approved Clinic',
            Fields_Payload__c = '{}', Submitted_By__c = rep.Id, Submitted_At__c = Datetime.now(), OwnerId = rep.Id
        );
        insert dcr;

        Test.startTest();
        String error;
        System.runAs(rep) {
            try {
                update new Data_Change_Request__c(Id = dcr.Id, Status__c = 'Approved');
            } catch (DmlException e) {
                error = e.getMessage();
            }
        }
        Test.stopTest();

        System.assertNotEquals(null, error, 'A rep must not be able to approve a data change request');
        System.assert(error.contains('Only a data steward'), error);
        System.assertEquals('Pending Approval', [SELECT Status__c FROM Data_Change_Request__c WHERE Id = :dcr.Id].Status__c);
        System.assertEquals(0, [SELECT COUNT() FROM Sciagen_Account__c WHERE Name = 'Self Approved Clinic']);
    }
}