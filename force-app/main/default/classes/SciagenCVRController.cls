/**
 * Backend for the new "Call Reports" LWC — creating/managing Call_Visit_Report__c
 * records and their four Master-Detail children (Key_Message__c, Promo_Drop__c,
 * CVR_Attendee__c, CVR_Internal_Attendee__c). See the "Call Visit Report —
 * Salesforce LWC Feature" plan for the full mapping.
 *
 * Child create/edit/delete deliberately has no Apex here — every child object is
 * Master-Detail + ControlledByParent, so the LWC does that directly via
 * lightning-record-edit-form / lightning/uiRecordApi, the same pattern already
 * used for Office_Window__c in accountDetail.js. The only place real Apex-level
 * atomicity is needed is submitCallReport's Record_Status__c + Key_Message__c
 * Locked__c cascade.
 *
 * Security: `with sharing` + `WITH USER_MODE` on every SOQL statement, matching
 * SciagenScheduleController/SciagenAccountController.
 */
public with sharing class SciagenCVRController {

    public class CVRListItem {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public Id hcpId;
        @AuraEnabled public String hcpName;
        @AuraEnabled public Id hcoId;
        @AuraEnabled public String hcoName;
        @AuraEnabled public Date visitDate;
        @AuraEnabled public String callType;
        @AuraEnabled public String callStatus;
        @AuraEnabled public String recordStatus;
        @AuraEnabled public String territoryName;
        @AuraEnabled public Integer linkedEventCount;
    }

    public class KeyMessageItem {
        @AuraEnabled public Id id;
        @AuraEnabled public String message;
        @AuraEnabled public String description;
        @AuraEnabled public String product;
        @AuraEnabled public String reaction;
        @AuraEnabled public Boolean locked;
    }

    public class PromoDropItem {
        @AuraEnabled public Id id;
        @AuraEnabled public String item;
        @AuraEnabled public Integer qty;
    }

    public class SampleDropItem {
        @AuraEnabled public Id id;
        @AuraEnabled public Id productId;
        @AuraEnabled public String productName;
        @AuraEnabled public Integer qty;
        // Phase 0 (SM-CC-01/02/05): surfaced so a rep can see what was
        // captured for a cold-chain product — cvrSampleDrops.js now captures
        // these on the add/edit form, where before this row was unreadable
        // back and the form never rendered them at all.
        @AuraEnabled public String coldChainTagNumber;
        @AuraEnabled public String coldChainStatus;
    }

    public class AttendeeItem {
        @AuraEnabled public Id id;
        @AuraEnabled public Id hcpId;
        @AuraEnabled public String hcpName;
    }

    public class InternalAttendeeItem {
        @AuraEnabled public Id id;
        @AuraEnabled public Id userId;
        @AuraEnabled public String userName;
    }

    public class CVRDetail {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public Id hcpId;
        @AuraEnabled public String hcpName;
        @AuraEnabled public Id hcoId;
        @AuraEnabled public String hcoName;
        @AuraEnabled public Date visitDate;
        @AuraEnabled public String callType;
        @AuraEnabled public String callStatus;
        @AuraEnabled public String recordStatus;
        @AuraEnabled public String activityType;
        @AuraEnabled public String rep;
        @AuraEnabled public Id territoryId;
        @AuraEnabled public String territoryName;
        @AuraEnabled public Id planId;
        @AuraEnabled public String planName;
        @AuraEnabled public String preCallNotes;
        @AuraEnabled public String discussionSummary;
        @AuraEnabled public String nextCallNotes;
        @AuraEnabled public Date nextVisitDate;
        @AuraEnabled public Datetime startTime;
        @AuraEnabled public Datetime endTime;
        @AuraEnabled public Boolean signatureCaptured;
        @AuraEnabled public Boolean emailSent;
        @AuraEnabled public Integer linkedEventCount;
        @AuraEnabled public List<KeyMessageItem> keyMessages;
        @AuraEnabled public List<PromoDropItem> promoDrops;
        @AuraEnabled public List<SampleDropItem> sampleDrops;
        @AuraEnabled public List<AttendeeItem> attendees;
        @AuraEnabled public List<InternalAttendeeItem> internalAttendees;
    }

    /// Not cacheable — re-invoked after every create/edit/status-change, same
    /// reasoning as SciagenScheduleController.getMyPlannedCalls.
    @AuraEnabled
    public static List<CVRListItem> getMyCallReports(Date startDate, Date endDate, String status) {
        List<String> whereClauses = new List<String>{
            'OwnerId = :currentUserId', 'Visit_Date__c >= :startDate', 'Visit_Date__c <= :endDate'
        };
        Map<String, Object> binds = new Map<String, Object>{
            'currentUserId' => UserInfo.getUserId(), 'startDate' => startDate, 'endDate' => endDate
        };
        if (String.isNotBlank(status)) {
            whereClauses.add('Record_Status__c = :status');
            binds.put('status', status);
        }
        String query = 'SELECT Id, Name, HCP__c, HCP__r.Name, HCO__c, HCO__r.Name, Visit_Date__c, ' +
            'Call_Type__c, Call_Status__c, Record_Status__c, Linked_Event_Count__c ' +
            'FROM Call_Visit_Report__c WHERE ' + String.join(whereClauses, ' AND ') +
            ' ORDER BY Visit_Date__c DESC';
        List<Call_Visit_Report__c> reports = Database.queryWithBinds(query, binds, AccessLevel.USER_MODE);

        Set<Id> accountIds = new Set<Id>();
        for (Call_Visit_Report__c c : reports) {
            if (c.HCP__c != null) { accountIds.add(c.HCP__c); }
            if (c.HCO__c != null) { accountIds.add(c.HCO__c); }
        }
        Map<Id, String> territoryByAccountId = SciagenAccountController.territoryNamesByAccountId(accountIds);

        List<CVRListItem> results = new List<CVRListItem>();
        for (Call_Visit_Report__c c : reports) {
            CVRListItem item = new CVRListItem();
            item.id = c.Id;
            item.name = c.Name;
            item.hcpId = c.HCP__c;
            item.hcpName = c.HCP__c != null ? c.HCP__r.Name : null;
            item.hcoId = c.HCO__c;
            item.hcoName = c.HCO__c != null ? c.HCO__r.Name : null;
            item.visitDate = c.Visit_Date__c;
            item.callType = c.Call_Type__c;
            item.callStatus = c.Call_Status__c;
            item.recordStatus = c.Record_Status__c;
            item.territoryName = c.HCP__c != null ? territoryByAccountId.get(c.HCP__c) : territoryByAccountId.get(c.HCO__c);
            item.linkedEventCount = c.Linked_Event_Count__c == null ? 0 : c.Linked_Event_Count__c.intValue();
            results.add(item);
        }
        return results;
    }

    /// Not cacheable — children mutate via plain record-edit-forms outside this
    /// method's control, so a cached read would silently show stale rows.
    @AuraEnabled
    public static CVRDetail getCVRDetail(Id cvrId) {
        List<Call_Visit_Report__c> matches = [
            SELECT Id, Name, HCP__c, HCP__r.Name, HCO__c, HCO__r.Name, Visit_Date__c, Call_Type__c,
                   Call_Status__c, Record_Status__c, Activity_Type__c, Rep__c, Territory__c, Territory__r.Name,
                   Plan__c, Plan__r.Name, Pre_Call_Notes__c, Discussion_Summary__c, Next_Call_Notes__c,
                   Next_Visit_Date__c, Start_Time__c, End_Time__c, Signature_Captured__c, Email_Sent__c,
                   Linked_Event_Count__c
            FROM Call_Visit_Report__c
            WHERE Id = :cvrId
            WITH USER_MODE
            LIMIT 1
        ];
        if (matches.isEmpty()) {
            throw new AuraHandledException('Call Visit Report not found or not accessible.');
        }
        Call_Visit_Report__c c = matches[0];

        CVRDetail detail = new CVRDetail();
        detail.id = c.Id;
        detail.name = c.Name;
        detail.hcpId = c.HCP__c;
        detail.hcpName = c.HCP__c != null ? c.HCP__r.Name : null;
        detail.hcoId = c.HCO__c;
        detail.hcoName = c.HCO__c != null ? c.HCO__r.Name : null;
        detail.visitDate = c.Visit_Date__c;
        detail.callType = c.Call_Type__c;
        detail.callStatus = c.Call_Status__c;
        detail.recordStatus = c.Record_Status__c;
        detail.activityType = c.Activity_Type__c;
        detail.rep = c.Rep__c;
        detail.territoryId = c.Territory__c;
        detail.territoryName = c.Territory__c != null ? c.Territory__r.Name : null;
        detail.planId = c.Plan__c;
        detail.planName = c.Plan__c != null ? c.Plan__r.Name : null;
        detail.preCallNotes = c.Pre_Call_Notes__c;
        detail.discussionSummary = c.Discussion_Summary__c;
        detail.nextCallNotes = c.Next_Call_Notes__c;
        detail.nextVisitDate = c.Next_Visit_Date__c;
        detail.startTime = c.Start_Time__c;
        detail.endTime = c.End_Time__c;
        detail.signatureCaptured = c.Signature_Captured__c;
        detail.emailSent = c.Email_Sent__c;
        detail.linkedEventCount = c.Linked_Event_Count__c == null ? 0 : c.Linked_Event_Count__c.intValue();

        detail.keyMessages = new List<KeyMessageItem>();
        for (Key_Message__c km : [
            SELECT Id, Message__c, Description__c, Product__c, Reaction__c, Locked__c
            FROM Key_Message__c
            WHERE CVR__c = :cvrId
            WITH USER_MODE
            ORDER BY CreatedDate
        ]) {
            KeyMessageItem item = new KeyMessageItem();
            item.id = km.Id;
            item.message = km.Message__c;
            item.description = km.Description__c;
            item.product = km.Product__c;
            item.reaction = km.Reaction__c;
            item.locked = km.Locked__c;
            detail.keyMessages.add(item);
        }

        detail.promoDrops = new List<PromoDropItem>();
        for (Promo_Drop__c pd : [
            SELECT Id, Item__c, Qty__c
            FROM Promo_Drop__c
            WHERE CVR__c = :cvrId
            WITH USER_MODE
            ORDER BY CreatedDate
        ]) {
            PromoDropItem item = new PromoDropItem();
            item.id = pd.Id;
            item.item = pd.Item__c;
            item.qty = pd.Qty__c == null ? null : pd.Qty__c.intValue();
            detail.promoDrops.add(item);
        }

        detail.sampleDrops = new List<SampleDropItem>();
        for (Sample_Drop__c sd : [
            SELECT Id, Product__c, Product__r.Name, Product__r.SKUCode__c, Qty__c, Cold_Chain_Tag_Number__c, Cold_Chain_Status__c
            FROM Sample_Drop__c
            WHERE CVR__c = :cvrId
            WITH USER_MODE
            ORDER BY CreatedDate
        ]) {
            SampleDropItem item = new SampleDropItem();
            item.id = sd.Id;
            item.productId = sd.Product__c;
            // SKUCode__c (Name + SKU__c formula) is the display label reps
            // pick from and should see back — Name is only a fallback for a
            // product with no SKUCode__c value.
            item.productName = sd.Product__c == null ? null
                : (String.isNotBlank(sd.Product__r.SKUCode__c) ? sd.Product__r.SKUCode__c : sd.Product__r.Name);
            item.qty = sd.Qty__c == null ? null : sd.Qty__c.intValue();
            item.coldChainTagNumber = sd.Cold_Chain_Tag_Number__c;
            item.coldChainStatus = sd.Cold_Chain_Status__c;
            detail.sampleDrops.add(item);
        }

        detail.attendees = new List<AttendeeItem>();
        for (CVR_Attendee__c a : [
            SELECT Id, HCP__c, HCP__r.Name
            FROM CVR_Attendee__c
            WHERE CVR__c = :cvrId
            WITH USER_MODE
            ORDER BY CreatedDate
        ]) {
            AttendeeItem item = new AttendeeItem();
            item.id = a.Id;
            item.hcpId = a.HCP__c;
            item.hcpName = a.HCP__c != null ? a.HCP__r.Name : null;
            detail.attendees.add(item);
        }

        detail.internalAttendees = new List<InternalAttendeeItem>();
        for (CVR_Internal_Attendee__c ia : [
            SELECT Id, User__c, User__r.Name
            FROM CVR_Internal_Attendee__c
            WHERE CVR__c = :cvrId
            WITH USER_MODE
            ORDER BY CreatedDate
        ]) {
            InternalAttendeeItem item = new InternalAttendeeItem();
            item.id = ia.Id;
            item.userId = ia.User__c;
            item.userName = ia.User__c != null ? ia.User__r.Name : null;
            detail.internalAttendees.add(item);
        }

        return detail;
    }

    /// Flips Record_Status__c to Submitted and cascades Locked__c = true onto
    /// every Key_Message__c child, in one transaction — this is the one CVR
    /// operation that genuinely needs Apex-level atomicity rather than a plain
    /// record-edit-form.
    @AuraEnabled
    public static void submitCallReport(Id cvrId) {
        List<Call_Visit_Report__c> matches = [
            SELECT Id, OwnerId, Record_Status__c, Visit_Date__c
            FROM Call_Visit_Report__c WHERE Id = :cvrId WITH USER_MODE LIMIT 1
        ];
        if (matches.isEmpty()) {
            throw new AuraHandledException('Call Visit Report not found or not accessible.');
        }
        if (matches[0].OwnerId != UserInfo.getUserId()) {
            throw new AuraHandledException('Only the owning rep can submit this call report.');
        }
        if (isPastSubmissionDeadline(matches[0].Visit_Date__c)) {
            throw new AuraHandledException('This call is dated ' + matches[0].Visit_Date__c.format() +
                ', and the submission deadline for that month has passed. Contact your admin if you believe this is an error.');
        }

        List<Key_Message__c> keyMessages = [
            SELECT Id, Locked__c FROM Key_Message__c WHERE CVR__c = :cvrId WITH USER_MODE
        ];
        for (Key_Message__c km : keyMessages) {
            km.Locked__c = true;
        }

        Call_Visit_Report__c toUpdate = new Call_Visit_Report__c(Id = cvrId, Record_Status__c = 'Submitted');

        Database.update(toUpdate, AccessLevel.USER_MODE);
        if (!keyMessages.isEmpty()) {
            Database.update(keyMessages, AccessLevel.USER_MODE);
        }
    }

    /// Call_Backdate_Limit__c is a Hierarchy Custom Setting — getInstance()
    /// with no argument resolves User > Profile > Org-default automatically
    /// for the running user, same effective precedence the iOS app resolves
    /// by hand over REST (SalesforceRestDataService.resolveHierarchySetting).
    /// Also governs how far a draft/saved call report stays editable before
    /// callVisitReportDetail.js locks it read-only, matching iOS's RootView
    /// isCVREditable.
    @AuraEnabled(cacheable=true)
    public static Integer getCallBackdateLimitDays() {
        Call_Backdate_Limit__c setting = Call_Backdate_Limit__c.getInstance();
        return (setting != null && setting.Days__c != null) ? Integer.valueOf(setting.Days__c) : 30;
    }

    private static final List<String> MONTH_FIELD_NAMES = new List<String>{
        'January__c', 'February__c', 'March__c', 'April__c', 'May__c', 'June__c',
        'July__c', 'August__c', 'September__c', 'October__c', 'November__c', 'December__c'
    };

    /// Call_Submission_Restriction__c is a Hierarchy Custom Setting — same
    /// User > Profile > Org resolution as Call_Backdate_Limit__c above. Each
    /// month field holds the day of the *following* month by which a call
    /// dated in that month must be Submitted (e.g. December__c = 10 means a
    /// December call can't be Submitted past January 10th); a blank field
    /// means that month has no deadline. Clamps an out-of-range deadline day
    /// (e.g. an admin setting January__c = 31, but February only has 28/29
    /// days) to the deadline month's actual last day instead of throwing.
    private static Boolean isPastSubmissionDeadline(Date visitDate) {
        if (visitDate == null) {
            return false;
        }
        Call_Submission_Restriction__c setting = Call_Submission_Restriction__c.getInstance();
        if (setting == null) {
            return false;
        }
        Object rawDeadlineDay = setting.get(MONTH_FIELD_NAMES[visitDate.month() - 1]);
        if (rawDeadlineDay == null) {
            return false;
        }
        Integer deadlineDay = Integer.valueOf((Decimal) rawDeadlineDay);
        Date deadlineMonthFirst = Date.newInstance(visitDate.year(), visitDate.month(), 1).addMonths(1);
        Integer daysInDeadlineMonth = Date.daysInMonth(deadlineMonthFirst.year(), deadlineMonthFirst.month());
        Date deadline = Date.newInstance(deadlineMonthFirst.year(), deadlineMonthFirst.month(),
            Math.min(deadlineDay, daysInDeadlineMonth));
        return Date.today() > deadline;
    }
}