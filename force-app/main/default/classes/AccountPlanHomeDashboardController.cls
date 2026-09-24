/**
 * Backend for the standalone KAM Home dashboard tab (kamHomeDashboard LWC) —
 * aggregates across every Account Plan, a different persona from
 * AccountPlanController's single-record workspace.
 *
 * Security: `with sharing` + WITH USER_MODE on every query, matching
 * AccountPlanController's conventions.
 */
public with sharing class AccountPlanHomeDashboardController {

    public class StrategyProgress {
        @AuraEnabled public String planName;
        @AuraEnabled public String strategyName;
        @AuraEnabled public Integer totalActivities;
        @AuraEnabled public Integer completedActivities;
        @AuraEnabled public Decimal progressPercent;
    }

    public class PlanProgress {
        @AuraEnabled public Id planId;
        @AuraEnabled public String planName;
        @AuraEnabled public Integer totalActionItems;
        @AuraEnabled public Integer completedActionItems;
        @AuraEnabled public Decimal progressPercent;
    }

    public class ActivityCount {
        @AuraEnabled public String planName;
        @AuraEnabled public String assignee;
        @AuraEnabled public Integer count;
    }

    public class StatusBucket {
        @AuraEnabled public String bucket;
        @AuraEnabled public Integer count;
    }

    public class HomeDashboardData {
        @AuraEnabled public List<StrategyProgress> strategyProgress;
        @AuraEnabled public List<PlanProgress> planProgress;
        @AuraEnabled public List<ActivityCount> recentActivity;
        @AuraEnabled public List<StatusBucket> teamObjectiveAchievement;
    }

    @AuraEnabled(cacheable=true)
    public static HomeDashboardData getHomeDashboardData() {
        List<Plan_Strategy__c> strategyRecords = [
            SELECT Id, Strategy_Name__c, Plan__c, Plan__r.Plan_Title__c,
                (SELECT Id, Manual_Complete__c,
                    (SELECT Id, Status__c FROM ActionItems__r)
                 FROM Activities__r)
            FROM Plan_Strategy__c
            WITH USER_MODE
        ];

        HomeDashboardData data = new HomeDashboardData();

        // -- 1. Strategy Progress + 2. Plan Progress (built from the same nested load) --
        data.strategyProgress = new List<StrategyProgress>();
        Map<Id, Integer> planTotalActionItems = new Map<Id, Integer>();
        Map<Id, Integer> planCompletedActionItems = new Map<Id, Integer>();
        Map<Id, String> planNames = new Map<Id, String>();

        for (Plan_Strategy__c s : strategyRecords) {
            Id planId = s.Plan__c;
            planNames.put(planId, s.Plan__r != null ? s.Plan__r.Plan_Title__c : null);
            if (!planTotalActionItems.containsKey(planId)) {
                planTotalActionItems.put(planId, 0);
                planCompletedActionItems.put(planId, 0);
            }

            Integer strategyTotalActivities = s.Activities__r.size();
            Integer strategyCompletedActivities = 0;

            for (Plan_Activity__c a : s.Activities__r) {
                Integer activityTotal = a.ActionItems__r.size();
                Integer activityCompleted = 0;
                for (Action_Item__c ai : a.ActionItems__r) {
                    if (ai.Status__c == 'Completed') activityCompleted++;
                }
                Boolean activityComplete = a.Manual_Complete__c || (activityTotal > 0 && activityCompleted == activityTotal);
                if (activityComplete) strategyCompletedActivities++;

                planTotalActionItems.put(planId, planTotalActionItems.get(planId) + activityTotal);
                planCompletedActionItems.put(planId, planCompletedActionItems.get(planId) + activityCompleted);
            }

            StrategyProgress sp = new StrategyProgress();
            sp.planName = s.Plan__r != null ? s.Plan__r.Plan_Title__c : null;
            sp.strategyName = s.Strategy_Name__c;
            sp.totalActivities = strategyTotalActivities;
            sp.completedActivities = strategyCompletedActivities;
            sp.progressPercent = strategyTotalActivities > 0
                ? Decimal.valueOf(strategyCompletedActivities).divide(Decimal.valueOf(strategyTotalActivities), 4) * 100
                : 0;
            data.strategyProgress.add(sp);
        }

        data.planProgress = new List<PlanProgress>();
        for (Id planId : planTotalActionItems.keySet()) {
            Integer total = planTotalActionItems.get(planId);
            Integer completed = planCompletedActionItems.get(planId);
            PlanProgress pp = new PlanProgress();
            pp.planId = planId;
            pp.planName = planNames.get(planId);
            pp.totalActionItems = total;
            pp.completedActionItems = completed;
            pp.progressPercent = total > 0 ? Decimal.valueOf(completed).divide(Decimal.valueOf(total), 4) * 100 : 0;
            data.planProgress.add(pp);
        }

        // -- 3. Key Account Activities (Last 30 Days), grouped by plan + assignee --
        List<Action_Item__c> recentItems = [
            SELECT Assignee__c, Activity__r.Strategy__r.Plan__r.Plan_Title__c
            FROM Action_Item__c
            WHERE CreatedDate = LAST_N_DAYS:30
            WITH USER_MODE
        ];
        Map<String, Integer> recentCounts = new Map<String, Integer>();
        Map<String, String> recentPlanNames = new Map<String, String>();
        Map<String, String> recentAssignees = new Map<String, String>();
        for (Action_Item__c ai : recentItems) {
            String planName = ai.Activity__r?.Strategy__r?.Plan__r != null ? ai.Activity__r.Strategy__r.Plan__r.Plan_Title__c : 'Unknown Plan';
            String assignee = String.isBlank(ai.Assignee__c) ? 'Unassigned' : ai.Assignee__c;
            String key = planName + '|' + assignee;
            recentCounts.put(key, (recentCounts.containsKey(key) ? recentCounts.get(key) : 0) + 1);
            recentPlanNames.put(key, planName);
            recentAssignees.put(key, assignee);
        }
        data.recentActivity = new List<ActivityCount>();
        for (String key : recentCounts.keySet()) {
            ActivityCount ac = new ActivityCount();
            ac.planName = recentPlanNames.get(key);
            ac.assignee = recentAssignees.get(key);
            ac.count = recentCounts.get(key);
            data.recentActivity.add(ac);
        }

        // -- 4. Team Objective Achievement, grouped into the dashboard's 3 buckets --
        List<Action_Item__c> allItems = [SELECT Status__c FROM Action_Item__c WITH USER_MODE];
        Integer inProgressCount = 0;
        Integer postponedCount = 0;
        Integer achievedCount = 0;
        for (Action_Item__c ai : allItems) {
            if (ai.Status__c == 'Completed') {
                achievedCount++;
            } else if (ai.Status__c == 'Postponed') {
                postponedCount++;
            } else {
                inProgressCount++; // Open + In Progress
            }
        }
        data.teamObjectiveAchievement = new List<StatusBucket>();
        data.teamObjectiveAchievement.add(bucket('In Progress', inProgressCount));
        data.teamObjectiveAchievement.add(bucket('Postponed', postponedCount));
        data.teamObjectiveAchievement.add(bucket('Achieved', achievedCount));

        return data;
    }

    private static StatusBucket bucket(String name, Integer count) {
        StatusBucket b = new StatusBucket();
        b.bucket = name;
        b.count = count;
        return b;
    }

    // MARK: - Plan list (kamHomeDashboard's browse/search section — Account
    // Plans live on the KAM Dashboard rather than a separate browser page)

    public class PlanListItem {
        @AuraEnabled public Id id;
        @AuraEnabled public String title;
        @AuraEnabled public String accountName;
        @AuraEnabled public String status;
        @AuraEnabled public String stage;
        @AuraEnabled public String health;
        @AuraEnabled public String ownerName;
        // Added for accountPlanBrowser's table (Account Plans page) — kept on
        // the same PlanListItem/searchAccountPlans kamHomeDashboard already
        // uses rather than a parallel query, so both surfaces stay in sync.
        @AuraEnabled public String hcoName;
        @AuraEnabled public String hcpName;
        @AuraEnabled public String division;
        @AuraEnabled public String appliedProducts;
        @AuraEnabled public String startDate;
        @AuraEnabled public String endDate;
        @AuraEnabled public Integer totalActionItems;
        @AuraEnabled public Integer completedActionItems;
        @AuraEnabled public Integer overdueActionItems;
        @AuraEnabled public Decimal progressPercent;
    }

    // Not cacheable — re-invoked after every search/filter change, same
    // reasoning as RCPAController.searchAudits.
    @AuraEnabled
    public static List<PlanListItem> searchAccountPlans(String searchTerm, String statusFilter, String stageFilter) {
        String term = '%' + String.escapeSingleQuotes(String.isBlank(searchTerm) ? '' : searchTerm) + '%';

        List<String> whereClauses = new List<String>{ 'Plan_Title__c LIKE :term' };
        Map<String, Object> binds = new Map<String, Object>{ 'term' => term };
        if (String.isNotBlank(statusFilter)) {
            whereClauses.add('Status__c = :statusFilter');
            binds.put('statusFilter', statusFilter);
        }
        if (String.isNotBlank(stageFilter)) {
            whereClauses.add('Stage__c = :stageFilter');
            binds.put('stageFilter', stageFilter);
        }

        String query = 'SELECT Id, Plan_Title__c, Status__c, Stage__c, Health__c, Division__c, Applied_Products__c, ' +
            'Start_Date__c, End_Date__c, HCO__r.Name, HCP__r.Name, Owner.Name, ' +
            '(SELECT Id, (SELECT Id, Manual_Complete__c, (SELECT Id, Status__c, Due_Date__c FROM ActionItems__r) FROM Activities__r) FROM Strategies__r) ' +
            'FROM Account_Plan__c WHERE ' + String.join(whereClauses, ' AND ') + ' ORDER BY Plan_Title__c ASC LIMIT 100';

        List<Account_Plan__c> plans = Database.queryWithBinds(query, binds, AccessLevel.USER_MODE);
        List<PlanListItem> items = new List<PlanListItem>();
        for (Account_Plan__c p : plans) {
            PlanListItem item = new PlanListItem();
            item.id = p.Id;
            item.title = p.Plan_Title__c;
            item.accountName = p.HCO__c != null ? p.HCO__r.Name : (p.HCP__c != null ? p.HCP__r.Name : null);
            item.status = p.Status__c;
            item.stage = p.Stage__c;
            item.health = p.Health__c;
            item.ownerName = p.Owner != null ? p.Owner.Name : null;
            item.hcoName = p.HCO__c != null ? p.HCO__r.Name : null;
            item.hcpName = p.HCP__c != null ? p.HCP__r.Name : null;
            item.division = p.Division__c;
            item.appliedProducts = p.Applied_Products__c;
            item.startDate = p.Start_Date__c != null ? p.Start_Date__c.format() : null;
            item.endDate = p.End_Date__c != null ? p.End_Date__c.format() : null;

            Integer total = 0;
            Integer completed = 0;
            Integer overdue = 0;
            Date today = Date.today();
            for (Plan_Strategy__c s : p.Strategies__r) {
                for (Plan_Activity__c a : s.Activities__r) {
                    total += a.ActionItems__r.size();
                    for (Action_Item__c ai : a.ActionItems__r) {
                        if (ai.Status__c == 'Completed') {
                            completed++;
                        } else if (ai.Due_Date__c != null && ai.Due_Date__c < today) {
                            overdue++;
                        }
                    }
                }
            }
            item.totalActionItems = total;
            item.completedActionItems = completed;
            item.overdueActionItems = overdue;
            item.progressPercent = total > 0 ? Decimal.valueOf(completed).divide(Decimal.valueOf(total), 4) * 100 : 0;

            items.add(item);
        }
        return items;
    }
}