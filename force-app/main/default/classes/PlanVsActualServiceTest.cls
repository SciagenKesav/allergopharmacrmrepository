@isTest
private class PlanVsActualServiceTest {

    private static final Date MONTH_START = Date.newInstance(2026, 9, 1);
    private static final Date MONTH_END = Date.newInstance(2026, 9, 30);
    private static final Date TODAY = Date.newInstance(2026, 9, 20);

    private static Id fakeId(SObjectType t, Integer n) {
        return Id.valueOf(t.getDescribe().getKeyPrefix() + String.valueOf(n).leftPad(12, '0'));
    }
    private static final Id REP = fakeId(User.SObjectType, 1);
    private static final Id HCP_A = fakeId(Sciagen_Account__c.SObjectType, 1);
    private static final Id HCP_B = fakeId(Sciagen_Account__c.SObjectType, 2);

    private static Integer seq = 100;

    private static PlanVsActualService.PlanRow plan(Id hcp, Integer day, String status) {
        PlanVsActualService.PlanRow p = new PlanVsActualService.PlanRow();
        p.id = fakeId(Planned_Call__c.SObjectType, seq++);
        p.ownerId = REP;
        p.hcpId = hcp;
        p.plannedDate = Date.newInstance(2026, 9, day);
        p.currentDate = p.plannedDate;
        p.status = status;
        p.plannedType = 'Detailing';
        p.currentType = 'Detailing';
        return p;
    }

    private static PlanVsActualService.ActualRow actual(Id hcp, Date d) {
        PlanVsActualService.ActualRow a = new PlanVsActualService.ActualRow();
        a.id = fakeId(Call_Visit_Report__c.SObjectType, seq++);
        a.ownerId = REP;
        a.hcpId = hcp;
        a.visitDate = d;
        a.callType = 'Detailing';
        return a;
    }

    private static PlanVsActualService.Analysis run(List<PlanVsActualService.PlanRow> plans,
                                                    List<PlanVsActualService.ActualRow> actuals,
                                                    List<PlanVsActualService.LeaveSpan> leave) {
        return PlanVsActualService.analyze(plans, actuals, leave, TODAY, MONTH_START, MONTH_END);
    }

    private static PlanVsActualService.Item byPlan(PlanVsActualService.Analysis r, Id planId) {
        for (PlanVsActualService.Item i : r.items) { if (i.planId == planId) return i; }
        return null;
    }

    @isTest
    static void sameDayIsOnPlan() {
        PlanVsActualService.PlanRow p = plan(HCP_A, 10, 'Planned');
        PlanVsActualService.Analysis r = run(new List<PlanVsActualService.PlanRow>{ p },
            new List<PlanVsActualService.ActualRow>{ actual(HCP_A, Date.newInstance(2026, 9, 10)) }, new List<PlanVsActualService.LeaveSpan>());
        System.assertEquals(PlanVsActualService.ON_PLAN, byPlan(r, p.id).outcome);
        System.assertEquals(0, byPlan(r, p.id).gapDays);
        System.assertEquals(0, r.stats.get(REP).unplanned);
    }

    @isTest
    static void differentDayIsOtherDayWithGap() {
        PlanVsActualService.PlanRow late = plan(HCP_A, 10, 'Planned');
        PlanVsActualService.PlanRow early = plan(HCP_B, 10, 'Planned');
        PlanVsActualService.Analysis r = run(new List<PlanVsActualService.PlanRow>{ late, early },
            new List<PlanVsActualService.ActualRow>{ actual(HCP_A, Date.newInstance(2026, 9, 12)), actual(HCP_B, Date.newInstance(2026, 9, 8)) },
            new List<PlanVsActualService.LeaveSpan>());
        System.assertEquals(PlanVsActualService.OTHER_DAY, byPlan(r, late.id).outcome);
        System.assertEquals(2, byPlan(r, late.id).gapDays);
        System.assertEquals(-2, byPlan(r, early.id).gapDays);
    }

    @isTest
    static void unresolvedPlanIsMissedInThePastAndUpcomingAhead() {
        PlanVsActualService.PlanRow past = plan(HCP_A, 5, 'Planned');
        PlanVsActualService.PlanRow ahead = plan(HCP_B, 25, 'Planned');
        PlanVsActualService.Analysis r = run(new List<PlanVsActualService.PlanRow>{ past, ahead },
            new List<PlanVsActualService.ActualRow>(), new List<PlanVsActualService.LeaveSpan>());
        System.assertEquals(PlanVsActualService.MISSED, byPlan(r, past.id).outcome);
        System.assertEquals(PlanVsActualService.UPCOMING, byPlan(r, ahead.id).outcome);
    }

    @isTest
    static void approvedLeaveExcusesAMissedCall() {
        PlanVsActualService.PlanRow p = plan(HCP_A, 5, 'Planned');
        PlanVsActualService.LeaveSpan l = new PlanVsActualService.LeaveSpan();
        l.ownerId = REP;
        l.fromDate = Date.newInstance(2026, 9, 4);
        l.toDate = Date.newInstance(2026, 9, 6);
        PlanVsActualService.Analysis r = run(new List<PlanVsActualService.PlanRow>{ p },
            new List<PlanVsActualService.ActualRow>(), new List<PlanVsActualService.LeaveSpan>{ l });
        System.assertEquals(PlanVsActualService.EXCUSED, byPlan(r, p.id).outcome);
        PlanVsActualService.OwnerStats s = r.stats.get(REP);
        System.assertEquals(0, s.due(), 'an excused call is not held against the rep');
        System.assertEquals(null, s.achievementPct());
    }

    @isTest
    static void cancelledPlanIsCancelledAndNotMatched() {
        PlanVsActualService.PlanRow p = plan(HCP_A, 5, 'Cancelled');
        PlanVsActualService.Analysis r = run(new List<PlanVsActualService.PlanRow>{ p },
            new List<PlanVsActualService.ActualRow>{ actual(HCP_A, Date.newInstance(2026, 9, 5)) }, new List<PlanVsActualService.LeaveSpan>());
        System.assertEquals(PlanVsActualService.CANCELLED, byPlan(r, p.id).outcome);
        System.assertEquals(1, r.stats.get(REP).unplanned, 'the call that happened anyway is unplanned');
    }

    @isTest
    static void reportWithNoPlanIsUnplanned() {
        PlanVsActualService.Analysis r = run(new List<PlanVsActualService.PlanRow>(),
            new List<PlanVsActualService.ActualRow>{ actual(HCP_A, Date.newInstance(2026, 9, 9)) }, new List<PlanVsActualService.LeaveSpan>());
        PlanVsActualService.OwnerStats s = r.stats.get(REP);
        System.assertEquals(1, s.unplanned);
        System.assertEquals(1, s.actual);
        System.assertEquals(1, r.actualByDay.get(9));
        System.assertEquals(100.0, s.unplannedPct());
    }

    @isTest
    static void draftReportsAreNotCountedAsCalls() {
        PlanVsActualService.PlanRow p = plan(HCP_A, 5, 'Planned');
        PlanVsActualService.ActualRow draft = actual(HCP_A, Date.newInstance(2026, 9, 5));
        draft.submitted = false;
        PlanVsActualService.Analysis r = run(new List<PlanVsActualService.PlanRow>{ p },
            new List<PlanVsActualService.ActualRow>{ draft }, new List<PlanVsActualService.LeaveSpan>());
        System.assertEquals(PlanVsActualService.MISSED, byPlan(r, p.id).outcome);
        System.assertEquals(1, r.stats.get(REP).drafts);
        System.assertEquals(0, r.stats.get(REP).actual);
    }

    @isTest
    static void twoPlansForOneDoctorPairWithTheNearestReports() {
        PlanVsActualService.PlanRow first = plan(HCP_A, 3, 'Planned');
        PlanVsActualService.PlanRow second = plan(HCP_A, 10, 'Planned');
        PlanVsActualService.Analysis r = run(new List<PlanVsActualService.PlanRow>{ first, second },
            new List<PlanVsActualService.ActualRow>{ actual(HCP_A, Date.newInstance(2026, 9, 11)), actual(HCP_A, Date.newInstance(2026, 9, 3)) },
            new List<PlanVsActualService.LeaveSpan>());
        System.assertEquals(PlanVsActualService.ON_PLAN, byPlan(r, first.id).outcome);
        System.assertEquals(1, byPlan(r, second.id).gapDays);
    }

    @isTest
    static void explicitLinkBeatsProximity() {
        PlanVsActualService.PlanRow p = plan(HCP_A, 10, 'Planned');
        PlanVsActualService.ActualRow near = actual(HCP_A, Date.newInstance(2026, 9, 10));
        PlanVsActualService.ActualRow linked = actual(HCP_A, Date.newInstance(2026, 9, 14));
        p.linkedCvrId = linked.id;
        PlanVsActualService.Analysis r = run(new List<PlanVsActualService.PlanRow>{ p },
            new List<PlanVsActualService.ActualRow>{ near, linked }, new List<PlanVsActualService.LeaveSpan>());
        System.assertEquals(linked.id, byPlan(r, p.id).cvrId);
        System.assertEquals(4, byPlan(r, p.id).gapDays);
        System.assertEquals(1, r.stats.get(REP).unplanned, 'the nearer report is left over');
    }

    @isTest
    static void sourcePlanOnTheReportLinksToo() {
        PlanVsActualService.PlanRow p = plan(HCP_A, 10, 'Planned');
        PlanVsActualService.ActualRow a = actual(HCP_B, Date.newInstance(2026, 9, 13));
        a.sourcePlanId = p.id;
        PlanVsActualService.Analysis r = run(new List<PlanVsActualService.PlanRow>{ p },
            new List<PlanVsActualService.ActualRow>{ a }, new List<PlanVsActualService.LeaveSpan>());
        System.assertEquals(a.id, byPlan(r, p.id).cvrId);
    }

    @isTest
    static void callDoneJustAfterMonthEndStillCountsAgainstThePlan() {
        PlanVsActualService.PlanRow p = plan(HCP_A, 30, 'Planned');
        PlanVsActualService.ActualRow a = actual(HCP_A, Date.newInstance(2026, 10, 2));
        PlanVsActualService.Analysis r = PlanVsActualService.analyze(new List<PlanVsActualService.PlanRow>{ p },
            new List<PlanVsActualService.ActualRow>{ a }, new List<PlanVsActualService.LeaveSpan>(), Date.newInstance(2026, 10, 5), MONTH_START, MONTH_END);
        System.assertEquals(PlanVsActualService.OTHER_DAY, byPlan(r, p.id).outcome);
        System.assertEquals(2, byPlan(r, p.id).gapDays);
        System.assertEquals(0, r.stats.get(REP).actual, 'an October call is not a September call');
        System.assertEquals(0, r.stats.get(REP).unplanned);
    }

    @isTest
    static void completedPlanWithoutAReportIsDoneButFlagged() {
        PlanVsActualService.PlanRow p = plan(HCP_A, 10, 'Completed');
        p.currentDate = Date.newInstance(2026, 9, 11);
        PlanVsActualService.Analysis r = run(new List<PlanVsActualService.PlanRow>{ p },
            new List<PlanVsActualService.ActualRow>(), new List<PlanVsActualService.LeaveSpan>());
        PlanVsActualService.Item i = byPlan(r, p.id);
        System.assertEquals(PlanVsActualService.OTHER_DAY, i.outcome);
        System.assertEquals(true, i.reportNotFound);
    }

    @isTest
    static void callTypeChangeIsFlagged() {
        PlanVsActualService.PlanRow p = plan(HCP_A, 10, 'Planned');
        PlanVsActualService.ActualRow a = actual(HCP_A, Date.newInstance(2026, 9, 10));
        a.callType = 'Sampling';
        PlanVsActualService.Analysis r = run(new List<PlanVsActualService.PlanRow>{ p },
            new List<PlanVsActualService.ActualRow>{ a }, new List<PlanVsActualService.LeaveSpan>());
        System.assertEquals(true, byPlan(r, p.id).typeChanged);
        System.assertEquals(1, r.stats.get(REP).typeChanged);
    }

    @isTest
    static void planMovedToTheFutureIsUpcomingNotMissed() {
        PlanVsActualService.PlanRow p = plan(HCP_A, 5, 'Planned');
        p.currentDate = Date.newInstance(2026, 9, 25);
        PlanVsActualService.Analysis r = run(new List<PlanVsActualService.PlanRow>{ p },
            new List<PlanVsActualService.ActualRow>(), new List<PlanVsActualService.LeaveSpan>());
        System.assertEquals(PlanVsActualService.UPCOMING, byPlan(r, p.id).outcome);
        System.assertEquals(true, byPlan(r, p.id).moved);
    }

    @isTest
    static void percentagesAndDailyCounts() {
        List<PlanVsActualService.PlanRow> plans = new List<PlanVsActualService.PlanRow>{
            plan(HCP_A, 2, 'Planned'), plan(HCP_B, 3, 'Planned'), plan(fakeId(Sciagen_Account__c.SObjectType, 3), 4, 'Planned'),
            plan(fakeId(Sciagen_Account__c.SObjectType, 4), 25, 'Planned')
        };
        PlanVsActualService.Analysis r = run(plans, new List<PlanVsActualService.ActualRow>{
            actual(HCP_A, Date.newInstance(2026, 9, 2)), actual(HCP_B, Date.newInstance(2026, 9, 5))
        }, new List<PlanVsActualService.LeaveSpan>());
        PlanVsActualService.OwnerStats s = r.stats.get(REP);
        System.assertEquals(4, s.planned);
        System.assertEquals(3, s.due(), 'the 25th has not come yet');
        System.assertEquals(66.7, s.achievementPct());
        System.assertEquals(33.3, s.onDayPct());
        System.assertEquals(1, r.plannedByDay.get(2));
        System.assertEquals(1, r.actualByDay.get(5));
    }

    @isTest
    static void aCallBelongsToItsOwnMonthsPlanBeforeItCanExcuseAnEarlierMiss() {
        // Missed plan on 28 Aug and a plan on 2 Sep, both for the same doctor. The 2 Sep call is the September plan's.
        PlanVsActualService.PlanRow missedAug = plan(HCP_A, 1, 'Planned');
        missedAug.plannedDate = Date.newInstance(2026, 8, 28);
        missedAug.currentDate = missedAug.plannedDate;
        PlanVsActualService.PlanRow sepPlan = plan(HCP_A, 2, 'Planned');
        PlanVsActualService.Analysis r = run(new List<PlanVsActualService.PlanRow>{ missedAug, sepPlan },
            new List<PlanVsActualService.ActualRow>{ actual(HCP_A, Date.newInstance(2026, 9, 2)) }, new List<PlanVsActualService.LeaveSpan>());
        System.assertEquals(null, byPlan(r, missedAug.id), 'August plans are not part of the September report');
        System.assertEquals(PlanVsActualService.ON_PLAN, byPlan(r, sepPlan.id).outcome);

        PlanVsActualService.Analysis augRun = PlanVsActualService.analyze(new List<PlanVsActualService.PlanRow>{ missedAug, sepPlan },
            new List<PlanVsActualService.ActualRow>{ actual(HCP_A, Date.newInstance(2026, 9, 2)) }, new List<PlanVsActualService.LeaveSpan>(),
            TODAY, Date.newInstance(2026, 8, 1), Date.newInstance(2026, 8, 31));
        System.assertEquals(1, augRun.items.size());
        System.assertEquals(PlanVsActualService.MISSED, augRun.items[0].outcome);
    }
}