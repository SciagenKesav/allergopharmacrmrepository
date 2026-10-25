@isTest
private class SentEmailSendServiceTest {

    // Deliverability is an org setting that can reject sends even inside tests, so tests deliver in simulation:
    // the whole send pipeline runs (consent, template, daily limit, chunking), only Messaging.sendEmail is skipped.
    static { SentEmailSendService.simulateDelivery = true; }


    private static final String APPROVED_SUBJECT = 'A note for {{HCP Name}}';
    private static final String APPROVED_BODY = 'Dear {{HCP Name}},\nApproved text about {{Brand Name}}.\nRegards, {{Rep Name}}';

    private static Sciagen_Account__c hcp;
    private static Email_Template__c tmpl;
    private static Approved_Content__c allowedContent;
    private static Approved_Content__c otherContent;

    private static void seed(Datetime consentCapturedAt, Boolean optedIn) {
        seed(consentCapturedAt, optedIn, null);
    }

    private static void seed(Datetime consentCapturedAt, Boolean optedIn, Id hcpOwner) {
        hcp = new Sciagen_Account__c(Type__c = 'HCP', Name = 'Dr. Consent Test', Prefix__c = 'Dr.', First_Name__c = 'Consent', Last_Name__c = 'Test');
        if (hcpOwner != null) hcp.OwnerId = hcpOwner;
        insert hcp;
        Consent__c c = new Consent__c(Name = 'Consent', HCP__c = hcp.Id, Captured_At__c = consentCapturedAt, Signed__c = true);
        insert c;
        insert new Consent_Email__c(Name = 'Email', Consent__c = c.Id, Email__c = 'Doctor@Example.com', Opted_In__c = optedIn);
        tmpl = new Email_Template__c(Name = 'T', Template_Name__c = 'T', Subject__c = APPROVED_SUBJECT, Body__c = APPROVED_BODY,
            Brand__c = 'ACAROID', CMS_Document_Id__c = 'T-1');
        insert tmpl;
        allowedContent = new Approved_Content__c(Name = 'A', Content_Name__c = 'Brochure', Asset_URL__c = 'https://s3.example.com/a.pdf', Kind__c = 'PDF');
        otherContent = new Approved_Content__c(Name = 'B', Content_Name__c = 'Other', Asset_URL__c = 'https://s3.example.com/b.pdf', Kind__c = 'PDF');
        insert new List<Approved_Content__c>{ allowedContent, otherContent };
        insert new Email_Template_Content__c(Name = 'Allowed', Template__c = tmpl.Id, Content__c = allowedContent.Id);
    }

    private static Sent_Email__c email(String to, String attachmentIds) {
        return new Sent_Email__c(Name = 'E', HCP__c = hcp.Id, Folder__c = 'Sent', To_Email__c = to, Subject__c = 'Hello',
            Body_Text__c = 'Dear Doctor, approved text.', Rep_Note__c = 'Great meeting you.', Template__c = tmpl.Id,
            Attachment_Content_Ids__c = attachmentIds, Client_Id__c = 'CID-' + Crypto.getRandomInteger());
    }

    private static Sent_Email__c run(Sent_Email__c e) {
        Test.startTest();
        insert e;
        Test.stopTest();
        return reload(e.Id);
    }

    private static Sent_Email__c reload(Id id) {
        return [SELECT Status__c, Status_Message__c, Sent_At__c, Subject__c, Body_Text__c FROM Sent_Email__c WHERE Id = :id];
    }

    private static String fileJson(String subject, String body) {
        return JSON.serialize(new Map<String, Object>{ 'schemaVersion' => 1, 'subject' => subject, 'bodyText' => body });
    }

    @isTest static void newSentEmailIsQueuedThenSent() {
        seed(Datetime.now().addDays(-10), true);
        Sent_Email__c r = run(email('doctor@example.com', String.valueOf(allowedContent.Id)));
        System.assertEquals('Sent', r.Status__c, r.Status_Message__c);
        System.assertNotEquals(null, r.Sent_At__c);
    }

    @isTest static void sendsApprovedTemplateTextNotClientText() {
        seed(Datetime.now().addDays(-10), true);
        Sent_Email__c e = email('doctor@example.com', String.valueOf(allowedContent.Id));
        e.Subject__c = 'Unapproved promo subject';
        e.Body_Text__c = 'Buy now! Off-label claim.';
        Sent_Email__c r = run(e);
        System.assertEquals('Sent', r.Status__c, r.Status_Message__c);
        // What was delivered is written back: rendered approved copy, never the client's text.
        System.assertEquals('A note for Dr. Consent Test', r.Subject__c);
        System.assert(r.Body_Text__c.startsWith('Dear Dr. Consent Test,\nApproved text about ACAROID.\nRegards, ' + UserInfo.getName()), r.Body_Text__c);
        System.assert(!r.Body_Text__c.contains('Off-label'), r.Body_Text__c);
        // The rep's note is in its own labelled block after the approved text.
        Integer noteAt = r.Body_Text__c.indexOf('Personal note from');
        System.assert(noteAt > r.Body_Text__c.indexOf('Regards'), r.Body_Text__c);
        System.assert(r.Body_Text__c.contains('(not part of the approved content):\nGreat meeting you.'), r.Body_Text__c);
        System.assert(r.Body_Text__c.contains('Brochure: https://s3.example.com/a.pdf'), r.Body_Text__c);
    }

    @isTest static void repWithMobilePermissionSetCanQueueAndSend() {
        User rep = SciagenTestUsers.mobileRep('aerep');
        seed(Datetime.now().addDays(-10), true, rep.Id);
        Sent_Email__c e = email('doctor@example.com', null);
        Test.startTest();
        System.runAs(rep) { insert e; }
        Test.stopTest();
        Sent_Email__c r = reload(e.Id);
        System.assertEquals('Sent', r.Status__c, r.Status_Message__c);
        System.assert(r.Body_Text__c.contains('Regards, Test User aerep'), r.Body_Text__c);
    }

    @isTest static void failsWithoutTemplate() {
        seed(Datetime.now().addDays(-10), true);
        Sent_Email__c e = email('doctor@example.com', null);
        e.Template__c = null;
        Sent_Email__c r = run(e);
        System.assertEquals('Failed', r.Status__c);
        System.assert(r.Status_Message__c.contains('approved template'), r.Status_Message__c);
        System.assertEquals('Hello', r.Subject__c, 'a failed email keeps the client record untouched');
    }

    @isTest static void failsForRepSavedTemplate() {
        seed(Datetime.now().addDays(-10), true);
        tmpl.Is_User_Saved__c = true;
        update tmpl;
        Sent_Email__c r = run(email('doctor@example.com', null));
        System.assertEquals('Failed', r.Status__c);
        System.assert(r.Status_Message__c.contains('CMS-approved'), r.Status_Message__c);
    }

    @isTest static void failsForUnknownMergeToken() {
        seed(Datetime.now().addDays(-10), true);
        tmpl.Body__c = 'Dear {{HCP Name}}, your discount code is {{Coupon}}.';
        update tmpl;
        Sent_Email__c r = run(email('doctor@example.com', null));
        System.assertEquals('Failed', r.Status__c);
        System.assert(r.Status_Message__c.contains('{{Coupon}}'), r.Status_Message__c);
    }

    @isTest static void repPhoneTokenNeedsAPhoneOnFile() {
        seed(Datetime.now().addDays(-10), true);
        tmpl.Body__c = 'Call me on {{Rep Phone}}.';
        update tmpl;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            update new User(Id = UserInfo.getUserId(), MobilePhone = null, Phone = null);
        }
        Sent_Email__c r = run(email('doctor@example.com', null));
        System.assertEquals('Failed', r.Status__c);
        System.assert(r.Status_Message__c.contains('{{Rep Phone}}'), r.Status_Message__c);
    }

    @isTest static void repPhoneTokenUsesMobilePhone() {
        seed(Datetime.now().addDays(-10), true);
        tmpl.Body__c = 'Call me on {{Rep Phone}} in {{ Territory }}? {{HCO Name}} / {{Meeting Date}} / {{Next Visit Date}} / {{Call Date}}';
        update tmpl;
        Territory__c terr = new Territory__c(Name = 'Delhi-East', Territory_Code__c = 'TDLE', Type__c = 'Territory');
        insert terr;
        insert new Account_Territory__c(Account__c = hcp.Id, Territory__c = terr.Id);
        Sciagen_Account__c hco = new Sciagen_Account__c(Type__c = 'HCO', Name = 'City Clinic');
        insert hco;
        insert new Affiliation__c(HCP__c = hcp.Id, HCO__c = hco.Id, Is_Primary__c = true);
        System.runAs(new User(Id = UserInfo.getUserId())) {
            update new User(Id = UserInfo.getUserId(), MobilePhone = '+91 98100 00000');
        }
        Sent_Email__c r = run(email('doctor@example.com', null));
        System.assertEquals('Sent', r.Status__c, r.Status_Message__c);
        System.assert(r.Body_Text__c.startsWith('Call me on +91 98100 00000 in Delhi-East? City Clinic / '), r.Body_Text__c);
        System.assert(!r.Body_Text__c.contains('{{'), r.Body_Text__c);
    }

    @isTest static void failsWhenComposedFromStaleTemplateVersion() {
        seed(Datetime.now().addDays(-10), true);
        tmpl.Content_Hash__c = 'aaaa';
        update tmpl;
        Sent_Email__c e = email('doctor@example.com', null);
        e.Content_Hash__c = 'bbbb';
        Sent_Email__c r = run(e);
        System.assertEquals('Failed', r.Status__c);
        System.assert(r.Status_Message__c.contains('out-of-date'), r.Status_Message__c);
    }

    @isTest static void failsWhenNoteTooLong() {
        seed(Datetime.now().addDays(-10), true);
        Sent_Email__c e = email('doctor@example.com', null);
        e.Rep_Note__c = 'x'.repeat(501);
        Sent_Email__c r = run(e);
        System.assertEquals('Failed', r.Status__c);
        System.assert(r.Status_Message__c.contains('500'), r.Status_Message__c);
    }

    @isTest static void usesSalesforceHostedTemplateFileAndVerifiesHash() {
        seed(Datetime.now().addDays(-10), true);
        String json = fileJson('File subject for {{HCP Name}}', 'File body for {{HCP Name}}.');
        ContentVersion cv = new ContentVersion(Title = 'tmpl', PathOnClient = 'tmpl.json', VersionData = Blob.valueOf(json));
        insert cv;
        String hash = ApprovedEmailRenderer.sha256Hex(Blob.valueOf(json));
        tmpl.Body__c = 'Fallback body, must not be used.';
        tmpl.Asset_URL__c = 'https://x.file.force.com/sfc/dist/version/download/?oid=00D000000000001&ids=' +
            String.valueOf(cv.Id).left(15) + '&d=%2Fa%2Fabc&asPdf=false';
        tmpl.Content_Hash__c = hash.toUpperCase();
        update tmpl;
        Sent_Email__c e = email('doctor@example.com', null);
        e.Content_Hash__c = hash;
        Sent_Email__c r = run(e);
        System.assertEquals('Sent', r.Status__c, r.Status_Message__c);
        System.assertEquals('File subject for Dr. Consent Test', r.Subject__c);
        System.assert(r.Body_Text__c.startsWith('File body for Dr. Consent Test.'), r.Body_Text__c);
    }

    @isTest static void rejectsTemplateFileWhoseHashDoesNotMatch() {
        seed(Datetime.now().addDays(-10), true);
        ContentVersion cv = new ContentVersion(Title = 'tmpl', PathOnClient = 'tmpl.json',
            VersionData = Blob.valueOf(fileJson('S', 'Tampered body')));
        insert cv;
        tmpl.Asset_URL__c = 'https://x.file.force.com/sfc/dist/version/download/?ids=' + cv.Id;
        tmpl.Content_Hash__c = ApprovedEmailRenderer.sha256Hex(Blob.valueOf('the approved file'));
        update tmpl;
        Sent_Email__c r = run(email('doctor@example.com', null));
        System.assertEquals('Failed', r.Status__c);
        System.assert(r.Status_Message__c.contains('integrity'), r.Status_Message__c);
    }

    private class S3Mock implements HttpCalloutMock {
        Integer status; String body;
        S3Mock(Integer status, String body) { this.status = status; this.body = body; }
        public HttpResponse respond(HttpRequest req) {
            System.assertEquals('GET', req.getMethod());
            HttpResponse res = new HttpResponse();
            res.setStatusCode(status);
            res.setBody(body);
            return res;
        }
    }

    @isTest static void fetchesS3TemplateFile() {
        seed(Datetime.now().addDays(-10), true);
        String json = fileJson('S3 subject', 'S3 body for {{HCP}} from {{REP}}.');
        tmpl.Body__c = null;
        tmpl.Asset_URL__c = 'https://bucket.s3.amazonaws.com/t.json?X-Amz-Signature=abc';
        tmpl.Content_Hash__c = ApprovedEmailRenderer.sha256Hex(Blob.valueOf(json));
        update tmpl;
        Test.setMock(HttpCalloutMock.class, new S3Mock(200, json));
        Sent_Email__c r = run(email('doctor@example.com', null));
        System.assertEquals('Sent', r.Status__c, r.Status_Message__c);
        System.assert(r.Body_Text__c.startsWith('S3 body for Dr. Consent Test from ' + UserInfo.getName() + '.'), r.Body_Text__c);
    }

    @isTest static void s3FailureWithNoFallbackFails() {
        seed(Datetime.now().addDays(-10), true);
        tmpl.Body__c = null;
        tmpl.Asset_URL__c = 'https://bucket.s3.amazonaws.com/t.json';
        update tmpl;
        Test.setMock(HttpCalloutMock.class, new S3Mock(403, 'denied'));
        Sent_Email__c r = run(email('doctor@example.com', null));
        System.assertEquals('Failed', r.Status__c);
        System.assert(r.Status_Message__c.contains('could not be loaded'), r.Status_Message__c);
    }

    @isTest static void sendsMoreThanTenInOneTransaction() {
        seed(Datetime.now().addDays(-10), true);
        List<Sent_Email__c> rows = new List<Sent_Email__c>();
        for (Integer i = 0; i < 15; i++) rows.add(email('doctor@example.com', null));
        Test.startTest();
        insert rows;
        Test.stopTest();
        System.assertEquals(15, [SELECT COUNT() FROM Sent_Email__c WHERE Status__c = 'Sent']);
    }

    @isTest static void chunksLargeBatchesIntoFollowUpJobs() {
        seed(Datetime.now().addDays(-10), true);
        List<Sent_Email__c> rows = new List<Sent_Email__c>();
        for (Integer i = 0; i < 3; i++) rows.add(email('doctor@example.com', null));
        insert rows; // its job is not run: no startTest/stopTest around this insert
        Set<Id> ids = new Map<Id, Sent_Email__c>(rows).keySet();
        Test.startTest();
        SentEmailSendService.maxPerJob = 2;
        SentEmailSendService.processIds(ids);
        System.assertEquals(2, [SELECT COUNT() FROM Sent_Email__c WHERE Status__c = 'Sent']);
        System.assertEquals(1, [SELECT COUNT() FROM Sent_Email__c WHERE Status__c = 'Queued']);
        Test.stopTest(); // runs the chained job
        System.assertEquals(3, [SELECT COUNT() FROM Sent_Email__c WHERE Status__c = 'Sent']);
    }

    @isTest static void malformedAttachmentIdFailsOnlyThatRow() {
        seed(Datetime.now().addDays(-10), true);
        Sent_Email__c bad = email('doctor@example.com', 'not-an-id');
        Sent_Email__c good = email('doctor@example.com', null);
        Test.startTest();
        insert new List<Sent_Email__c>{ bad, good };
        Test.stopTest();
        System.assertEquals('Failed', reload(bad.Id).Status__c);
        System.assertEquals('Sent', reload(good.Id).Status__c);
    }

    @isTest static void clientCannotPreSetDeliveryStatus() {
        seed(Datetime.now().addDays(-10), false); // no opt-in -> must fail, even if the client claims Sent
        Sent_Email__c e = email('doctor@example.com', null);
        e.Status__c = 'Sent';
        Sent_Email__c r = run(e);
        System.assertEquals('Failed', r.Status__c);
    }

    @isTest static void failsWithoutOptIn() {
        seed(Datetime.now().addDays(-10), false);
        Sent_Email__c r = run(email('doctor@example.com', null));
        System.assertEquals('Failed', r.Status__c);
        System.assert(r.Status_Message__c.contains('consent'), r.Status_Message__c);
    }

    @isTest static void failsForAddressNotConsentedTo() {
        seed(Datetime.now().addDays(-10), true);
        Sent_Email__c r = run(email('someone.else@example.com', null));
        System.assertEquals('Failed', r.Status__c);
    }

    @isTest static void failsWhenConsentExpired() {
        seed(Datetime.now().addYears(-4), true);
        Sent_Email__c r = run(email('doctor@example.com', null));
        System.assertEquals('Failed', r.Status__c);
    }

    @isTest static void failsWhenTemplateWithdrawn() {
        seed(Datetime.now().addDays(-10), true);
        tmpl.Is_Withdrawn__c = true;
        update tmpl;
        Sent_Email__c r = run(email('doctor@example.com', null));
        System.assertEquals('Failed', r.Status__c);
        System.assert(r.Status_Message__c.contains('withdrawn'), r.Status_Message__c);
    }

    @isTest static void failsWhenTemplateExpired() {
        seed(Datetime.now().addDays(-10), true);
        tmpl.Expiry_Date__c = Date.today().addDays(-1);
        update tmpl;
        System.assertEquals('Failed', run(email('doctor@example.com', null)).Status__c);
    }

    @isTest static void failsForAttachmentNotAllowedByTemplate() {
        seed(Datetime.now().addDays(-10), true);
        Sent_Email__c r = run(email('doctor@example.com', allowedContent.Id + ',' + otherContent.Id));
        System.assertEquals('Failed', r.Status__c);
        System.assert(r.Status_Message__c.contains('attachment'), r.Status_Message__c);
    }

    @isTest static void failsWhenDailyLimitReached() {
        seed(Datetime.now().addDays(-10), true);
        List<Sent_Email__c> prior = new List<Sent_Email__c>();
        for (Integer i = 0; i < SentEmailSendService.DAILY_LIMIT; i++) {
            prior.add(new Sent_Email__c(Name = 'P' + i, HCP__c = hcp.Id, Folder__c = 'Draft', Status__c = 'Sent', Sent_At__c = Datetime.now()));
        }
        insert prior;
        Sent_Email__c r = run(email('doctor@example.com', null));
        System.assertEquals('Failed', r.Status__c);
        System.assert(r.Status_Message__c.contains('limit'), r.Status_Message__c);
    }

    @isTest static void draftIsNeverQueued() {
        seed(Datetime.now().addDays(-10), true);
        Sent_Email__c e = email('doctor@example.com', null);
        e.Folder__c = 'Draft';
        Sent_Email__c r = run(e);
        System.assertEquals(null, r.Status__c);
    }
}