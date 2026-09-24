/**
 * Help & Support for reps and their managers (Lightning). Everything runs in
 * the user's own sharing: a rep sees what they raised, a manager also sees
 * what they are copied on. Business Admins use SupportConsoleController.
 */
public with sharing class SupportController {

    private static final Set<String> ALLOWED_TYPES = new Set<String>{ 'png', 'jpg', 'jpeg', 'pdf', 'txt', 'log', 'csv', 'json', 'xlsx', 'docx' };
    private static final Integer MAX_APEX_UPLOAD_BYTES = 4 * 1024 * 1024;

    public class Context {
        @AuraEnabled public Id userId;
        @AuraEnabled public String userName;
        @AuraEnabled public Boolean isAgent;
        @AuraEnabled public Boolean hasTeam;
        @AuraEnabled public String managerName;
        @AuraEnabled public List<String> categories = new List<String>();
        @AuraEnabled public List<String> priorities = new List<String>();
        @AuraEnabled public Integer maxFileMb = 10;
        @AuraEnabled public List<String> allowedTypes = new List<String>();
    }

    public class CallOption {
        @AuraEnabled public Id id;
        @AuraEnabled public String label;
    }

    @AuraEnabled
    public static Context getContext() {
        Context c = new Context();
        c.userId = UserInfo.getUserId();
        c.userName = UserInfo.getName();
        c.isAgent = SupportRequestService.isAgent();
        Id me = UserInfo.getUserId();
        List<User> mine = [SELECT Manager.Name FROM User WHERE Id = :me LIMIT 1];
        c.managerName = mine.isEmpty() || mine[0].Manager == null ? null : mine[0].Manager.Name;
        c.hasTeam = [SELECT COUNT() FROM Support_Request__c WHERE Manager__c = :me AND Requester__c != :me LIMIT 1] > 0;
        for (Schema.PicklistEntry e : Support_Request__c.Category__c.getDescribe().getPicklistValues()) if (e.isActive()) c.categories.add(e.getValue());
        for (Schema.PicklistEntry e : Support_Request__c.Priority__c.getDescribe().getPicklistValues()) if (e.isActive()) c.priorities.add(e.getValue());
        c.allowedTypes = new List<String>(ALLOWED_TYPES);
        c.allowedTypes.sort();
        return c;
    }

    @AuraEnabled
    public static SupportListService.ListPage listRequests(SupportListService.Filter filter) {
        SupportListService.Filter f = filter == null ? new SupportListService.Filter() : filter;
        if (f.scope != 'team') f.scope = 'mine';
        return SupportListService.search(f, AccessLevel.USER_MODE);
    }

    @AuraEnabled
    public static SupportListService.Detail getRequest(Id requestId) {
        SupportListService.Detail d = SupportListService.detail(requestId, AccessLevel.USER_MODE);
        return d;
    }

    /** The rep has read the latest reply. */
    @AuraEnabled
    public static void markRead(Id requestId) {
        List<Support_Request__c> rows = [SELECT Id, Requester__c, Manager__c FROM Support_Request__c WHERE Id = :requestId WITH USER_MODE LIMIT 1];
        if (rows.isEmpty() || rows[0].Requester__c != UserInfo.getUserId()) return;
        SupportRequestService.updateInternally(new List<Support_Request__c>{ new Support_Request__c(Id = requestId, Requester_Last_Read_At__c = Datetime.now()) }, true);
    }

    @AuraEnabled
    public static Id createRequest(String subject, String description, String category, String priority, Id callId, String clientId) {
        if (String.isBlank(subject)) throw new AuraHandledException('Give the request a short subject.');
        if (String.isNotBlank(clientId)) {
            List<Support_Request__c> existing = [SELECT Id FROM Support_Request__c WHERE Client_Id__c = :clientId WITH USER_MODE LIMIT 1];
            if (!existing.isEmpty()) return existing[0].Id;
        }
        Support_Request__c r = new Support_Request__c(
            Subject__c = subject.trim().left(120), Description__c = description, Category__c = category,
            Priority__c = String.isBlank(priority) ? 'Normal' : priority, Call_Visit_Report__c = callId, Source__c = 'Web',
            Client_Id__c = String.isBlank(clientId) ? null : clientId);
        try {
            Database.insert(r, AccessLevel.USER_MODE);
        } catch (DmlException e) {
            throw new AuraHandledException(e.getDmlMessage(0));
        }
        return r.Id;
    }

    @AuraEnabled
    public static Id addMessage(Id requestId, String body, String clientId) {
        if (String.isNotBlank(clientId)) {
            List<Support_Comment__c> existing = [SELECT Id FROM Support_Comment__c WHERE Client_Id__c = :clientId WITH USER_MODE LIMIT 1];
            if (!existing.isEmpty()) return existing[0].Id;
        }
        Support_Comment__c c = new Support_Comment__c(Support_Request__c = requestId, Body__c = body, Sent_Via__c = 'Web', Client_Id__c = String.isBlank(clientId) ? null : clientId);
        try {
            Database.insert(c, AccessLevel.USER_MODE);
        } catch (DmlException e) {
            throw new AuraHandledException(e.getDmlMessage(0));
        }
        return c.Id;
    }

    @AuraEnabled
    public static void cancelRequest(Id requestId) { setStatus(requestId, 'Cancelled'); }

    @AuraEnabled
    public static void reopenRequest(Id requestId) { setStatus(requestId, 'Open'); }

    private static void setStatus(Id requestId, String status) {
        try {
            Database.update(new Support_Request__c(Id = requestId, Status__c = status), AccessLevel.USER_MODE);
        } catch (DmlException e) {
            throw new AuraHandledException(e.getDmlMessage(0));
        }
    }

    /** The rep's own recent submitted calls, for "Unlock a submitted call". */
    @AuraEnabled(cacheable=false)
    public static List<CallOption> myCallsForUnlock() {
        List<CallOption> out = new List<CallOption>();
        for (Call_Visit_Report__c c : [
            SELECT Id, Visit_Date__c, HCP__r.Name FROM Call_Visit_Report__c
            WHERE OwnerId = :UserInfo.getUserId() AND Record_Status__c = 'Submitted' AND Visit_Date__c >= :Date.today().addDays(-120)
            ORDER BY Visit_Date__c DESC LIMIT 200
        ]) {
            CallOption o = new CallOption();
            o.id = c.Id;
            o.label = (c.HCP__r == null ? 'Call' : c.HCP__r.Name) + ' - ' + (c.Visit_Date__c == null ? '' : c.Visit_Date__c.format());
            out.add(o);
        }
        return out;
    }

    /**
     * Adds a pasted or dropped screenshot to a request or message. Larger files
     * and everything picked from disk use the standard file uploader, which
     * streams straight to Salesforce.
     */
    @AuraEnabled
    public static Id uploadFile(Id parentId, String fileName, String base64) {
        String type = parentId.getSObjectType().getDescribe().getName();
        if (type != 'Support_Request__c' && type != 'Support_Comment__c') throw new AuraHandledException('Files can only be added to a support request.');
        String ext = fileName != null && fileName.contains('.') ? fileName.substringAfterLast('.').toLowerCase() : '';
        if (!ALLOWED_TYPES.contains(ext)) throw new AuraHandledException('That file type is not allowed. Use an image, PDF, text, CSV, Excel or Word file.');
        Blob data = EncodingUtil.base64Decode(base64);
        if (data.size() > MAX_APEX_UPLOAD_BYTES) throw new AuraHandledException('That picture is too large. Use the Upload button for files over 4 MB.');
        if (type == 'Support_Request__c') {
            if ([SELECT COUNT() FROM Support_Request__c WHERE Id = :parentId WITH USER_MODE] == 0) throw new AuraHandledException('You do not have access to that request.');
        } else if ([SELECT COUNT() FROM Support_Comment__c WHERE Id = :parentId WITH USER_MODE] == 0) {
            throw new AuraHandledException('You do not have access to that message.');
        }
        ContentVersion v = new ContentVersion(Title = fileName.left(200), PathOnClient = fileName, VersionData = data, FirstPublishLocationId = parentId);
        insert v;
        return v.Id;
    }
}