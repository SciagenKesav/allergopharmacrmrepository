/**
 * Inbound REST endpoint for Sciagen CMS content push.
 * Sciagen CMS calls this once per asset/page the moment that page's file is
 * uploaded and the parent document reaches "Approved Promotional" status.
 * POST /services/apexrest/cms/v1/content
 *
 * Assets themselves live in S3, not Salesforce — the CMS uploads each slide's
 * file to S3 itself and sends an S3 *signed* URL here; Salesforce never
 * receives or stores file bytes, only the metadata + a pointer. Each call
 * carries exactly one slide/page (no batched array) — a multi-page deck
 * arrives as one call per page, all sharing the same cmsDocumentId, and this
 * upserts that page's Slide__c in place alongside the shared Presentation__c
 * (used by the CLM library and synced to the iPad app, which downloads each
 * slide's asset directly from its S3 URL) and Approved_Content__c (used by
 * Approved Email — only page 1's URL is kept there, see processPush).
 *
 * Because the URL is a *signed* (time-limited) S3 URL, not a permanent one,
 * it will eventually stop resolving. The iPad app downloads and caches each
 * asset once shortly after this push lands, so it's insulated from later
 * expiry — but the web CLM Library's preview button re-opens this stored URL
 * on every click, so it will start failing once the signature expires. CMS
 * should sign for the longest TTL their tooling allows; there is no refresh
 * callback today.
 */
@RestResource(urlMapping='/cms/v1/content')
global with sharing class CMSContentReceiver {

    global class ContentPushRequest {
        public String cmsDocumentId;       // e.g. "Wockhardt_P-2026-0001" — shared across every page's call
        public String title;
        public String contentType;         // Promotional / Non-Promotional
        public String documentType;        // Leave Behind Literature, Reference/Clinical Pub, Prescriber Information...
        public String brand;               // Emrok / Glaritus / Miqnaf / ...
        public String productSkuCode;      // matches Product__c.SKU_Code__c, optional
        public String approvalStatus;      // should be 'Approved Promotional' for anything reaching this endpoint
        public String expiryDate;          // ISO 8601 date, e.g. '2026-12-31'
        public String mlrReference;        // e.g. 'MLR-2026-CV-0047'
        public Integer slideNo;            // 1-based page/slide number within the deck — required, also the upsert key
        public String slideName;           // falls back to the document title if blank
        public String assetFileType;       // Native / HTML / PDF / PPT / Word / Video / Audio
        public String assetUrl;            // S3 signed URL for this page's file, already uploaded by the CMS
        public Boolean isTraining;         // optional: true = training-only content; omitted leaves an existing deck's flag unchanged
        public String trainingType;        // optional: Medical / Compliance and Policy / Company Communication / References (matched to the picklist)
    }

    global class ContentPushResult {
        public Boolean success;
        public String message;
        public Id approvedContentId;
        public Id presentationId;
        public Id slideId;
        public Integer slideNo;
        public String assetUrl;
    }

    @HttpPost
    global static ContentPushResult receive() {
        ContentPushResult result = new ContentPushResult();
        try {
            RestRequest req = RestContext.request;
            ContentPushRequest payload =
                (ContentPushRequest) JSON.deserialize(req.requestBody.toString(), ContentPushRequest.class);
            result = processPush(payload);
        } catch (Exception e) {
            result.success = false;
            result.message = 'CMS push failed: ' + e.getMessage();
            RestContext.response.statusCode = 400;
        }
        return result;
    }

    global static ContentPushResult processPush(ContentPushRequest payload) {
        ContentPushResult result = new ContentPushResult();

        if (String.isBlank(payload.cmsDocumentId)) {
            result.success = false;
            result.message = 'cmsDocumentId is required.';
            return result;
        }

        // Only content that has actually reached Approved Promotional gets served to the field —
        // anything else (Draft, In Review, etc.) is CMS's business, not Salesforce's.
        if (payload.approvalStatus != 'Approved Promotional') {
            result.success = true;
            result.message = 'Received but not synced — status is "' + payload.approvalStatus +
                '", only Approved Promotional documents are stored.';
            return result;
        }

        if (payload.slideNo == null) {
            result.success = false;
            result.message = 'slideNo is required.';
            return result;
        }

        // Resolve optional Product lookup by SKU code
        Id productId = null;
        if (String.isNotBlank(payload.productSkuCode)) {
            List<Product__c> prods = [SELECT Id FROM Product__c WHERE SKU_Code__c = :payload.productSkuCode LIMIT 1];
            if (!prods.isEmpty()) {
                productId = prods[0].Id;
            }
        }

        Date expiry = null;
        if (String.isNotBlank(payload.expiryDate)) {
            expiry = Date.valueOf(payload.expiryDate);
        }

        // 1) Upsert Approved_Content__c (used by Approved Email attachments). Each call only
        // knows about one page, so Asset_URL__c — the single attachment Approved Email would
        // send — is only (re)set from page 1's push; later/earlier pages never overwrite it.
        Approved_Content__c ac = new Approved_Content__c(
            CMS_Document_Id__c = payload.cmsDocumentId,
            Content_Name__c = payload.title,
            Kind__c = mapContentKind(payload.assetFileType),
            Product__c = productId
        );
        if (payload.slideNo == 1) {
            ac.Asset_URL__c = payload.assetUrl;
        }
        upsert ac Approved_Content__c.CMS_Document_Id__c;
        result.approvedContentId = ac.Id;

        // Checked before the upsert below, since a plain (non-Database.) upsert doesn't report
        // back whether it inserted or updated — needed to tell a brand-new deck from a re-push
        // of one already in the library, so the Content_Alert__c created further down says the
        // right thing ("New" vs "Updated") instead of always claiming new content.
        List<Presentation__c> existingPres =
            [SELECT Id, Is_Training__c, Training_Type__c FROM Presentation__c WHERE CMS_Document_Id__c = :payload.cmsDocumentId LIMIT 1];
        Boolean isNewPresentation = existingPres.isEmpty();
        // isTraining / trainingType are optional. A push that omits them must not reset what an
        // earlier push (or a person) already set; a brand-new deck defaults to not-training.
        Boolean trainingFlag = payload.isTraining != null
            ? payload.isTraining
            : (isNewPresentation ? false : existingPres[0].Is_Training__c == true);
        String currentType = isNewPresentation ? null : existingPres[0].Training_Type__c;
        String trainingTypeValue = currentType;
        if (payload.isTraining == false) {
            trainingTypeValue = null;                       // not training content -> no training type
        } else if (String.isNotBlank(payload.trainingType)) {
            // unrecognised value: keep what is there (blank for a new deck) instead of failing the push
            trainingTypeValue = matchPicklist(Presentation__c.Training_Type__c, payload.trainingType, currentType);
        }

        // 2) Upsert Presentation__c (used by the CLM library). Every page's call re-sends the
        // same document-level metadata, so this is naturally idempotent across all of a deck's
        // per-page calls, not just re-pushes of the same page.
        Presentation__c pres = new Presentation__c(
            CMS_Document_Id__c = payload.cmsDocumentId,
            Presentation_Name__c = payload.title,
            Version__c = 'v1.0',
            Brand__c = matchPicklist(Presentation__c.Brand__c, payload.brand, null),
            Product__c = productId,
            Approval_Status__c = payload.approvalStatus,
            Expiry_Date__c = expiry,
            MLR_Reference__c = payload.mlrReference,
            Is_Custom__c = false,
            Is_Training__c = trainingFlag,
            Training_Type__c = trainingTypeValue
        );
        upsert pres Presentation__c.CMS_Document_Id__c;
        result.presentationId = pres.Id;

        // 3) Upsert this one Slide__c, keyed on (Presentation__c, Slide_No__c) so a re-push of
        // the same page (e.g. a corrected asset) updates it in place rather than duplicating.
        // Other pages of the same deck, pushed via their own separate calls, are untouched by
        // this one. Asset_URL__c is set directly from the CMS's own S3 signed URL — Salesforce
        // stores only the pointer.
        List<Slide__c> existingSlides = [
            SELECT Id FROM Slide__c WHERE Presentation__c = :pres.Id AND Slide_No__c = :payload.slideNo LIMIT 1
        ];
        Slide__c slide = !existingSlides.isEmpty()
            ? existingSlides[0]
            : new Slide__c(Presentation__c = pres.Id, Slide_No__c = payload.slideNo);
        slide.Slide_Name__c = String.isNotBlank(payload.slideName) ? payload.slideName : payload.title;
        slide.Product__c = productId;
        slide.Brand__c = matchPicklist(Slide__c.Brand__c, payload.brand, 'Other');
        slide.File_Type__c = mapFileType(payload.assetFileType, payload.assetUrl);
        slide.Asset_URL__c = payload.assetUrl;
        upsert slide;

        // 4) Fire a Content_Alert__c so the Home page's "Content Alerts" tile (web and iPad
        // both read this same object) actually lights up when new or refreshed content lands
        // — this was previously never populated by the live CMS push at all, only by the demo
        // seeder, so the tile stayed empty no matter how much real content came in. Scoped to
        // page 1 of each push only: a multi-page deck's remaining pages arrive as their own
        // separate calls (see this method's own doc comment), and firing on every one of them
        // would spam one alert per page instead of one per push.
        if (payload.slideNo == 1) {
            insert new Content_Alert__c(
                Name = isNewPresentation ? 'New Content' : 'Updated Content',
                Title__c = payload.title + (isNewPresentation ? ' is now available' : ' was updated'),
                Detail__c = (String.isNotBlank(payload.brand) ? payload.brand : 'Other') + (String.isNotBlank(payload.documentType) ? ' - ' + payload.documentType : ''),
                Presentation__c = pres.Id,
                Kind__c = isNewPresentation ? 'New' : 'Updated'
            );
        }

        result.slideId = slide.Id;
        result.slideNo = payload.slideNo;
        result.assetUrl = payload.assetUrl;
        result.success = true;
        result.message = 'Synced ' + payload.cmsDocumentId + ' slide ' + payload.slideNo +
            ' -> Presentation ' + pres.Id + ', Approved Content ' + ac.Id;
        return result;
    }

    private static String mapContentKind(String assetFileType) {
        if (assetFileType == 'PDF') return 'PDF';
        if (assetFileType == 'Link') return 'Link';
        return 'Visual';
    }

    /// Falls back to inferring the type from the asset's own file extension
    /// when the CMS sends an assetFileType we don't recognize — rather than
    /// blindly defaulting to 'PDF', which was silently mis-tagging real
    /// PNG/JPEG image pushes as PDF (the iPad/web CLM viewer then tries to
    /// open the PNG bytes with PDFKit and fails to render it at all). This
    /// self-corrects regardless of what exact string the CMS ends up
    /// sending for an image push, as long as the asset URL itself has a
    /// recognizable extension.
    private static String mapFileType(String assetFileType, String assetUrl) {
        Set<String> known = new Set<String>{
            'Native','HTML','PDF','PPT','Word','Video','Audio','PNG','JPEG','JPG','TIFF'
        };
        if (known.contains(assetFileType)) {
            return assetFileType;
        }
        String inferred = fileTypeFromUrlExtension(assetUrl);
        return inferred != null ? inferred : 'PDF';
    }

    private static final Map<String, String> EXTENSION_TO_FILE_TYPE = new Map<String, String>{
        'png' => 'PNG', 'jpg' => 'JPG', 'jpeg' => 'JPEG', 'tif' => 'TIFF', 'tiff' => 'TIFF',
        'pdf' => 'PDF', 'ppt' => 'PPT', 'pptx' => 'PPT', 'doc' => 'Word', 'docx' => 'Word',
        'mp4' => 'Video', 'mov' => 'Video', 'm4a' => 'Audio', 'mp3' => 'Audio'
    };

    private static String fileTypeFromUrlExtension(String assetUrl) {
        if (String.isBlank(assetUrl)) return null;
        String path = assetUrl;
        Integer queryIdx = path.indexOf('?');
        if (queryIdx >= 0) path = path.substring(0, queryIdx);
        Integer lastDot = path.lastIndexOf('.');
        Integer lastSlash = path.lastIndexOf('/');
        if (lastDot < 0 || lastDot < lastSlash) return null;
        String ext = path.substring(lastDot + 1).toLowerCase();
        return EXTENSION_TO_FILE_TYPE.get(ext);
    }

    /// Returns the picklist's own spelling of `value` (matched ignoring case) when it is an active
    /// value of that field, otherwise `fallback`. The Brand picklists are restricted and differ
    /// between Presentation and Slide, so a hard-coded brand list used to fail the whole push with
    /// INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST whenever the CMS sent a brand the field did not allow
    /// (e.g. ACAROID mapped to "Other"). Reading the allowed values from the field keeps this in step
    /// with whatever the org's picklist currently contains.
    private static String matchPicklist(Schema.SObjectField field, String value, String fallback) {
        if (String.isBlank(value)) return fallback;
        String wanted = value.trim().toLowerCase().replaceAll('\\s+', ' ');
        for (Schema.PicklistEntry e : field.getDescribe().getPicklistValues()) {
            if (e.isActive() && e.getValue().toLowerCase().replaceAll('\\s+', ' ') == wanted) return e.getValue();
        }
        return fallback;
    }
}