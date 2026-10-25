/**
 * Inbound REST endpoint for Sciagen CMS approved-email-template push.
 * POST /services/apexrest/cms/v1/email-template
 *
 * Mirrors CMSContentReceiver (slides): the CMS uploads each template's JSON
 * file to S3 itself and sends an S3 *signed* URL here. Salesforce keeps only
 * metadata + that pointer (Email_Template__c.Asset_URL__c); the iPad app pulls
 * the metadata through the normal sync, downloads the JSON from S3 once, and
 * caches it on the device so templates can be composed offline.
 *
 * S3 file contract (schemaVersion 1):
 *   { "schemaVersion": 1, "subject": "...", "bodyText": "...tokens like {{HCP Name}}..." }
 *
 * One call per template (a template in another language is its own document,
 * with its own cmsDocumentId). Only 'Approved Promotional' documents are
 * stored/activated; a withdrawal status (Withdrawn / Expired / Retired /
 * Archived) flags an existing template Is_Withdrawn__c so the iPad stops
 * offering it. Any other status (Draft, In Review...) is CMS's own business
 * and is acknowledged but ignored.
 *
 * allowedContentCmsDocumentIds names which already-pushed Approved_Content__c
 * items (by their CMS document id) may be attached to this template; the
 * junction is replaced to match, and SentEmailSendService enforces the same
 * list again server-side at send time.
 */
@RestResource(urlMapping='/cms/v1/email-template')
global with sharing class CMSEmailTemplateReceiver {

    private static final Set<String> WITHDRAWN_STATUSES = new Set<String>{ 'Withdrawn', 'Expired', 'Retired', 'Archived' };
    private static final Set<String> KNOWN_LANGUAGES = new Set<String>{ 'English', 'Hindi' };

    global class TemplatePushRequest {
        public String cmsDocumentId;
        public String templateName;
        public String subject;
        public String brand;
        public String productSkuCode;
        public String language;
        public String approvalStatus;
        public String expiryDate;          // ISO 8601 date
        public String mlrReference;
        public String version;
        public String assetUrl;            // S3 signed URL of the template JSON
        public String contentHash;         // SHA-256 of that JSON file
        public String bodyText;            // optional plain-text copy, used only as an offline-first-run fallback
        public List<String> allowedContentCmsDocumentIds;
    }

    global class TemplatePushResult {
        public Boolean success;
        public String message;
        public Id templateId;
    }

    @HttpPost
    global static TemplatePushResult receive() {
        TemplatePushResult result = new TemplatePushResult();
        try {
            TemplatePushRequest payload = (TemplatePushRequest) JSON.deserialize(
                RestContext.request.requestBody.toString(), TemplatePushRequest.class);
            result = processPush(payload);
        } catch (Exception e) {
            result.success = false;
            result.message = 'CMS email template push failed: ' + e.getMessage();
            RestContext.response.statusCode = 400;
        }
        return result;
    }

    global static TemplatePushResult processPush(TemplatePushRequest payload) {
        TemplatePushResult result = new TemplatePushResult();

        if (String.isBlank(payload.cmsDocumentId)) {
            result.success = false;
            result.message = 'cmsDocumentId is required.';
            return result;
        }

        if (WITHDRAWN_STATUSES.contains(payload.approvalStatus)) {
            List<Email_Template__c> existing = [
                SELECT Id FROM Email_Template__c WHERE CMS_Document_Id__c = :payload.cmsDocumentId LIMIT 1
            ];
            if (!existing.isEmpty()) {
                existing[0].Is_Withdrawn__c = true;
                update existing[0];
                result.templateId = existing[0].Id;
            }
            result.success = true;
            result.message = 'Template withdrawn (status "' + payload.approvalStatus + '").';
            return result;
        }

        if (payload.approvalStatus != 'Approved Promotional') {
            result.success = true;
            result.message = 'Received but not synced — status is "' + payload.approvalStatus +
                '", only Approved Promotional templates are stored.';
            return result;
        }

        if (String.isBlank(payload.templateName) || String.isBlank(payload.subject)) {
            result.success = false;
            result.message = 'templateName and subject are required.';
            return result;
        }
        if (String.isBlank(payload.assetUrl) && String.isBlank(payload.bodyText)) {
            result.success = false;
            result.message = 'assetUrl (S3 template file) or bodyText is required.';
            return result;
        }

        Id productId = null;
        if (String.isNotBlank(payload.productSkuCode)) {
            List<Product__c> prods = [SELECT Id FROM Product__c WHERE SKU_Code__c = :payload.productSkuCode LIMIT 1];
            if (!prods.isEmpty()) productId = prods[0].Id;
        }

        Date expiry = String.isNotBlank(payload.expiryDate) ? Date.valueOf(payload.expiryDate) : null;

        Email_Template__c tmpl = new Email_Template__c(
            Name = payload.templateName.abbreviate(80),
            CMS_Document_Id__c = payload.cmsDocumentId,
            Template_Name__c = payload.templateName.abbreviate(255),
            Subject__c = payload.subject.abbreviate(255),
            Brand__c = payload.brand,
            Product__c = productId,
            Language__c = KNOWN_LANGUAGES.contains(payload.language) ? payload.language : (String.isBlank(payload.language) ? 'English' : 'Other'),
            Is_User_Saved__c = false,
            Is_Withdrawn__c = false,
            Expiry_Date__c = expiry,
            MLR_Reference__c = payload.mlrReference,
            Template_Version__c = payload.version,
            Content_Hash__c = payload.contentHash,
            Asset_URL__c = payload.assetUrl
        );
        if (String.isNotBlank(payload.bodyText)) tmpl.Body__c = payload.bodyText;
        upsert tmpl Email_Template__c.CMS_Document_Id__c;
        result.templateId = tmpl.Id;

        // Replace the allowed-attachment junction so it matches the CMS's list exactly.
        Set<String> wantedDocIds = new Set<String>();
        if (payload.allowedContentCmsDocumentIds != null) wantedDocIds.addAll(payload.allowedContentCmsDocumentIds);
        Map<Id, Approved_Content__c> wanted = new Map<Id, Approved_Content__c>(
            [SELECT Id, CMS_Document_Id__c FROM Approved_Content__c WHERE CMS_Document_Id__c IN :wantedDocIds]);

        Set<Id> keep = new Set<Id>();
        List<Email_Template_Content__c> toDelete = new List<Email_Template_Content__c>();
        for (Email_Template_Content__c j : [SELECT Id, Content__c FROM Email_Template_Content__c WHERE Template__c = :tmpl.Id]) {
            if (wanted.containsKey(j.Content__c) && !keep.contains(j.Content__c)) keep.add(j.Content__c);
            else toDelete.add(j);
        }
        if (!toDelete.isEmpty()) delete toDelete;
        List<Email_Template_Content__c> toInsert = new List<Email_Template_Content__c>();
        for (Id contentId : wanted.keySet()) {
            if (!keep.contains(contentId)) {
                toInsert.add(new Email_Template_Content__c(Name = 'Allowed', Template__c = tmpl.Id, Content__c = contentId));
            }
        }
        if (!toInsert.isEmpty()) insert toInsert;

        Integer unresolved = wantedDocIds.size() - wanted.size();
        result.success = true;
        result.message = 'Template stored (' + wanted.size() + ' attachment(s) linked' +
            (unresolved > 0 ? ', ' + unresolved + ' CMS content id(s) not found — push that content first' : '') + ').';
        return result;
    }
}