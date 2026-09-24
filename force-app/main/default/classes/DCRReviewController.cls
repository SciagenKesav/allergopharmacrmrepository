/**
 * Backend for the DCR (Data Change Request) review queue LWC — the first
 * Salesforce-side surface for stewards to browse, filter, and approve/reject
 * the New/Edit HCP/HCO requests reps submit from the iPad app (see
 * SciagenAccountSyncService, which writes Data_Change_Request__c). Before
 * this, the only way to act on a DCR was the raw standard object tab.
 *
 * Approving any request here just flips Status__c — the existing
 * DataChangeRequestApprovalHandler trigger does the actual work: creating the
 * Account for "New HCP"/"New HCO", or writing the requested field values onto
 * the existing Subject_Account__c for "Edit HCP"/"Edit HCO".
 *
 * Security: `with sharing` + WITH USER_MODE / AccessLevel.USER_MODE on every
 * query and DML, matching RCPAMatrixController's conventions.
 */
public with sharing class DCRReviewController {

    // Fields_Payload__c keys are the app's own internal camelCase field ids,
    // not Salesforce API names — mirrored verbatim from DCRView.swift's
    // `diffLabels` (line 68) so labels here read exactly like they did on
    // the rep's phone.
    private static final Map<String, String> FIELD_LABELS = new Map<String, String>{
        'name' => 'Name', 'type' => 'Type', 'speciality' => 'Speciality',
        'city' => 'City', 'state' => 'State', 'pincode' => 'Pincode', 'phone' => 'Phone',
        'prefix' => 'Prefix', 'firstName' => 'First Name', 'lastName' => 'Last Name',
        'specialty' => 'Specialty', 'degree1' => 'Degree', 'hcpType' => 'HCP Type',
        'email' => 'Email', 'affiliationHCO' => 'Affiliation (HCO)'
    };

    // MARK: - Queue

    public class DCRQueueItem {
        @AuraEnabled public Id id;
        @AuraEnabled public String type;
        @AuraEnabled public String status;
        @AuraEnabled public String subjectName;
        @AuraEnabled public String submittedBy;
        @AuraEnabled public String submittedAt;
        @AuraEnabled public String fullAddress;
        @AuraEnabled public Integer commentCount;
    }

    @AuraEnabled
    public static List<DCRQueueItem> getDCRQueue() {
        List<Data_Change_Request__c> dcrs = [
            SELECT Id, Type__c, Status__c, Subject_Name__c, Submitted_By__c, Submitted_At__c, Full_Address__c, Comment_Count__c
            FROM Data_Change_Request__c
            WITH USER_MODE
            ORDER BY Submitted_At__c DESC NULLS LAST, CreatedDate DESC
        ];
        List<DCRQueueItem> items = new List<DCRQueueItem>();
        for (Data_Change_Request__c dcr : dcrs) {
            DCRQueueItem item = new DCRQueueItem();
            item.id = dcr.Id;
            item.type = dcr.Type__c;
            item.status = dcr.Status__c;
            item.subjectName = dcr.Subject_Name__c;
            item.submittedBy = dcr.Submitted_By__c;
            item.commentCount = dcr.Comment_Count__c != null ? Integer.valueOf(dcr.Comment_Count__c) : 0;
            item.submittedAt = dcr.Submitted_At__c != null ? dcr.Submitted_At__c.format() : null;
            item.fullAddress = dcr.Full_Address__c;
            items.add(item);
        }
        return items;
    }

    // MARK: - Detail

    // New HCP/New HCO: Fields_Payload__c is a flat {key: value} map.
    public class FlatField implements Comparable {
        @AuraEnabled public String label;
        @AuraEnabled public String value;
        public Integer compareTo(Object other) {
            return label.compareTo(((FlatField) other).label);
        }
    }

    // Edit HCP/Edit HCO: Fields_Payload__c is a {key: {current, requested}} map.
    public class DiffField implements Comparable {
        @AuraEnabled public String label;
        @AuraEnabled public String current;
        @AuraEnabled public String requested;
        public Integer compareTo(Object other) {
            return label.compareTo(((DiffField) other).label);
        }
    }

    public class DCRDetail {
        @AuraEnabled public Id id;
        @AuraEnabled public String type;
        @AuraEnabled public String status;
        @AuraEnabled public String subjectName;
        @AuraEnabled public Id relatedHCOId;
        @AuraEnabled public String relatedHCOName;
        @AuraEnabled public Id subjectAccountId;
        @AuraEnabled public String subjectAccountName;
        @AuraEnabled public String summary;
        @AuraEnabled public String submittedBy;
        @AuraEnabled public String submittedAt;
        @AuraEnabled public String rejectionReason;
        @AuraEnabled public Boolean isDiff;
        @AuraEnabled public List<FlatField> flatFields;
        @AuraEnabled public List<DiffField> diffFields;
        @AuraEnabled public Id photoContentVersionId;
    }

    @AuraEnabled
    public static DCRDetail getDCRDetail(Id dcrId) {
        List<Data_Change_Request__c> dcrs = [
            SELECT Id, Type__c, Status__c, Subject_Name__c, Related_HCO__c, Related_HCO__r.Name,
                   Subject_Account__c, Subject_Account__r.Name, Fields_Payload__c, Summary__c,
                   Submitted_By__c, Submitted_At__c, Rejection_Reason__c
            FROM Data_Change_Request__c
            WHERE Id = :dcrId
            WITH USER_MODE
            LIMIT 1
        ];
        if (dcrs.isEmpty()) {
            throw new AuraHandledException('Data Change Request not found or not accessible.');
        }
        Data_Change_Request__c dcr = dcrs[0];

        DCRDetail detail = new DCRDetail();
        detail.id = dcr.Id;
        detail.type = dcr.Type__c;
        detail.status = dcr.Status__c;
        detail.subjectName = dcr.Subject_Name__c;
        detail.relatedHCOId = dcr.Related_HCO__c;
        detail.relatedHCOName = dcr.Related_HCO__r != null ? dcr.Related_HCO__r.Name : null;
        detail.subjectAccountId = dcr.Subject_Account__c;
        detail.subjectAccountName = dcr.Subject_Account__r != null ? dcr.Subject_Account__r.Name : null;
        detail.summary = dcr.Summary__c;
        detail.submittedBy = dcr.Submitted_By__c;
        detail.submittedAt = dcr.Submitted_At__c != null ? dcr.Submitted_At__c.format() : null;
        detail.rejectionReason = dcr.Rejection_Reason__c;
        detail.isDiff = dcr.Type__c == 'Edit HCP' || dcr.Type__c == 'Edit HCO';
        detail.flatFields = new List<FlatField>();
        detail.diffFields = new List<DiffField>();

        Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(
            String.isBlank(dcr.Fields_Payload__c) ? '{}' : dcr.Fields_Payload__c);

        if (detail.isDiff) {
            for (String key : payload.keySet()) {
                Object raw = payload.get(key);
                if (!(raw instanceof Map<String, Object>)) continue;
                Map<String, Object> pair = (Map<String, Object>) raw;
                DiffField df = new DiffField();
                df.label = FIELD_LABELS.containsKey(key) ? FIELD_LABELS.get(key) : key;
                df.current = displayValue(pair.get('current'));
                df.requested = displayValue(pair.get('requested'));
                detail.diffFields.add(df);
            }
            detail.diffFields.sort();
        } else {
            for (String key : payload.keySet()) {
                FlatField ff = new FlatField();
                ff.label = FIELD_LABELS.containsKey(key) ? FIELD_LABELS.get(key) : key;
                ff.value = displayValue(payload.get(key));
                detail.flatFields.add(ff);
            }
            detail.flatFields.sort();
        }

        detail.photoContentVersionId = findLatestPhotoVersion(dcrId);
        return detail;
    }

    // Matches DCRView.swift's diffSummary(...) convention: an empty/blank
    // value reads as "(blank)" rather than an empty cell.
    private static String displayValue(Object raw) {
        String s = raw != null ? String.valueOf(raw).trim() : '';
        return String.isBlank(s) ? '(blank)' : s;
    }

    // Same ContentDocumentLink -> ContentVersion lookup shape as
    // DataChangeRequestApprovalHandler.carryProofPhotoToAccount.
    private static Id findLatestPhotoVersion(Id dcrId) {
        List<ContentDocumentLink> links = [
            SELECT ContentDocumentId FROM ContentDocumentLink WHERE LinkedEntityId = :dcrId WITH USER_MODE
        ];
        if (links.isEmpty()) return null;
        Set<Id> docIds = new Set<Id>();
        for (ContentDocumentLink l : links) docIds.add(l.ContentDocumentId);
        List<ContentVersion> versions = [
            SELECT Id FROM ContentVersion
            WHERE ContentDocumentId IN :docIds AND IsLatest = true
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        return versions.isEmpty() ? null : versions[0].Id;
    }

    // MARK: - Actions

    @AuraEnabled
    public static void approveDCR(Id dcrId) {
        Data_Change_Request__c dcr = loadPendingOrThrow(dcrId, 'approved');
        dcr.Status__c = 'Approved';
        saveOrThrow(dcr);
    }

    @AuraEnabled
    public static void rejectDCR(Id dcrId, String reason) {
        if (String.isBlank(reason)) {
            throw new AuraHandledException('A rejection reason is required.');
        }
        Data_Change_Request__c dcr = loadPendingOrThrow(dcrId, 'rejected');
        dcr.Status__c = 'Rejected';
        dcr.Rejection_Reason__c = reason;
        saveOrThrow(dcr);
    }

    // MARK: - Comments (DCR_Comment__c thread)

    public class CommentItem {
        @AuraEnabled public Id id;
        @AuraEnabled public String authorName;
        @AuraEnabled public String authorRole;
        @AuraEnabled public String body;
        @AuraEnabled public String createdAt;
    }

    @AuraEnabled(cacheable=true)
    public static List<CommentItem> getComments(Id dcrId) {
        List<CommentItem> items = new List<CommentItem>();
        for (DCR_Comment__c c : [
            SELECT Id, Author__c, Author__r.Name, Author_Role__c, Body__c, CreatedDate
            FROM DCR_Comment__c
            WHERE Data_Change_Request__c = :dcrId
            WITH USER_MODE
            ORDER BY CreatedDate ASC
        ]) {
            CommentItem item = new CommentItem();
            item.id = c.Id;
            item.authorName = c.Author__c != null ? c.Author__r.Name : null;
            item.authorRole = c.Author_Role__c;
            item.body = c.Body__c;
            item.createdAt = c.CreatedDate.format();
            items.add(item);
        }
        return items;
    }

    /// A Business Admin's reply on the DCR Review Queue — always filed as
    /// Author_Role__c = 'Business Admin', regardless of the DCR's own
    /// Status__c, so a steward can keep the conversation going even after
    /// approving/rejecting (e.g. to answer a follow-up question).
    @AuraEnabled
    public static void addComment(Id dcrId, String body) {
        if (String.isBlank(body)) {
            throw new AuraHandledException('Enter a message before replying.');
        }
        List<Data_Change_Request__c> dcrs = [
            SELECT Id FROM Data_Change_Request__c WHERE Id = :dcrId WITH USER_MODE LIMIT 1
        ];
        if (dcrs.isEmpty()) {
            throw new AuraHandledException('Data Change Request not found or not accessible.');
        }
        try {
            Database.insert(new DCR_Comment__c(
                Data_Change_Request__c = dcrId,
                Author__c = UserInfo.getUserId(),
                Author_Role__c = 'Business Admin',
                Body__c = body
            ), AccessLevel.USER_MODE);
        } catch (DmlException e) {
            throw new AuraHandledException(e.getDmlMessage(0));
        }
    }

    private static Data_Change_Request__c loadPendingOrThrow(Id dcrId, String action) {
        List<Data_Change_Request__c> dcrs = [
            SELECT Id, Status__c FROM Data_Change_Request__c WHERE Id = :dcrId WITH USER_MODE LIMIT 1
        ];
        if (dcrs.isEmpty()) {
            throw new AuraHandledException('Data Change Request not found or not accessible.');
        }
        if (dcrs[0].Status__c != 'Pending Approval') {
            throw new AuraHandledException('Only a Pending Approval request can be ' + action + '.');
        }
        return dcrs[0];
    }

    // Surfaces a trigger-added error (e.g. DataChangeRequestApprovalHandler
    // failing to auto-create the Account) as a readable message instead of a
    // generic DML failure.
    private static void saveOrThrow(Data_Change_Request__c dcr) {
        try {
            Database.update(dcr, AccessLevel.USER_MODE);
        } catch (DmlException e) {
            // AuraHandledException's constructor message is NOT what
            // getMessage() returns to a caller (a well-known Apex gotcha) —
            // .setMessage() is required, or every caller (including our own
            // tests) only ever sees the generic "Script-thrown exception".
            AuraHandledException ahe = new AuraHandledException(e.getDmlMessage(0));
            ahe.setMessage(e.getDmlMessage(0));
            throw ahe;
        }
    }
}