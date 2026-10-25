@isTest
private class CMSEmailTemplateReceiverTest {

    static CMSEmailTemplateReceiver.TemplatePushRequest req(String docId, String status) {
        CMSEmailTemplateReceiver.TemplatePushRequest r = new CMSEmailTemplateReceiver.TemplatePushRequest();
        r.cmsDocumentId = docId;
        r.templateName = 'Emrok Introduction';
        r.subject = 'Introducing Emrok';
        r.brand = 'Emrok';
        r.language = 'English';
        r.approvalStatus = status;
        r.expiryDate = '2099-12-31';
        r.mlrReference = 'MLR-2026-0001';
        r.version = '1.0';
        r.assetUrl = 'https://sciagen-cms-assets.s3.amazonaws.com/email/emrok-intro.json?X-Amz-Signature=abc';
        r.contentHash = 'a'.repeat(64);
        return r;
    }

    @isTest
    static void approvedPushCreatesTemplateAndLinksAllowedContent() {
        insert new Approved_Content__c(Name = 'Brochure', Content_Name__c = 'Emrok Brochure', CMS_Document_Id__c = 'DOC-BRO-1', Kind__c = 'PDF');
        CMSEmailTemplateReceiver.TemplatePushRequest r = req('DOC-EM-1', 'Approved Promotional');
        r.allowedContentCmsDocumentIds = new List<String>{ 'DOC-BRO-1', 'DOC-MISSING' };

        CMSEmailTemplateReceiver.TemplatePushResult res = CMSEmailTemplateReceiver.processPush(r);

        System.assertEquals(true, res.success);
        System.assert(res.message.contains('1 attachment'), res.message);
        System.assert(res.message.contains('1 CMS content id'), 'unresolved id must be reported: ' + res.message);
        Email_Template__c t = [SELECT Subject__c, Is_Withdrawn__c, Asset_URL__c, Template_Version__c, Expiry_Date__c FROM Email_Template__c WHERE CMS_Document_Id__c = 'DOC-EM-1'];
        System.assertEquals('Introducing Emrok', t.Subject__c);
        System.assertEquals(false, t.Is_Withdrawn__c);
        System.assertEquals('1.0', t.Template_Version__c);
        System.assertEquals(Date.newInstance(2099, 12, 31), t.Expiry_Date__c);
        System.assertEquals(1, [SELECT COUNT() FROM Email_Template_Content__c WHERE Template__c = :t.Id]);
    }

    @isTest
    static void repushIsIdempotentAndReplacesAllowedContent() {
        insert new List<Approved_Content__c>{
            new Approved_Content__c(Name = 'A', Content_Name__c = 'A', CMS_Document_Id__c = 'DOC-A', Kind__c = 'PDF'),
            new Approved_Content__c(Name = 'B', Content_Name__c = 'B', CMS_Document_Id__c = 'DOC-B', Kind__c = 'PDF')
        };
        CMSEmailTemplateReceiver.TemplatePushRequest r = req('DOC-EM-2', 'Approved Promotional');
        r.allowedContentCmsDocumentIds = new List<String>{ 'DOC-A' };
        CMSEmailTemplateReceiver.processPush(r);
        r.allowedContentCmsDocumentIds = new List<String>{ 'DOC-B' };
        r.version = '1.1';
        CMSEmailTemplateReceiver.processPush(r);

        System.assertEquals(1, [SELECT COUNT() FROM Email_Template__c WHERE CMS_Document_Id__c = 'DOC-EM-2']);
        List<Email_Template_Content__c> links = [SELECT Content__r.CMS_Document_Id__c FROM Email_Template_Content__c WHERE Template__r.CMS_Document_Id__c = 'DOC-EM-2'];
        System.assertEquals(1, links.size());
        System.assertEquals('DOC-B', links[0].Content__r.CMS_Document_Id__c);
        System.assertEquals('1.1', [SELECT Template_Version__c FROM Email_Template__c WHERE CMS_Document_Id__c = 'DOC-EM-2'].Template_Version__c);
    }

    @isTest
    static void withdrawnStatusFlagsExistingTemplate() {
        CMSEmailTemplateReceiver.processPush(req('DOC-EM-3', 'Approved Promotional'));
        CMSEmailTemplateReceiver.TemplatePushResult res = CMSEmailTemplateReceiver.processPush(req('DOC-EM-3', 'Withdrawn'));
        System.assertEquals(true, res.success);
        System.assertEquals(true, [SELECT Is_Withdrawn__c FROM Email_Template__c WHERE CMS_Document_Id__c = 'DOC-EM-3'].Is_Withdrawn__c);
        // Re-approving brings it back.
        CMSEmailTemplateReceiver.processPush(req('DOC-EM-3', 'Approved Promotional'));
        System.assertEquals(false, [SELECT Is_Withdrawn__c FROM Email_Template__c WHERE CMS_Document_Id__c = 'DOC-EM-3'].Is_Withdrawn__c);
    }

    @isTest
    static void nonApprovedStatusIsAcknowledgedButNotStored() {
        CMSEmailTemplateReceiver.TemplatePushResult res = CMSEmailTemplateReceiver.processPush(req('DOC-EM-4', 'In Review'));
        System.assertEquals(true, res.success);
        System.assertEquals(0, [SELECT COUNT() FROM Email_Template__c WHERE CMS_Document_Id__c = 'DOC-EM-4']);
    }

    @isTest
    static void validationRejectsMissingFields() {
        CMSEmailTemplateReceiver.TemplatePushRequest noId = req(null, 'Approved Promotional');
        System.assertEquals(false, CMSEmailTemplateReceiver.processPush(noId).success);
        CMSEmailTemplateReceiver.TemplatePushRequest noSource = req('DOC-EM-5', 'Approved Promotional');
        noSource.assetUrl = null;
        noSource.bodyText = null;
        System.assertEquals(false, CMSEmailTemplateReceiver.processPush(noSource).success);
        CMSEmailTemplateReceiver.TemplatePushRequest noSubject = req('DOC-EM-6', 'Approved Promotional');
        noSubject.subject = null;
        System.assertEquals(false, CMSEmailTemplateReceiver.processPush(noSubject).success);
    }

    @isTest
    static void unknownLanguageMapsToOther() {
        CMSEmailTemplateReceiver.TemplatePushRequest r = req('DOC-EM-7', 'Approved Promotional');
        r.language = 'Tamil';
        CMSEmailTemplateReceiver.processPush(r);
        System.assertEquals('Other', [SELECT Language__c FROM Email_Template__c WHERE CMS_Document_Id__c = 'DOC-EM-7'].Language__c);
    }
}