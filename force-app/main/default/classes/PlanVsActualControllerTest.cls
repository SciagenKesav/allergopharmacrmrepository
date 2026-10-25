@isTest
private class PlanVsActualControllerTest {

    private static Date monthStart() { return Date.today().toStartOfMonth().addMonths(-1); }

    private static Date workday(Integer day) {
        Date d = monthStart().addDays(day - 1);
        while (Datetime.newInstance(d, Time.newInstance(12, 0, 0, 0)).format('EEEE') == 'Sunday') d = d.addDays(1);
        return d;
    }

    private static Planned_Call__c plan(Sciagen_Account__c hcp, Date d, String status, Boolean isEvent) {
        return new Planned_Call__c(HCP__c = hcp.Id, Call_DateTime__c = Datetime.newInstance(d, Time.newInstance(11, 0, 0, 0)),
            Call_Type__c = 'Detailing', Status__c = status, Is_Event__c = isEvent);
    }

    private static Call_Visit_Report__c cvr(Sciagen_Account__c hcp, Date d, String recordStatus) {
        return new Call_Visit_Report__c(HCP__c = hcp.Id, Visit_Date__c = d, Call_Type__c = 'Detailing',
            Call_Status__c = 'Completed', Record_Status__c = recordStatus);
    }

    private static List<Sciagen_Account__c> doctors(Integer n) {
        List<Sciagen_Account__c> out = new List<Sciagen_Account__c>();
        List<String> names = new List<String>{ 'Aarav Nair', 'Bhavna Kulkarni', 'Chirag Deshmukh', 'Divya Menon', 'Eshan Trivedi', 'Farida Qureshi' };
        for (Integer i = 0; i < n; i++) out.add(new Sciagen_Account__c(Name = 'Dr. ' + names[i], Type__c = 'HCP'));
        insert out;
        return out;
    }

    @testSetup
    static void seed() {
        // This test deliberately plants Planned_Call__c rows in *last* month (see monthStart()) to
        // exercise "plan vs. actual" across a month boundary -- PlannedCallScheduleGuardService's
        // backdate limit (added after this test was written) would otherwise reject them. A real
        // Call_Backdate_Limit__c row (not the testBackdateLimitDays static hook) is what actually
        // takes effect reliably here: static-variable overrides set inside @testSetup are not
        // guaranteed to apply to @testSetup's own DML in a full multi-class test run, only inserted
        // *data* is (which is @testSetup's whole documented purpose).
        insert new Call_Backdate_Limit__c(SetupOwnerId = UserInfo.getOrganizationId(), Days__c = 60);
        List<Sciagen_Account__c> d = doctors(6);
        insert new List<Planned_Call__c>{
            plan(d[0], workday(3), 'Planned', false),
            plan(d[1], workday(5), 'Planned', false),
            plan(d[2], workday(8), 'Planned', false),
            plan(d[3], workday(9), 'Cancelled', false),
            plan(d[0], workday(12), 'Completed', false),
            plan(d[4], workday(13), 'Planned', true)
        };
        insert new List<Call_Visit_Report__c>{
            cvr(d[0], workday(3), 'Submitted'),
            cvr(d[1], workday(7), 'Submitted'),
            cvr(d[4], workday(10), 'Submitted'),
            cvr(d[5], workday(11), 'Draft')
        };
    }

    @isTest
    static void overviewCountsEachKindOfDeviation() {
        PlanVsActualController.Overview o = PlanVsActualController.getOverview(String.valueOf(monthStart()), null, null);
        System.assertEquals(4, o.planned, 'event and call-log rows are not plans');
        System.assertEquals(1, o.onPlan);
        System.assertEquals(1, o.otherDay);
        System.assertEquals(1, o.missed);
        System.assertEquals(1, o.cancelled);
        System.assertEquals(1, o.unplanned);
        System.assertEquals(3, o.actual);
        System.assertEquals(1, o.drafts);
        System.assertEquals(50.0, o.achievementPct);
        System.assertEquals(25.0, o.onDayPct);
        System.assertEquals(1, o.reps.size());
        System.assertEquals(UserInfo.getUserId(), o.reps[0].userId);
        System.assertEquals(monthStart().addMonths(1).addDays(-1).day(), o.days.size());
    }

    @isTest
    static void itemsCanBeFilteredByOutcome() {
        PlanVsActualController.ItemsResult all = PlanVsActualController.getItems(String.valueOf(monthStart()), null, null, null);
        System.assertEquals(5, all.total);
        PlanVsActualController.ItemsResult missed = PlanVsActualController.getItems(String.valueOf(monthStart()), null, null, new List<String>{ 'Missed' });
        System.assertEquals(1, missed.items.size());
        System.assertEquals('Dr. Chirag Deshmukh', missed.items[0].hcpName);
        PlanVsActualController.ItemsResult other = PlanVsActualController.getItems(String.valueOf(monthStart()), null, null, new List<String>{ 'Other day' });
        System.assertEquals(2, other.items[0].gapDays);
    }

    @isTest
    static void repAndTerritoryFiltersNarrowTheResult() {
        Id someoneElse = [SELECT Id FROM User WHERE Id != :UserInfo.getUserId() AND IsActive = true LIMIT 1].Id;
        System.assertEquals(0, PlanVsActualController.getOverview(String.valueOf(monthStart()), null, someoneElse).reps.size());
        System.assertEquals(1, PlanVsActualController.getOverview(String.valueOf(monthStart()), null, UserInfo.getUserId()).reps.size());

        Territory__c north = new Territory__c(Name = 'North', Type__c = 'Territory');
        insert north;
        System.assertEquals(0, PlanVsActualController.getOverview(String.valueOf(monthStart()), north.Id, null).reps.size(), 'nobody is in North yet');
        insert new User_Territory__c(User__c = UserInfo.getUserId(), Territory__c = north.Id, Is_Primary__c = true);
        PlanVsActualController.Overview o = PlanVsActualController.getOverview(String.valueOf(monthStart()), north.Id, null);
        System.assertEquals(1, o.reps.size());
        System.assertEquals('North', o.reps[0].territory);
        System.assertEquals(1, PlanVsActualController.getTerritories().size());
    }

    @isTest
    static void approvedLeaveExcusesTheMissedCall() {
        insert new Leave_Request__c(From_Date__c = workday(8), To_Date__c = workday(8), Status__c = 'Approved', Type__c = 'Casual Leave');
        PlanVsActualController.Overview o = PlanVsActualController.getOverview(String.valueOf(monthStart()), null, null);
        System.assertEquals(0, o.missed);
        System.assertEquals(1, o.excused);
    }

    @isTest
    static void futureMonthPlansAreAllUpcoming() {
        List<Sciagen_Account__c> d = [SELECT Id FROM Sciagen_Account__c LIMIT 1];
        Date next = Date.today().toStartOfMonth().addMonths(1).addDays(9);
        while (Datetime.newInstance(next, Time.newInstance(12, 0, 0, 0)).format('EEEE') == 'Sunday') next = next.addDays(1);
        insert plan(d[0], next, 'Planned', false);
        PlanVsActualController.Overview o = PlanVsActualController.getOverview(String.valueOf(Date.today().toStartOfMonth().addMonths(1)), null, null);
        System.assertEquals(1, o.planned);
        System.assertEquals(1, o.upcoming);
        System.assertEquals(null, o.achievementPct, 'nothing is due yet');
    }

    @isTest
    static void blankMonthDefaultsToThisMonth() {
        PlanVsActualController.Overview o = PlanVsActualController.getOverview(null, null, null);
        System.assertEquals(String.valueOf(Date.today().toStartOfMonth()), o.monthStart);
    }

    @isTest
    static void reportLinkedToAPlanIsMatchedEvenForADifferentDoctor() {
        // Plants a Planned_Call__c in last month -- covered by seed()'s Call_Backdate_Limit__c row.
        List<Sciagen_Account__c> d = [SELECT Id FROM Sciagen_Account__c ORDER BY Name LIMIT 6];
        Planned_Call__c planned = plan(d[0], workday(15), 'Planned', false);
        insert planned;
        // Filed against another doctor on another day, but explicitly linked to the plan.
        Call_Visit_Report__c linked = cvr(d[1], workday(17), 'Submitted');
        linked.Source_Planned_Call__c = planned.Id;
        insert linked;
        PlanVsActualController.ItemsResult res = PlanVsActualController.getItems(String.valueOf(monthStart()), null, null, new List<String>{ 'Other day' });
        Boolean found = false;
        for (PlanVsActualController.ItemDTO i : res.items) {
            if (i.planId == planned.Id) { found = true; System.assertEquals(linked.Id, i.cvrId); }
        }
        System.assert(found, 'the linked report should fulfil the plan');
    }
}