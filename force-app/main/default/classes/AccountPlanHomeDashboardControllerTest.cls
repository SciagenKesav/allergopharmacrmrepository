@isTest
private class AccountPlanHomeDashboardControllerTest {

    @testSetup
    static void setup() {
        Account_Plan__c planA = new Account_Plan__c(Plan_Title__c = 'Dashboard Test Plan A', Status__c = 'Active', Stage__c = 'Early');
        Account_Plan__c planB = new Account_Plan__c(Plan_Title__c = 'Dashboard Test Plan B', Status__c = 'Active', Stage__c = 'Prospect');
        insert new List<Account_Plan__c>{ planA, planB };

        Plan_Strategy__c strategyA = new Plan_Strategy__c(Plan__c = planA.Id, Strategy_Name__c = 'A Strategy');
        Plan_Strategy__c strategyB = new Plan_Strategy__c(Plan__c = planB.Id, Strategy_Name__c = 'B Strategy');
        insert new List<Plan_Strategy__c>{ strategyA, strategyB };

        Plan_Activity__c activityA1 = new Plan_Activity__c(Strategy__c = strategyA.Id, Activity_Name__c = 'A Activity 1');
        Plan_Activity__c activityA2 = new Plan_Activity__c(Strategy__c = strategyA.Id, Activity_Name__c = 'A Activity 2', Manual_Complete__c = true);
        Plan_Activity__c activityB1 = new Plan_Activity__c(Strategy__c = strategyB.Id, Activity_Name__c = 'B Activity 1');
        insert new List<Plan_Activity__c>{ activityA1, activityA2, activityB1 };

        insert new List<Action_Item__c>{
            new Action_Item__c(Activity__c = activityA1.Id, Title__c = 'A1 Item 1', Status__c = 'Completed', Assignee__c = 'Rep One'),
            // Due yesterday but not Completed — the one case that should count as overdue.
            new Action_Item__c(Activity__c = activityA1.Id, Title__c = 'A1 Item 2', Status__c = 'In Progress', Assignee__c = 'Rep One', Due_Date__c = Date.today().addDays(-1)),
            // Due next week — not overdue, confirms a future due date isn't miscounted.
            new Action_Item__c(Activity__c = activityB1.Id, Title__c = 'B1 Item 1', Status__c = 'Postponed', Assignee__c = 'Rep Two', Due_Date__c = Date.today().addDays(7))
        };
    }

    @isTest
    static void testGetHomeDashboardDataAggregatesAcrossPlans() {
        Test.startTest();
        AccountPlanHomeDashboardController.HomeDashboardData data = AccountPlanHomeDashboardController.getHomeDashboardData();
        Test.stopTest();

        System.assertEquals(2, data.strategyProgress.size());
        Map<String, AccountPlanHomeDashboardController.StrategyProgress> byStrategy = new Map<String, AccountPlanHomeDashboardController.StrategyProgress>();
        for (AccountPlanHomeDashboardController.StrategyProgress sp : data.strategyProgress) byStrategy.put(sp.strategyName, sp);

        System.assertEquals(2, byStrategy.get('A Strategy').totalActivities);
        System.assertEquals(1, byStrategy.get('A Strategy').completedActivities, 'A Activity 2 is Manual_Complete__c');
        System.assertEquals(1, byStrategy.get('B Strategy').totalActivities);
        System.assertEquals(0, byStrategy.get('B Strategy').completedActivities, 'B Activity 1 has one Postponed item, not complete');

        System.assertEquals(2, data.planProgress.size());
        Map<String, AccountPlanHomeDashboardController.PlanProgress> byPlan = new Map<String, AccountPlanHomeDashboardController.PlanProgress>();
        for (AccountPlanHomeDashboardController.PlanProgress pp : data.planProgress) byPlan.put(pp.planName, pp);
        System.assertEquals(2, byPlan.get('Dashboard Test Plan A').totalActionItems);
        System.assertEquals(1, byPlan.get('Dashboard Test Plan A').completedActionItems);
        System.assertEquals(1, byPlan.get('Dashboard Test Plan B').totalActionItems);
        System.assertEquals(0, byPlan.get('Dashboard Test Plan B').completedActionItems);

        Integer totalRecent = 0;
        for (AccountPlanHomeDashboardController.ActivityCount ac : data.recentActivity) totalRecent += ac.count;
        System.assertEquals(3, totalRecent, 'All 3 seeded Action Items were created within the last 30 days');

        Map<String, Integer> buckets = new Map<String, Integer>();
        for (AccountPlanHomeDashboardController.StatusBucket b : data.teamObjectiveAchievement) buckets.put(b.bucket, b.count);
        System.assertEquals(1, buckets.get('In Progress'));
        System.assertEquals(1, buckets.get('Postponed'));
        System.assertEquals(1, buckets.get('Achieved'));
    }

    @isTest
    static void testSearchAccountPlansComputesProgressAndActionItemCounts() {
        Test.startTest();
        List<AccountPlanHomeDashboardController.PlanListItem> items =
            AccountPlanHomeDashboardController.searchAccountPlans('Dashboard Test', null, null);
        Test.stopTest();

        System.assertEquals(2, items.size());
        Map<String, AccountPlanHomeDashboardController.PlanListItem> byTitle =
            new Map<String, AccountPlanHomeDashboardController.PlanListItem>();
        for (AccountPlanHomeDashboardController.PlanListItem item : items) byTitle.put(item.title, item);

        AccountPlanHomeDashboardController.PlanListItem planA = byTitle.get('Dashboard Test Plan A');
        System.assertEquals(2, planA.totalActionItems);
        System.assertEquals(1, planA.completedActionItems);
        System.assertEquals(1, planA.overdueActionItems, 'A1 Item 2 is open and due yesterday');
        System.assertEquals(50, planA.progressPercent);

        AccountPlanHomeDashboardController.PlanListItem planB = byTitle.get('Dashboard Test Plan B');
        System.assertEquals(1, planB.totalActionItems);
        System.assertEquals(0, planB.completedActionItems);
        System.assertEquals(0, planB.overdueActionItems, 'B1 Item 1 is due next week, not overdue');
        System.assertEquals(0, planB.progressPercent);
    }
}