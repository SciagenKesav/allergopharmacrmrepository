@isTest
private class AccountPlanHomeDashboardCovTest {

    @testSetup
    static void setup() {
        Sciagen_Account__c hco = new Sciagen_Account__c(Type__c = 'HCO', Name = 'Dash Cov Hospital', HCO_Type__c = 'Hospital', Speciality__c = 'Other');
        Sciagen_Account__c hcp = new Sciagen_Account__c(Type__c = 'HCP', Name = 'Dr. Dash Cov', First_Name__c = 'Dash', Last_Name__c = 'Cov',
            Specialty__c = 'Cardiology', HCP_Type__c = 'Physician');
        insert new List<Sciagen_Account__c>{ hco, hcp };

        Account_Plan__c p1 = new Account_Plan__c(Plan_Title__c = 'Cov Plan Alpha', HCO__c = hco.Id, Status__c = 'Active', Stage__c = 'Prospect',
            Objective__c = 'Grow', Start_Date__c = Date.today().addDays(-5), End_Date__c = Date.today().addDays(60));
        Account_Plan__c p2 = new Account_Plan__c(Plan_Title__c = 'Cov Plan Beta', HCP__c = hcp.Id, Status__c = 'Active', Stage__c = 'Early');
        Account_Plan__c p3 = new Account_Plan__c(Plan_Title__c = 'Cov Plan Gamma', Status__c = 'Active', Stage__c = 'Prospect');
        insert new List<Account_Plan__c>{ p1, p2, p3 };

        Plan_Strategy__c s1 = new Plan_Strategy__c(Plan__c = p1.Id, Strategy_Name__c = 'Alpha Strategy');
        insert s1;
        Plan_Activity__c a1 = new Plan_Activity__c(Strategy__c = s1.Id, Activity_Name__c = 'Alpha Activity');
        insert a1;
        insert new List<Action_Item__c>{
            new Action_Item__c(Activity__c = a1.Id, Title__c = 'Done', Status__c = 'Completed', Due_Date__c = Date.today().addDays(3)),
            new Action_Item__c(Activity__c = a1.Id, Title__c = 'Late', Status__c = 'Open', Due_Date__c = Date.today().addDays(-3)),
            new Action_Item__c(Activity__c = a1.Id, Title__c = 'Undated', Status__c = 'Open')
        };
    }

    @isTest static void searchWithNoFiltersReturnsAllPlansWithRollups() {
        Test.startTest();
        List<AccountPlanHomeDashboardController.PlanListItem> items = AccountPlanHomeDashboardController.searchAccountPlans(null, null, null);
        Test.stopTest();
        System.assertEquals(3, items.size());
        Map<String, AccountPlanHomeDashboardController.PlanListItem> byTitle = new Map<String, AccountPlanHomeDashboardController.PlanListItem>();
        for (AccountPlanHomeDashboardController.PlanListItem i : items) byTitle.put(i.title, i);

        AccountPlanHomeDashboardController.PlanListItem alpha = byTitle.get('Cov Plan Alpha');
        System.assertEquals('Dash Cov Hospital', alpha.accountName);
        System.assertEquals('Dash Cov Hospital', alpha.hcoName);
        System.assertEquals(3, alpha.totalActionItems);
        System.assertEquals(1, alpha.completedActionItems);
        System.assertEquals(1, alpha.overdueActionItems);
        System.assertEquals(Decimal.valueOf(1).divide(Decimal.valueOf(3), 4) * 100, alpha.progressPercent);
        System.assertNotEquals(null, alpha.startDate);
        System.assertNotEquals(null, alpha.endDate);

        AccountPlanHomeDashboardController.PlanListItem beta = byTitle.get('Cov Plan Beta');
        System.assertEquals(beta.hcpName, beta.accountName);
        System.assertNotEquals(null, beta.accountName);
        System.assertEquals(null, beta.hcoName);
        System.assertEquals(0, beta.progressPercent);
        System.assertEquals(null, beta.startDate);

        System.assertEquals(null, byTitle.get('Cov Plan Gamma').accountName);
    }

    @isTest static void searchAppliesTermStatusAndStageFilters() {
        System.assertEquals(1, AccountPlanHomeDashboardController.searchAccountPlans('Alpha', null, null).size());
        System.assertEquals(2, AccountPlanHomeDashboardController.searchAccountPlans('Cov Plan', 'Active', 'Prospect').size());
        System.assertEquals(1, AccountPlanHomeDashboardController.searchAccountPlans('Cov Plan', 'Active', 'Early').size());
        System.assertEquals(0, AccountPlanHomeDashboardController.searchAccountPlans('Cov Plan', 'Active', 'Nonexistent').size());
        System.assertEquals(0, AccountPlanHomeDashboardController.searchAccountPlans('Cov Plan', 'Closed', null).size());
    }
}