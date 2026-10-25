@isTest
private class CMSContentReceiverTest {

    static CMSContentReceiver.ContentPushRequest pushReq(String cmsDocumentId, String title, String approvalStatus,
            Integer slideNo, String slideName, String fileType, String assetUrl) {
        CMSContentReceiver.ContentPushRequest req = new CMSContentReceiver.ContentPushRequest();
        req.cmsDocumentId = cmsDocumentId;
        req.title = title;
        req.approvalStatus = approvalStatus;
        req.slideNo = slideNo;
        req.slideName = slideName;
        req.assetFileType = fileType;
        req.assetUrl = assetUrl;
        return req;
    }

    @isTest
    static void testApprovedPushCreatesMultiSlideDeckAcrossCalls() {
        Product__c prod = new Product__c(Brand_Name__c = 'Emrok', Division__c = 'Cardiology', SKU_Code__c = 'EMROK-SKU-1', Product_Code__c = 'CMS-TEST-P1');
        insert prod;

        // A multi-page deck arrives as one call per page, all sharing cmsDocumentId — the CMS
        // never batches pages into a single request.
        // A real CMS resends the full document-level metadata (brand, product, MLR ref, etc.)
        // identically with every page's call, not just the first — this test does the same.
        CMSContentReceiver.ContentPushRequest req1 = pushReq('Wockhardt_P-2026-0001',
            'EMROK | EMROK O — Robust Efficacy and Safety', 'Approved Promotional',
            1, 'Efficacy Overview', 'PDF', 'https://sciagen-cms-assets.s3.amazonaws.com/wockhardt/p1.pdf?X-Amz-Signature=abc');
        CMSContentReceiver.ContentPushRequest req2 = pushReq('Wockhardt_P-2026-0001',
            'EMROK | EMROK O — Robust Efficacy and Safety', 'Approved Promotional',
            2, 'Dosing Guide', 'PDF', 'https://sciagen-cms-assets.s3.amazonaws.com/wockhardt/p2.pdf?X-Amz-Signature=abc');
        CMSContentReceiver.ContentPushRequest req3 = pushReq('Wockhardt_P-2026-0001',
            'EMROK | EMROK O — Robust Efficacy and Safety', 'Approved Promotional',
            3, 'Safety Data', 'PDF', 'https://sciagen-cms-assets.s3.amazonaws.com/wockhardt/p3.pdf?X-Amz-Signature=abc');
        for (CMSContentReceiver.ContentPushRequest r : new List<CMSContentReceiver.ContentPushRequest>{ req1, req2, req3 }) {
            r.brand = 'ACAROID';
            r.productSkuCode = 'EMROK-SKU-1';
            r.expiryDate = '2026-12-31';
            r.mlrReference = 'MLR-2026-CV-0047';
        }

        Test.startTest();
        CMSContentReceiver.ContentPushResult result1 = CMSContentReceiver.processPush(req1);
        CMSContentReceiver.ContentPushResult result2 = CMSContentReceiver.processPush(req2);
        CMSContentReceiver.ContentPushResult result3 = CMSContentReceiver.processPush(req3);
        Test.stopTest();

        System.assertEquals(true, result1.success, 'Push should succeed: ' + result1.message);
        System.assertEquals(result1.presentationId, result2.presentationId, 'Every page shares the same Presentation__c');
        System.assertEquals(result1.presentationId, result3.presentationId, 'Every page shares the same Presentation__c');
        System.assertEquals(result1.approvedContentId, result2.approvedContentId);

        Presentation__c pres = [SELECT CMS_Document_Id__c, Approval_Status__c, Brand__c FROM Presentation__c WHERE Id = :result1.presentationId];
        System.assertEquals('Wockhardt_P-2026-0001', pres.CMS_Document_Id__c);
        System.assertEquals('Approved Promotional', pres.Approval_Status__c);
        System.assertEquals('ACAROID', pres.Brand__c);

        List<Slide__c> slides = [SELECT Slide_No__c, Slide_Name__c, File_Type__c, Asset_URL__c FROM Slide__c WHERE Presentation__c = :result1.presentationId ORDER BY Slide_No__c];
        System.assertEquals(3, slides.size());
        System.assertEquals(1, slides[0].Slide_No__c);
        System.assertEquals('Efficacy Overview', slides[0].Slide_Name__c);
        System.assertEquals('PDF', slides[0].File_Type__c);
        System.assertEquals('https://sciagen-cms-assets.s3.amazonaws.com/wockhardt/p1.pdf?X-Amz-Signature=abc', slides[0].Asset_URL__c);
        System.assertEquals(3, slides[2].Slide_No__c);
        System.assertEquals('Safety Data', slides[2].Slide_Name__c);
        System.assertEquals('https://sciagen-cms-assets.s3.amazonaws.com/wockhardt/p3.pdf?X-Amz-Signature=abc', slides[2].Asset_URL__c);

        // Approved_Content__c only ever takes page 1's signed URL — later pages don't touch it.
        Approved_Content__c ac = [SELECT Asset_URL__c FROM Approved_Content__c WHERE Id = :result1.approvedContentId];
        System.assertEquals('https://sciagen-cms-assets.s3.amazonaws.com/wockhardt/p1.pdf?X-Amz-Signature=abc', ac.Asset_URL__c);
        System.assertEquals(0, [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :result1.approvedContentId], 'No Salesforce File should be created — assets live in S3 now');
    }

    @isTest
    static void testRepushUpdatesExistingSlideInPlaceWithoutTouchingOthers() {
        CMSContentReceiver.ContentPushResult first = CMSContentReceiver.processPush(
            pushReq('Wockhardt_P-2026-0004', 'Repush Test Deck', 'Approved Promotional',
                1, 'Original Slide 1', 'PDF', 'https://s3.example.com/p1-v1.pdf?sig=1'));
        CMSContentReceiver.processPush(
            pushReq('Wockhardt_P-2026-0004', 'Repush Test Deck', 'Approved Promotional',
                2, 'Original Slide 2', 'PDF', 'https://s3.example.com/p2.pdf?sig=1'));
        System.assertEquals(2, [SELECT COUNT() FROM Slide__c WHERE Presentation__c = :first.presentationId]);

        // Re-push a corrected slide 1 (fresh signed URL) and a new slide 3 — slide 2 isn't
        // mentioned again and must be left alone, not deleted.
        Test.startTest();
        CMSContentReceiver.ContentPushResult second = CMSContentReceiver.processPush(
            pushReq('Wockhardt_P-2026-0004', 'Repush Test Deck', 'Approved Promotional',
                1, 'Corrected Slide 1', 'PDF', 'https://s3.example.com/p1-v2.pdf?sig=2'));
        CMSContentReceiver.processPush(
            pushReq('Wockhardt_P-2026-0004', 'Repush Test Deck', 'Approved Promotional',
                3, 'New Slide 3', 'PDF', 'https://s3.example.com/p3.pdf?sig=1'));
        Test.stopTest();

        System.assertEquals(true, second.success);
        System.assertEquals(first.presentationId, second.presentationId, 'Same cmsDocumentId must reuse the same Presentation__c');

        List<Slide__c> slides = [SELECT Slide_No__c, Slide_Name__c, Asset_URL__c FROM Slide__c WHERE Presentation__c = :first.presentationId ORDER BY Slide_No__c];
        System.assertEquals(3, slides.size(), 'Slide 2 should still exist untouched, plus the corrected slide 1 and new slide 3');
        System.assertEquals('Corrected Slide 1', slides[0].Slide_Name__c);
        System.assertEquals('https://s3.example.com/p1-v2.pdf?sig=2', slides[0].Asset_URL__c);
        System.assertEquals('Original Slide 2', slides[1].Slide_Name__c);
        System.assertEquals('New Slide 3', slides[2].Slide_Name__c);
    }

    @isTest
    static void testOutOfOrderPageOneNeverOverwritesApprovedContentFromLaterPage() {
        // Slide 2 pushed before slide 1 has ever arrived — Approved_Content__c should be
        // created (Kind__c is required) but with no Asset_URL__c yet.
        CMSContentReceiver.ContentPushResult firstCall = CMSContentReceiver.processPush(
            pushReq('Wockhardt_P-2026-0006', 'Out of Order Deck', 'Approved Promotional',
                2, 'Slide 2', 'PDF', 'https://s3.example.com/p2.pdf?sig=1'));
        Approved_Content__c acAfterSlide2 = [SELECT Asset_URL__c FROM Approved_Content__c WHERE Id = :firstCall.approvedContentId];
        System.assertEquals(null, acAfterSlide2.Asset_URL__c, 'Page 2 alone must not set the lead asset URL');

        Test.startTest();
        CMSContentReceiver.processPush(
            pushReq('Wockhardt_P-2026-0006', 'Out of Order Deck', 'Approved Promotional',
                1, 'Slide 1', 'PDF', 'https://s3.example.com/p1.pdf?sig=1'));
        Test.stopTest();

        Approved_Content__c acAfterSlide1 = [SELECT Asset_URL__c FROM Approved_Content__c WHERE Id = :firstCall.approvedContentId];
        System.assertEquals('https://s3.example.com/p1.pdf?sig=1', acAfterSlide1.Asset_URL__c, 'Page 1 arriving later must still set the lead asset URL');
    }

    /// A real bug this test guards against: the CMS sent an unrecognized
    /// assetFileType string for a genuine PNG push, which mapFileType()
    /// silently coerced to 'PDF' — the iPad/web CLM viewer then tried to
    /// open real PNG bytes with PDFKit and failed to render it at all. The
    /// fix infers the type from the asset URL's own extension whenever
    /// assetFileType isn't recognized, rather than defaulting to PDF blind.
    @isTest
    static void testUnrecognizedAssetFileTypeInfersFromUrlExtension() {
        Test.startTest();
        CMSContentReceiver.ContentPushResult pngResult = CMSContentReceiver.processPush(
            pushReq('Wockhardt_P-2026-0007', 'Image Push Test', 'Approved Promotional',
                1, 'Cover Deck', 'Image', 'https://s3.example.com/cover.pptx?sig=1'));
        CMSContentReceiver.ContentPushResult unknownResult = CMSContentReceiver.processPush(
            pushReq('Wockhardt_P-2026-0007', 'Image Push Test', 'Approved Promotional',
                2, 'Truly Unknown', 'SomethingElseEntirely', 'https://s3.example.com/mystery-no-extension'));
        Test.stopTest();

        Slide__c pngSlide = [SELECT File_Type__c FROM Slide__c WHERE Id = :pngResult.slideId];
        // Uses an extension the Slide File Type picklist (a restricted list: Native, HTML, PDF, PPT, Word, Video,
        // Audio) can hold -- image extensions such as .png are not in that list.
        System.assertEquals('PPT', pngSlide.File_Type__c,
            'An unrecognized assetFileType with a .pptx asset URL should infer PPT, not silently fall back to PDF');

        Slide__c unknownSlide = [SELECT File_Type__c FROM Slide__c WHERE Id = :unknownResult.slideId];
        System.assertEquals('PDF', unknownSlide.File_Type__c,
            'With no recognizable extension either, PDF remains the safe fallback');
    }

    @isTest
    static void testNonApprovedContentIsSkipped() {
        Test.startTest();
        CMSContentReceiver.ContentPushResult result = CMSContentReceiver.processPush(
            pushReq('Wockhardt_P-2026-0002', 'Draft document', 'Medical Approval', 1, null, null, null));
        Test.stopTest();

        System.assertEquals(true, result.success);
        System.assertEquals(0, [SELECT COUNT() FROM Presentation__c WHERE CMS_Document_Id__c = 'Wockhardt_P-2026-0002']);
    }

    @isTest
    static void testMissingDocumentIdFails() {
        CMSContentReceiver.ContentPushRequest req = new CMSContentReceiver.ContentPushRequest();
        req.approvalStatus = 'Approved Promotional';

        Test.startTest();
        CMSContentReceiver.ContentPushResult result = CMSContentReceiver.processPush(req);
        Test.stopTest();

        System.assertEquals(false, result.success);
    }

    @isTest
    static void testMissingSlideNoFails() {
        CMSContentReceiver.ContentPushRequest req = new CMSContentReceiver.ContentPushRequest();
        req.cmsDocumentId = 'Wockhardt_P-2026-0005';
        req.approvalStatus = 'Approved Promotional';
        // slideNo intentionally left null

        Test.startTest();
        CMSContentReceiver.ContentPushResult result = CMSContentReceiver.processPush(req);
        Test.stopTest();

        System.assertEquals(false, result.success);
    }

    @isTest
    static void testRestEndpointHttpPost() {
        Test.startTest();
        RestRequest req = new RestRequest();
        req.requestURI = '/services/apexrest/cms/v1/content';
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf('{"cmsDocumentId":"Wockhardt_P-2026-0003","title":"Test Doc","approvalStatus":"Approved Promotional","slideNo":1,"slideName":"Only Slide","assetUrl":"https://s3.example.com/only.pdf?sig=1"}');
        RestContext.request = req;
        RestContext.response = new RestResponse();

        CMSContentReceiver.ContentPushResult result = CMSContentReceiver.receive();
        Test.stopTest();

        System.assertEquals(true, result.success);
        System.assertEquals(1, result.slideNo);
        System.assertEquals('https://s3.example.com/only.pdf?sig=1', result.assetUrl);
    }

    @isTest
    static void testFirstPushOfANewDeckCreatesANewContentAlertOnPageOneOnly() {
        Test.startTest();
        CMSContentReceiver.processPush(pushReq('Wockhardt_P-2026-0004', 'Emrok Detailer', 'Approved Promotional',
            1, 'Cover', 'PDF', 'https://s3.example.com/cover.pdf?sig=1'));
        CMSContentReceiver.processPush(pushReq('Wockhardt_P-2026-0004', 'Emrok Detailer', 'Approved Promotional',
            2, 'Page 2', 'PDF', 'https://s3.example.com/p2.pdf?sig=1'));
        Test.stopTest();

        List<Content_Alert__c> alerts = [SELECT Title__c, Kind__c, Presentation__c FROM Content_Alert__c];
        System.assertEquals(1, alerts.size(), 'exactly one alert for the whole push — none for page 2');
        System.assertEquals('New', alerts[0].Kind__c);
        System.assert(alerts[0].Title__c.contains('now available'), alerts[0].Title__c);
    }

    @isTest
    static void testRepushingAnAlreadyKnownDeckCreatesAnUpdatedContentAlert() {
        CMSContentReceiver.processPush(pushReq('Wockhardt_P-2026-0005', 'Glaritus Brochure', 'Approved Promotional',
            1, 'Cover', 'PDF', 'https://s3.example.com/v1.pdf?sig=1'));

        Test.startTest();
        CMSContentReceiver.processPush(pushReq('Wockhardt_P-2026-0005', 'Glaritus Brochure', 'Approved Promotional',
            1, 'Cover', 'PDF', 'https://s3.example.com/v2.pdf?sig=2'));
        Test.stopTest();

        List<Content_Alert__c> alerts = [SELECT Kind__c FROM Content_Alert__c ORDER BY CreatedDate];
        System.assertEquals(2, alerts.size(), 'one New alert from the first push, one Updated alert from the re-push');
        System.assertEquals('New', alerts[0].Kind__c);
        System.assertEquals('Updated', alerts[1].Kind__c);
    }

    @isTest
    static void testBrandMatchingIsCaseInsensitiveAndUnknownBrandDoesNotFailThePush() {
        CMSContentReceiver.ContentPushRequest lower = pushReq('BRD-1', 'Lower', 'Approved Promotional', 1, 'S', 'PDF', 'https://x/p1.pdf');
        lower.brand = 'acaroid';
        System.assertEquals(true, CMSContentReceiver.processPush(lower).success);
        System.assertEquals('ACAROID', [SELECT Brand__c FROM Presentation__c WHERE CMS_Document_Id__c = 'BRD-1'].Brand__c);

        CMSContentReceiver.ContentPushRequest unknown = pushReq('BRD-2', 'Unknown', 'Approved Promotional', 1, 'S', 'PDF', 'https://x/p1.pdf');
        unknown.brand = 'Some New Brand';
        CMSContentReceiver.ContentPushResult r = CMSContentReceiver.processPush(unknown);
        System.assertEquals(true, r.success, r.message);
        System.assertEquals(null, [SELECT Brand__c FROM Presentation__c WHERE CMS_Document_Id__c = 'BRD-2'].Brand__c, 'an unrecognised brand is left blank, not rejected');
        System.assertEquals('Other', [SELECT Brand__c FROM Slide__c WHERE Presentation__c = :r.presentationId].Brand__c);

        CMSContentReceiver.ContentPushRequest none = pushReq('BRD-3', 'None', 'Approved Promotional', 1, 'S', 'PDF', 'https://x/p1.pdf');
        System.assertEquals(true, CMSContentReceiver.processPush(none).success, 'a push with no brand still works');
    }

    // ---------------------------------------------------------------- isTraining / trainingType

    private static Presentation__c trainingOf(String docId) {
        return [SELECT Is_Training__c, Training_Type__c FROM Presentation__c WHERE CMS_Document_Id__c = :docId];
    }

    @isTest
    static void testIsTrainingAndTypeAreSaved() {
        CMSContentReceiver.ContentPushRequest r = pushReq('TRN-1', 'Onboarding', 'Approved Promotional', 1, 'Intro', 'PDF', 'https://x/p1.pdf');
        r.isTraining = true;
        r.trainingType = 'Medical';
        System.assertEquals(true, CMSContentReceiver.processPush(r).success);
        Presentation__c p = trainingOf('TRN-1');
        System.assertEquals(true, p.Is_Training__c);
        System.assertEquals('Medical', p.Training_Type__c);
    }

    @isTest
    static void testTrainingTypeMatchesIgnoringCaseAndSpacing() {
        CMSContentReceiver.ContentPushRequest r = pushReq('TRN-2', 'Policy', 'Approved Promotional', 1, 'Intro', 'PDF', 'https://x/p1.pdf');
        r.isTraining = true;
        r.trainingType = 'COMPLIANCE   AND  policy';   // different case and extra spaces than the picklist value
        CMSContentReceiver.processPush(r);
        System.assertEquals('Compliance and Policy', trainingOf('TRN-2').Training_Type__c);
    }

    @isTest
    static void testUnknownTrainingTypeIsLeftBlankAndPushStillSucceeds() {
        CMSContentReceiver.ContentPushRequest r = pushReq('TRN-3', 'Deck', 'Approved Promotional', 1, 'Intro', 'PDF', 'https://x/p1.pdf');
        r.isTraining = true;
        r.trainingType = 'Not A Real Type';
        System.assertEquals(true, CMSContentReceiver.processPush(r).success);
        Presentation__c p = trainingOf('TRN-3');
        System.assertEquals(true, p.Is_Training__c);
        System.assertEquals(null, p.Training_Type__c);
    }

    @isTest
    static void testOmittedFieldsKeepExistingValuesAndFalseClearsTheType() {
        CMSContentReceiver.ContentPushRequest first = pushReq('TRN-4', 'Deck', 'Approved Promotional', 1, 'Intro', 'PDF', 'https://x/p1.pdf');
        CMSContentReceiver.processPush(first);
        System.assertEquals(false, trainingOf('TRN-4').Is_Training__c, 'new deck without the flag is not training');

        CMSContentReceiver.ContentPushRequest flagged = pushReq('TRN-4', 'Deck', 'Approved Promotional', 1, 'Intro', 'PDF', 'https://x/p1.pdf');
        flagged.isTraining = true; flagged.trainingType = 'References';
        CMSContentReceiver.processPush(flagged);

        CMSContentReceiver.ContentPushRequest later = pushReq('TRN-4', 'Deck', 'Approved Promotional', 2, 'Next', 'PDF', 'https://x/p2.pdf');
        CMSContentReceiver.processPush(later);
        Presentation__c kept = trainingOf('TRN-4');
        System.assertEquals(true, kept.Is_Training__c, 'omitting isTraining must not reset it');
        System.assertEquals('References', kept.Training_Type__c, 'omitting trainingType must not clear it');

        CMSContentReceiver.ContentPushRequest cleared = pushReq('TRN-4', 'Deck', 'Approved Promotional', 3, 'Last', 'PDF', 'https://x/p3.pdf');
        cleared.isTraining = false;
        CMSContentReceiver.processPush(cleared);
        Presentation__c off = trainingOf('TRN-4');
        System.assertEquals(false, off.Is_Training__c);
        System.assertEquals(null, off.Training_Type__c, 'an explicit false clears the type');
    }

    @isTest
    static void testFieldsAreReadFromTheRestJsonBody() {
        RestRequest req = new RestRequest();
        req.requestUri = '/services/apexrest/cms/v1/content';
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf('{"cmsDocumentId":"TRN-5","title":"Json deck","approvalStatus":"Approved Promotional","slideNo":1,"assetFileType":"PDF","assetUrl":"https://x/s1.pdf","isTraining":true,"trainingType":"Company Communication"}');
        RestContext.request = req;
        RestContext.response = new RestResponse();
        CMSContentReceiver.ContentPushResult res = CMSContentReceiver.receive();
        System.assertEquals(true, res.success, res.message);
        Presentation__c p = trainingOf('TRN-5');
        System.assertEquals(true, p.Is_Training__c);
        System.assertEquals('Company Communication', p.Training_Type__c);
    }
}