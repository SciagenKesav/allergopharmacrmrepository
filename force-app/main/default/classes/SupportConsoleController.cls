/**
 * Help & Support console for Business Admins: the tracker (filtered, paged),
 * board numbers, replying, assigning, resolving and unlocking calls.
 *
 * Runs without sharing because admins see every rep's requests; every entry
 * point therefore checks the Support Agent permission first.
 */
public without sharing class SupportConsoleController {

    public class Board {
        @AuraEnabled public Integer open;
        @AuraEnabled public Integer unassigned;
        @AuraEnabled public Integer needsReply;
        @AuraEnabled public Integer waiting;
        @AuraEnabled public Integer overdue;
        @AuraEnabled public Integer mine;
        @AuraEnabled public Integer openedToday;
        @AuraEnabled public Integer resolvedToday;
        @AuraEnabled public Decimal avgFirstResponseHours;
        @AuraEnabled public Integer oldestOpenDays;
        @AuraEnabled public List<CategoryCount> byCategory = new List<CategoryCount>();
        @AuraEnabled public List<DayCount> trend = new List<DayCount>();
    }
    public class CategoryCount {
        @AuraEnabled public String category;
        @AuraEnabled public Integer count;
    }
    public class DayCount {
        @AuraEnabled public Date day;
        @AuraEnabled public Integer raised = 0;
        @AuraEnabled public Integer resolved = 0;
    }
    public class AgentOption {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
    }
    public class ConsoleContext {
        @AuraEnabled public Id userId;
        @AuraEnabled public String userName;
        @AuraEnabled public Boolean canUnlock;
        @AuraEnabled public Boolean canUnlockPlan;
        @AuraEnabled public List<AgentOption> agents = new List<AgentOption>();
        @AuraEnabled public List<String> categories = new List<String>();
        @AuraEnabled public List<String> priorities = new List<String>();
        @AuraEnabled public List<String> statuses = new List<String>();
        @AuraEnabled public List<String> resolutions = new List<String>();
    }
    public class RowResult {
        @AuraEnabled public Id id;
        @AuraEnabled public Boolean ok;
        @AuraEnabled public String message;
    }

    private static void requireAgent() {
        if (!SupportRequestService.isAgent()) throw new AuraHandledException('This page is for the Business Admin support team.');
    }

    @AuraEnabled
    public static ConsoleContext getContext() {
        requireAgent();
        ConsoleContext c = new ConsoleContext();
        c.userId = UserInfo.getUserId();
        c.userName = UserInfo.getName();
        c.canUnlock = FeatureManagement.checkPermission('Support_Unlock_Calls');
        c.canUnlockPlan = MonthlyCallPlanService.canUnlock();
        for (User u : SupportAssignmentService.agents().values()) {
            AgentOption o = new AgentOption();
            o.id = u.Id;
            o.name = u.Name;
            c.agents.add(o);
        }
        for (Schema.PicklistEntry e : Support_Request__c.Category__c.getDescribe().getPicklistValues()) if (e.isActive()) c.categories.add(e.getValue());
        for (Schema.PicklistEntry e : Support_Request__c.Priority__c.getDescribe().getPicklistValues()) if (e.isActive()) c.priorities.add(e.getValue());
        for (Schema.PicklistEntry e : Support_Request__c.Status__c.getDescribe().getPicklistValues()) if (e.isActive()) c.statuses.add(e.getValue());
        for (Schema.PicklistEntry e : Support_Request__c.Resolution_Type__c.getDescribe().getPicklistValues()) if (e.isActive()) c.resolutions.add(e.getValue());
        return c;
    }

    @AuraEnabled
    public static Board getBoard() {
        requireAgent();
        Id me = UserInfo.getUserId();
        Datetime now = Datetime.now();
        Board b = new Board();
        b.open = [SELECT COUNT() FROM Support_Request__c WHERE Is_Open__c = true];
        b.unassigned = [SELECT COUNT() FROM Support_Request__c WHERE Is_Open__c = true AND Assigned_To__c = null];
        b.needsReply = [SELECT COUNT() FROM Support_Request__c WHERE Is_Open__c = true AND Awaiting__c = 'Support'];
        b.waiting = [SELECT COUNT() FROM Support_Request__c WHERE Status__c = 'Waiting on Rep'];
        b.overdue = [SELECT COUNT() FROM Support_Request__c WHERE Is_Open__c = true AND First_Response_At__c = null AND SLA_Due_At__c < :now];
        b.mine = [SELECT COUNT() FROM Support_Request__c WHERE Is_Open__c = true AND Assigned_To__c = :me];
        b.openedToday = [SELECT COUNT() FROM Support_Request__c WHERE CreatedDate = TODAY];
        b.resolvedToday = [SELECT COUNT() FROM Support_Request__c WHERE Resolved_At__c = TODAY];
        for (AggregateResult ar : [SELECT AVG(First_Response_Minutes__c) m FROM Support_Request__c WHERE CreatedDate = LAST_N_DAYS:7 AND First_Response_At__c != null]) {
            Decimal m = (Decimal) ar.get('m');
            b.avgFirstResponseHours = m == null ? null : (m / 60).setScale(1);
        }
        for (AggregateResult ar : [SELECT MIN(CreatedDate) m FROM Support_Request__c WHERE Is_Open__c = true]) {
            Datetime m = (Datetime) ar.get('m');
            b.oldestOpenDays = m == null ? null : m.date().daysBetween(Date.today());
        }
        for (AggregateResult ar : [SELECT Category__c c, COUNT(Id) n FROM Support_Request__c WHERE Is_Open__c = true GROUP BY Category__c ORDER BY COUNT(Id) DESC]) {
            CategoryCount cc = new CategoryCount();
            cc.category = (String) ar.get('c');
            cc.count = (Integer) ar.get('n');
            b.byCategory.add(cc);
        }
        Map<Date, DayCount> days = new Map<Date, DayCount>();
        for (Integer i = 13; i >= 0; i--) {
            DayCount d = new DayCount();
            d.day = Date.today().addDays(-i);
            days.put(d.day, d);
            b.trend.add(d);
        }
        for (AggregateResult ar : [SELECT DAY_ONLY(CreatedDate) d, COUNT(Id) n FROM Support_Request__c WHERE CreatedDate = LAST_N_DAYS:14 GROUP BY DAY_ONLY(CreatedDate)]) {
            Date d = (Date) ar.get('d');
            if (days.containsKey(d)) days.get(d).raised = (Integer) ar.get('n');
        }
        for (AggregateResult ar : [SELECT DAY_ONLY(Resolved_At__c) d, COUNT(Id) n FROM Support_Request__c WHERE Resolved_At__c = LAST_N_DAYS:14 GROUP BY DAY_ONLY(Resolved_At__c)]) {
            Date d = (Date) ar.get('d');
            if (days.containsKey(d)) days.get(d).resolved = (Integer) ar.get('n');
        }
        return b;
    }

    @AuraEnabled
    public static SupportListService.ListPage listRequests(SupportListService.Filter filter) {
        requireAgent();
        SupportListService.Filter f = filter == null ? new SupportListService.Filter() : filter;
        f.scope = 'all';
        return SupportListService.search(f, AccessLevel.SYSTEM_MODE);
    }

    @AuraEnabled
    public static List<SupportListService.Row> exportRows(SupportListService.Filter filter) {
        requireAgent();
        SupportListService.Filter f = filter == null ? new SupportListService.Filter() : filter;
        f.scope = 'all';
        return SupportListService.exportRows(f, 2000, AccessLevel.SYSTEM_MODE);
    }

    @AuraEnabled
    public static SupportListService.Detail getRequest(Id requestId) {
        requireAgent();
        SupportListService.Detail d = SupportListService.detail(requestId, AccessLevel.SYSTEM_MODE);
        d.canReply = d.row.isOpen || d.row.status == 'Resolved' || d.row.status == 'Closed';
        d.canCancel = false;
        d.canReopen = !d.row.isOpen;
        return d;
    }

    @AuraEnabled
    public static void markRead(Id requestId) {
        requireAgent();
        SupportRequestService.updateInternally(new List<Support_Request__c>{ new Support_Request__c(Id = requestId, Support_Last_Read_At__c = Datetime.now()) }, true);
    }

    /**
     * Sends a reply as support and, in the same step, moves the request on:
     * Waiting on Rep (default), Open, or Resolved with a resolution.
     */
    @AuraEnabled
    public static Id reply(Id requestId, String body, String nextStatus, String resolutionType, String clientId) {
        requireAgent();
        if (String.isBlank(body)) throw new AuraHandledException('Write a message before sending.');
        Set<String> allowed = new Set<String>{ 'Open', 'Waiting on Rep', 'Resolved', 'Closed' };
        String status = String.isBlank(nextStatus) ? 'Waiting on Rep' : nextStatus;
        if (!allowed.contains(status)) throw new AuraHandledException('Choose Open, Waiting on Rep or Resolved.');
        if (String.isNotBlank(clientId)) {
            List<Support_Comment__c> existing = [SELECT Id FROM Support_Comment__c WHERE Client_Id__c = :clientId LIMIT 1];
            if (!existing.isEmpty()) return existing[0].Id;
        }
        Support_Comment__c c = new Support_Comment__c(Support_Request__c = requestId, Body__c = body, Sent_Via__c = 'Web', Client_Id__c = String.isBlank(clientId) ? null : clientId);
        Support_Request__c u = new Support_Request__c(Id = requestId, Status__c = status);
        if (status == 'Resolved' || status == 'Closed') u.Resolution_Type__c = String.isBlank(resolutionType) ? 'Answered' : resolutionType;
        try {
            insert c;
            Support_Request__c current = [SELECT Status__c, Assigned_To__c FROM Support_Request__c WHERE Id = :requestId];
            if (current.Assigned_To__c == null) u.Assigned_To__c = UserInfo.getUserId();
            if (current.Status__c != status || u.Assigned_To__c != null || u.Resolution_Type__c != null) update u;
        } catch (DmlException e) {
            throw new AuraHandledException(e.getDmlMessage(0));
        }
        return c.Id;
    }

    @AuraEnabled
    public static List<RowResult> setStatus(List<Id> ids, String status, String resolutionType) {
        requireAgent();
        Set<String> allowed = new Set<String>{ 'Open', 'Waiting on Rep', 'Resolved', 'Closed' };
        if (!allowed.contains(status)) throw new AuraHandledException('Choose Open, Waiting on Rep, Resolved or Closed.');
        List<Support_Request__c> rows = new List<Support_Request__c>();
        for (Id i : capped(ids)) {
            Support_Request__c r = new Support_Request__c(Id = i, Status__c = status);
            if (status == 'Resolved' || status == 'Closed') r.Resolution_Type__c = String.isBlank(resolutionType) ? 'Answered' : resolutionType;
            rows.add(r);
        }
        return results(Database.update(rows, false), rows);
    }

    @AuraEnabled
    public static List<RowResult> assign(List<Id> ids, Id userId) {
        requireAgent();
        List<Support_Request__c> rows = new List<Support_Request__c>();
        for (Id i : capped(ids)) rows.add(new Support_Request__c(Id = i, Assigned_To__c = userId));
        return results(Database.update(rows, false), rows);
    }

    @AuraEnabled
    public static List<RowResult> setPriority(List<Id> ids, String priority) {
        requireAgent();
        List<Support_Request__c> rows = new List<Support_Request__c>();
        for (Id i : capped(ids)) rows.add(new Support_Request__c(Id = i, Priority__c = priority));
        return results(Database.update(rows, false), rows);
    }

    @AuraEnabled
    public static void copyManager(Id requestId, Id managerId) {
        requireAgent();
        try { update new Support_Request__c(Id = requestId, Manager__c = managerId); }
        catch (DmlException e) { throw new AuraHandledException(e.getDmlMessage(0)); }
    }

    @AuraEnabled
    public static void unlockCall(Id requestId, String note) {
        requireAgent();
        try { SupportUnlockService.unlock(requestId, note); }
        catch (SupportUnlockService.UnlockException e) { throw new AuraHandledException(e.getMessage()); }
    }

    @AuraEnabled
    public static void declineUnlock(Id requestId, String reason) {
        requireAgent();
        try { SupportUnlockService.decline(requestId, reason); }
        catch (SupportUnlockService.UnlockException e) { throw new AuraHandledException(e.getMessage()); }
    }

    @AuraEnabled
    public static void unlockPlan(Id requestId, String reason) {
        requireAgent();
        try { SupportUnlockService.unlockPlan(requestId, reason); }
        catch (SupportUnlockService.UnlockException e) { throw new AuraHandledException(e.getMessage()); }
    }

    @AuraEnabled
    public static void declinePlanUnlock(Id requestId, String reason) {
        requireAgent();
        try { SupportUnlockService.declinePlan(requestId, reason); }
        catch (SupportUnlockService.UnlockException e) { throw new AuraHandledException(e.getMessage()); }
    }

    @AuraEnabled
    public static SupportUnlockService.PlanInfo getPlanInfo(Id requestId) {
        requireAgent();
        return SupportUnlockService.planInfo(requestId);
    }

    private static List<Id> capped(List<Id> ids) {
        List<Id> out = new List<Id>();
        if (ids == null) return out;
        Set<Id> seen = new Set<Id>();
        for (Id i : ids) if (i != null && seen.add(i) && out.size() < 200) out.add(i);
        return out;
    }

    private static List<RowResult> results(List<Database.SaveResult> saved, List<Support_Request__c> rows) {
        List<RowResult> out = new List<RowResult>();
        for (Integer i = 0; i < saved.size(); i++) {
            RowResult r = new RowResult();
            r.id = rows[i].Id;
            r.ok = saved[i].isSuccess();
            r.message = r.ok ? null : saved[i].getErrors()[0].getMessage();
            out.add(r);
        }
        return out;
    }
}