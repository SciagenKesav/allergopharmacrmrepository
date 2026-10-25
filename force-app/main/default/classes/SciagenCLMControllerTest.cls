@isTest
private class SciagenCLMControllerTest {

    /// Brand__c values are org data (they differ per customer), so fixtures use
    /// whatever the org's restricted picklists actually offer.
    static String activeValue(Schema.SObjectField field, Integer index) {
        List<String> values = new List<String>();
        for (Schema.PicklistEntry e : field.getDescribe().getPicklistValues()) {
            if (e.isActive()) values.add(e.getValue());
        }
        return values.isEmpty() ? null : values[Math.min(index, values.size() - 1)];
    }
    static String presBrand() { return activeValue(Presentation__c.Brand__c, 0); }
    static String otherPresBrand() { return activeValue(Presentation__c.Brand__c, 1); }
    static String slideBrand() { return activeValue(Slide__c.Brand__c, 0); }

    @testSetup
    static void setup() {
        Sciagen_Account__c hcp = new Sciagen_Account__c(
            Type__c = 'HCP', Name = 'Dr. CLM Test', Prefix__c = 'Dr.', First_Name__c = 'CLM',
            Last_Name__c = 'Test', Specialty__c = 'Cardiology', HCP_Type__c = 'Physician'
        );
        insert hcp;

        Call_Visit_Report__c cvr = new Call_Visit_Report__c(
            HCP__c = hcp.Id, Visit_Date__c = Date.today(), Record_Status__c = 'Draft'
        );
        insert cvr;

        Product__c product = new Product__c(Product_Code__c = 'T-SCLMCT-1', Name = 'CLM Test Product', Brand_Name__c = 'Emrok', Division__c = 'Cardiology');
        insert product;

        Presentation__c approved = new Presentation__c(
            Presentation_Name__c = 'Emrok Detail Deck', Brand__c = presBrand(), Product__c = product.Id,
            Version__c = 'v1.0', Approval_Status__c = 'Approved Promotional'
        );
        Presentation__c draft = new Presentation__c(
            Presentation_Name__c = 'Unapproved Deck', Brand__c = otherPresBrand(), Approval_Status__c = 'Draft'
        );
        insert new List<Presentation__c>{ approved, draft };

        insert new List<Slide__c>{
            new Slide__c(
                Presentation__c = approved.Id, Slide_Name__c = 'Efficacy Overview', Slide_No__c = 1,
                File_Type__c = 'PDF', Brand__c = slideBrand(), Product__c = product.Id
            ),
            new Slide__c(
                Presentation__c = approved.Id, Slide_Name__c = 'Dosing Guide', Slide_No__c = 2,
                File_Type__c = 'PDF', Brand__c = slideBrand(), Product__c = product.Id
            )
        };
    }

    @isTest
    static void getPresentationLibraryOnlyReturnsApprovedPromotionalDecks() {
        Test.startTest();
        List<SciagenCLMController.PresentationListItem> items =
            SciagenCLMController.getPresentationLibrary(null, null, null);
        Test.stopTest();

        System.assertEquals(1, items.size(), 'Only the Approved Promotional deck should be returned');
        System.assertEquals('Emrok Detail Deck', items[0].name);
        System.assertEquals(presBrand(), items[0].brand);
        System.assertEquals('CLM Test Product', items[0].productName);
        System.assertEquals(2, items[0].slideCount);
        System.assertEquals(false, items[0].isFavorite, 'Not favorited yet');
    }

    @isTest
    static void getPresentationLibraryFiltersByBrand() {
        Test.startTest();
        List<SciagenCLMController.PresentationListItem> matching =
            SciagenCLMController.getPresentationLibrary(null, presBrand(), null);
        List<SciagenCLMController.PresentationListItem> nonMatching =
            SciagenCLMController.getPresentationLibrary(null, 'Cardiace', null);
        Test.stopTest();

        System.assertEquals(1, matching.size());
        System.assertEquals(0, nonMatching.size());
    }

    @isTest
    static void getPresentationDetailReturnsSlidesInOrder() {
        Presentation__c preso = [SELECT Id FROM Presentation__c WHERE Presentation_Name__c = 'Emrok Detail Deck' LIMIT 1];

        Test.startTest();
        SciagenCLMController.PresentationDetail detail = SciagenCLMController.getPresentationDetail(preso.Id);
        Test.stopTest();

        System.assertEquals('Emrok Detail Deck', detail.name);
        System.assertEquals(2, detail.slides.size());
        System.assertEquals('Efficacy Overview', detail.slides[0].name);
        System.assertEquals(1, detail.slides[0].slideNo);
        System.assertEquals('Dosing Guide', detail.slides[1].name);
        System.assertEquals(2, detail.slides[1].slideNo);
    }

    /// Its own presentation/slide, deliberately not added to @testSetup's
    /// "Emrok Detail Deck" — that fixture's exact slide count is depended on
    /// by logPresentationSessionCreatesSessionEventsAndLockedKeyMessages below.
    @isTest
    static void getPresentationDetailReturnsHtmlSlideContent() {
        Product__c product = new Product__c(Product_Code__c = 'T-SCLMCT-2', Name = 'HTML Test Product', Brand_Name__c = 'Emrok', Division__c = 'Cardiology');
        insert product;
        Presentation__c preso = new Presentation__c(
            Presentation_Name__c = 'Interactive Deck', Brand__c = presBrand(), Product__c = product.Id,
            Approval_Status__c = 'Approved Promotional'
        );
        insert preso;
        insert new Slide__c(
            Presentation__c = preso.Id, Slide_Name__c = 'Interactive Dosing Calculator', Slide_No__c = 1,
            File_Type__c = 'HTML', Brand__c = slideBrand(), Product__c = product.Id,
            HTML_Content__c = '<h1>Dosing Calculator</h1>'
        );

        Test.startTest();
        SciagenCLMController.PresentationDetail detail = SciagenCLMController.getPresentationDetail(preso.Id);
        Test.stopTest();

        System.assertEquals(1, detail.slides.size());
        System.assertEquals('HTML', detail.slides[0].fileType);
        System.assertEquals('<h1>Dosing Calculator</h1>', detail.slides[0].htmlContent);
    }

    @isTest
    static void logPresentationSessionCreatesSessionEventsAndLockedKeyMessages() {
        Call_Visit_Report__c cvr = [SELECT Id FROM Call_Visit_Report__c LIMIT 1];
        Presentation__c preso = [SELECT Id FROM Presentation__c WHERE Presentation_Name__c = 'Emrok Detail Deck' LIMIT 1];
        List<Slide__c> slides = [SELECT Id FROM Slide__c WHERE Presentation__c = :preso.Id ORDER BY Slide_No__c];

        List<SciagenCLMController.SlideCheckItem> checkItems = new List<SciagenCLMController.SlideCheckItem>();
        for (Integer i = 0; i < slides.size(); i++) {
            SciagenCLMController.SlideCheckItem item = new SciagenCLMController.SlideCheckItem();
            item.slideId = slides[i].Id;
            item.sequence = i + 1;
            item.timeSpentSec = 45;
            checkItems.add(item);
        }

        Test.startTest();
        SciagenCLMController.SessionLogResult result = SciagenCLMController.logPresentationSession(
            cvr.Id, preso.Id, Datetime.now(), Datetime.now().addMinutes(5), 30, 0, 0, JSON.serialize(checkItems)
        );
        Test.stopTest();

        System.assertEquals(2, result.keyMessagesCreated);

        List<Presentation_Session__c> sessions = [SELECT Id, Total_Slides__c FROM Presentation_Session__c WHERE CVR__c = :cvr.Id];
        System.assertEquals(1, sessions.size());
        System.assertEquals(2, sessions[0].Total_Slides__c);

        List<Slide_Event__c> events = [SELECT Id, Slide_Name__c, Sequence__c FROM Slide_Event__c WHERE Session__c = :sessions[0].Id ORDER BY Sequence__c];
        System.assertEquals(2, events.size());
        System.assertEquals('Efficacy Overview', events[0].Slide_Name__c);

        List<Key_Message__c> keyMessages = [SELECT Id, Message__c, Product__c, Locked__c FROM Key_Message__c WHERE CVR__c = :cvr.Id];
        System.assertEquals(2, keyMessages.size());
        for (Key_Message__c km : keyMessages) {
            System.assertEquals(true, km.Locked__c);
            System.assertEquals('CLM Test Product', km.Product__c, 'Should resolve the slide\'s actual Product, not its Brand');
        }
    }

    @isTest
    static void logPresentationSessionRejectsSubmittedCVR() {
        Call_Visit_Report__c cvr = [SELECT Id FROM Call_Visit_Report__c LIMIT 1];
        cvr.Record_Status__c = 'Submitted';
        update cvr;
        Presentation__c preso = [SELECT Id FROM Presentation__c WHERE Presentation_Name__c = 'Emrok Detail Deck' LIMIT 1];
        Slide__c slide = [SELECT Id FROM Slide__c WHERE Presentation__c = :preso.Id LIMIT 1];

        SciagenCLMController.SlideCheckItem item = new SciagenCLMController.SlideCheckItem();
        item.slideId = slide.Id;
        item.sequence = 1;
        List<SciagenCLMController.SlideCheckItem> checkItems = new List<SciagenCLMController.SlideCheckItem>{ item };

        Test.startTest();
        Boolean threw = false;
        try {
            SciagenCLMController.logPresentationSession(cvr.Id, preso.Id, null, null, null, null, null, JSON.serialize(checkItems));
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assertEquals(true, threw, 'Logging against a Submitted CVR should be rejected');
    }

    @isTest
    static void toggleFavoriteAddsAndRemovesAFavoriteRecord() {
        Presentation__c preso = [SELECT Id FROM Presentation__c WHERE Presentation_Name__c = 'Emrok Detail Deck' LIMIT 1];

        Test.startTest();
        SciagenCLMController.toggleFavorite(preso.Id, true);
        List<SciagenCLMController.PresentationListItem> afterFavoriting = SciagenCLMController.getPresentationLibrary(null, null, null);
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM Presentation_Favorite__c WHERE Presentation__c = :preso.Id AND User_Id__c = :UserInfo.getUserId()], 'One favorite row should exist after toggling on');
        System.assertEquals(true, afterFavoriting[0].isFavorite);

        SciagenCLMController.toggleFavorite(preso.Id, false);
        List<SciagenCLMController.PresentationListItem> afterUnfavoriting = SciagenCLMController.getPresentationLibrary(null, null, null);

        System.assertEquals(0, [SELECT COUNT() FROM Presentation_Favorite__c WHERE Presentation__c = :preso.Id], 'The favorite row should be removed after toggling off');
        System.assertEquals(false, afterUnfavoriting[0].isFavorite);
    }

    @isTest
    static void toggleFavoriteOnTwiceDoesNotCreateADuplicateRow() {
        Presentation__c preso = [SELECT Id FROM Presentation__c WHERE Presentation_Name__c = 'Emrok Detail Deck' LIMIT 1];

        Test.startTest();
        SciagenCLMController.toggleFavorite(preso.Id, true);
        SciagenCLMController.toggleFavorite(preso.Id, true);
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM Presentation_Favorite__c WHERE Presentation__c = :preso.Id]);
    }
}