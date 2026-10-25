/**
 * Compares what each rep planned for a month with the calls they actually
 * reported. Pure logic: it takes plain rows and returns classified items, so
 * it can be tested without touching the database.
 *
 * A plan is matched to a call report first by the explicit link between them
 * (Resulting_CVR__c / Source_Planned_Call__c) and otherwise by rep + HCP (or
 * HCO when the plan has no HCP), picking the report closest in time. A report
 * may be up to GRACE_DAYS outside the month, so a call planned for the 30th
 * and made on the 2nd is "done on another day", not "missed". Plans from the
 * neighbouring weeks are matched too (so a call is claimed by its own month's
 * plan before it can excuse a miss in this one) but only plans planned inside
 * the month are reported.
 *
 * Outcomes for a plan: On plan, Other day, Missed, Excused (approved leave),
 * Cancelled, Upcoming. A submitted call report matching no plan is Unplanned.
 */
public with sharing class PlanVsActualService {

    /** Sciagen App Config → Plan vs Actual Grace Days (default 14). */
    public static Integer GRACE_DAYS { get { return SciagenAppConfig.planVsActualGraceDays(); } }

    public static final String ON_PLAN = 'On plan';
    public static final String OTHER_DAY = 'Other day';
    public static final String MISSED = 'Missed';
    public static final String EXCUSED = 'Excused';
    public static final String CANCELLED = 'Cancelled';
    public static final String UPCOMING = 'Upcoming';
    public static final String UNPLANNED = 'Unplanned';

    public class PlanRow {
        public Id id;
        public Id ownerId;
        public Id hcpId;
        public Id hcoId;
        public String hcpName;
        public String hcoName;
        public Date plannedDate;
        public Date currentDate;
        public String status;
        public String plannedType;
        public String currentType;
        public Id linkedCvrId;
    }

    public class ActualRow {
        public Id id;
        public Id ownerId;
        public Id hcpId;
        public Id hcoId;
        public String hcpName;
        public String hcoName;
        public Date visitDate;
        public String callType;
        public Boolean submitted = true;
        public Id sourcePlanId;
    }

    public class LeaveSpan {
        public Id ownerId;
        public Date fromDate;
        public Date toDate;
    }

    public class Item {
        public String outcome;
        public Id ownerId;
        public Id planId;
        public Id cvrId;
        public Id hcpId;
        public Id hcoId;
        public String hcpName;
        public String hcoName;
        public Date plannedDate;
        public Date actualDate;
        public Integer gapDays;
        public String plannedType;
        public String actualType;
        public Boolean typeChanged = false;
        public Boolean moved = false;
        public Boolean reportNotFound = false;
    }

    public class OwnerStats {
        public Id ownerId;
        public Integer planned = 0;
        public Integer onPlan = 0;
        public Integer otherDay = 0;
        public Integer missed = 0;
        public Integer excused = 0;
        public Integer cancelled = 0;
        public Integer upcoming = 0;
        public Integer unplanned = 0;
        public Integer actual = 0;
        public Integer drafts = 0;
        public Integer typeChanged = 0;

        /** Plans whose day has come and which weren't excused: the base for adherence. */
        public Integer due() { return planned - upcoming - excused; }
        public Decimal achievementPct() { return pct(onPlan + otherDay, due()); }
        public Decimal onDayPct() { return pct(onPlan, due()); }
        public Decimal unplannedPct() { return pct(unplanned, actual); }
    }

    public class Analysis {
        public List<Item> items = new List<Item>();
        public Map<Id, OwnerStats> stats = new Map<Id, OwnerStats>();
        public Map<Integer, Integer> plannedByDay = new Map<Integer, Integer>();
        public Map<Integer, Integer> actualByDay = new Map<Integer, Integer>();
    }

    public static Decimal pct(Integer part, Integer whole) {
        if (whole == null || whole <= 0) return null;
        return (Decimal.valueOf(part) * 100 / whole).setScale(1);
    }

    private class Pair implements Comparable {
        PlanRow plan;
        ActualRow actual;
        Integer distance;
        Pair(PlanRow p, ActualRow a) {
            plan = p;
            actual = a;
            distance = Math.abs(p.currentDate.daysBetween(a.visitDate));
        }
        public Integer compareTo(Object other) {
            Pair o = (Pair) other;
            if (distance != o.distance) return distance < o.distance ? -1 : 1;
            Integer byPlan = plan.plannedDate.daysBetween(o.plan.plannedDate);
            return byPlan == 0 ? 0 : (byPlan > 0 ? -1 : 1);
        }
    }

    public static Analysis analyze(List<PlanRow> plans, List<ActualRow> actuals, List<LeaveSpan> leave,
                                   Date today, Date monthStart, Date monthEnd) {
        Analysis result = new Analysis();
        Map<Id, List<PlanRow>> plansByOwner = new Map<Id, List<PlanRow>>();
        Map<Id, List<ActualRow>> actualsByOwner = new Map<Id, List<ActualRow>>();
        Map<Id, List<LeaveSpan>> leaveByOwner = new Map<Id, List<LeaveSpan>>();
        for (PlanRow p : plans) add(plansByOwner, p.ownerId, p);
        for (ActualRow a : actuals) add(actualsByOwner, a.ownerId, a);
        for (LeaveSpan l : leave) add(leaveByOwner, l.ownerId, l);

        Set<Id> owners = new Set<Id>(plansByOwner.keySet());
        owners.addAll(actualsByOwner.keySet());
        for (Id ownerId : owners) {
            analyzeOwner(ownerId,
                plansByOwner.containsKey(ownerId) ? plansByOwner.get(ownerId) : new List<PlanRow>(),
                actualsByOwner.containsKey(ownerId) ? actualsByOwner.get(ownerId) : new List<ActualRow>(),
                leaveByOwner.containsKey(ownerId) ? leaveByOwner.get(ownerId) : new List<LeaveSpan>(),
                today, monthStart, monthEnd, result);
        }
        return result;
    }

    private static void analyzeOwner(Id ownerId, List<PlanRow> plans, List<ActualRow> actuals, List<LeaveSpan> leave,
                                     Date today, Date monthStart, Date monthEnd, Analysis out) {
        OwnerStats stats = new OwnerStats();
        stats.ownerId = ownerId;
        out.stats.put(ownerId, stats);

        List<ActualRow> submitted = new List<ActualRow>();
        for (ActualRow a : actuals) {
            if (a.submitted != true) {
                if (inMonth(a.visitDate, monthStart, monthEnd)) stats.drafts++;
                continue;
            }
            submitted.add(a);
        }

        Map<Id, ActualRow> actualById = new Map<Id, ActualRow>();
        for (ActualRow a : submitted) actualById.put(a.id, a);
        Map<Id, PlanRow> planById = new Map<Id, PlanRow>();
        for (PlanRow p : plans) planById.put(p.id, p);

        Map<Id, ActualRow> matchOfPlan = new Map<Id, ActualRow>();
        Set<Id> takenActuals = new Set<Id>();

        // 1. Explicit links.
        for (PlanRow p : plans) {
            if (p.status == 'Cancelled') continue;
            if (p.linkedCvrId != null && actualById.containsKey(p.linkedCvrId) && !takenActuals.contains(p.linkedCvrId)) {
                matchOfPlan.put(p.id, actualById.get(p.linkedCvrId));
                takenActuals.add(p.linkedCvrId);
            }
        }
        for (ActualRow a : submitted) {
            if (a.sourcePlanId == null || takenActuals.contains(a.id) || !planById.containsKey(a.sourcePlanId)) continue;
            PlanRow p = planById.get(a.sourcePlanId);
            if (p.status == 'Cancelled' || matchOfPlan.containsKey(p.id)) continue;
            matchOfPlan.put(p.id, a);
            takenActuals.add(a.id);
        }

        // 2. Same rep and same HCP (or HCO), closest in time first.
        Map<String, List<ActualRow>> actualsByKey = new Map<String, List<ActualRow>>();
        for (ActualRow a : submitted) {
            if (!takenActuals.contains(a.id)) add(actualsByKey, key(a.hcpId, a.hcoId), a);
        }
        List<Pair> pairs = new List<Pair>();
        for (PlanRow p : plans) {
            if (p.status == 'Cancelled' || matchOfPlan.containsKey(p.id)) continue;
            String k = key(p.hcpId, p.hcoId);
            if (k == null || !actualsByKey.containsKey(k)) continue;
            for (ActualRow a : actualsByKey.get(k)) pairs.add(new Pair(p, a));
        }
        pairs.sort();
        for (Pair pr : pairs) {
            if (matchOfPlan.containsKey(pr.plan.id) || takenActuals.contains(pr.actual.id)) continue;
            matchOfPlan.put(pr.plan.id, pr.actual);
            takenActuals.add(pr.actual.id);
        }

        // 3. Classify every plan planned inside the month.
        for (PlanRow p : plans) {
            if (!inMonth(p.plannedDate, monthStart, monthEnd)) continue;
            Item item = new Item();
            item.ownerId = ownerId;
            item.planId = p.id;
            item.hcpId = p.hcpId;
            item.hcoId = p.hcoId;
            item.hcpName = p.hcpName;
            item.hcoName = p.hcoName;
            item.plannedDate = p.plannedDate;
            item.plannedType = p.plannedType;
            item.moved = p.currentDate != null && p.plannedDate != null && p.currentDate != p.plannedDate && p.status == 'Planned';
            ActualRow a = matchOfPlan.get(p.id);
            if (a != null) {
                item.cvrId = a.id;
                item.actualDate = a.visitDate;
                item.actualType = a.callType;
            } else if (p.status == 'Completed') {
                // The app marked it done but no matching report is visible to us.
                item.actualDate = p.currentDate;
                item.actualType = p.currentType;
                item.reportNotFound = true;
            }
            Boolean done = item.actualDate != null;
            if (done) {
                item.gapDays = p.plannedDate.daysBetween(item.actualDate);
                item.outcome = item.gapDays == 0 ? ON_PLAN : OTHER_DAY;
                item.typeChanged = !String.isBlank(item.plannedType) && !String.isBlank(item.actualType) && item.plannedType != item.actualType;
            } else if (p.status == 'Cancelled') {
                item.outcome = CANCELLED;
            } else if (onLeave(leave, p.plannedDate)) {
                item.outcome = EXCUSED;
            } else if ((p.currentDate != null ? p.currentDate : p.plannedDate) < today) {
                item.outcome = MISSED;
            } else {
                item.outcome = UPCOMING;
            }
            count(stats, item);
            out.items.add(item);
            if (item.outcome != CANCELLED) bump(out.plannedByDay, p.plannedDate.day());
        }

        // 4. Calls with no plan behind them.
        for (ActualRow a : submitted) {
            if (!inMonth(a.visitDate, monthStart, monthEnd)) continue;
            stats.actual++;
            bump(out.actualByDay, a.visitDate.day());
            if (takenActuals.contains(a.id)) continue;
            Item item = new Item();
            item.outcome = UNPLANNED;
            item.ownerId = ownerId;
            item.cvrId = a.id;
            item.hcpId = a.hcpId;
            item.hcoId = a.hcoId;
            item.hcpName = a.hcpName;
            item.hcoName = a.hcoName;
            item.actualDate = a.visitDate;
            item.actualType = a.callType;
            stats.unplanned++;
            out.items.add(item);
        }
    }

    private static void count(OwnerStats s, Item item) {
        s.planned++;
        if (item.outcome == ON_PLAN) s.onPlan++;
        else if (item.outcome == OTHER_DAY) s.otherDay++;
        else if (item.outcome == MISSED) s.missed++;
        else if (item.outcome == EXCUSED) s.excused++;
        else if (item.outcome == CANCELLED) s.cancelled++;
        else if (item.outcome == UPCOMING) s.upcoming++;
        if (item.typeChanged == true) s.typeChanged++;
    }

    private static Boolean onLeave(List<LeaveSpan> leave, Date d) {
        for (LeaveSpan l : leave) {
            if (l.fromDate != null && l.toDate != null && d >= l.fromDate && d <= l.toDate) return true;
        }
        return false;
    }

    private static Boolean inMonth(Date d, Date monthStart, Date monthEnd) {
        return d != null && d >= monthStart && d <= monthEnd;
    }

    private static String key(Id hcpId, Id hcoId) {
        if (hcpId != null) return 'P:' + hcpId;
        if (hcoId != null) return 'O:' + hcoId;
        return null;
    }

    private static void bump(Map<Integer, Integer> m, Integer day) {
        m.put(day, (m.containsKey(day) ? m.get(day) : 0) + 1);
    }

    private static void add(Map<Id, List<PlanRow>> m, Id k, PlanRow v) {
        if (!m.containsKey(k)) m.put(k, new List<PlanRow>());
        m.get(k).add(v);
    }
    private static void add(Map<Id, List<ActualRow>> m, Id k, ActualRow v) {
        if (!m.containsKey(k)) m.put(k, new List<ActualRow>());
        m.get(k).add(v);
    }
    private static void add(Map<Id, List<LeaveSpan>> m, Id k, LeaveSpan v) {
        if (!m.containsKey(k)) m.put(k, new List<LeaveSpan>());
        m.get(k).add(v);
    }
    private static void add(Map<String, List<ActualRow>> m, String k, ActualRow v) {
        if (!m.containsKey(k)) m.put(k, new List<ActualRow>());
        m.get(k).add(v);
    }
}