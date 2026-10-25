/**
 * Backend for the Plan vs Actual page used by managers and head office.
 * Runs `with sharing`: a manager sees their reporting line through the role
 * hierarchy, a head-office user sees everyone through the Plan Review (All
 * Data) permission set. Loading is capped, and the page is told when a cap
 * was hit so it never shows partial numbers as if they were complete.
 */
public with sharing class PlanVsActualController {

    private static final Integer PLAN_LIMIT = 20000;
    private static final Integer ACTUAL_LIMIT = 30000;
    private static final Integer MAX_ITEM_ROWS = 2000;

    public class RepRow implements Comparable {
        @AuraEnabled public Id userId;
        @AuraEnabled public String name;
        @AuraEnabled public String territory;
        @AuraEnabled public Integer planned;
        @AuraEnabled public Integer onPlan;
        @AuraEnabled public Integer otherDay;
        @AuraEnabled public Integer missed;
        @AuraEnabled public Integer excused;
        @AuraEnabled public Integer cancelled;
        @AuraEnabled public Integer upcoming;
        @AuraEnabled public Integer unplanned;
        @AuraEnabled public Integer actual;
        @AuraEnabled public Integer drafts;
        @AuraEnabled public Decimal achievementPct;
        @AuraEnabled public Decimal onDayPct;

        /** Weakest adherence first, so the reps that need a conversation are at the top. */
        public Integer compareTo(Object other) {
            RepRow o = (RepRow) other;
            Decimal x = achievementPct == null ? 101 : achievementPct;
            Decimal y = o.achievementPct == null ? 101 : o.achievementPct;
            if (x != y) return x < y ? -1 : 1;
            return (name == null ? '' : name).compareTo(o.name == null ? '' : o.name);
        }
    }

    public class DayPoint {
        @AuraEnabled public Integer day;
        @AuraEnabled public Integer planned;
        @AuraEnabled public Integer actual;
    }

    public class Overview {
        @AuraEnabled public String monthStart;
        @AuraEnabled public String asOf;
        @AuraEnabled public Integer planned = 0;
        @AuraEnabled public Integer onPlan = 0;
        @AuraEnabled public Integer otherDay = 0;
        @AuraEnabled public Integer missed = 0;
        @AuraEnabled public Integer excused = 0;
        @AuraEnabled public Integer cancelled = 0;
        @AuraEnabled public Integer upcoming = 0;
        @AuraEnabled public Integer unplanned = 0;
        @AuraEnabled public Integer actual = 0;
        @AuraEnabled public Integer drafts = 0;
        @AuraEnabled public Integer typeChanged = 0;
        @AuraEnabled public Decimal achievementPct;
        @AuraEnabled public Decimal onDayPct;
        @AuraEnabled public Decimal unplannedPct;
        @AuraEnabled public Boolean truncated = false;
        @AuraEnabled public List<RepRow> reps = new List<RepRow>();
        @AuraEnabled public List<DayPoint> days = new List<DayPoint>();
    }

    public class ItemDTO {
        @AuraEnabled public String outcome;
        @AuraEnabled public Id userId;
        @AuraEnabled public String repName;
        @AuraEnabled public Id planId;
        @AuraEnabled public Id cvrId;
        @AuraEnabled public Id hcpId;
        @AuraEnabled public String hcpName;
        @AuraEnabled public String hcoName;
        @AuraEnabled public String plannedDate;
        @AuraEnabled public String actualDate;
        @AuraEnabled public Integer gapDays;
        @AuraEnabled public String plannedType;
        @AuraEnabled public String actualType;
        @AuraEnabled public Boolean typeChanged;
        @AuraEnabled public Boolean moved;
        @AuraEnabled public Boolean reportNotFound;
    }

    public class ItemsResult {
        @AuraEnabled public List<ItemDTO> items = new List<ItemDTO>();
        @AuraEnabled public Integer total = 0;
        @AuraEnabled public Boolean truncated = false;
    }

    private class Loaded {
        PlanVsActualService.Analysis analysis;
        Map<Id, String> ownerNames = new Map<Id, String>();
        Boolean truncated = false;
        Date monthStart;
        Date monthEnd;
    }

    @AuraEnabled(cacheable=false)
    public static Overview getOverview(String monthStart, Id territoryId, Id userId) {
        Loaded l = load(parseMonth(monthStart), territoryId, userId);
        Overview o = new Overview();
        o.monthStart = String.valueOf(l.monthStart);
        o.asOf = String.valueOf(Date.today());
        o.truncated = l.truncated;

        Map<Id, String> territoryByUser = primaryTerritories(l.analysis.stats.keySet());
        for (PlanVsActualService.OwnerStats s : l.analysis.stats.values()) {
            o.planned += s.planned;
            o.onPlan += s.onPlan;
            o.otherDay += s.otherDay;
            o.missed += s.missed;
            o.excused += s.excused;
            o.cancelled += s.cancelled;
            o.upcoming += s.upcoming;
            o.unplanned += s.unplanned;
            o.actual += s.actual;
            o.drafts += s.drafts;
            o.typeChanged += s.typeChanged;

            RepRow r = new RepRow();
            r.userId = s.ownerId;
            r.name = l.ownerNames.get(s.ownerId);
            r.territory = territoryByUser.get(s.ownerId);
            r.planned = s.planned;
            r.onPlan = s.onPlan;
            r.otherDay = s.otherDay;
            r.missed = s.missed;
            r.excused = s.excused;
            r.cancelled = s.cancelled;
            r.upcoming = s.upcoming;
            r.unplanned = s.unplanned;
            r.actual = s.actual;
            r.drafts = s.drafts;
            r.achievementPct = s.achievementPct();
            r.onDayPct = s.onDayPct();
            o.reps.add(r);
        }
        Integer due = o.planned - o.upcoming - o.excused;
        o.achievementPct = PlanVsActualService.pct(o.onPlan + o.otherDay, due);
        o.onDayPct = PlanVsActualService.pct(o.onPlan, due);
        o.unplannedPct = PlanVsActualService.pct(o.unplanned, o.actual);
        o.reps.sort();

        Integer lastDay = l.monthEnd.day();
        for (Integer d = 1; d <= lastDay; d++) {
            DayPoint p = new DayPoint();
            p.day = d;
            p.planned = l.analysis.plannedByDay.containsKey(d) ? l.analysis.plannedByDay.get(d) : 0;
            p.actual = l.analysis.actualByDay.containsKey(d) ? l.analysis.actualByDay.get(d) : 0;
            o.days.add(p);
        }
        return o;
    }

    /** Call-level rows. outcomes null or empty means all of them. */
    @AuraEnabled(cacheable=false)
    public static ItemsResult getItems(String monthStart, Id territoryId, Id userId, List<String> outcomes) {
        Loaded l = load(parseMonth(monthStart), territoryId, userId);
        Set<String> wanted = outcomes == null ? new Set<String>() : new Set<String>(outcomes);
        List<PlanVsActualService.Item> picked = new List<PlanVsActualService.Item>();
        for (PlanVsActualService.Item i : l.analysis.items) {
            if (wanted.isEmpty() || wanted.contains(i.outcome)) picked.add(i);
        }
        ItemsResult res = new ItemsResult();
        res.total = picked.size();
        res.truncated = l.truncated || picked.size() > MAX_ITEM_ROWS;
        List<ItemSort> sorted = new List<ItemSort>();
        for (PlanVsActualService.Item i : picked) sorted.add(new ItemSort(i, l.ownerNames.get(i.ownerId)));
        sorted.sort();
        for (ItemSort w : sorted) {
            if (res.items.size() >= MAX_ITEM_ROWS) break;
            PlanVsActualService.Item i = w.item;
            ItemDTO d = new ItemDTO();
            d.outcome = i.outcome;
            d.userId = i.ownerId;
            d.repName = l.ownerNames.get(i.ownerId);
            d.planId = i.planId;
            d.cvrId = i.cvrId;
            d.hcpId = i.hcpId;
            d.hcpName = i.hcpName;
            d.hcoName = i.hcoName;
            d.plannedDate = i.plannedDate == null ? null : String.valueOf(i.plannedDate);
            d.actualDate = i.actualDate == null ? null : String.valueOf(i.actualDate);
            d.gapDays = i.gapDays;
            d.plannedType = i.plannedType;
            d.actualType = i.actualType;
            d.typeChanged = i.typeChanged;
            d.moved = i.moved;
            d.reportNotFound = i.reportNotFound;
            res.items.add(d);
        }
        return res;
    }

    @AuraEnabled(cacheable=false)
    public static List<Map<String, String>> getTerritories() {
        List<Map<String, String>> out = new List<Map<String, String>>();
        for (Territory__c t : [SELECT Id, Name FROM Territory__c WITH USER_MODE ORDER BY Name LIMIT 1000]) {
            out.add(new Map<String, String>{ 'id' => t.Id, 'name' => t.Name });
        }
        return out;
    }

    // ---------------------------------------------------------------- loading

    private static Date parseMonth(String monthStart) {
        Date d = String.isBlank(monthStart) ? Date.today() : Date.valueOf(monthStart);
        return Date.newInstance(d.year(), d.month(), 1);
    }

    private static Loaded load(Date monthStart, Id territoryId, Id userId) {
        Loaded l = new Loaded();
        l.monthStart = monthStart;
        l.monthEnd = monthStart.addMonths(1).addDays(-1);
        Date windowStart = monthStart.addDays(-PlanVsActualService.GRACE_DAYS);
        Date windowEnd = l.monthEnd.addDays(PlanVsActualService.GRACE_DAYS);
        Datetime windowStartDt = Datetime.newInstance(windowStart, Time.newInstance(0, 0, 0, 0));
        Datetime windowEndDt = Datetime.newInstance(windowEnd.addDays(1), Time.newInstance(0, 0, 0, 0));

        Set<Id> owners = null;
        if (userId != null) {
            owners = new Set<Id>{ userId };
        } else if (territoryId != null) {
            owners = new Set<Id>();
            for (User_Territory__c ut : [SELECT User__c FROM User_Territory__c WHERE Territory__c = :territoryId AND User__c != null WITH USER_MODE]) {
                owners.add(ut.User__c);
            }
            if (owners.isEmpty()) {
                l.analysis = new PlanVsActualService.Analysis();
                return l;
            }
        }
        String ownerClause = owners == null ? '' : ' AND OwnerId IN :owners';

        Map<String, Object> binds = new Map<String, Object>{
            'windowStartDt' => windowStartDt, 'windowEndDt' => windowEndDt, 'owners' => owners,
            'windowStart' => windowStart, 'windowEnd' => windowEnd,
            'monthStart' => monthStart, 'monthEnd' => l.monthEnd
        };

        List<Planned_Call__c> planRecords = Database.queryWithBinds(
            'SELECT Id, OwnerId, Owner.Name, HCP__c, HCP__r.Name, HCO__c, HCO__r.Name, Call_DateTime__c, Original_Call_DateTime__c, '
            + 'Call_Type__c, Original_Call_Type__c, Status__c, Resulting_CVR__c, In_Frozen_Plan__c, Frozen_Call_DateTime__c, '
            + 'Frozen_Call_Type__c FROM Planned_Call__c '
            + 'WHERE Is_Event__c = false AND (Origin__c = \'Planned\' OR Origin__c = null) '
            + 'AND ((Original_Call_DateTime__c >= :windowStartDt AND Original_Call_DateTime__c < :windowEndDt) '
            + 'OR (Frozen_Call_DateTime__c >= :windowStartDt AND Frozen_Call_DateTime__c < :windowEndDt) '
            + 'OR (Original_Call_DateTime__c = null AND Call_DateTime__c >= :windowStartDt AND Call_DateTime__c < :windowEndDt))'
            + ownerClause + ' LIMIT ' + (PLAN_LIMIT + 1), binds, AccessLevel.USER_MODE);

        List<Call_Visit_Report__c> cvrRecords = Database.queryWithBinds(
            'SELECT Id, OwnerId, Owner.Name, HCP__c, HCP__r.Name, HCO__c, HCO__r.Name, Visit_Date__c, Start_Time__c, Call_Type__c, '
            + 'Record_Status__c, Source_Planned_Call__c FROM Call_Visit_Report__c '
            + 'WHERE Call_Status__c = \'Completed\' AND Visit_Date__c >= :windowStart AND Visit_Date__c <= :windowEnd'
            + ownerClause + ' LIMIT ' + (ACTUAL_LIMIT + 1), binds, AccessLevel.USER_MODE);

        List<Leave_Request__c> leaveRecords = Database.queryWithBinds(
            'SELECT OwnerId, From_Date__c, To_Date__c FROM Leave_Request__c WHERE Status__c = \'Approved\' '
            + 'AND From_Date__c <= :monthEnd AND To_Date__c >= :monthStart' + ownerClause + ' LIMIT 5000',
            binds, AccessLevel.USER_MODE);

        if (planRecords.size() > PLAN_LIMIT) { planRecords.remove(PLAN_LIMIT); l.truncated = true; }
        if (cvrRecords.size() > ACTUAL_LIMIT) { cvrRecords.remove(ACTUAL_LIMIT); l.truncated = true; }

        // Frozen monthly plans (MonthlyCallPlanService): in a frozen month the
        // plan is exactly what was frozen — its frozen date and type — and a
        // call added after the freeze is not a plan (its visit is Unplanned).
        Set<String> frozenMonths = new Set<String>();
        for (Monthly_Call_Plan__c mp : (List<Monthly_Call_Plan__c>) Database.queryWithBinds(
                'SELECT Plan_Key__c FROM Monthly_Call_Plan__c WHERE Status__c = \'Frozen\' '
                + 'AND Month__c >= :windowStart AND Month__c <= :windowEnd' + ownerClause,
                new Map<String, Object>{ 'windowStart' => windowStart.toStartOfMonth(), 'windowEnd' => windowEnd, 'owners' => owners },
                AccessLevel.USER_MODE)) {
            frozenMonths.add(mp.Plan_Key__c);
        }

        List<PlanVsActualService.PlanRow> plans = new List<PlanVsActualService.PlanRow>();
        for (Planned_Call__c p : planRecords) {
            PlanVsActualService.PlanRow r = new PlanVsActualService.PlanRow();
            r.id = p.Id;
            r.ownerId = p.OwnerId;
            r.hcpId = p.HCP__c;
            r.hcoId = p.HCO__c;
            r.hcpName = p.HCP__r?.Name;
            r.hcoName = p.HCO__r?.Name;
            r.currentDate = localDate(p.Call_DateTime__c);
            r.plannedDate = p.Original_Call_DateTime__c != null ? localDate(p.Original_Call_DateTime__c) : r.currentDate;
            r.status = p.Status__c;
            r.currentType = p.Call_Type__c;
            r.plannedType = !String.isBlank(p.Original_Call_Type__c) ? p.Original_Call_Type__c : p.Call_Type__c;
            if (p.In_Frozen_Plan__c == true && p.Frozen_Call_DateTime__c != null) {
                r.plannedDate = localDate(p.Frozen_Call_DateTime__c);
                if (!String.isBlank(p.Frozen_Call_Type__c)) r.plannedType = p.Frozen_Call_Type__c;
            } else if (r.plannedDate != null && frozenMonths.contains(MonthlyCallPlanService.planKey(p.OwnerId, r.plannedDate))) {
                continue;   // added after that month was frozen
            }
            r.linkedCvrId = p.Resulting_CVR__c;
            plans.add(r);
            l.ownerNames.put(p.OwnerId, p.Owner.Name);
        }
        List<PlanVsActualService.ActualRow> actuals = new List<PlanVsActualService.ActualRow>();
        for (Call_Visit_Report__c c : cvrRecords) {
            PlanVsActualService.ActualRow a = new PlanVsActualService.ActualRow();
            a.id = c.Id;
            a.ownerId = c.OwnerId;
            a.hcpId = c.HCP__c;
            a.hcoId = c.HCO__c;
            a.hcpName = c.HCP__r?.Name;
            a.hcoName = c.HCO__r?.Name;
            a.visitDate = c.Visit_Date__c != null ? c.Visit_Date__c : localDate(c.Start_Time__c);
            a.callType = c.Call_Type__c;
            a.submitted = c.Record_Status__c == 'Submitted';
            a.sourcePlanId = c.Source_Planned_Call__c;
            if (a.visitDate != null) actuals.add(a);
            l.ownerNames.put(c.OwnerId, c.Owner.Name);
        }
        List<PlanVsActualService.LeaveSpan> leave = new List<PlanVsActualService.LeaveSpan>();
        for (Leave_Request__c lr : leaveRecords) {
            PlanVsActualService.LeaveSpan s = new PlanVsActualService.LeaveSpan();
            s.ownerId = lr.OwnerId;
            s.fromDate = lr.From_Date__c;
            s.toDate = lr.To_Date__c;
            leave.add(s);
        }
        // Rows without a usable date can't be placed on the calendar.
        List<PlanVsActualService.PlanRow> dated = new List<PlanVsActualService.PlanRow>();
        for (PlanVsActualService.PlanRow p : plans) {
            if (p.plannedDate != null && p.currentDate != null) dated.add(p);
        }
        l.analysis = PlanVsActualService.analyze(dated, actuals, leave, Date.today(), monthStart, l.monthEnd);
        return l;
    }

    private static Date localDate(Datetime dt) {
        return dt == null ? null : Date.valueOf(dt.format('yyyy-MM-dd'));
    }

    private static Map<Id, String> primaryTerritories(Set<Id> userIds) {
        Map<Id, String> out = new Map<Id, String>();
        if (userIds.isEmpty()) return out;
        for (User_Territory__c ut : [
            SELECT User__c, Territory__r.Name, Is_Primary__c FROM User_Territory__c
            WHERE User__c IN :userIds AND Territory__c != null WITH USER_MODE
            ORDER BY Is_Primary__c ASC
        ]) {
            out.put(ut.User__c, ut.Territory__r.Name);
        }
        return out;
    }

    // --------------------------------------------------------------- ordering

    private class ItemSort implements Comparable {
        PlanVsActualService.Item item;
        String repName;
        ItemSort(PlanVsActualService.Item item, String repName) {
            this.item = item;
            this.repName = repName == null ? '' : repName;
        }
        public Integer compareTo(Object other) {
            ItemSort o = (ItemSort) other;
            Integer byRep = repName.compareTo(o.repName);
            if (byRep != 0) return byRep;
            Date ad = item.plannedDate != null ? item.plannedDate : item.actualDate;
            Date bd = o.item.plannedDate != null ? o.item.plannedDate : o.item.actualDate;
            if (ad == bd) return 0;
            return ad < bd ? -1 : 1;
        }
    }
}