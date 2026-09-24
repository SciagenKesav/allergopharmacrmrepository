/**
 * Rules for Support_Comment__c, the conversation on a request: who wrote it
 * (rep, manager or support), what a message does to the request, the daily
 * message limit, and the alerts to the other side. System lines ("Assigned
 * to ...") are Events: shown in the thread, never counted or alerted.
 */
public without sharing class SupportCommentService {

    private static Boolean systemInsert = false;

    public static Support_Comment__c event(Id requestId, String text) {
        return new Support_Comment__c(
            Support_Request__c = requestId, Kind__c = 'Event', Body__c = text.left(2000), Author_Role__c = 'System',
            Author__c = UserInfo.getUserId(), Sent_Via__c = 'System');
    }

    public static void insertEvents(List<Support_Comment__c> events) {
        if (events == null || events.isEmpty()) return;
        Boolean prev = systemInsert;
        systemInsert = true;
        try { insert events; }
        finally { systemInsert = prev; }
    }

    // ------------------------------------------------------------------ before insert

    public static void beforeInsert(List<Support_Comment__c> rows) {
        if (systemInsert) return;
        SupportConfig cfg = SupportConfig.load();
        Boolean agent = SupportRequestService.isAgent();
        Id me = UserInfo.getUserId();

        Set<Id> requestIds = new Set<Id>();
        for (Support_Comment__c c : rows) requestIds.add(c.Support_Request__c);
        Map<Id, Support_Request__c> requests = new Map<Id, Support_Request__c>([
            SELECT Id, Requester__c, Manager__c, Status__c, Closed_At__c, Resolved_At__c FROM Support_Request__c WHERE Id IN :requestIds
        ]);
        Integer sentToday = [SELECT COUNT() FROM Support_Comment__c WHERE Author__c = :me AND Kind__c = 'Message' AND CreatedDate = TODAY LIMIT 1001];
        Datetime now = Datetime.now();

        for (Support_Comment__c c : rows) {
            Support_Request__c req = requests.get(c.Support_Request__c);
            c.Kind__c = 'Message';                       // system lines are only written by this package's own code
            c.Author__c = me;
            if (c.Sent_Via__c == null || c.Sent_Via__c == 'System') c.Sent_Via__c = 'Web';
            if (req == null) continue;
            if (req.Requester__c == me) c.Author_Role__c = 'Requester';
            else if (agent) c.Author_Role__c = 'Support';
            else if (req.Manager__c == me) c.Author_Role__c = 'Manager';
            else c.Author_Role__c = 'Support';

            if (String.isBlank(c.Body__c)) { c.addError('Write a message before sending.'); continue; }
            sentToday++;
            if (!agent && sentToday > cfg.maxCommentsPerDay) {
                c.addError('You have reached today\'s message limit. Please try again tomorrow, or call your manager if it is urgent.');
                continue;
            }
            if (c.Author_Role__c == 'Requester' && !agent) {
                if (req.Status__c == 'Cancelled') { c.addError('This request was cancelled. Please raise a new request.'); continue; }
                if (req.Status__c == 'Closed' || req.Status__c == 'Resolved') {
                    Datetime closedAt = req.Closed_At__c != null ? req.Closed_At__c : req.Resolved_At__c;
                    if (closedAt != null && closedAt < now.addDays(-cfg.reopenDays)) {
                        c.addError('This request was closed more than ' + cfg.reopenDays + ' days ago. Please raise a new request.');
                    }
                }
            }
        }
    }

    // ------------------------------------------------------------------ after insert

    public static void afterInsert(List<Support_Comment__c> rows) {
        if (systemInsert) return;
        Datetime now = Datetime.now();
        Map<Id, List<Support_Comment__c>> byRequest = new Map<Id, List<Support_Comment__c>>();
        for (Support_Comment__c c : rows) {
            if (c.Kind__c != 'Message') continue;
            if (!byRequest.containsKey(c.Support_Request__c)) byRequest.put(c.Support_Request__c, new List<Support_Comment__c>());
            byRequest.get(c.Support_Request__c).add(c);
        }
        if (byRequest.isEmpty()) return;

        Map<Id, Support_Request__c> requests = new Map<Id, Support_Request__c>([
            SELECT Id, Name, Subject__c, Status__c, Requester__c, Manager__c, Assigned_To__c, CreatedDate, First_Response_At__c, Comment_Count__c
            FROM Support_Request__c WHERE Id IN :byRequest.keySet()
        ]);
        List<Support_Request__c> updates = new List<Support_Request__c>();
        for (Id rid : byRequest.keySet()) {
            Support_Request__c r = requests.get(rid);
            if (r == null) continue;
            Support_Request__c u = new Support_Request__c(Id = rid);
            u.Comment_Count__c = (r.Comment_Count__c == null ? 0 : r.Comment_Count__c) + byRequest.get(rid).size();
            u.Last_Activity_At__c = now;
            String status = r.Status__c;
            for (Support_Comment__c c : byRequest.get(rid)) {
                if (c.Author_Role__c == 'Requester') {
                    u.Last_Requester_Comment_At__c = now;
                    if (status == 'Waiting on Rep' || status == 'Resolved' || status == 'Closed') status = 'Open';
                } else {
                    u.Last_Support_Comment_At__c = now;
                    if (c.Author_Role__c == 'Support' && r.First_Response_At__c == null && u.First_Response_At__c == null) {
                        u.First_Response_At__c = now;
                        u.First_Response_Minutes__c = Decimal.valueOf((now.getTime() - r.CreatedDate.getTime()) / 60000);
                    }
                    if (status == 'New' && c.Author_Role__c == 'Support') status = 'Open';
                }
            }
            if (status != r.Status__c) u.Status__c = status;
            updates.add(u);
        }
        SupportRequestService.updateInternally(updates, true);

        // Reopened by a reply: say so in the thread.
        List<Support_Comment__c> events = new List<Support_Comment__c>();
        for (Support_Request__c u : updates) {
            Support_Request__c before = requests.get(u.Id);
            if (u.Status__c == 'Open' && before.Status__c != 'Open' && before.Status__c != 'New') {
                events.add(event(u.Id, before.Status__c == 'Waiting on Rep' ? 'The requester replied.' : 'Reopened by a reply.'));
            }
        }
        insertEvents(events);
        alert(byRequest, requests);
    }

    private static void alert(Map<Id, List<Support_Comment__c>> byRequest, Map<Id, Support_Request__c> requests) {
        Set<Id> authors = new Set<Id>();
        for (List<Support_Comment__c> list1 : byRequest.values()) for (Support_Comment__c c : list1) authors.add(c.Author__c);
        Map<Id, User> names = new Map<Id, User>([SELECT Id, Name FROM User WHERE Id IN :authors]);
        for (Id rid : byRequest.keySet()) {
            Support_Request__c r = requests.get(rid);
            if (r == null) continue;
            Support_Comment__c last = byRequest.get(rid)[byRequest.get(rid).size() - 1];
            String who = names.containsKey(last.Author__c) ? names.get(last.Author__c).Name : 'Someone';
            String snippet = last.Body__c == null ? '' : last.Body__c.left(200);
            if (last.Author_Role__c == 'Requester') {
                SupportNotifier.bell(SupportNotifier.ids(r.Assigned_To__c, null, null), who + ' replied: ' + r.Subject__c, snippet, rid);
            } else {
                Set<Id> targets = SupportNotifier.ids(r.Requester__c, r.Manager__c, last.Author_Role__c == 'Manager' ? r.Assigned_To__c : null);
                SupportNotifier.bell(targets, who + ' replied: ' + r.Subject__c, snippet, rid);
                SupportNotifier.email(SupportNotifier.ids(r.Requester__c, r.Manager__c, null), 'Reply on ' + r.Name + ': ' + r.Subject__c,
                    who + ' wrote:\n\n' + snippet + '\n\nOpen Sciagen CRM > Help & Support to read it and reply.');
            }
        }
    }
}