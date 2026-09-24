/**
 * Backend for the new "CLM Library" — browsing approved Presentation__c decks
 * (whose slide assets live in S3, pushed in by CMSContentReceiver as a plain
 * URL — Salesforce never stores the file bytes) and logging a
 * Presentation_Session__c + Slide_Event__c children against a
 * Call_Visit_Report__c, auto-generating locked Key_Message__c rows. See the
 * "CLM (Closed Loop Marketing) — Library + Session Logging" and "CLM Assets
 * Move to S3" plans for the full mapping.
 *
 * Security: `with sharing` + `WITH USER_MODE`/`AccessLevel.USER_MODE` on every
 * SOQL/DML, matching SciagenCVRController/SciagenScheduleController.
 */
public with sharing class SciagenCLMController {

    public class PresentationListItem {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String brand;
        @AuraEnabled public String productName;
        @AuraEnabled public String version;
        @AuraEnabled public Integer slideCount;
    }

    public class SlideItem {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public Integer slideNo;
        @AuraEnabled public String fileType;
        @AuraEnabled public Boolean isVideo;
        @AuraEnabled public Integer videoDurationSec;
        @AuraEnabled public String brand;
        @AuraEnabled public String productName;
        @AuraEnabled public String assetUrl;
        @AuraEnabled public String htmlContent;
    }

    public class PresentationDetail {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String brand;
        @AuraEnabled public String productName;
        @AuraEnabled public String version;
        @AuraEnabled public List<SlideItem> slides;
    }

    public class SessionListItem {
        @AuraEnabled public Id id;
        @AuraEnabled public Id presentationId;
        @AuraEnabled public String presentationName;
        @AuraEnabled public String brand;
        @AuraEnabled public Datetime startTime;
        @AuraEnabled public Datetime endTime;
        @AuraEnabled public Integer totalSlides;
    }

    public class SlideCheckItem {
        @AuraEnabled public Id slideId;
        @AuraEnabled public Integer sequence;
        @AuraEnabled public Integer timeSpentSec;
    }

    public class SessionLogResult {
        @AuraEnabled public Id sessionId;
        @AuraEnabled public Integer keyMessagesCreated;
    }

    @AuraEnabled(cacheable=true)
    public static List<String> getBrandOptions() {
        List<String> values = new List<String>();
        for (Schema.PicklistEntry entry : Presentation__c.Brand__c.getDescribe().getPicklistValues()) {
            if (entry.isActive()) {
                values.add(entry.getValue());
            }
        }
        return values;
    }

    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getProductOptions() {
        List<Map<String, String>> results = new List<Map<String, String>>();
        for (Product__c p : [SELECT Id, Name FROM Product__c WHERE Active__c = true WITH USER_MODE ORDER BY Name]) {
            results.add(new Map<String, String>{ 'id' => p.Id, 'name' => p.Name });
        }
        return results;
    }

    /// Always hard-filters to Approved Promotional — the rep-facing library
    /// only ever shows content the CMS has actually cleared, matching
    /// CMSContentReceiver's own gate on what gets synced in the first place.
    @AuraEnabled(cacheable=true)
    public static List<PresentationListItem> getPresentationLibrary(String searchTerm, String brand, Id productId) {
        List<String> whereClauses = new List<String>{ 'Approval_Status__c = \'Approved Promotional\'' };
        Map<String, Object> binds = new Map<String, Object>();
        if (String.isNotBlank(searchTerm)) {
            binds.put('term', '%' + String.escapeSingleQuotes(searchTerm) + '%');
            whereClauses.add('Presentation_Name__c LIKE :term');
        }
        if (String.isNotBlank(brand)) {
            binds.put('brand', brand);
            whereClauses.add('Brand__c = :brand');
        }
        if (productId != null) {
            binds.put('productId', productId);
            whereClauses.add('Product__c = :productId');
        }
        String query = 'SELECT Id, Presentation_Name__c, Brand__c, Product__c, Product__r.Name, Version__c ' +
            'FROM Presentation__c WHERE ' + String.join(whereClauses, ' AND ') +
            ' ORDER BY Presentation_Name__c LIMIT 200';
        List<Presentation__c> presos = Database.queryWithBinds(query, binds, AccessLevel.USER_MODE);

        Set<Id> presoIds = new Set<Id>();
        for (Presentation__c p : presos) {
            presoIds.add(p.Id);
        }
        Map<Id, Integer> slideCounts = new Map<Id, Integer>();
        for (AggregateResult ar : [
            SELECT Presentation__c pid, COUNT(Id) cnt FROM Slide__c
            WHERE Presentation__c IN :presoIds
            WITH USER_MODE
            GROUP BY Presentation__c
        ]) {
            slideCounts.put((Id) ar.get('pid'), (Integer) ar.get('cnt'));
        }

        List<PresentationListItem> results = new List<PresentationListItem>();
        for (Presentation__c p : presos) {
            PresentationListItem item = new PresentationListItem();
            item.id = p.Id;
            item.name = p.Presentation_Name__c;
            item.brand = p.Brand__c;
            item.productName = p.Product__c != null ? p.Product__r.Name : null;
            item.version = p.Version__c;
            item.slideCount = slideCounts.containsKey(p.Id) ? slideCounts.get(p.Id) : 0;
            results.add(item);
        }
        return results;
    }

    @AuraEnabled(cacheable=true)
    public static PresentationDetail getPresentationDetail(Id presentationId) {
        List<Presentation__c> matches = [
            SELECT Id, Presentation_Name__c, Brand__c, Product__c, Product__r.Name, Version__c
            FROM Presentation__c
            WHERE Id = :presentationId
            WITH USER_MODE
            LIMIT 1
        ];
        if (matches.isEmpty()) {
            throw new AuraHandledException('Presentation not found or not accessible.');
        }
        Presentation__c p = matches[0];

        PresentationDetail detail = new PresentationDetail();
        detail.id = p.Id;
        detail.name = p.Presentation_Name__c;
        detail.brand = p.Brand__c;
        detail.productName = p.Product__c != null ? p.Product__r.Name : null;
        detail.version = p.Version__c;

        List<Slide__c> slideRecords = [
            SELECT Id, Slide_Name__c, Slide_No__c, File_Type__c, Is_Video__c, Video_Duration__c,
                   Brand__c, Product__c, Product__r.Name, Asset_URL__c, HTML_Content__c
            FROM Slide__c
            WHERE Presentation__c = :presentationId
            WITH USER_MODE
            ORDER BY Slide_No__c 
       ];

        detail.slides = new List<SlideItem>();
        for (Slide__c s : slideRecords) {
            SlideItem item = new SlideItem();
            item.id = s.Id;
            item.name = s.Slide_Name__c;
            item.slideNo = s.Slide_No__c != null ? s.Slide_No__c.intValue() : null;
            item.fileType = s.File_Type__c;
            item.isVideo = s.Is_Video__c;
            item.videoDurationSec = s.Video_Duration__c != null ? s.Video_Duration__c.intValue() : null;
            item.brand = s.Brand__c;
            item.productName = s.Product__c != null ? s.Product__r.Name : null;
            item.assetUrl = s.Asset_URL__c;
            item.htmlContent = s.HTML_Content__c;
            detail.slides.add(item);
        }
        return detail;
    }

    /// Not cacheable — mutated by logPresentationSession, same reasoning as
    /// SciagenCVRController.getCVRDetail.
    @AuraEnabled
    public static List<SessionListItem> getSessionsForCVR(Id cvrId) {
        List<SessionListItem> results = new List<SessionListItem>();
        for (Presentation_Session__c s : [
            SELECT Id, Presentation__c, Presentation__r.Presentation_Name__c, Brand__c,
                   Start_Time__c, End_Time__c, Total_Slides__c
            FROM Presentation_Session__c
            WHERE CVR__c = :cvrId
            WITH USER_MODE
            ORDER BY CreatedDate DESC
        ]) {
            SessionListItem item = new SessionListItem();
            item.id = s.Id;
            item.presentationId = s.Presentation__c;
            item.presentationName = s.Presentation__r != null ? s.Presentation__r.Presentation_Name__c : null;
            item.brand = s.Brand__c;
            item.startTime = s.Start_Time__c;
            item.endTime = s.End_Time__c;
            item.totalSlides = s.Total_Slides__c != null ? s.Total_Slides__c.intValue() : null;
            results.add(item);
        }
        return results;
    }

    /// The one write path spanning Presentation_Session__c + Slide_Event__c +
    /// Key_Message__c — kept as a single Apex transaction rather than three
    /// client-side record-edit-forms because Slide_Event__c can't exist before
    /// its parent session has an Id, and a partial failure here would leave an
    /// orphaned session with no visible Key Messages. Only ADDS rows for this
    /// call's own new session — never regenerates/deletes locked Key Messages
    /// from an earlier session on the same CVR (this logs an after-the-fact
    /// event, not a live re-entrant player state like iOS's rebuild logic).
    /// `slidesJson` is a JSON-serialized List<SlideCheckItem> (client builds it
    /// via JSON.stringify), NOT a List<SlideCheckItem> parameter directly —
    /// the Aura/LWC bridge does not reliably populate the fields of a custom
    /// Apex class passed as a method parameter (confirmed live: the list
    /// arrives with the right length but every field on every item is null).
    /// Passing the pre-serialized JSON and deserializing it here with
    /// JSON.deserialize is the standard, reliable workaround.
    @AuraEnabled
    public static SessionLogResult logPresentationSession(
        Id cvrId, Id presentationId, Datetime startTime, Datetime endTime,
        Integer annotationSec, Integer videoTotalSec, Integer videoWatchedSec,
        String slidesJson
    ) {
        if (cvrId == null || presentationId == null) {
            throw new AuraHandledException('A presentation and call report are required.');
        }
        List<SlideCheckItem> checkedSlides = String.isBlank(slidesJson)
            ? new List<SlideCheckItem>()
            : (List<SlideCheckItem>) JSON.deserialize(slidesJson, List<SlideCheckItem>.class);
        if (checkedSlides.isEmpty()) {
            throw new AuraHandledException('Select at least one slide that was shown.');
        }

        List<Call_Visit_Report__c> cvrs = [
            SELECT Id, OwnerId, Record_Status__c FROM Call_Visit_Report__c WHERE Id = :cvrId WITH USER_MODE LIMIT 1
        ];
        if (cvrs.isEmpty()) {
            throw new AuraHandledException('Call Visit Report not found or not accessible.');
        }
        if (cvrs[0].OwnerId != UserInfo.getUserId()) {
            throw new AuraHandledException('Only the owning rep can log a presentation against this call report.');
        }
        if (cvrs[0].Record_Status__c == 'Submitted') {
            throw new AuraHandledException('This call report has been submitted and is locked.');
        }

        List<Presentation__c> presos = [
            SELECT Id, Brand__c, Version__c FROM Presentation__c WHERE Id = :presentationId WITH USER_MODE LIMIT 1
        ];
        if (presos.isEmpty()) {
            throw new AuraHandledException('Presentation not found or not accessible.');
        }
        Presentation__c preso = presos[0];

        Set<Id> slideIds = new Set<Id>();
        for (SlideCheckItem c : checkedSlides) {
            if (c.slideId != null) {
                slideIds.add(c.slideId);
            }
        }
        Map<Id, Slide__c> slidesById = new Map<Id, Slide__c>([
            SELECT Id, Slide_Name__c, Slide_No__c, Brand__c, Product__c, Product__r.Name
            FROM Slide__c
            WHERE Id IN :slideIds
            WITH USER_MODE
        ]);

        Presentation_Session__c session = new Presentation_Session__c(
            CVR__c = cvrId,
            Presentation__c = presentationId,
            Brand__c = preso.Brand__c,
            Version__c = preso.Version__c,
            Start_Time__c = startTime,
            End_Time__c = endTime,
            Total_Slides__c = checkedSlides.size(),
            Annotation_Sec__c = annotationSec,
            Video_Total_Sec__c = videoTotalSec,
            Video_Watched_Sec__c = videoWatchedSec
        );
        Database.insert(session, AccessLevel.USER_MODE);

        List<Slide_Event__c> events = new List<Slide_Event__c>();
        Set<String> distinctSlideNames = new Set<String>();
        Map<String, Slide__c> firstSlideByName = new Map<String, Slide__c>();
        for (SlideCheckItem c : checkedSlides) {
            Slide__c slide = slidesById.get(c.slideId);
            if (slide == null) {
                continue;
            }
            events.add(new Slide_Event__c(
                Session__c = session.Id,
                Slide__c = slide.Id,
                Slide_Name__c = slide.Slide_Name__c,
                Slide_No__c = slide.Slide_No__c,
                Sequence__c = c.sequence,
                Time_Spent_Sec__c = c.timeSpentSec,
                Is_Revisit__c = false,
                Product_Name__c = slide.Product__c != null ? slide.Product__r.Name : null
            ));
            if (!distinctSlideNames.contains(slide.Slide_Name__c)) {
                distinctSlideNames.add(slide.Slide_Name__c);
                firstSlideByName.put(slide.Slide_Name__c, slide);
            }
        }
        if (!events.isEmpty()) {
            Database.insert(events, AccessLevel.USER_MODE);
        }

        List<Key_Message__c> keyMessages = new List<Key_Message__c>();
        for (String slideName : distinctSlideNames) {
            Slide__c slide = firstSlideByName.get(slideName);
            keyMessages.add(new Key_Message__c(
                CVR__c = cvrId,
                Presentation_Session__c = session.Id,
                Message__c = slideName,
                Product__c = slide.Product__c != null ? slide.Product__r.Name : null,
                Locked__c = true
            ));
        }
        if (!keyMessages.isEmpty()) {
            Database.insert(keyMessages, AccessLevel.USER_MODE);
        }

        SessionLogResult result = new SessionLogResult();
        result.sessionId = session.Id;
        result.keyMessagesCreated = keyMessages.size();
        return result;
    }
}