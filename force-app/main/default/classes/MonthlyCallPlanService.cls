/**
 * Monthly call plan freeze.
 *
 * A rep plans the month on the iPad (My Schedule → Scheduler), then freezes
 * it. Freezing records a Monthly_Call_Plan__c (owner = rep, Status Frozen)
 * and stamps every planned call of that month as the baseline:
 * In_Frozen_Plan__c, Frozen_Call_DateTime__c, Frozen_Call_Type__c,
 * Monthly_Plan__c.
 *
 * From then on each call records how it differs from that baseline in
 * Plan_Deviation__c, kept up to date on every save (beforeWrite):
 *   Rescheduled          frozen call moved to another day, not done yet
 *   Done on another day  frozen call completed on a different day
 *   Cancelled            frozen call cancelled
 *   Added after freeze   a call in a frozen month that was not in the plan
 *   (blank)              as frozen
 * A frozen call can't be deleted (cancel it, so the change is recorded), and
 * the baseline fields can only be written by the freeze itself or by an
 * administrator. Missed calls (a frozen day that passes with no call) are
 * reported by Plan vs Actual, which for a frozen month measures against the
 * frozen baseline only.
 *
 * Unlocking (Business Admin, custom permission Unlock_Monthly_Plans): unlock()
 * sets the plan back to Draft and clears the month's baseline, so the rep can
 * change the plan and freeze it again — the new freeze is the new baseline.
 * The plan keeps an audit trail (Times Unlocked, Last Unlocked At/By, Unlock
 * Reason, field history). A rep asks for it from the iPad with a Help &
 * Support request of category "Unlock Monthly Plan"; unlocking answers that
 * request, and the next freeze resolves it.
 *
 * Without sharing: the freeze runs for the calling rep on their own records
 * (OwnerId = the running user), and the trigger must see the rep's plan
 * whatever the caller's sharing.
 */
public without sharing class MonthlyCallPlanService {

    public static final String FROZEN = 'Frozen';
    public static final String DEV_RESCHEDULED = 'Rescheduled';
    public static final String DEV_OTHER_DAY = 'Done on another day';
    public static final String DEV_CANCELLED = 'Cancelled';
    public static final String DEV_ADDED = 'Added after freeze';
    public static final String CAT_UNLOCK_PLAN = 'Unlock Monthly Plan';

    public class UnlockException extends Exception {}

    /** True only while freeze() stamps the baseline. */
    @TestVisible private static Boolean freezing = false;

    public class FreezeResult {
        public Boolean success = false;
        public String message;
        public Id planId;
        public String status;
        public Datetime frozenAt;
        public Integer callCount = 0;
        public Integer hcpCount = 0;
        public Integer emptyDays = 0;
    }

    public static String planKey(Id ownerId, Date anyDay) {
        return String.valueOf(ownerId) + '|' + Datetime.newInstance(anyDay.toStartOfMonth(), Time.newInstance(12, 0, 0, 0)).format('yyyy-MM');
    }

    // ------------------------------------------------------------------ freeze

    public static FreezeResult freeze(Id ownerId, Date anyDayInMonth) {
        FreezeResult r = new FreezeResult();
        Date monthStart = anyDayInMonth.toStartOfMonth();
        if (!SciagenAppConfig.planFreezeEnabled()) {
            r.message = 'Freezing monthly plans is turned off for your organisation.';
            return r;
        }
        if (monthStart < Date.today().toStartOfMonth() && !SciagenAppConfig.allowPastMonthFreeze()) {
            r.message = 'A past month can\'t be frozen.';
            return r;
        }
        String key = planKey(ownerId, monthStart);
        List<Monthly_Call_Plan__c> existing = [SELECT Id, Status__c, Frozen_At__c, Frozen_Call_Count__c, Frozen_HCP_Count__c,
                                               Working_Days_Without_Calls__c FROM Monthly_Call_Plan__c WHERE Plan_Key__c = :key LIMIT 1];
        if (!existing.isEmpty() && existing[0].Status__c == FROZEN) {
            r.message = 'This month\'s plan is already frozen.';
            fill(r, existing[0]);
            return r;
        }

        Datetime fromDt = Datetime.newInstance(monthStart, Time.newInstance(0, 0, 0, 0));
        Datetime toDt = Datetime.newInstance(monthStart.addMonths(1), Time.newInstance(0, 0, 0, 0));
        List<Planned_Call__c> calls = [
            SELECT Id, HCP__c, HCO__c, Call_DateTime__c, Call_Type__c FROM Planned_Call__c
            WHERE OwnerId = :ownerId AND Is_Event__c = false AND Status__c = 'Planned'
              AND (Origin__c = 'Planned' OR Origin__c = null)
              AND Call_DateTime__c >= :fromDt AND Call_DateTime__c < :toDt
            ORDER BY Call_DateTime__c];
        Integer minCalls = SciagenAppConfig.planFreezeMinCalls();
        if (calls.size() < minCalls) {
            r.message = minCalls == 1 ? 'Plan at least one call for this month before freezing it.'
                : 'Plan at least ' + minCalls + ' calls for this month before freezing it (' + calls.size() + ' planned so far).';
            return r;
        }

        Set<Id> hcps = new Set<Id>();
        Set<Date> plannedDays = new Set<Date>();
        for (Planned_Call__c c : calls) {
            if (c.HCP__c != null) hcps.add(c.HCP__c);
            plannedDays.add(c.Call_DateTime__c.date());
        }
        Integer emptyDays = 0;
        for (Date d = monthStart; d < monthStart.addMonths(1); d = d.addDays(1)) {
            if (!SciagenAppConfig.isNonWorkingDay(d) && !plannedDays.contains(d)) emptyDays++;
        }

        String ownerName = [SELECT Name FROM User WHERE Id = :ownerId].Name;
        Monthly_Call_Plan__c plan = new Monthly_Call_Plan__c(
            Plan_Key__c = key,
            Name = (ownerName + ' · ' + Datetime.newInstance(monthStart, Time.newInstance(12, 0, 0, 0)).format('MMM yyyy')).left(80),
            OwnerId = ownerId,
            Month__c = monthStart,
            Status__c = FROZEN,
            Frozen_At__c = Datetime.now(),
            Frozen_Call_Count__c = calls.size(),
            Frozen_HCP_Count__c = hcps.size(),
            Working_Days_Without_Calls__c = emptyDays);
        if (!existing.isEmpty()) plan.Id = existing[0].Id;
        upsert plan;

        for (Planned_Call__c c : calls) {
            c.In_Frozen_Plan__c = true;
            c.Frozen_Call_DateTime__c = c.Call_DateTime__c;
            c.Frozen_Call_Type__c = c.Call_Type__c;
            c.Monthly_Plan__c = plan.Id;
        }
        freezing = true;
        try { update calls; } finally { freezing = false; }
        resolveUnlockRequests(plan.Id);

        r.success = true;
        r.message = 'Plan frozen: ' + calls.size() + ' calls for ' + hcps.size() + ' HCPs.';
        r.planId = plan.Id;
        r.status = FROZEN;
        r.frozenAt = plan.Frozen_At__c;
        r.callCount = calls.size();
        r.hcpCount = hcps.size();
        r.emptyDays = emptyDays;
        return r;
    }

    // ------------------------------------------------------------------ unlock (Business Admin)

    public static Boolean canUnlock() {
        return FeatureManagement.checkPermission('Unlock_Monthly_Plans') || SciagenAccess.hasModifyAllData();
    }

    /** Opens a frozen plan again: Draft, baseline cleared, open unlock requests answered. */
    public static void unlock(Id planId, String reason) {
        if (!canUnlock()) throw new UnlockException('Only a Business Admin can unlock a monthly plan.');
        if (String.isBlank(reason)) throw new UnlockException('Give a reason for unlocking the plan.');
        List<Monthly_Call_Plan__c> rows = [SELECT Id, OwnerId, Month__c, Status__c, Unlock_Count__c
                                           FROM Monthly_Call_Plan__c WHERE Id = :planId LIMIT 1 FOR UPDATE];
        if (rows.isEmpty()) throw new UnlockException('That plan was not found.');
        Monthly_Call_Plan__c plan = rows[0];
        if (plan.Status__c != FROZEN) throw new UnlockException('This plan is not frozen, so the rep can already change it.');
        if (plan.Month__c < Date.today().toStartOfMonth() && !SciagenAppConfig.allowPastMonthFreeze()) {
            throw new UnlockException('This month has ended. A past month\'s plan stays frozen so its plan vs actual is kept.');
        }

        plan.Status__c = 'Draft';
        plan.Last_Unlocked_At__c = Datetime.now();
        plan.Last_Unlocked_By__c = UserInfo.getUserId();
        plan.Unlock_Reason__c = reason.trim().left(255);
        plan.Unlock_Count__c = (plan.Unlock_Count__c == null ? 0 : plan.Unlock_Count__c) + 1;
        update plan;

        // The month is a draft again: no baseline, no deviations until the next freeze.
        List<Planned_Call__c> calls = [SELECT Id FROM Planned_Call__c WHERE Monthly_Plan__c = :plan.Id];
        for (Planned_Call__c c : calls) {
            c.In_Frozen_Plan__c = false;
            c.Frozen_Call_DateTime__c = null;
            c.Frozen_Call_Type__c = null;
            c.Plan_Deviation__c = null;
            c.Monthly_Plan__c = null;
        }
        freezing = true;
        try { if (!calls.isEmpty()) update calls; } finally { freezing = false; }

        List<Support_Request__c> requests = [SELECT Id FROM Support_Request__c WHERE Monthly_Call_Plan__c = :plan.Id
                                             AND Is_Open__c = true AND Category__c = :CAT_UNLOCK_PLAN];
        if (requests.isEmpty()) return;
        List<Support_Request__c> updates = new List<Support_Request__c>();
        List<Support_Comment__c> replies = new List<Support_Comment__c>();
        for (Support_Request__c r : requests) {
            updates.add(new Support_Request__c(Id = r.Id, Unlock_Outcome__c = 'Unlocked', Status__c = 'Waiting on Rep',
                                               Assigned_To__c = UserInfo.getUserId()));
            replies.add(new Support_Comment__c(Support_Request__c = r.Id, Sent_Via__c = 'Web',
                Body__c = 'I have unlocked your monthly plan: ' + reason.trim() + '\nChange it in My Schedule → Scheduler and freeze it again. This request closes by itself when you do.'));
        }
        SupportRequestService.updateInternally(updates, false);
        insert replies;
    }

    /** After a freeze: the plan's open unlock requests are done. */
    private static void resolveUnlockRequests(Id planId) {
        List<Support_Request__c> updates = new List<Support_Request__c>();
        List<Support_Comment__c> events = new List<Support_Comment__c>();
        for (Support_Request__c r : [SELECT Id FROM Support_Request__c WHERE Monthly_Call_Plan__c = :planId
                                     AND Is_Open__c = true AND Category__c = :CAT_UNLOCK_PLAN AND Unlock_Outcome__c = 'Unlocked']) {
            updates.add(new Support_Request__c(Id = r.Id, Status__c = 'Resolved', Resolution_Type__c = 'Unlocked'));
            events.add(SupportCommentService.event(r.Id, 'The plan was changed and frozen again.'));
        }
        if (updates.isEmpty()) return;
        SupportRequestService.updateInternally(updates, true);
        SupportCommentService.insertEvents(events);
    }

    private static void fill(FreezeResult r, Monthly_Call_Plan__c p) {
        r.planId = p.Id;
        r.status = p.Status__c;
        r.frozenAt = p.Frozen_At__c;
        r.callCount = p.Frozen_Call_Count__c == null ? 0 : p.Frozen_Call_Count__c.intValue();
        r.hcpCount = p.Frozen_HCP_Count__c == null ? 0 : p.Frozen_HCP_Count__c.intValue();
        r.emptyDays = p.Working_Days_Without_Calls__c == null ? 0 : p.Working_Days_Without_Calls__c.intValue();
    }

    // ------------------------------------------------------------------ trigger: Planned_Call__c

    /** Before insert / update: protect the baseline and record the deviation. */
    public static void beforeWrite(List<Planned_Call__c> news, Map<Id, Planned_Call__c> oldMap) {
        Boolean admin = null;
        List<Planned_Call__c> calls = new List<Planned_Call__c>();
        for (Planned_Call__c c : news) {
            if (c.Is_Event__c == true) continue;
            Planned_Call__c o = oldMap == null ? null : oldMap.get(c.Id);
            if (!freezing && baselineTouched(c, o)) {
                if (admin == null) admin = SciagenAccess.hasModifyAllData();
                if (!admin) restoreBaseline(c, o);
            }
            calls.add(c);
        }
        if (calls.isEmpty()) return;

        // Frozen plans of these owners for the months these calls are in.
        Set<String> keys = new Set<String>();
        for (Planned_Call__c c : calls) {
            if (c.In_Frozen_Plan__c != true && c.Call_DateTime__c != null) keys.add(planKey(ownerOf(c), c.Call_DateTime__c.date()));
        }
        Map<String, Id> frozenPlans = new Map<String, Id>();
        if (!keys.isEmpty()) {
            for (Monthly_Call_Plan__c p : [SELECT Id, Plan_Key__c FROM Monthly_Call_Plan__c WHERE Plan_Key__c IN :keys AND Status__c = :FROZEN]) {
                frozenPlans.put(p.Plan_Key__c, p.Id);
            }
        }

        for (Planned_Call__c c : calls) {
            if (c.In_Frozen_Plan__c == true) {
                c.Plan_Deviation__c = deviationOf(c);
            } else if (c.Call_DateTime__c != null && frozenPlans.containsKey(planKey(ownerOf(c), c.Call_DateTime__c.date()))) {
                c.Plan_Deviation__c = DEV_ADDED;
                c.Monthly_Plan__c = frozenPlans.get(planKey(ownerOf(c), c.Call_DateTime__c.date()));
            } else {
                c.Plan_Deviation__c = null;
                if (!freezing) c.Monthly_Plan__c = null;
            }
        }
    }

    /** Before delete: a frozen call is cancelled, never deleted. */
    public static void beforeDelete(List<Planned_Call__c> olds) {
        Boolean admin = null;
        for (Planned_Call__c c : olds) {
            if (c.In_Frozen_Plan__c != true) continue;
            if (admin == null) admin = SciagenAccess.hasModifyAllData();
            if (admin) return;
            c.addError('This call is part of your frozen monthly plan and can\'t be deleted. Cancel it instead, so the change is recorded.');
        }
    }

    @TestVisible
    private static String deviationOf(Planned_Call__c c) {
        if (c.Status__c == 'Cancelled') return DEV_CANCELLED;
        Boolean sameDay = c.Call_DateTime__c != null && c.Frozen_Call_DateTime__c != null
            && c.Call_DateTime__c.date() == c.Frozen_Call_DateTime__c.date();
        if (sameDay) return null;
        return c.Status__c == 'Completed' ? DEV_OTHER_DAY : DEV_RESCHEDULED;
    }

    private static Id ownerOf(Planned_Call__c c) {
        return c.OwnerId != null ? c.OwnerId : UserInfo.getUserId();
    }

    private static Boolean baselineTouched(Planned_Call__c c, Planned_Call__c o) {
        if (o == null) {
            return c.In_Frozen_Plan__c == true || c.Frozen_Call_DateTime__c != null || String.isNotBlank(c.Frozen_Call_Type__c);
        }
        return c.In_Frozen_Plan__c != o.In_Frozen_Plan__c || c.Frozen_Call_DateTime__c != o.Frozen_Call_DateTime__c
            || c.Frozen_Call_Type__c != o.Frozen_Call_Type__c
            || (o.In_Frozen_Plan__c == true && c.Monthly_Plan__c != o.Monthly_Plan__c);
    }

    private static void restoreBaseline(Planned_Call__c c, Planned_Call__c o) {
        c.In_Frozen_Plan__c = o == null ? false : o.In_Frozen_Plan__c;
        c.Frozen_Call_DateTime__c = o == null ? null : o.Frozen_Call_DateTime__c;
        c.Frozen_Call_Type__c = o == null ? null : o.Frozen_Call_Type__c;
        if (o != null && o.In_Frozen_Plan__c == true) c.Monthly_Plan__c = o.Monthly_Plan__c;
    }
}