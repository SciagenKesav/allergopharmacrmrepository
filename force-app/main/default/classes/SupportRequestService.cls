/**
 * Rules for Support_Request__c: stamps who raised it and who is copied in,
 * keeps Open / Closed and "whose turn" honest, limits what a rep can change,
 * writes the system lines in the conversation and sends the alerts.
 *
 * Reps own their requests, so the platform would let them edit anything on
 * them. The guard below narrows that to: mark it read, cancel it, reopen it.
 */
public without sharing class SupportRequestService {

    public static final String CAT_UNLOCK = 'Unlock Submitted Call';
    public static final Set<String> OPEN_STATUSES = new Set<String>{ 'New', 'Open', 'Waiting on Rep' };

    /** Set while another trigger (comments, batch, unlock) updates a request on the user's behalf. */
    public static Boolean internalUpdate = false;
    public static Boolean suppressEvents = false;

    private static final Set<String> SYSTEM_FIELDS = new Set<String>{
        'lastmodifieddate', 'lastmodifiedbyid', 'systemmodstamp', 'lastvieweddate', 'lastreferenceddate', 'isdeleted', 'createddate', 'createdbyid'
    };
    private static final Set<String> REP_EDITABLE = new Set<String>{ 'requester_last_read_at__c', 'status__c' };

    public static Boolean isAgent() { return FeatureManagement.checkPermission('Support_Agent'); }

    // ------------------------------------------------------------------ before insert

    public static void beforeInsert(List<Support_Request__c> rows) {
        SupportConfig cfg = SupportConfig.load();
        Boolean agent = isAgent();
        Id me = UserInfo.getUserId();
        Datetime now = Datetime.now();

        Set<Id> requesterIds = new Set<Id>();
        for (Support_Request__c r : rows) {
            if (!agent || r.Requester__c == null) r.Requester__c = me;
            requesterIds.add(r.Requester__c);
        }
        Map<Id, User> users = new Map<Id, User>([SELECT Id, ManagerId FROM User WHERE Id IN :requesterIds]);
        Map<Id, String> territories = SampleTerritoryService.namesFor(requesterIds);

        Map<Id, Integer> raisedToday = new Map<Id, Integer>();
        if (!agent) {
            for (AggregateResult ar : [
                SELECT Requester__c u, COUNT(Id) n FROM Support_Request__c WHERE Requester__c IN :requesterIds AND CreatedDate = TODAY GROUP BY Requester__c
            ]) raisedToday.put((Id) ar.get('u'), (Integer) ar.get('n'));
        }

        Set<Id> callIds = new Set<Id>();
        for (Support_Request__c r : rows) if (r.Category__c == CAT_UNLOCK && r.Call_Visit_Report__c != null) callIds.add(r.Call_Visit_Report__c);
        Map<Id, Call_Visit_Report__c> calls = new Map<Id, Call_Visit_Report__c>([
            SELECT Id, OwnerId, Record_Status__c, Visit_Date__c, HCP__r.Name FROM Call_Visit_Report__c WHERE Id IN :callIds
        ]);
        Set<Id> alreadyOpen = new Set<Id>();
        for (Support_Request__c o : [
            SELECT Call_Visit_Report__c FROM Support_Request__c WHERE Call_Visit_Report__c IN :callIds AND Is_Open__c = true AND Category__c = :CAT_UNLOCK
        ]) alreadyOpen.add(o.Call_Visit_Report__c);

        for (Support_Request__c r : rows) {
            Id requester = r.Requester__c;
            if (!agent) {
                Integer n = raisedToday.containsKey(requester) ? raisedToday.get(requester) : 0;
                if (n >= cfg.maxRequestsPerDay) {
                    r.addError('You have reached today\'s limit of ' + cfg.maxRequestsPerDay + ' requests. Please add to an existing request instead.');
                    continue;
                }
                raisedToday.put(requester, n + 1);
            }
            if (r.Category__c == CAT_UNLOCK) {
                Call_Visit_Report__c call = r.Call_Visit_Report__c == null ? null : calls.get(r.Call_Visit_Report__c);
                if (call == null) { r.addError('Choose the submitted call you want unlocked.'); continue; }
                if (call.Record_Status__c != 'Submitted') { r.addError('That call is not submitted, so it is already open for editing.'); continue; }
                if (!agent && call.OwnerId != requester) { r.addError('You can only ask to unlock your own calls.'); continue; }
                if (alreadyOpen.contains(call.Id)) { r.addError('There is already an open request to unlock this call.'); continue; }
                alreadyOpen.add(call.Id);
                r.Call_Summary__c = ((call.HCP__r == null ? 'Call' : call.HCP__r.Name) + ' - ' + (call.Visit_Date__c == null ? '' : call.Visit_Date__c.format())).left(255);
            }
            User u = users.get(requester);
            r.OwnerId = requester;
            r.Manager__c = u == null ? null : u.ManagerId;
            r.Requester_Territory__c = territories.get(requester);
            r.Status__c = 'New';
            r.Is_Open__c = true;
            r.Awaiting__c = 'Support';
            if (r.Priority__c == null) r.Priority__c = 'Normal';
            if (r.Source__c == null) r.Source__c = agent ? 'Admin' : 'Web';
            if (!agent) r.Assigned_To__c = null;
            r.Resolution_Type__c = null;
            r.Unlock_Outcome__c = null;
            r.Comment_Count__c = 0;
            r.Attachment_Count__c = 0;
            r.Reopen_Count__c = 0;
            r.Last_Activity_At__c = now;
            r.Requester_Last_Read_At__c = now;
            r.Last_Requester_Comment_At__c = null;
            r.Last_Support_Comment_At__c = null;
            r.First_Response_At__c = null;
            r.SLA_Due_At__c = cfg.firstResponseDue(r.Priority__c, now);
        }

        if (cfg.autoAssign) {
            List<Support_Request__c> open = new List<Support_Request__c>();
            for (Support_Request__c r : rows) if (r.Assigned_To__c == null) open.add(r);
            SupportAssignmentService.autoAssign(open);
        }
        for (Support_Request__c r : rows) if (r.Assigned_To__c != null) r.Status__c = 'Open';
    }

    // ------------------------------------------------------------------ before update

    public static void beforeUpdate(List<Support_Request__c> rows, Map<Id, Support_Request__c> oldMap) {
        SupportConfig cfg = SupportConfig.load();
        Boolean agent = isAgent();
        Id me = UserInfo.getUserId();
        Datetime now = Datetime.now();
        Set<String> guarded = new Set<String>();
        if (!agent && !internalUpdate) {
            for (String f : Schema.SObjectType.Support_Request__c.fields.getMap().keySet()) {
                if (!REP_EDITABLE.contains(f) && !SYSTEM_FIELDS.contains(f)) guarded.add(f);
            }
        }
        for (Support_Request__c r : rows) {
            Support_Request__c o = oldMap.get(r.Id);
            if (!agent && !internalUpdate) {
                if (!repMayEdit(r, o, me, guarded, cfg, now)) continue;
            }

            if (o.Assigned_To__c != r.Assigned_To__c && r.Assigned_To__c != null && r.Status__c == 'New') r.Status__c = 'Open';
            if (r.Priority__c != o.Priority__c && r.First_Response_At__c == null) {
                r.SLA_Due_At__c = cfg.firstResponseDue(r.Priority__c, r.CreatedDate);
            }

            if (r.Status__c != o.Status__c) {
                Boolean wasOpen = OPEN_STATUSES.contains(o.Status__c);
                Boolean isOpen = OPEN_STATUSES.contains(r.Status__c);
                r.Is_Open__c = isOpen;
                r.Awaiting__c = r.Status__c == 'Waiting on Rep' ? 'Requester' : (isOpen ? 'Support' : 'Nobody');
                if (r.Status__c == 'Resolved') {
                    r.Resolved_At__c = now;
                    r.Resolution_Minutes__c = minutesBetween(r.CreatedDate, now);
                } else if (r.Status__c == 'Closed' || r.Status__c == 'Cancelled') {
                    r.Closed_At__c = now;
                    if (r.Resolved_At__c == null) {
                        r.Resolved_At__c = now;
                        r.Resolution_Minutes__c = minutesBetween(r.CreatedDate, now);
                    }
                } else if (!wasOpen && isOpen) {
                    r.Reopen_Count__c = (r.Reopen_Count__c == null ? 0 : r.Reopen_Count__c) + 1;
                    r.Resolved_At__c = null;
                    r.Closed_At__c = null;
                    r.Resolution_Type__c = null;
                    r.Resolution_Minutes__c = null;
                }
                r.Last_Activity_At__c = now;
            }
            if (o.Assigned_To__c != r.Assigned_To__c || o.Priority__c != r.Priority__c || o.Manager__c != r.Manager__c) r.Last_Activity_At__c = now;
        }
    }

    private static Boolean repMayEdit(Support_Request__c r, Support_Request__c o, Id me, Set<String> guarded, SupportConfig cfg, Datetime now) {
        if (o.Requester__c != me) {
            r.addError('Only the person who raised this request, or the support team, can change it. You can reply in the conversation.');
            return false;
        }
        for (String f : guarded) {
            if (r.get(f) != o.get(f)) {
                r.addError('You can mark a request as read, cancel it or reopen it. To change anything else, reply in the conversation.');
                return false;
            }
        }
        if (r.Status__c != o.Status__c) {
            Boolean cancel = OPEN_STATUSES.contains(o.Status__c) && r.Status__c == 'Cancelled';
            Datetime closedAt = o.Closed_At__c != null ? o.Closed_At__c : o.Resolved_At__c;
            Boolean reopen = (o.Status__c == 'Resolved' || o.Status__c == 'Closed') && r.Status__c == 'Open'
                && closedAt != null && closedAt > now.addDays(-cfg.reopenDays);
            if (!cancel && !reopen) {
                r.addError(o.Status__c == 'Closed' || o.Status__c == 'Resolved'
                    ? 'This request was closed more than ' + cfg.reopenDays + ' days ago. Please raise a new request.'
                    : 'You can only cancel a request that is still open.');
                return false;
            }
        }
        return true;
    }

    private static Decimal minutesBetween(Datetime a, Datetime b) {
        if (a == null || b == null) return null;
        return Decimal.valueOf((b.getTime() - a.getTime()) / 60000);
    }

    // ------------------------------------------------------------------ after insert / update

    public static void afterInsert(List<Support_Request__c> rows) {
        SupportSharingService.sync(rows, null);
        List<Support_Comment__c> events = new List<Support_Comment__c>();
        for (Support_Request__c r : rows) {
            events.add(SupportCommentService.event(r.Id, 'Request raised' + (r.Assigned_To__c != null ? ' and assigned' : '') + '.'));
            SupportNotifier.bell(SupportNotifier.ids(r.Manager__c, r.Assigned_To__c, null),
                'Support request ' + r.Subject__c, 'New ' + r.Category__c + ' request ' + (r.Priority__c == 'Urgent' || r.Priority__c == 'High' ? '(' + r.Priority__c + ')' : ''), r.Id);
        }
        SupportCommentService.insertEvents(events);
    }

    public static void afterUpdate(List<Support_Request__c> rows, Map<Id, Support_Request__c> oldMap) {
        SupportSharingService.sync(rows, oldMap);
        if (suppressEvents) return;

        Set<Id> userIds = new Set<Id>();
        for (Support_Request__c r : rows) {
            Support_Request__c o = oldMap.get(r.Id);
            if (o.Assigned_To__c != r.Assigned_To__c) { userIds.add(r.Assigned_To__c); userIds.add(o.Assigned_To__c); }
            if (o.Manager__c != r.Manager__c) userIds.add(r.Manager__c);
            userIds.add(UserInfo.getUserId());
        }
        userIds.remove(null);
        Map<Id, User> names = new Map<Id, User>([SELECT Id, Name FROM User WHERE Id IN :userIds]);
        String actor = names.containsKey(UserInfo.getUserId()) ? names.get(UserInfo.getUserId()).Name : 'Support';

        List<Support_Comment__c> events = new List<Support_Comment__c>();
        for (Support_Request__c r : rows) {
            Support_Request__c o = oldMap.get(r.Id);
            if (o.Status__c != r.Status__c) {
                String line;
                if (!OPEN_STATUSES.contains(o.Status__c) && OPEN_STATUSES.contains(r.Status__c)) line = 'Reopened by ' + actor + '.';
                else if (r.Status__c == 'Resolved') line = 'Marked as resolved by ' + actor + (r.Resolution_Type__c == null ? '' : ' (' + r.Resolution_Type__c + ')') + '.';
                else if (r.Status__c == 'Closed') line = 'Closed.';
                else if (r.Status__c == 'Cancelled') line = 'Cancelled by ' + actor + '.';
                else line = 'Status changed to ' + r.Status__c + '.';
                events.add(SupportCommentService.event(r.Id, line));
                if (r.Status__c == 'Resolved' || r.Status__c == 'Closed') {
                    String title = 'Resolved: ' + r.Subject__c;
                    SupportNotifier.bell(SupportNotifier.ids(r.Requester__c, r.Manager__c, null), title, 'Your request ' + r.Name + ' was marked ' + r.Status__c.toLowerCase() + '.', r.Id);
                    SupportNotifier.email(SupportNotifier.ids(r.Requester__c, r.Manager__c, null), title,
                        'Request ' + r.Name + ' (' + r.Subject__c + ') was marked ' + r.Status__c.toLowerCase() + '. Open Sciagen CRM > Help & Support to read the reply, or reply there to reopen it.');
                }
            }
            if (o.Assigned_To__c != r.Assigned_To__c) {
                String to = r.Assigned_To__c == null ? null : (names.containsKey(r.Assigned_To__c) ? names.get(r.Assigned_To__c).Name : 'a Business Admin');
                events.add(SupportCommentService.event(r.Id, to == null ? 'Unassigned.' : 'Assigned to ' + to + '.'));
                SupportNotifier.bell(SupportNotifier.ids(r.Assigned_To__c, null, null), 'Assigned to you: ' + r.Subject__c, r.Category__c + ' - ' + r.Name, r.Id);
            }
            if (o.Priority__c != r.Priority__c) events.add(SupportCommentService.event(r.Id, 'Priority changed to ' + r.Priority__c + '.'));
            if (o.Manager__c != r.Manager__c && r.Manager__c != null) {
                String mn = names.containsKey(r.Manager__c) ? names.get(r.Manager__c).Name : 'the manager';
                events.add(SupportCommentService.event(r.Id, mn + ' copied in.'));
            }
        }
        SupportCommentService.insertEvents(events);
    }

    /** Runs an update of requests on behalf of the current user without tripping the rep guard. */
    public static void updateInternally(List<Support_Request__c> rows, Boolean quiet) {
        if (rows.isEmpty()) return;
        Boolean prevInternal = internalUpdate;
        Boolean prevQuiet = suppressEvents;
        internalUpdate = true;
        suppressEvents = quiet;
        try { update rows; }
        finally { internalUpdate = prevInternal; suppressEvents = prevQuiet; }
    }
}