/**
 * Reads for the Help & Support screens: filtered, keyset-paged lists (no
 * OFFSET, so page 500 costs the same as page 1 at 3,000 reps) and the full
 * detail of one request with its conversation and files.
 */
public without sharing class SupportListService {

    public class Filter {
        @AuraEnabled public String view;            // open, closed, all, unassigned, mine, needsReply, waiting, overdue
        @AuraEnabled public String requesterId;     // admin view: only this user's requests (set by SupportController, ignored for reps)
        @AuraEnabled public String scope;           // mine (raised by me), team (I am the copied manager), all (support)
        @AuraEnabled public String category;
        @AuraEnabled public String priority;
        @AuraEnabled public String status;
        @AuraEnabled public String assignedToId;    // 'none' for unassigned
        @AuraEnabled public String managerId;
        @AuraEnabled public String territory;
        @AuraEnabled public String text;
        @AuraEnabled public Date fromDate;
        @AuraEnabled public Date toDate;
        @AuraEnabled public String sortField;
        @AuraEnabled public String sortDir;
        @AuraEnabled public Integer pageSize;
        @AuraEnabled public Datetime cursorAt;
        @AuraEnabled public String cursorId;
    }

    public class Row {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String subject;
        @AuraEnabled public String category;
        @AuraEnabled public String priority;
        @AuraEnabled public String status;
        @AuraEnabled public Boolean isOpen;
        @AuraEnabled public String awaiting;
        @AuraEnabled public Id requesterId;
        @AuraEnabled public String requesterName;
        @AuraEnabled public Id managerId;
        @AuraEnabled public String managerName;
        @AuraEnabled public Id assignedId;
        @AuraEnabled public String assignedName;
        @AuraEnabled public String territory;
        @AuraEnabled public String callSummary;
        @AuraEnabled public Id callId;
        @AuraEnabled public Integer commentCount;
        @AuraEnabled public Integer attachmentCount;
        @AuraEnabled public Datetime createdAt;
        @AuraEnabled public Datetime lastActivityAt;
        @AuraEnabled public Datetime slaDueAt;
        @AuraEnabled public Boolean overdue;
        @AuraEnabled public Boolean unreadForRequester;
        @AuraEnabled public Boolean unreadForSupport;
        @AuraEnabled public String resolution;
        @AuraEnabled public String unlockOutcome;
        @AuraEnabled public String source;
    }

    public class ListPage {
        @AuraEnabled public List<Row> rows = new List<Row>();
        @AuraEnabled public Boolean hasMore = false;
        @AuraEnabled public Datetime nextAt;
        @AuraEnabled public String nextId;
        @AuraEnabled public Integer total;          // capped at 10,000
    }

    public class Attachment {
        @AuraEnabled public Id documentId;
        @AuraEnabled public Id versionId;
        @AuraEnabled public Id linkedId;
        @AuraEnabled public String title;
        @AuraEnabled public String extension;
        @AuraEnabled public Integer size;
        @AuraEnabled public Boolean isImage;
        @AuraEnabled public String url;
        @AuraEnabled public String previewUrl;
    }

    public class Message {
        @AuraEnabled public Id id;
        @AuraEnabled public String kind;
        @AuraEnabled public String role;
        @AuraEnabled public Id authorId;
        @AuraEnabled public String authorName;
        @AuraEnabled public String body;
        @AuraEnabled public Datetime createdAt;
        @AuraEnabled public String sentVia;
        @AuraEnabled public List<Attachment> attachments = new List<Attachment>();
    }

    public class Detail {
        @AuraEnabled public Row row;
        @AuraEnabled public String description;
        @AuraEnabled public String deviceInfo;
        @AuraEnabled public List<Message> messages = new List<Message>();
        @AuraEnabled public List<Attachment> requestFiles = new List<Attachment>();
        @AuraEnabled public Boolean canReply;
        @AuraEnabled public Boolean canCancel;
        @AuraEnabled public Boolean canReopen;
        @AuraEnabled public String closedNote;
    }

    private static final Set<String> SORT_FIELDS = new Set<String>{ 'Last_Activity_At__c', 'CreatedDate', 'SLA_Due_At__c' };
    private static final Set<String> IMAGE_EXT = new Set<String>{ 'png', 'jpg', 'jpeg', 'gif', 'heic' };
    private static final String SELECT_FIELDS =
        'Id, Name, Subject__c, Category__c, Priority__c, Status__c, Is_Open__c, Awaiting__c, Requester__c, Requester__r.Name, Manager__c, Manager__r.Name, ' +
        'Assigned_To__c, Assigned_To__r.Name, Requester_Territory__c, Call_Summary__c, Call_Visit_Report__c, Comment_Count__c, Attachment_Count__c, ' +
        'CreatedDate, Last_Activity_At__c, Last_Support_Comment_At__c, Last_Requester_Comment_At__c, Requester_Last_Read_At__c, Support_Last_Read_At__c, ' +
        'SLA_Due_At__c, First_Response_At__c, Resolution_Type__c, Unlock_Outcome__c, Source__c';

    // ------------------------------------------------------------------ list

    public static ListPage search(Filter f, AccessLevel level) {
        Integer size = f.pageSize == null ? 50 : Math.max(1, Math.min(f.pageSize, 200));
        String sortField = SORT_FIELDS.contains(f.sortField) ? f.sortField : 'Last_Activity_At__c';
        Boolean ascending = f.sortDir == 'ASC';
        Map<String, Object> binds = new Map<String, Object>();
        String where1 = whereClause(f, binds);
        String base = 'SELECT ' + SELECT_FIELDS + ' FROM Support_Request__c WHERE ' + where1;

        String pageWhere = where1;
        if (f.cursorAt != null && String.isNotBlank(f.cursorId)) {
            String op = ascending ? '>' : '<';
            binds.put('curAt', f.cursorAt);
            binds.put('curId', (Id) f.cursorId);
            pageWhere += ' AND (' + sortField + ' ' + op + ' :curAt OR (' + sortField + ' = :curAt AND Id ' + op + ' :curId))';
        }
        String dir = ascending ? 'ASC' : 'DESC';
        String soql = 'SELECT ' + SELECT_FIELDS + ' FROM Support_Request__c WHERE ' + pageWhere +
            ' ORDER BY ' + sortField + ' ' + dir + ', Id ' + dir + ' LIMIT ' + (size + 1);
        List<Support_Request__c> found = Database.queryWithBinds(soql, binds, level);

        ListPage p = new ListPage();
        Datetime now = Datetime.now();
        Integer n = 0;
        for (Support_Request__c r : found) {
            if (n == size) { p.hasMore = true; break; }
            p.rows.add(toRow(r, now));
            n++;
        }
        if (p.hasMore && !p.rows.isEmpty()) {
            Support_Request__c lastRow = found[size - 1];
            p.nextAt = (Datetime) lastRow.get(sortField);
            p.nextId = lastRow.Id;
        }
        if (f.cursorAt == null) {
            Map<String, Object> countBinds = new Map<String, Object>();
            String countWhere = whereClause(f, countBinds);
            p.total = Database.countQueryWithBinds('SELECT COUNT() FROM Support_Request__c WHERE ' + countWhere + ' LIMIT 10000', countBinds, level);
        }
        return p;
    }

    /** All the requests matching a filter, for export (capped). */
    public static List<Row> exportRows(Filter f, Integer cap, AccessLevel level) {
        Map<String, Object> binds = new Map<String, Object>();
        String soql = 'SELECT ' + SELECT_FIELDS + ' FROM Support_Request__c WHERE ' + whereClause(f, binds) + ' ORDER BY CreatedDate DESC, Id DESC LIMIT ' + cap;
        List<Row> out = new List<Row>();
        Datetime now = Datetime.now();
        for (Support_Request__c r : (List<Support_Request__c>) Database.queryWithBinds(soql, binds, level)) out.add(toRow(r, now));
        return out;
    }

    private static String whereClause(Filter f, Map<String, Object> binds) {
        List<String> w = new List<String>();
        Id me = UserInfo.getUserId();
        binds.put('me', me);
        binds.put('nowAt', Datetime.now());
        String scope = f.scope == null ? 'mine' : f.scope;
        if (String.isNotBlank(f.requesterId)) { w.add('Requester__c = :requesterId'); binds.put('requesterId', (Id) f.requesterId); }
        else if (scope == 'mine') w.add('Requester__c = :me');
        else if (scope == 'team') w.add('(Manager__c = :me AND Requester__c != :me)');

        String view = f.view == null ? 'open' : f.view;
        Boolean windowed = false;
        if (view == 'open') w.add('Is_Open__c = true');
        else if (view == 'closed') { w.add('Is_Open__c = false'); windowed = true; }
        else if (view == 'all') windowed = true;
        else if (view == 'unassigned') { w.add('Is_Open__c = true'); w.add('Assigned_To__c = null'); }
        else if (view == 'mine') { w.add('Is_Open__c = true'); w.add('Assigned_To__c = :me'); }
        else if (view == 'needsReply') { w.add('Is_Open__c = true'); w.add('Awaiting__c = \'Support\''); }
        else if (view == 'waiting') w.add('Status__c = \'Waiting on Rep\'');
        else if (view == 'overdue') { w.add('Is_Open__c = true'); w.add('First_Response_At__c = null'); w.add('SLA_Due_At__c < :nowAt'); }

        if (String.isNotBlank(f.category)) { w.add('Category__c = :category'); binds.put('category', f.category); }
        if (String.isNotBlank(f.priority)) { w.add('Priority__c = :priority'); binds.put('priority', f.priority); }
        if (String.isNotBlank(f.status)) { w.add('Status__c = :status'); binds.put('status', f.status); }
        if (String.isNotBlank(f.assignedToId)) {
            if (f.assignedToId == 'none') w.add('Assigned_To__c = null');
            else { w.add('Assigned_To__c = :assignedTo'); binds.put('assignedTo', (Id) f.assignedToId); }
        }
        if (String.isNotBlank(f.managerId)) { w.add('Manager__c = :managerId'); binds.put('managerId', (Id) f.managerId); }
        if (String.isNotBlank(f.territory)) { w.add('Requester_Territory__c LIKE :territory'); binds.put('territory', '%' + f.territory.trim() + '%'); }
        if (String.isNotBlank(f.text)) {
            w.add('(Name LIKE :term OR Subject__c LIKE :term OR Requester__r.Name LIKE :term OR Call_Summary__c LIKE :term)');
            binds.put('term', '%' + f.text.trim() + '%');
        }
        if (f.fromDate != null) { w.add('CreatedDate >= :fromAt'); binds.put('fromAt', Datetime.newInstance(f.fromDate, Time.newInstance(0, 0, 0, 0))); }
        else if (windowed) { w.add('Last_Activity_At__c >= :windowAt'); binds.put('windowAt', Datetime.now().addDays(-90)); }
        if (f.toDate != null) { w.add('CreatedDate < :toAt'); binds.put('toAt', Datetime.newInstance(f.toDate.addDays(1), Time.newInstance(0, 0, 0, 0))); }
        if (w.isEmpty()) w.add('Id != null');
        return String.join(w, ' AND ');
    }

    public static Row toRow(Support_Request__c r, Datetime now) {
        Row x = new Row();
        x.id = r.Id;
        x.name = r.Name;
        x.subject = r.Subject__c;
        x.category = r.Category__c;
        x.priority = r.Priority__c;
        x.status = r.Status__c;
        x.isOpen = r.Is_Open__c == true;
        x.awaiting = r.Awaiting__c;
        x.requesterId = r.Requester__c;
        x.requesterName = r.Requester__r == null ? null : r.Requester__r.Name;
        x.managerId = r.Manager__c;
        x.managerName = r.Manager__r == null ? null : r.Manager__r.Name;
        x.assignedId = r.Assigned_To__c;
        x.assignedName = r.Assigned_To__r == null ? null : r.Assigned_To__r.Name;
        x.territory = r.Requester_Territory__c;
        x.callSummary = r.Call_Summary__c;
        x.callId = r.Call_Visit_Report__c;
        x.commentCount = r.Comment_Count__c == null ? 0 : r.Comment_Count__c.intValue();
        x.attachmentCount = r.Attachment_Count__c == null ? 0 : r.Attachment_Count__c.intValue();
        x.createdAt = r.CreatedDate;
        x.lastActivityAt = r.Last_Activity_At__c;
        x.slaDueAt = r.SLA_Due_At__c;
        x.overdue = r.Is_Open__c == true && r.First_Response_At__c == null && r.SLA_Due_At__c != null && r.SLA_Due_At__c < now;
        x.unreadForRequester = r.Last_Support_Comment_At__c != null && (r.Requester_Last_Read_At__c == null || r.Last_Support_Comment_At__c > r.Requester_Last_Read_At__c);
        x.unreadForSupport = r.Last_Requester_Comment_At__c != null && (r.Support_Last_Read_At__c == null || r.Last_Requester_Comment_At__c > r.Support_Last_Read_At__c);
        x.resolution = r.Resolution_Type__c;
        x.unlockOutcome = r.Unlock_Outcome__c;
        x.source = r.Source__c;
        return x;
    }

    // ------------------------------------------------------------------ detail

    public static Detail detail(Id requestId, AccessLevel level) {
        List<Support_Request__c> found = Database.query(
            'SELECT ' + SELECT_FIELDS + ', Description__c, Device_Info__c, Closed_At__c, Resolved_At__c FROM Support_Request__c WHERE Id = :requestId LIMIT 1', level);
        if (found.isEmpty()) throw new AuraHandledException('That request was not found, or you do not have access to it.');
        Support_Request__c r = found[0];
        Detail d = new Detail();
        d.row = toRow(r, Datetime.now());
        d.description = r.Description__c;
        d.deviceInfo = r.Device_Info__c;

        List<Support_Comment__c> comments = Database.query(
            'SELECT Id, Kind__c, Author_Role__c, Author__c, Author__r.Name, Body__c, CreatedDate, Sent_Via__c FROM Support_Comment__c ' +
            'WHERE Support_Request__c = :requestId ORDER BY CreatedDate ASC, Id ASC LIMIT 500', level);
        Set<Id> linkIds = new Set<Id>{ requestId };
        for (Support_Comment__c c : comments) linkIds.add(c.Id);
        Map<Id, List<Attachment>> files = filesFor(linkIds);
        d.requestFiles = files.containsKey(requestId) ? files.get(requestId) : new List<Attachment>();
        for (Support_Comment__c c : comments) {
            Message m = new Message();
            m.id = c.Id; m.kind = c.Kind__c; m.role = c.Author_Role__c; m.authorId = c.Author__c;
            m.authorName = c.Author__r == null ? null : c.Author__r.Name;
            m.body = c.Body__c; m.createdAt = c.CreatedDate; m.sentVia = c.Sent_Via__c;
            if (files.containsKey(c.Id)) m.attachments = files.get(c.Id);
            d.messages.add(m);
        }

        SupportConfig cfg = SupportConfig.load();
        Datetime closedAt = r.Closed_At__c != null ? r.Closed_At__c : r.Resolved_At__c;
        Boolean open = r.Is_Open__c == true;
        Boolean canReopenWindow = closedAt != null && closedAt > Datetime.now().addDays(-cfg.reopenDays);
        d.canReply = open || ((r.Status__c == 'Resolved' || r.Status__c == 'Closed') && canReopenWindow);
        d.canCancel = open;
        d.canReopen = (r.Status__c == 'Resolved' || r.Status__c == 'Closed') && canReopenWindow;
        if (!open && closedAt != null) {
            d.closedNote = r.Status__c + ' on ' + closedAt.format('d MMM yyyy') + (d.canReopen ? '. Reply to reopen it.' : '. Please raise a new request if you still need help.');
        }
        return d;
    }

    public static Map<Id, List<Attachment>> filesFor(Set<Id> linkedIds) {
        Map<Id, List<Attachment>> out = new Map<Id, List<Attachment>>();
        for (ContentDocumentLink l : [
            SELECT LinkedEntityId, ContentDocumentId, ContentDocument.Title, ContentDocument.FileExtension, ContentDocument.ContentSize, ContentDocument.LatestPublishedVersionId
            FROM ContentDocumentLink WHERE LinkedEntityId IN :linkedIds
        ]) {
            Attachment a = new Attachment();
            a.documentId = l.ContentDocumentId;
            a.versionId = l.ContentDocument.LatestPublishedVersionId;
            a.linkedId = l.LinkedEntityId;
            a.title = l.ContentDocument.Title;
            a.extension = (l.ContentDocument.FileExtension == null ? '' : l.ContentDocument.FileExtension).toLowerCase();
            a.size = l.ContentDocument.ContentSize;
            a.isImage = IMAGE_EXT.contains(a.extension);
            a.url = '/sfc/servlet.shepherd/version/download/' + a.versionId;
            a.previewUrl = a.isImage ? '/sfc/servlet.shepherd/version/renditionDownload?rendition=THUMB720BY480&versionId=' + a.versionId : null;
            if (!out.containsKey(l.LinkedEntityId)) out.put(l.LinkedEntityId, new List<Attachment>());
            out.get(l.LinkedEntityId).add(a);
        }
        return out;
    }
}