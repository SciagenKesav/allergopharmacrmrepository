@isTest
private class SciagenAccountSyncServiceTest {

    @TestSetup
    static void setup() {
        Territory__c chennai = new Territory__c(Name = 'Test Sync Chennai', Territory_Code__c = 'TSCHN', Type__c = 'Territory');
        Territory__c other = new Territory__c(Name = 'Test Sync Other', Territory_Code__c = 'TSOTH', Type__c = 'Territory');
        insert new List<Territory__c>{ chennai, other };

        Sciagen_Account__c hco = new Sciagen_Account__c(Name = 'Test Sync Hospital', Type__c = 'HCO', Account_Code__c = 'TS-HCO-001');
        insert hco;
        Sciagen_Account__c hcp = new Sciagen_Account__c(Name = 'Dr. Test Sync', Type__c = 'HCP', Account_Code__c = 'TS-HCP-001');
        insert hcp;

        insert new Account_Territory__c(Account__c = hco.Id, Territory__c = chennai.Id);
        insert new Account_Territory__c(Account__c = hcp.Id, Territory__c = chennai.Id);
    }

    private static Sciagen_Account__c hco() {
        return [SELECT Id FROM Sciagen_Account__c WHERE Name = 'Test Sync Hospital' LIMIT 1];
    }
    private static Sciagen_Account__c hcp() {
        return [SELECT Id FROM Sciagen_Account__c WHERE Name = 'Dr. Test Sync' LIMIT 1];
    }
    private static Territory__c chennaiTerritory() {
        return [SELECT Id FROM Territory__c WHERE Name = 'Test Sync Chennai' LIMIT 1];
    }

    // ===================== syncDown =====================

    @isTest
    static void syncDown_returnsBothAccounts() {
        Test.startTest();
        SciagenAccountSyncService.SyncDownResult result =
            SciagenAccountSyncService.doSyncDown(new Map<String, String>());
        Test.stopTest();

        System.assertEquals(true, result.success);
        System.assertEquals(2, result.records.size());
    }

    @isTest
    static void syncDown_filtersByType() {
        Test.startTest();
        SciagenAccountSyncService.SyncDownResult result =
            SciagenAccountSyncService.doSyncDown(new Map<String, String>{ 'type' => 'HCP' });
        Test.stopTest();

        System.assertEquals(1, result.records.size());
        System.assertEquals('HCP', result.records[0].type);
    }

    @isTest
    static void syncDown_filtersByTerritory() {
        Test.startTest();
        SciagenAccountSyncService.SyncDownResult result =
            SciagenAccountSyncService.doSyncDown(new Map<String, String>{ 'territory' => 'Test Sync Chennai' });
        Test.stopTest();

        System.assertEquals(2, result.records.size());
        for (SciagenAccountSyncService.AccountSyncRecord rec : result.records) {
            System.assertEquals('Test Sync Chennai', rec.territory);
        }
    }

    @isTest
    static void syncDown_sinceInFuture_returnsNothing() {
        Map<String, String> params = new Map<String, String>{ 'since' => '2099-01-01T00:00:00Z' };

        Test.startTest();
        SciagenAccountSyncService.SyncDownResult result = SciagenAccountSyncService.doSyncDown(params);
        Test.stopTest();

        System.assertEquals(true, result.success);
        System.assertEquals(0, result.records.size());
    }

    @isTest
    static void syncDown_invalidType_failsGracefully() {
        RestRequest req = new RestRequest();
        req.requestURI = '/services/apexrest/sciagen/v1/accounts';
        req.httpMethod = 'GET';
        req.params.put('type', 'NotAValidType');
        RestContext.request = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        SciagenAccountSyncService.SyncDownResult result = SciagenAccountSyncService.syncDown();
        Test.stopTest();

        System.assertEquals(false, result.success);
        System.assertEquals(400, RestContext.response.statusCode);
    }

    /** Proves this REST endpoint inherits the same territory-based sharing as the rest of the app. */
    @isTest
    static void syncDown_respectsTerritoryBasedSharing() {
        Profile standardProfile = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User repInChennai = testUser('SyncRepA', 'Chennai', standardProfile.Id);
        User repElsewhere = testUser('SyncRepB', 'Elsewhere', standardProfile.Id);

        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert new List<User>{ repInChennai, repElsewhere };
            PermissionSet mobileAccess = [SELECT Id FROM PermissionSet WHERE Name = 'Sciagen_Mobile_App_Access' LIMIT 1];
            insert new List<PermissionSetAssignment>{
                new PermissionSetAssignment(AssigneeId = repInChennai.Id, PermissionSetId = mobileAccess.Id),
                new PermissionSetAssignment(AssigneeId = repElsewhere.Id, PermissionSetId = mobileAccess.Id)
            };
        }
        insert new User_Territory__c(User__c = repInChennai.Id, Territory__c = chennaiTerritory().Id);

        Test.startTest();
        SciagenAccountSyncService.SyncDownResult resultForRepInChennai;
        SciagenAccountSyncService.SyncDownResult resultForRepElsewhere;
        System.runAs(repInChennai) {
            resultForRepInChennai = SciagenAccountSyncService.doSyncDown(new Map<String, String>());
        }
        System.runAs(repElsewhere) {
            resultForRepElsewhere = SciagenAccountSyncService.doSyncDown(new Map<String, String>());
        }
        Test.stopTest();

        System.assertEquals(2, resultForRepInChennai.records.size(),
            'Rep assigned to Chennai should see both accounts in that territory');
        System.assertEquals(0, resultForRepElsewhere.records.size(),
            'Rep with no territory assignment should see nothing under Private OWD');
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

    // ===================== syncUp =====================

    @isTest
    static void syncUp_newHCP_createsDCRWithRelatedHCO() {
        SciagenAccountSyncService.AccountUpsertRequest req = new SciagenAccountSyncService.AccountUpsertRequest();
        req.localId = 'local-1';
        req.type = 'HCP';
        req.mode = 'new';
        req.relatedHCOId = hco().Id;
        req.subjectName = 'Dr. Arun Kumar';
        req.summary = 'New Chennai cardiologist';
        req.fields = new Map<String, String>{ 'specialty' => 'Cardiology', 'city' => 'Chennai' };

        SciagenAccountSyncService.AccountSyncPushRequest payload = new SciagenAccountSyncService.AccountSyncPushRequest();
        payload.records = new List<SciagenAccountSyncService.AccountUpsertRequest>{ req };

        Test.startTest();
        SciagenAccountSyncService.SyncUpResult result = SciagenAccountSyncService.doSyncUp(payload);
        Test.stopTest();

        System.assertEquals(1, result.results.size());
        SciagenAccountSyncService.AccountUpsertResult rowResult = result.results[0];
        System.assertEquals(true, rowResult.success);
        System.assertEquals('local-1', rowResult.localId);
        System.assertNotEquals(null, rowResult.dcrId);

        Data_Change_Request__c dcr = [
            SELECT Type__c, Status__c, Subject_Name__c, Related_HCO__c, Submitted_By__c, Fields_Payload__c
            FROM Data_Change_Request__c WHERE Id = :rowResult.dcrId
        ];
        System.assertEquals('New HCP', dcr.Type__c);
        System.assertEquals('Pending Approval', dcr.Status__c);
        System.assertEquals('Dr. Arun Kumar', dcr.Subject_Name__c);
        System.assertEquals(hco().Id, dcr.Related_HCO__c);
        System.assertEquals(UserInfo.getUserId(), (Id) dcr.Submitted_By__c);
        System.assert(dcr.Fields_Payload__c.contains('Cardiology'));
    }

    @isTest
    static void syncUp_newHCO_populatesAddressFieldsAsRealFieldsNotJustSummary() {
        SciagenAccountSyncService.AccountUpsertRequest req = new SciagenAccountSyncService.AccountUpsertRequest();
        req.localId = 'local-hco-1';
        req.type = 'HCO';
        req.mode = 'new';
        req.subjectName = 'New Apollo Clinic';
        req.summary = 'New HCO · Clinic · Chennai, Tamil Nadu';
        req.fields = new Map<String, String>{
            'name' => 'New Apollo Clinic', 'type' => 'Clinic', 'city' => 'Chennai',
            'state' => 'Tamil Nadu', 'pincode' => '600001', 'phone' => '+91-44-9998887'
        };

        SciagenAccountSyncService.AccountSyncPushRequest payload = new SciagenAccountSyncService.AccountSyncPushRequest();
        payload.records = new List<SciagenAccountSyncService.AccountUpsertRequest>{ req };

        Test.startTest();
        SciagenAccountSyncService.SyncUpResult result = SciagenAccountSyncService.doSyncUp(payload);
        Test.stopTest();

        SciagenAccountSyncService.AccountUpsertResult rowResult = result.results[0];
        System.assertEquals(true, rowResult.success);

        Data_Change_Request__c dcr = [
            SELECT Type__c, Subject_Name__c, City__c, State__c, Pincode__c, Phone__c, Full_Address__c
            FROM Data_Change_Request__c WHERE Id = :rowResult.dcrId
        ];
        System.assertEquals('New HCO', dcr.Type__c);
        System.assertEquals('New Apollo Clinic', dcr.Subject_Name__c);
        System.assertEquals('Chennai', dcr.City__c);
        System.assertEquals('Tamil Nadu', dcr.State__c);
        System.assertEquals('600001', dcr.Pincode__c);
        System.assertEquals('+91-44-9998887', dcr.Phone__c);
        System.assertEquals('Chennai, Tamil Nadu - 600001', dcr.Full_Address__c);
    }

    @isTest
    static void syncUp_newHCP_hasNoAddressFieldsSinceItNeverCollectsOne() {
        SciagenAccountSyncService.AccountUpsertRequest req = new SciagenAccountSyncService.AccountUpsertRequest();
        req.localId = 'local-hcp-noaddr-1';
        req.type = 'HCP';
        req.mode = 'new';
        req.relatedHCOId = hco().Id;
        req.subjectName = 'Dr. No Address';
        req.summary = 'New HCP · Cardiology · affiliated to Test Sync Hospital';
        req.fields = new Map<String, String>{ 'specialty' => 'Cardiology', 'phone' => '+91-98765-00000' };

        SciagenAccountSyncService.AccountSyncPushRequest payload = new SciagenAccountSyncService.AccountSyncPushRequest();
        payload.records = new List<SciagenAccountSyncService.AccountUpsertRequest>{ req };

        Test.startTest();
        SciagenAccountSyncService.SyncUpResult result = SciagenAccountSyncService.doSyncUp(payload);
        Test.stopTest();

        SciagenAccountSyncService.AccountUpsertResult rowResult = result.results[0];
        System.assertEquals(true, rowResult.success);

        Data_Change_Request__c dcr = [
            SELECT City__c, State__c, Pincode__c, Phone__c, Full_Address__c
            FROM Data_Change_Request__c WHERE Id = :rowResult.dcrId
        ];
        System.assertEquals(null, dcr.City__c);
        System.assertEquals(null, dcr.Full_Address__c);
        System.assertEquals('+91-98765-00000', dcr.Phone__c, 'Phone is still collected on the HCP form, just no address');
    }

    @isTest
    static void syncUp_newHCP_withPhoto_attachesContentVersionToDCR() {
        SciagenAccountSyncService.AccountUpsertRequest req = new SciagenAccountSyncService.AccountUpsertRequest();
        req.localId = 'local-photo-1';
        req.type = 'HCP';
        req.mode = 'new';
        req.relatedHCOId = hco().Id;
        req.subjectName = 'Dr. Photo Test';
        req.summary = 'New HCP with proof photo';
        req.fields = new Map<String, String>{ 'specialty' => 'Cardiology' };
        req.photoBase64 = EncodingUtil.base64Encode(Blob.valueOf('fake-image-bytes-for-test'));
        req.photoFileName = 'visiting_card.jpg';

        SciagenAccountSyncService.AccountSyncPushRequest payload = new SciagenAccountSyncService.AccountSyncPushRequest();
        payload.records = new List<SciagenAccountSyncService.AccountUpsertRequest>{ req };

        Test.startTest();
        SciagenAccountSyncService.SyncUpResult result = SciagenAccountSyncService.doSyncUp(payload);
        Test.stopTest();

        SciagenAccountSyncService.AccountUpsertResult rowResult = result.results[0];
        System.assertEquals(true, rowResult.success);

        List<ContentDocumentLink> links = [
            SELECT ContentDocumentId, ContentDocument.Title
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :rowResult.dcrId
        ];
        System.assertEquals(1, links.size(), 'Proof photo should be linked to the created DCR');
        System.assertEquals('visiting_card.jpg', links[0].ContentDocument.Title);
    }

    @isTest
    static void syncUp_newHCP_withoutPhoto_createsNoContentVersion() {
        SciagenAccountSyncService.AccountUpsertRequest req = new SciagenAccountSyncService.AccountUpsertRequest();
        req.localId = 'local-nophoto-1';
        req.type = 'HCP';
        req.mode = 'new';
        req.relatedHCOId = hco().Id;
        req.subjectName = 'Dr. No Photo';
        req.summary = 'New HCP without a proof photo';

        SciagenAccountSyncService.AccountSyncPushRequest payload = new SciagenAccountSyncService.AccountSyncPushRequest();
        payload.records = new List<SciagenAccountSyncService.AccountUpsertRequest>{ req };

        Test.startTest();
        SciagenAccountSyncService.SyncUpResult result = SciagenAccountSyncService.doSyncUp(payload);
        Test.stopTest();

        SciagenAccountSyncService.AccountUpsertResult rowResult = result.results[0];
        System.assertEquals(true, rowResult.success);

        List<ContentDocumentLink> links = [SELECT Id FROM ContentDocumentLink WHERE LinkedEntityId = :rowResult.dcrId];
        System.assertEquals(0, links.size(), 'No photo attached means no ContentVersion should be created');
    }

    @isTest
    static void syncUp_editHCO_createsDCRWithSubjectAccount() {
        SciagenAccountSyncService.AccountUpsertRequest req = new SciagenAccountSyncService.AccountUpsertRequest();
        req.localId = 'local-2';
        req.type = 'HCO';
        req.mode = 'edit';
        req.subjectAccountId = hco().Id;
        req.subjectName = 'Test Sync Hospital';
        req.summary = 'Corrected phone number';
        req.fields = new Map<String, String>{ 'phone' => '+91-44-1234567' };

        SciagenAccountSyncService.AccountSyncPushRequest payload = new SciagenAccountSyncService.AccountSyncPushRequest();
        payload.records = new List<SciagenAccountSyncService.AccountUpsertRequest>{ req };

        Test.startTest();
        SciagenAccountSyncService.SyncUpResult result = SciagenAccountSyncService.doSyncUp(payload);
        Test.stopTest();

        SciagenAccountSyncService.AccountUpsertResult rowResult = result.results[0];
        System.assertEquals(true, rowResult.success);

        Data_Change_Request__c dcr = [SELECT Type__c, Subject_Account__c FROM Data_Change_Request__c WHERE Id = :rowResult.dcrId];
        System.assertEquals('Edit HCO', dcr.Type__c);
        System.assertEquals(hco().Id, dcr.Subject_Account__c);
    }

    @isTest
    static void syncUp_editHCP_withFieldDiffs_storesNestedPayload() {
        SciagenAccountSyncService.AccountUpsertRequest req = new SciagenAccountSyncService.AccountUpsertRequest();
        req.localId = 'local-diff-1';
        req.type = 'HCP';
        req.mode = 'edit';
        req.subjectAccountId = hcp().Id;
        req.subjectName = 'Dr. Test Sync';
        req.summary = '• Phone: 111 → 222';
        SciagenAccountSyncService.FieldDiff phoneDiffValue = new SciagenAccountSyncService.FieldDiff();
        phoneDiffValue.current = '111';
        phoneDiffValue.requested = '222';
        req.fieldDiffs = new Map<String, SciagenAccountSyncService.FieldDiff>{ 'phone' => phoneDiffValue };

        SciagenAccountSyncService.AccountSyncPushRequest payload = new SciagenAccountSyncService.AccountSyncPushRequest();
        payload.records = new List<SciagenAccountSyncService.AccountUpsertRequest>{ req };

        Test.startTest();
        SciagenAccountSyncService.SyncUpResult result = SciagenAccountSyncService.doSyncUp(payload);
        Test.stopTest();

        SciagenAccountSyncService.AccountUpsertResult rowResult = result.results[0];
        System.assertEquals(true, rowResult.success);

        Data_Change_Request__c dcr = [
            SELECT Type__c, Subject_Account__c, Fields_Payload__c, Summary__c
            FROM Data_Change_Request__c WHERE Id = :rowResult.dcrId
        ];
        System.assertEquals('Edit HCP', dcr.Type__c);
        System.assertEquals(hcp().Id, dcr.Subject_Account__c);
        System.assertEquals('• Phone: 111 → 222', dcr.Summary__c);

        Map<String, Object> payloadFields = (Map<String, Object>) JSON.deserializeUntyped(dcr.Fields_Payload__c);
        Map<String, Object> phoneDiff = (Map<String, Object>) payloadFields.get('phone');
        System.assertEquals('111', phoneDiff.get('current'));
        System.assertEquals('222', phoneDiff.get('requested'));
    }

    @isTest
    static void syncUp_edit_withNoFieldsOrDiffs_returnsValidationError() {
        SciagenAccountSyncService.AccountUpsertRequest req = new SciagenAccountSyncService.AccountUpsertRequest();
        req.localId = 'local-nodiff-1';
        req.type = 'HCP';
        req.mode = 'edit';
        req.subjectAccountId = hcp().Id;
        req.subjectName = 'Dr. Test Sync';
        req.summary = 'No actual changes';

        SciagenAccountSyncService.AccountSyncPushRequest payload = new SciagenAccountSyncService.AccountSyncPushRequest();
        payload.records = new List<SciagenAccountSyncService.AccountUpsertRequest>{ req };

        Test.startTest();
        SciagenAccountSyncService.SyncUpResult result = SciagenAccountSyncService.doSyncUp(payload);
        Test.stopTest();

        SciagenAccountSyncService.AccountUpsertResult rowResult = result.results[0];
        System.assertEquals(false, rowResult.success);
        System.assert(rowResult.message.contains('changed field'));
        System.assertEquals(0, [SELECT COUNT() FROM Data_Change_Request__c WHERE Subject_Name__c = 'Dr. Test Sync']);
    }

    @isTest
    static void syncUp_newHCP_flatFields_stillSerializesFields() {
        SciagenAccountSyncService.AccountUpsertRequest req = new SciagenAccountSyncService.AccountUpsertRequest();
        req.localId = 'local-flat-1';
        req.type = 'HCP';
        req.mode = 'new';
        req.relatedHCOId = hco().Id;
        req.subjectName = 'Dr. Flat Fields';
        req.summary = 'New HCP, flat fields regression check';
        req.fields = new Map<String, String>{ 'specialty' => 'Oncology' };

        SciagenAccountSyncService.AccountSyncPushRequest payload = new SciagenAccountSyncService.AccountSyncPushRequest();
        payload.records = new List<SciagenAccountSyncService.AccountUpsertRequest>{ req };

        Test.startTest();
        SciagenAccountSyncService.SyncUpResult result = SciagenAccountSyncService.doSyncUp(payload);
        Test.stopTest();

        SciagenAccountSyncService.AccountUpsertResult rowResult = result.results[0];
        System.assertEquals(true, rowResult.success);

        Data_Change_Request__c dcr = [SELECT Fields_Payload__c FROM Data_Change_Request__c WHERE Id = :rowResult.dcrId];
        System.assert(dcr.Fields_Payload__c.contains('Oncology'));
    }

    @isTest
    static void syncUp_mixedBatch_partialSuccess() {
        SciagenAccountSyncService.AccountUpsertRequest valid = new SciagenAccountSyncService.AccountUpsertRequest();
        valid.localId = 'ok-1';
        valid.type = 'HCP';
        valid.mode = 'new';
        valid.subjectName = 'Dr. Valid Record';

        SciagenAccountSyncService.AccountUpsertRequest invalid = new SciagenAccountSyncService.AccountUpsertRequest();
        invalid.localId = 'bad-1';
        invalid.type = 'HCP';
        invalid.mode = 'edit'; // edit without subjectAccountId -> validation failure
        invalid.subjectName = 'Dr. Missing Subject Id';

        SciagenAccountSyncService.AccountSyncPushRequest payload = new SciagenAccountSyncService.AccountSyncPushRequest();
        payload.records = new List<SciagenAccountSyncService.AccountUpsertRequest>{ valid, invalid };

        Test.startTest();
        SciagenAccountSyncService.SyncUpResult result = SciagenAccountSyncService.doSyncUp(payload);
        Test.stopTest();

        System.assertEquals(2, result.results.size());
        System.assertEquals(true, result.results[0].success);
        System.assertEquals(false, result.results[1].success);
        System.assert(result.results[1].message.contains('subjectAccountId'));
    }

    @isTest
    static void syncUp_emptyPayload_returnsUnsuccessful() {
        SciagenAccountSyncService.AccountSyncPushRequest payload = new SciagenAccountSyncService.AccountSyncPushRequest();
        payload.records = new List<SciagenAccountSyncService.AccountUpsertRequest>();

        Test.startTest();
        SciagenAccountSyncService.SyncUpResult result = SciagenAccountSyncService.doSyncUp(payload);
        Test.stopTest();

        System.assertEquals(false, result.success);
    }

    @isTest
    static void syncUp_viaRestEntryPoint_malformedBody_returns400() {
        RestRequest req = new RestRequest();
        req.requestURI = '/services/apexrest/sciagen/v1/accounts';
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf('{not valid json');
        RestContext.request = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        SciagenAccountSyncService.SyncUpResult result = SciagenAccountSyncService.syncUp();
        Test.stopTest();

        System.assertEquals(false, result.success);
        System.assertEquals(400, RestContext.response.statusCode);
    }

    /**
     * Regression test for a real production incident: an edit-mode sync (fieldDiffs
     * populated) 400'd on every real device call, even though doSyncUp() called directly
     * with the same data passed every existing test. The difference is JSON.deserialize()
     * itself — syncUp()'s actual REST entry point — which every *other* syncUp test here
     * bypasses by building the request object in Apex. This one goes through the real
     * path: a literal JSON string body, parsed by syncUp() exactly like a live iPad call.
     * See AccountUpsertRequest.FieldDiff's doc comment for why the old `Object`-typed
     * fieldDiffs field made JSON.deserialize() throw "Apex Type unsupported in JSON:
     * Object" here specifically, while every doSyncUp()-direct test stayed green.
     */
    @isTest
    static void syncUp_viaRestEntryPoint_withFieldDiffs_succeeds() {
        String jsonBody = '{"records":[' +
            '{"localId":"local-new","type":"HCP","mode":"new","relatedHCOId":"' + hco().Id + '",' +
            '"subjectName":"Dr. Rest Path New","fields":{"firstName":"Rest","lastName":"Path"}},' +
            '{"localId":"local-edit","type":"HCP","mode":"edit","subjectAccountId":"' + hcp().Id + '",' +
            '"subjectName":"Dr. Test Sync","fieldDiffs":{"phone":{"current":"111","requested":"222"}}}' +
            ']}';

        RestRequest req = new RestRequest();
        req.requestURI = '/services/apexrest/sciagen/v1/accounts';
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf(jsonBody);
        RestContext.request = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        SciagenAccountSyncService.SyncUpResult result = SciagenAccountSyncService.syncUp();
        Test.stopTest();

        System.assertEquals(true, result.success, 'A batch with both a new-mode and an edit-mode (fieldDiffs) record must parse and succeed');
        System.assertEquals(null, RestContext.response.statusCode, 'No exception means the 400-on-exception branch in syncUp() never runs');
        System.assertEquals(2, result.results.size());
        System.assertEquals(true, result.results[0].success, 'new-mode record');
        System.assertEquals(true, result.results[1].success, 'edit-mode (fieldDiffs) record');
    }
}