/**
 * Files on support requests and messages: only ordinary document and image
 * types, at most 10 MB each, and a running file count on the request so the
 * lists can show a paperclip without querying files.
 */
public without sharing class SupportFileService {

    public static final Set<String> ALLOWED = new Set<String>{ 'png', 'jpg', 'jpeg', 'pdf', 'txt', 'log', 'csv', 'json', 'xlsx', 'docx' };
    public static final Integer MAX_BYTES = 10 * 1024 * 1024;

    private static String requestPrefix() { return Support_Request__c.SObjectType.getDescribe().getKeyPrefix(); }
    private static String commentPrefix() { return Support_Comment__c.SObjectType.getDescribe().getKeyPrefix(); }

    private static Boolean isSupportRecord(Id linkedId) {
        if (linkedId == null) return false;
        String p = String.valueOf(linkedId).left(3);
        return p == requestPrefix() || p == commentPrefix();
    }

    private static String extensionOf(String name) {
        return name != null && name.contains('.') ? name.substringAfterLast('.').toLowerCase() : '';
    }

    /** Files uploaded straight onto a request or message. */
    public static void validateVersions(List<ContentVersion> versions) {
        for (ContentVersion v : versions) {
            if (!isSupportRecord(v.FirstPublishLocationId)) continue;
            if (!ALLOWED.contains(extensionOf(v.PathOnClient))) {
                v.addError('That file type is not allowed. Use an image, PDF, text, CSV, Excel or Word file.');
            } else if (v.VersionData != null && v.VersionData.size() > MAX_BYTES) {
                v.addError('That file is larger than 10 MB.');
            }
        }
    }

    /** Files linked afterwards (the standard uploader creates the file first, then links it). */
    public static void validateLinks(List<ContentDocumentLink> links) {
        Set<Id> docIds = new Set<Id>();
        for (ContentDocumentLink l : links) if (isSupportRecord(l.LinkedEntityId)) docIds.add(l.ContentDocumentId);
        if (docIds.isEmpty()) return;
        Map<Id, ContentDocument> docs = new Map<Id, ContentDocument>([SELECT Id, FileExtension, ContentSize FROM ContentDocument WHERE Id IN :docIds]);
        for (ContentDocumentLink l : links) {
            ContentDocument d = docs.get(l.ContentDocumentId);
            if (d == null || !isSupportRecord(l.LinkedEntityId)) continue;
            String ext = d.FileExtension == null ? '' : d.FileExtension.toLowerCase();
            if (!ALLOWED.contains(ext)) l.addError('That file type is not allowed. Use an image, PDF, text, CSV, Excel or Word file.');
            else if (d.ContentSize != null && d.ContentSize > MAX_BYTES) l.addError('That file is larger than 10 MB.');
        }
    }

    public static void countLinks(List<ContentDocumentLink> links, Integer delta) {
        Map<Id, Integer> perComment = new Map<Id, Integer>();
        Map<Id, Integer> perRequest = new Map<Id, Integer>();
        for (ContentDocumentLink l : links) {
            if (!isSupportRecord(l.LinkedEntityId)) continue;
            if (String.valueOf(l.LinkedEntityId).left(3) == commentPrefix()) perComment.put(l.LinkedEntityId, (perComment.containsKey(l.LinkedEntityId) ? perComment.get(l.LinkedEntityId) : 0) + delta);
            else perRequest.put(l.LinkedEntityId, (perRequest.containsKey(l.LinkedEntityId) ? perRequest.get(l.LinkedEntityId) : 0) + delta);
        }
        if (perComment.isEmpty() && perRequest.isEmpty()) return;

        List<Support_Comment__c> comments = [SELECT Id, Support_Request__c, Attachment_Count__c FROM Support_Comment__c WHERE Id IN :perComment.keySet()];
        for (Support_Comment__c c : comments) {
            Id rid = c.Support_Request__c;
            perRequest.put(rid, (perRequest.containsKey(rid) ? perRequest.get(rid) : 0) + perComment.get(c.Id));
            c.Attachment_Count__c = Math.max(0, (c.Attachment_Count__c == null ? 0 : c.Attachment_Count__c) + perComment.get(c.Id));
        }
        List<Support_Request__c> requests = [SELECT Id, Attachment_Count__c FROM Support_Request__c WHERE Id IN :perRequest.keySet()];
        for (Support_Request__c r : requests) r.Attachment_Count__c = Math.max(0, (r.Attachment_Count__c == null ? 0 : r.Attachment_Count__c) + perRequest.get(r.Id));
        if (!comments.isEmpty()) update comments;
        SupportRequestService.updateInternally(requests, true);
    }
}