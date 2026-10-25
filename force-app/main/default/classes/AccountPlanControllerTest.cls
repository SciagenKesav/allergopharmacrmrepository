@isTest
private class AccountPlanControllerTest {

    @testSetup
    static void setup() {
        Sciagen_Account__c hco = new Sciagen_Account__c(
            Type__c = 'HCO', Name = 'Plan Test Hospital', HCO_Type__c = 'Hospital', Speciality__c = 'Other'
        );
        insert hco;

        Account_Plan__c plan = new Account_Plan__c(
            Plan_Title__c = 'Plan Test Account Plan',
            HCO__c = hco.Id,
            Status__c = 'Active',
            Stage__c = 'Prospect',
            Objective__c = 'Grow adoption across the network'
        );
        insert plan;

        Plan_Strategy__c strategy1 = new Plan_Strategy__c(Plan__c = plan.Id, Strategy_Name__c = 'Strategy One', Share_With__c = 'NOAD;MSL');
        Plan_Strategy__c strategy2 = new Plan_Strategy__c(Plan__c = plan.Id, Strategy_Name__c = 'Strategy Two');
        insert new List<Plan_Strategy__c>{ strategy1, strategy2 };

        Plan_Activity__c activity1 = new Plan_Activity__c(Strategy__c = strategy1.Id, Activity_Name__c = 'Activity One');
        Plan_Activity__c activity2 = new Plan_Activity__c(Strategy__c = strategy1.Id, Activity_Name__c = 'Activity Two', Manual_Complete__c = true);
        Plan_Activity__c activity3 = new Plan_Activity__c(Strategy__c = strategy2.Id, Activity_Name__c = 'Activity Three');
        insert new List<Plan_Activity__c>{ activity1, activity2, activity3 };

        Action_Item__c item1 = new Action_Item__c(
            Activity__c = activity1.Id, Title__c = 'Item One', Status__c = 'Completed',
            Due_Date__c = Date.today().addDays(10)
        );
        Action_Item__c item2 = new Action_Item__c(
            Activity__c = activity1.Id, Title__c = 'Item Two', Status__c = 'Open',
            Due_Date__c = Date.today().addDays(5)
        );
        Action_Item__c item3 = new Action_Item__c(
            Activity__c = activity3.Id, Title__c = 'Item Three', Status__c = 'Postponed',
            Due_Date__c = Date.today().addDays(2)
        );
        insert new List<Action_Item__c>{ item1, item2, item3 };

        Sciagen_Account__c hcp = new Sciagen_Account__c(
            Type__c = 'HCP', Name = 'Dr. Plan Test', Prefix__c = 'Dr.', First_Name__c = 'Plan', Last_Name__c = 'Test',
            Specialty__c = 'Cardiology', HCP_Type__c = 'Physician'
        );
        insert hcp;
        insert new Affiliation__c(HCP__c = hcp.Id, HCO__c = hco.Id);

        insert new Plan_Stakeholder__c(
            Plan__c = plan.Id, HCP__c = hcp.Id, Stakeholder_Name__c = 'Dr. Plan Test',
            Role__c = 'Decision Maker', Influence__c = 'High', Strength__c = 'Advocate'
        );
        insert new Account_Team_Member__c(Plan__c = plan.Id, Member_Name__c = 'Rep One', Role__c = 'KAM', Access__c = 'Write');
        insert new Plan_Goal__c(
            Plan__c = plan.Id, Title__c = 'Grow Rx share', Metric__c = 'Rx Count', Target__c = 100,
            Current__c = 40, Unit__c = 'units', Due_Date__c = Date.today().addMonths(3)
        );
    }

    @isTest
    static void testGetPlanWorkspaceComputesRollupsAndUpcomingOrdering() {
        Account_Plan__c plan = [SELECT Id FROM Account_Plan__c LIMIT 1];

        Test.startTest();
        AccountPlanController.PlanWorkspace ws = AccountPlanController.getPlanWorkspace(plan.Id);
        Test.stopTest();

        System.assertEquals('Prospect', ws.stage);
        System.assertEquals('Early', ws.nextStage);
        System.assertEquals(2, ws.totalStrategies);
        System.assertEquals(0, ws.completedStrategies, 'Neither strategy has 100% of its activities complete');
        System.assertEquals(3, ws.totalActivities);
        System.assertEquals(1, ws.completedActivities, 'Only Activity Two (Manual_Complete__c) is complete');
        System.assertEquals(3, ws.totalActionItems);
        System.assertEquals(1, ws.completedActionItems, 'Only Item One is Completed — Postponed does not count');

        Decimal expectedActionItemPct = Decimal.valueOf(1).divide(Decimal.valueOf(3), 4) * 100;
        System.assertEquals(expectedActionItemPct, ws.actionItemProgressPercent);

        System.assertEquals(2, ws.upcoming.size(), 'Item One is Completed and excluded from Upcoming');
        System.assertEquals('Item Three', ws.upcoming[0].title, 'Item Three is due soonest (in 2 days)');
        System.assertEquals('Item Two', ws.upcoming[1].title, 'Item Two is due next (in 5 days)');

        for (AccountPlanController.StrategyDTO s : ws.strategies) {
            if (s.name == 'Strategy One') {
                System.assertEquals(2, s.totalActivities);
                System.assertEquals(1, s.completedActivities);
                System.assertEquals(new List<String>{ 'NOAD', 'MSL' }, s.shareWith);
            }
        }

        System.assertEquals(1, ws.stakeholders.size());
        System.assertEquals('Dr. Plan Test', ws.stakeholders[0].name);
        System.assertEquals('Decision Maker', ws.stakeholders[0].role);
        System.assertEquals('High', ws.stakeholders[0].influence);
        System.assertEquals('Advocate', ws.stakeholders[0].strength);

        System.assertEquals(1, ws.teamMembers.size());
        System.assertEquals('Rep One', ws.teamMembers[0].name);
        System.assertEquals('KAM', ws.teamMembers[0].role);
        System.assertEquals('Write', ws.teamMembers[0].access);

        System.assertEquals(1, ws.goals.size());
        System.assertEquals('Grow Rx share', ws.goals[0].title);
        System.assertEquals(100, ws.goals[0].target);
        System.assertEquals(40, ws.goals[0].current);
    }

    @isTest
    static void testExportToPowerPointThrowsNotYetAvailable() {
        Account_Plan__c plan = [SELECT Id FROM Account_Plan__c LIMIT 1];
        Test.startTest();
        Boolean threw = false;
        try {
            AccountPlanController.exportToPowerPoint(plan.Id, 'Default');
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();
        System.assertEquals(true, threw);
    }

    @isTest
    static void testPlanCallInterlink_getLinkGetUnlink() {
        Account_Plan__c plan = [SELECT Id, HCO__c FROM Account_Plan__c LIMIT 1];
        Sciagen_Account__c hcp = [SELECT Id FROM Sciagen_Account__c WHERE Type__c = 'HCP' LIMIT 1];

        Planned_Call__c pc = new Planned_Call__c(
            HCP__c = hcp.Id, Call_Type__c = 'Detailing', Call_DateTime__c = SciagenTestTime.nextBusinessSlot(), Status__c = 'Planned'
        );
        insert pc;
        Call_Visit_Report__c cvr = new Call_Visit_Report__c(
            HCP__c = hcp.Id, Visit_Date__c = Date.today(), Call_Type__c = 'Detailing', Record_Status__c = 'Draft'
        );
        insert cvr;

        Test.startTest();
        // Not yet linked — both are candidates for linking.
        List<AccountPlanController.LinkableCallOption> linkable = AccountPlanController.getLinkableCalls(plan.Id);
        System.assertEquals(2, linkable.size());

        AccountPlanController.linkCallToPlan(pc.Id, 'Planned Call', plan.Id);
        AccountPlanController.linkCallToPlan(cvr.Id, 'Call Visit Report', plan.Id);

        List<AccountPlanController.PlanCallItem> linked = AccountPlanController.getPlanCalls(plan.Id);
        Test.stopTest();

        System.assertEquals(2, linked.size());
        Set<String> kinds = new Set<String>();
        for (AccountPlanController.PlanCallItem item : linked) kinds.add(item.kind);
        System.assert(kinds.contains('Planned Call'));
        System.assert(kinds.contains('Call Visit Report'));

        System.assertEquals(plan.Id, [SELECT Plan__c FROM Planned_Call__c WHERE Id = :pc.Id].Plan__c);
        System.assertEquals(plan.Id, [SELECT Plan__c FROM Call_Visit_Report__c WHERE Id = :cvr.Id].Plan__c);

        AccountPlanController.unlinkCallFromPlan(pc.Id, 'Planned Call');
        AccountPlanController.unlinkCallFromPlan(cvr.Id, 'Call Visit Report');
        System.assertEquals(null, [SELECT Plan__c FROM Planned_Call__c WHERE Id = :pc.Id].Plan__c);
        System.assertEquals(null, [SELECT Plan__c FROM Call_Visit_Report__c WHERE Id = :cvr.Id].Plan__c);
    }

    @isTest
    static void testPlanCallInterlink_unknownKindThrows() {
        Sciagen_Account__c hcp = [SELECT Id FROM Sciagen_Account__c WHERE Type__c = 'HCP' LIMIT 1];
        Planned_Call__c pc = new Planned_Call__c(
            HCP__c = hcp.Id, Call_Type__c = 'Detailing', Call_DateTime__c = SciagenTestTime.nextBusinessSlot(), Status__c = 'Planned'
        );
        insert pc;

        Test.startTest();
        Boolean linkThrew = false;
        try {
            AccountPlanController.linkCallToPlan(pc.Id, 'Something Else', null);
        } catch (AuraHandledException e) {
            linkThrew = true;
        }
        Boolean unlinkThrew = false;
        try {
            AccountPlanController.unlinkCallFromPlan(pc.Id, 'Something Else');
        } catch (AuraHandledException e) {
            unlinkThrew = true;
        }
        Test.stopTest();

        System.assertEquals(true, linkThrew);
        System.assertEquals(true, unlinkThrew);
    }

    @isTest
    static void testGetLinkableCallsThrowsForUnknownPlan() {
        Test.startTest();
        Boolean threw = false;
        try {
            AccountPlanController.getLinkableCalls(UserInfo.getUserId());
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();
        System.assertEquals(true, threw);
    }

    @isTest
    static void testMarkStageCompleteAdvancesAndNoOpsAtFinalStage() {
        Account_Plan__c plan = [SELECT Id FROM Account_Plan__c LIMIT 1];

        Test.startTest();
        String afterFirst = AccountPlanController.markStageComplete(plan.Id);
        System.assertEquals('Early', afterFirst);

        // Drive it all the way to the final stage, then confirm one more call no-ops.
        AccountPlanController.markStageComplete(plan.Id); // Mid
        AccountPlanController.markStageComplete(plan.Id); // Partnership
        String afterFinal = AccountPlanController.markStageComplete(plan.Id); // Synergistic
        System.assertEquals('Synergistic', afterFinal);
        String afterNoOp = AccountPlanController.markStageComplete(plan.Id);
        Test.stopTest();

        System.assertEquals('Synergistic', afterNoOp, 'Stage must not advance past the final value');
    }

    @isTest
    static void testCreateActionItemPersistsAllFields() {
        Plan_Activity__c activity = [SELECT Id FROM Plan_Activity__c WHERE Activity_Name__c = 'Activity One' LIMIT 1];
        Sciagen_Account__c hco = [SELECT Id FROM Sciagen_Account__c LIMIT 1];

        Test.startTest();
        Id newId = AccountPlanController.createActionItem(
            activity.Id, 'New Item', 'In Progress', 'Follow up description',
            Date.today(), Date.today().addDays(14), new List<String>{ 'PSS', 'ODM' }, hco.Id
        );
        Test.stopTest();

        Action_Item__c created = [
            SELECT Title__c, Status__c, Description__c, Start_Date__c, Due_Date__c, Share_With__c, Account__c, Activity__c
            FROM Action_Item__c WHERE Id = :newId
        ];
        System.assertEquals('New Item', created.Title__c);
        System.assertEquals('In Progress', created.Status__c);
        System.assertEquals('Follow up description', created.Description__c);
        System.assertEquals(Date.today(), created.Start_Date__c);
        System.assertEquals(Date.today().addDays(14), created.Due_Date__c);
        System.assertEquals('PSS;ODM', created.Share_With__c);
        System.assertEquals(hco.Id, created.Account__c);
        System.assertEquals(activity.Id, created.Activity__c);
    }

    @isTest
    static void testCreateActionItemThrowsForUnknownActivity() {
        Test.startTest();
        try {
            AccountPlanController.createActionItem(
                UserInfo.getUserId(), 'X', 'Open', null, null, null, new List<String>(), null
            );
            System.assert(false, 'Expected AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @isTest
    static void testGetActivityOptionsScopesToPlanAndFiltersBySearchTerm() {
        Account_Plan__c plan = [SELECT Id FROM Account_Plan__c LIMIT 1];

        Test.startTest();
        List<AccountPlanController.ActivityOption> options = AccountPlanController.getActivityOptions(plan.Id, 'Activity Two');
        Test.stopTest();

        System.assertEquals(1, options.size());
        System.assertEquals('Activity Two', options[0].label);
        System.assertEquals('Strategy One', options[0].strategyName);
    }

    @isTest
    static void testCreateStakeholderInsertsUnderPlan() {
        Account_Plan__c plan = [SELECT Id FROM Account_Plan__c LIMIT 1];

        Test.startTest();
        Id newId = AccountPlanController.createStakeholder(plan.Id, 'New Stakeholder', 'Influencer', 'High', 'Strong');
        Test.stopTest();

        Plan_Stakeholder__c created = [SELECT Stakeholder_Name__c, Role__c, Influence__c, Strength__c, Plan__c FROM Plan_Stakeholder__c WHERE Id = :newId];
        System.assertEquals('New Stakeholder', created.Stakeholder_Name__c);
        System.assertEquals('Influencer', created.Role__c);
        System.assertEquals('High', created.Influence__c);
        System.assertEquals('Strong', created.Strength__c);
        System.assertEquals(plan.Id, created.Plan__c);
    }

    @isTest
    static void testCreateStakeholderThrowsWhenNameBlank() {
        Account_Plan__c plan = [SELECT Id FROM Account_Plan__c LIMIT 1];
        Test.startTest();
        try {
            AccountPlanController.createStakeholder(plan.Id, '', 'Influencer', 'High', 'Strong');
            System.assert(false, 'Expected AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @isTest
    static void testCreateTeamMemberInsertsUnderPlan() {
        Account_Plan__c plan = [SELECT Id FROM Account_Plan__c LIMIT 1];

        Test.startTest();
        Id newId = AccountPlanController.createTeamMember(plan.Id, 'New Member', 'MSL', 'Write');
        Test.stopTest();

        Account_Team_Member__c created = [SELECT Member_Name__c, Role__c, Access__c, Plan__c FROM Account_Team_Member__c WHERE Id = :newId];
        System.assertEquals('New Member', created.Member_Name__c);
        System.assertEquals('MSL', created.Role__c);
        System.assertEquals('Write', created.Access__c);
        System.assertEquals(plan.Id, created.Plan__c);
    }

    @isTest
    static void testCreateGoalInsertsUnderPlan() {
        Account_Plan__c plan = [SELECT Id FROM Account_Plan__c LIMIT 1];

        Test.startTest();
        Id newId = AccountPlanController.createGoal(plan.Id, 'New Goal', 'Visits', 50, 10, 'visits', Date.today().addMonths(6));
        Test.stopTest();

        Plan_Goal__c created = [SELECT Title__c, Metric__c, Target__c, Current__c, Unit__c, Due_Date__c, Plan__c FROM Plan_Goal__c WHERE Id = :newId];
        System.assertEquals('New Goal', created.Title__c);
        System.assertEquals('Visits', created.Metric__c);
        System.assertEquals(50, created.Target__c);
        System.assertEquals(10, created.Current__c);
        System.assertEquals('visits', created.Unit__c);
        System.assertEquals(Date.today().addMonths(6), created.Due_Date__c);
        System.assertEquals(plan.Id, created.Plan__c);
    }

    @isTest
    static void testCreateStrategyInsertsUnderPlanWithShareWith() {
        Account_Plan__c plan = [SELECT Id FROM Account_Plan__c LIMIT 1];

        Test.startTest();
        Id newId = AccountPlanController.createStrategy(plan.Id, 'New Strategy', 'Some detail', new List<String>{ 'NOAD', 'PSS' });
        Test.stopTest();

        Plan_Strategy__c created = [SELECT Strategy_Name__c, Detail__c, Share_With__c, Plan__c FROM Plan_Strategy__c WHERE Id = :newId];
        System.assertEquals('New Strategy', created.Strategy_Name__c);
        System.assertEquals('Some detail', created.Detail__c);
        System.assertEquals('NOAD;PSS', created.Share_With__c);
        System.assertEquals(plan.Id, created.Plan__c);
    }
}