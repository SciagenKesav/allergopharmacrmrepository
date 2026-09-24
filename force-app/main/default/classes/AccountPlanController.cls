/**
 * Backend for the Account Plan (KAM) record-page workspace — one bulk DTO
 * load per record (getPlanWorkspace), plus the Stage stepper's advance
 * action and the New Action Item modal's create/typeahead actions.
 *
 * Hierarchy and progress rollup mirror the iPad app's PlanActivity.isComplete
 * (KAMModels.swift) and Veeva's own KAM progress-calculation convention:
 * bottom-up completion — Action Items roll up into their Activity, Activities
 * roll up into their Strategy, Strategies roll up into the Plan.
 *
 * Security: `with sharing` + WITH USER_MODE on every query, and every
 * bind-variable query is assigned to a List first rather than iterated
 * inline — an inline `for (X : [SELECT ... :bindVar ... WITH USER_MODE])`
 * hit a real platform SOQL-compilation bug ("Variable does not exist:
 * tmpVar1") during the RCPA build; assigning to a List first avoids it.
 */
public with sharing class AccountPlanController {

    private static final List<String> STAGE_SEQUENCE = new List<String>{
        'Prospect', 'Early', 'Mid', 'Partnership', 'Synergistic'
    };

    // MARK: - DTOs

    public class ActionItemDTO {
        @AuraEnabled public Id id;
        @AuraEnabled public String title;
        @AuraEnabled public String description;
        @AuraEnabled public String status;
        @AuraEnabled public String assignee;
        @AuraEnabled public String startDate;
        @AuraEnabled public String dueDate;
        @AuraEnabled public List<String> shareWith;
        @AuraEnabled public Boolean isCompleted;
        @AuraEnabled public String activityName;
        public Date dueDateRaw; // not @AuraEnabled — ISO Date for server-side sorting; dueDate above is display-formatted
    }

    public class ActivityDTO {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String detail;
        @AuraEnabled public Boolean manualComplete;
        @AuraEnabled public List<ActionItemDTO> actionItems;
        @AuraEnabled public Integer totalActionItems;
        @AuraEnabled public Integer completedActionItems;
        @AuraEnabled public Decimal progressPercent;
        @AuraEnabled public Boolean isComplete;
    }

    public class StrategyDTO {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String detail;
        @AuraEnabled public List<String> shareWith;
        @AuraEnabled public List<ActivityDTO> activities;
        @AuraEnabled public Integer totalActivities;
        @AuraEnabled public Integer completedActivities;
        @AuraEnabled public Decimal progressPercent;
    }

    public class StakeholderDTO {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String role;
        @AuraEnabled public String influence;
        @AuraEnabled public String strength;
    }

    public class TeamMemberDTO {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String role;
        @AuraEnabled public String access;
    }

    public class GoalDTO {
        @AuraEnabled public Id id;
        @AuraEnabled public String title;
        @AuraEnabled public String metric;
        @AuraEnabled public Decimal target;
        @AuraEnabled public Decimal current;
        @AuraEnabled public String unit;
        @AuraEnabled public String dueDate;
    }

    public class PlanWorkspace {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String status;
        @AuraEnabled public String stage;
        @AuraEnabled public String nextStage;
        @AuraEnabled public String planType;
        @AuraEnabled public String planRecordType;
        @AuraEnabled public Boolean active;
        @AuraEnabled public Integer numberOfLocations;
        @AuraEnabled public Integer totalEnrollment;
        @AuraEnabled public Decimal totalRevenue;
        @AuraEnabled public String ocmApm;
        @AuraEnabled public String health;
        @AuraEnabled public Boolean medicalEngagementPlan;
        @AuraEnabled public String objective;
        @AuraEnabled public String differentiationStrategy;
        @AuraEnabled public String keyInitiatives;
        @AuraEnabled public String division;
        @AuraEnabled public String startDate;
        @AuraEnabled public String endDate;
        @AuraEnabled public String strengths;
        @AuraEnabled public String weaknesses;
        @AuraEnabled public String opportunities;
        @AuraEnabled public String threats;
        @AuraEnabled public String appliedProducts;
        @AuraEnabled public Id hcoId;
        @AuraEnabled public String hcoName;
        @AuraEnabled public Id hcpId;
        @AuraEnabled public String hcpName;
        @AuraEnabled public String ownerName;
        @AuraEnabled public String createdByName;
        @AuraEnabled public String lastModifiedByName;

        @AuraEnabled public List<StrategyDTO> strategies;
        @AuraEnabled public Integer totalStrategies;
        @AuraEnabled public Integer completedStrategies;
        @AuraEnabled public Decimal strategyProgressPercent;

        @AuraEnabled public Integer totalActivities;
        @AuraEnabled public Integer completedActivities;
        @AuraEnabled public Decimal activityProgressPercent;

        @AuraEnabled public Integer totalActionItems;
        @AuraEnabled public Integer completedActionItems;
        @AuraEnabled public Decimal actionItemProgressPercent;

        @AuraEnabled public List<ActionItemDTO> upcoming;
        @AuraEnabled public List<StakeholderDTO> stakeholders;
        @AuraEnabled public List<TeamMemberDTO> teamMembers;
        @AuraEnabled public List<GoalDTO> goals;
    }

    // MARK: - getPlanWorkspace

    @AuraEnabled
    public static PlanWorkspace getPlanWorkspace(Id planId) {
        List<Account_Plan__c> plans = [
            SELECT Id, Plan_Title__c, Status__c, Stage__c, Type__c, Plan_Record_Type__c, Active__c,
                   Number_of_Locations__c, Total_Enrollment__c, Total_Revenue__c, OCM_APM__c, Health__c,
                   Medical_Engagement_Plan__c, Objective__c, Differentiation_Strategy__c, Key_Initiatives__c,
                   Division__c, Start_Date__c, End_Date__c, Strengths__c, Weaknesses__c, Opportunities__c,
                   Threats__c, Applied_Products__c, HCO__c, HCO__r.Name, HCP__c, HCP__r.Name,
                   Owner.Name, CreatedBy.Name, LastModifiedBy.Name
            FROM Account_Plan__c
            WHERE Id = :planId
            WITH USER_MODE
            LIMIT 1
        ];
        if (plans.isEmpty()) {
            throw new AuraHandledException('Account Plan not found or not accessible.');
        }
        Account_Plan__c plan = plans[0];

        List<Plan_Strategy__c> strategyRecords = [
            SELECT Id, Strategy_Name__c, Detail__c, Share_With__c,
                (SELECT Id, Activity_Name__c, Detail__c, Manual_Complete__c,
                    (SELECT Id, Title__c, Description__c, Status__c, Assignee__c,
                            Start_Date__c, Due_Date__c, Share_With__c
                     FROM ActionItems__r
                     ORDER BY Due_Date__c ASC NULLS LAST)
                 FROM Activities__r
                 ORDER BY CreatedDate ASC)
            FROM Plan_Strategy__c
            WHERE Plan__c = :planId
            WITH USER_MODE
            ORDER BY CreatedDate ASC
        ];

        List<Plan_Stakeholder__c> stakeholderRecords = [
            SELECT Id, Stakeholder_Name__c, Role__c, Influence__c, Strength__c
            FROM Plan_Stakeholder__c
            WHERE Plan__c = :planId
            WITH USER_MODE
            ORDER BY CreatedDate ASC
        ];

        List<Account_Team_Member__c> teamRecords = [
            SELECT Id, Member_Name__c, Role__c, Access__c
            FROM Account_Team_Member__c
            WHERE Plan__c = :planId
            WITH USER_MODE
            ORDER BY CreatedDate ASC
        ];

        List<Plan_Goal__c> goalRecords = [
            SELECT Id, Title__c, Metric__c, Target__c, Current__c, Unit__c, Due_Date__c
            FROM Plan_Goal__c
            WHERE Plan__c = :planId
            WITH USER_MODE
            ORDER BY CreatedDate ASC
        ];

        PlanWorkspace ws = new PlanWorkspace();
        ws.id = plan.Id;
        ws.name = plan.Plan_Title__c;
        ws.status = plan.Status__c;
        // Records created before Stage__c existed have it null — display as the
        // field's own default (Prospect) rather than mis-rendering as "Final Stage".
        ws.stage = String.isBlank(plan.Stage__c) ? STAGE_SEQUENCE[0] : plan.Stage__c;
        Integer stageIndex = STAGE_SEQUENCE.indexOf(ws.stage);
        ws.nextStage = (stageIndex >= 0 && stageIndex < STAGE_SEQUENCE.size() - 1)
            ? STAGE_SEQUENCE[stageIndex + 1] : null;
        ws.planType = plan.Type__c;
        ws.planRecordType = plan.Plan_Record_Type__c;
        ws.active = plan.Active__c;
        ws.numberOfLocations = plan.Number_of_Locations__c != null ? plan.Number_of_Locations__c.intValue() : null;
        ws.totalEnrollment = plan.Total_Enrollment__c != null ? plan.Total_Enrollment__c.intValue() : null;
        ws.totalRevenue = plan.Total_Revenue__c;
        ws.ocmApm = plan.OCM_APM__c;
        ws.health = plan.Health__c;
        ws.medicalEngagementPlan = plan.Medical_Engagement_Plan__c;
        ws.objective = plan.Objective__c;
        ws.differentiationStrategy = plan.Differentiation_Strategy__c;
        ws.keyInitiatives = plan.Key_Initiatives__c;
        ws.division = plan.Division__c;
        ws.startDate = plan.Start_Date__c != null ? plan.Start_Date__c.format() : null;
        ws.endDate = plan.End_Date__c != null ? plan.End_Date__c.format() : null;
        ws.strengths = plan.Strengths__c;
        ws.weaknesses = plan.Weaknesses__c;
        ws.opportunities = plan.Opportunities__c;
        ws.threats = plan.Threats__c;
        ws.appliedProducts = plan.Applied_Products__c;
        ws.hcoId = plan.HCO__c;
        ws.hcoName = plan.HCO__r != null ? plan.HCO__r.Name : null;
        ws.hcpId = plan.HCP__c;
        ws.hcpName = plan.HCP__r != null ? plan.HCP__r.Name : null;
        ws.ownerName = plan.Owner != null ? plan.Owner.Name : null;
        ws.createdByName = plan.CreatedBy != null ? plan.CreatedBy.Name : null;
        ws.lastModifiedByName = plan.LastModifiedBy != null ? plan.LastModifiedBy.Name : null;

        List<ActionItemDTO> allActionItems = new List<ActionItemDTO>();
        List<StrategyDTO> strategies = new List<StrategyDTO>();
        Integer completedStrategyCount = 0;
        Integer totalActivityCount = 0;
        Integer completedActivityCount = 0;

        for (Plan_Strategy__c s : strategyRecords) {
            StrategyDTO sDto = new StrategyDTO();
            sDto.id = s.Id;
            sDto.name = s.Strategy_Name__c;
            sDto.detail = s.Detail__c;
            sDto.shareWith = String.isBlank(s.Share_With__c) ? new List<String>() : s.Share_With__c.split(';');
            sDto.activities = new List<ActivityDTO>();

            Integer strategyActivityCount = s.Activities__r.size();
            Integer strategyCompletedActivityCount = 0;

            for (Plan_Activity__c a : s.Activities__r) {
                ActivityDTO aDto = new ActivityDTO();
                aDto.id = a.Id;
                aDto.name = a.Activity_Name__c;
                aDto.detail = a.Detail__c;
                aDto.manualComplete = a.Manual_Complete__c;
                aDto.actionItems = new List<ActionItemDTO>();

                Integer activityActionItemCount = a.ActionItems__r.size();
                Integer activityCompletedActionItemCount = 0;

                for (Action_Item__c ai : a.ActionItems__r) {
                    ActionItemDTO aiDto = new ActionItemDTO();
                    aiDto.id = ai.Id;
                    aiDto.title = ai.Title__c;
                    aiDto.description = ai.Description__c;
                    aiDto.status = ai.Status__c;
                    aiDto.assignee = ai.Assignee__c;
                    aiDto.startDate = ai.Start_Date__c != null ? ai.Start_Date__c.format() : null;
                    aiDto.dueDate = ai.Due_Date__c != null ? ai.Due_Date__c.format() : null;
                    aiDto.dueDateRaw = ai.Due_Date__c;
                    aiDto.shareWith = String.isBlank(ai.Share_With__c) ? new List<String>() : ai.Share_With__c.split(';');
                    aiDto.isCompleted = ai.Status__c == 'Completed';
                    aiDto.activityName = a.Activity_Name__c;
                    if (aiDto.isCompleted) activityCompletedActionItemCount++;
                    aDto.actionItems.add(aiDto);
                    allActionItems.add(aiDto);
                }

                aDto.totalActionItems = activityActionItemCount;
                aDto.completedActionItems = activityCompletedActionItemCount;
                aDto.progressPercent = activityActionItemCount > 0
                    ? Decimal.valueOf(activityCompletedActionItemCount).divide(Decimal.valueOf(activityActionItemCount), 4) * 100
                    : 0;
                aDto.isComplete = a.Manual_Complete__c
                    || (activityActionItemCount > 0 && activityCompletedActionItemCount == activityActionItemCount);
                if (aDto.isComplete) strategyCompletedActivityCount++;

                sDto.activities.add(aDto);
            }

            sDto.totalActivities = strategyActivityCount;
            sDto.completedActivities = strategyCompletedActivityCount;
            sDto.progressPercent = strategyActivityCount > 0
                ? Decimal.valueOf(strategyCompletedActivityCount).divide(Decimal.valueOf(strategyActivityCount), 4) * 100
                : 0;

            Boolean strategyComplete = strategyActivityCount > 0 && strategyCompletedActivityCount == strategyActivityCount;
            if (strategyComplete) completedStrategyCount++;

            totalActivityCount += strategyActivityCount;
            completedActivityCount += strategyCompletedActivityCount;

            strategies.add(sDto);
        }

        ws.strategies = strategies;
        ws.totalStrategies = strategies.size();
        ws.completedStrategies = completedStrategyCount;
        ws.strategyProgressPercent = strategies.size() > 0
            ? Decimal.valueOf(completedStrategyCount).divide(Decimal.valueOf(strategies.size()), 4) * 100
            : 0;

        ws.totalActivities = totalActivityCount;
        ws.completedActivities = completedActivityCount;
        ws.activityProgressPercent = totalActivityCount > 0
            ? Decimal.valueOf(completedActivityCount).divide(Decimal.valueOf(totalActivityCount), 4) * 100
            : 0;

        Integer completedActionItemCount = 0;
        for (ActionItemDTO ai : allActionItems) if (ai.isCompleted) completedActionItemCount++;
        ws.totalActionItems = allActionItems.size();
        ws.completedActionItems = completedActionItemCount;
        ws.actionItemProgressPercent = allActionItems.size() > 0
            ? Decimal.valueOf(completedActionItemCount).divide(Decimal.valueOf(allActionItems.size()), 4) * 100
            : 0;

        // Upcoming(3): not completed, has a due date that isn't in the past, soonest first.
        List<ActionItemDTO> upcomingCandidates = new List<ActionItemDTO>();
        Date today = Date.today();
        for (ActionItemDTO ai : allActionItems) {
            if (ai.isCompleted || ai.dueDateRaw == null) continue;
            if (ai.dueDateRaw >= today) upcomingCandidates.add(ai);
        }
        upcomingCandidates.sort(new ActionItemDueDateComparator());
        ws.upcoming = new List<ActionItemDTO>();
        for (Integer i = 0; i < Math.min(3, upcomingCandidates.size()); i++) {
            ws.upcoming.add(upcomingCandidates[i]);
        }

        ws.stakeholders = new List<StakeholderDTO>();
        for (Plan_Stakeholder__c st : stakeholderRecords) {
            StakeholderDTO dto = new StakeholderDTO();
            dto.id = st.Id;
            dto.name = st.Stakeholder_Name__c;
            dto.role = st.Role__c;
            dto.influence = st.Influence__c;
            dto.strength = st.Strength__c;
            ws.stakeholders.add(dto);
        }

        ws.teamMembers = new List<TeamMemberDTO>();
        for (Account_Team_Member__c tm : teamRecords) {
            TeamMemberDTO dto = new TeamMemberDTO();
            dto.id = tm.Id;
            dto.name = tm.Member_Name__c;
            dto.role = tm.Role__c;
            dto.access = tm.Access__c;
            ws.teamMembers.add(dto);
        }

        ws.goals = new List<GoalDTO>();
        for (Plan_Goal__c g : goalRecords) {
            GoalDTO dto = new GoalDTO();
            dto.id = g.Id;
            dto.title = g.Title__c;
            dto.metric = g.Metric__c;
            dto.target = g.Target__c;
            dto.current = g.Current__c;
            dto.unit = g.Unit__c;
            dto.dueDate = g.Due_Date__c != null ? g.Due_Date__c.format() : null;
            ws.goals.add(dto);
        }

        return ws;
    }

    private class ActionItemDueDateComparator implements Comparator<ActionItemDTO> {
        public Integer compare(ActionItemDTO a, ActionItemDTO b) {
            if (a.dueDateRaw == b.dueDateRaw) return 0;
            return a.dueDateRaw < b.dueDateRaw ? -1 : 1;
        }
    }

    // MARK: - Stage stepper

    @AuraEnabled
    public static String markStageComplete(Id planId) {
        List<Account_Plan__c> plans = [SELECT Id, Stage__c FROM Account_Plan__c WHERE Id = :planId WITH USER_MODE LIMIT 1];
        if (plans.isEmpty()) {
            throw new AuraHandledException('Account Plan not found or not accessible.');
        }
        Account_Plan__c plan = plans[0];
        // A null Stage__c (records created before the field existed) is treated as
        // the field's own default (Prospect), matching getPlanWorkspace's display logic.
        String effectiveStage = String.isBlank(plan.Stage__c) ? STAGE_SEQUENCE[0] : plan.Stage__c;
        Integer currentIndex = STAGE_SEQUENCE.indexOf(effectiveStage);
        if (currentIndex < 0 || currentIndex >= STAGE_SEQUENCE.size() - 1) {
            return effectiveStage; // already at (or past) the final stage — no-op
        }
        plan.Stage__c = STAGE_SEQUENCE[currentIndex + 1];
        update plan;
        return plan.Stage__c;
    }

    // MARK: - New Action Item modal

    @AuraEnabled
    public static Id createActionItem(Id activityId, String title, String status, String description,
                                       Date startDate, Date dueDate, List<String> shareWith, Id accountId) {
        List<Plan_Activity__c> activities = [SELECT Id FROM Plan_Activity__c WHERE Id = :activityId WITH USER_MODE LIMIT 1];
        if (activities.isEmpty()) {
            throw new AuraHandledException('Account Tactic not found or not accessible.');
        }
        if (accountId != null) {
            List<Sciagen_Account__c> accounts = [SELECT Id FROM Sciagen_Account__c WHERE Id = :accountId WITH USER_MODE LIMIT 1];
            if (accounts.isEmpty()) {
                throw new AuraHandledException('Account not found or not accessible.');
            }
        }
        Action_Item__c item = new Action_Item__c(
            Activity__c = activityId,
            Title__c = title,
            Status__c = String.isBlank(status) ? 'Open' : status,
            Description__c = description,
            Start_Date__c = startDate,
            Due_Date__c = dueDate,
            Share_With__c = (shareWith != null && !shareWith.isEmpty()) ? String.join(shareWith, ';') : null,
            Account__c = accountId
        );
        insert item;
        return item.Id;
    }

    public class ActivityOption {
        @AuraEnabled public Id id;
        @AuraEnabled public String label;
        @AuraEnabled public String strategyName;
    }

    @AuraEnabled(cacheable=true)
    public static List<ActivityOption> getActivityOptions(Id planId, String searchTerm) {
        String term = '%' + String.escapeSingleQuotes(String.isBlank(searchTerm) ? '' : searchTerm) + '%';
        List<Plan_Activity__c> activities = [
            SELECT Id, Activity_Name__c, Strategy__r.Strategy_Name__c
            FROM Plan_Activity__c
            WHERE Strategy__r.Plan__c = :planId AND Activity_Name__c LIKE :term
            WITH USER_MODE
            ORDER BY Activity_Name__c ASC
            LIMIT 25
        ];
        List<ActivityOption> options = new List<ActivityOption>();
        for (Plan_Activity__c a : activities) {
            ActivityOption o = new ActivityOption();
            o.id = a.Id;
            o.label = a.Activity_Name__c;
            o.strategyName = a.Strategy__r != null ? a.Strategy__r.Strategy_Name__c : null;
            options.add(o);
        }
        return options;
    }

    // MARK: - Applied Products typeahead (New Account Plan modal)

    public class ProductOption {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String brand;
    }

    @AuraEnabled(cacheable=true)
    public static List<ProductOption> getProductOptions(String searchTerm) {
        String term = '%' + String.escapeSingleQuotes(String.isBlank(searchTerm) ? '' : searchTerm) + '%';
        List<Product__c> products = [
            SELECT Id, Name, Brand_Name__c
            FROM Product__c
            WHERE Name LIKE :term AND Active__c = true
            WITH USER_MODE
            ORDER BY Name ASC
            LIMIT 25
        ];
        List<ProductOption> options = new List<ProductOption>();
        for (Product__c p : products) {
            ProductOption o = new ProductOption();
            o.id = p.Id;
            o.name = p.Name;
            o.brand = p.Brand_Name__c;
            options.add(o);
        }
        return options;
    }

    // MARK: - HCP typeahead, scoped to the selected HCO (New Account Plan modal)
    //
    // HCP__c's own lookup filter already restricts it to Type__c = 'HCP'
    // accounts, but that's org-wide — the New Account Plan modal wants the
    // HCP search to further narrow to only HCPs actually affiliated with the
    // HCO already chosen on the same form, via the Affiliation__c junction
    // (same HCO -> HCP traversal as getLinkableCalls above).

    public class HcpOption {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
    }

    @AuraEnabled(cacheable=true)
    public static List<HcpOption> getHcpOptionsForHco(Id hcoId, String searchTerm) {
        List<HcpOption> options = new List<HcpOption>();
        if (hcoId == null) {
            return options;
        }

        Set<Id> hcpIds = new Set<Id>();
        List<Affiliation__c> affiliations = [
            SELECT HCP__c FROM Affiliation__c WHERE HCO__c = :hcoId AND HCP__c != null WITH USER_MODE
        ];
        for (Affiliation__c a : affiliations) {
            hcpIds.add(a.HCP__c);
        }
        if (hcpIds.isEmpty()) {
            return options;
        }

        String term = '%' + String.escapeSingleQuotes(String.isBlank(searchTerm) ? '' : searchTerm) + '%';
        List<Sciagen_Account__c> hcps = [
            SELECT Id, Name
            FROM Sciagen_Account__c
            WHERE Id IN :hcpIds AND Name LIKE :term
            WITH USER_MODE
            ORDER BY Name ASC
            LIMIT 25
        ];
        for (Sciagen_Account__c hcp : hcps) {
            HcpOption o = new HcpOption();
            o.id = hcp.Id;
            o.name = hcp.Name;
            options.add(o);
        }
        return options;
    }

    // MARK: - Export to PowerPoint (UI shell only — see the Account Plan plan doc;
    // real template-token PPTX generation is an explicit follow-on, not part of this build)

    @AuraEnabled
    public static void exportToPowerPoint(Id planId, String templateName) {
        throw new AuraHandledException('Export to PowerPoint isn’t available yet — this is coming in a future release.');
    }

    // MARK: - Plan Calls (Planned_Call__c + Call_Visit_Report__c interlink)
    //
    // Mirrors the iPad app's AssociateCallSheet — a rep can link an existing
    // Planned Call or Call Visit Report to this Account Plan, and this section
    // shows every call already linked. Both objects have their own optional
    // Plan__c lookup (Call_Visit_Report__c's already existed; Planned_Call__c's
    // was added alongside this work).

    public class PlanCallItem {
        @AuraEnabled public Id id;
        @AuraEnabled public String kind; // 'Planned Call' or 'Call Visit Report'
        @AuraEnabled public String accountName;
        @AuraEnabled public String callType;
        @AuraEnabled public String dateLabel;
        @AuraEnabled public String status;
    }

    @AuraEnabled
    public static List<PlanCallItem> getPlanCalls(Id planId) {
        List<PlanCallItem> items = new List<PlanCallItem>();

        List<Planned_Call__c> plannedCalls = [
            SELECT Id, HCP__r.Name, HCO__r.Name, Call_Type__c, Call_DateTime__c, Status__c
            FROM Planned_Call__c
            WHERE Plan__c = :planId
            WITH USER_MODE
            ORDER BY Call_DateTime__c DESC
        ];
        for (Planned_Call__c pc : plannedCalls) {
            PlanCallItem item = new PlanCallItem();
            item.id = pc.Id;
            item.kind = 'Planned Call';
            item.accountName = pc.HCP__r != null ? pc.HCP__r.Name : (pc.HCO__r != null ? pc.HCO__r.Name : null);
            item.callType = pc.Call_Type__c;
            item.dateLabel = pc.Call_DateTime__c != null ? pc.Call_DateTime__c.format() : null;
            item.status = pc.Status__c;
            items.add(item);
        }

        List<Call_Visit_Report__c> visitReports = [
            SELECT Id, HCP__r.Name, HCO__r.Name, Call_Type__c, Visit_Date__c, Record_Status__c
            FROM Call_Visit_Report__c
            WHERE Plan__c = :planId
            WITH USER_MODE
            ORDER BY Visit_Date__c DESC
        ];
        for (Call_Visit_Report__c cvr : visitReports) {
            PlanCallItem item = new PlanCallItem();
            item.id = cvr.Id;
            item.kind = 'Call Visit Report';
            item.accountName = cvr.HCP__r != null ? cvr.HCP__r.Name : (cvr.HCO__r != null ? cvr.HCO__r.Name : null);
            item.callType = cvr.Call_Type__c;
            item.dateLabel = cvr.Visit_Date__c != null ? cvr.Visit_Date__c.format() : null;
            item.status = cvr.Record_Status__c;
            items.add(item);
        }

        return items;
    }

    public class LinkableCallOption {
        @AuraEnabled public Id id;
        @AuraEnabled public String kind; // 'Planned Call' or 'Call Visit Report'
        @AuraEnabled public String label;
        @AuraEnabled public String subLabel;
    }

    @AuraEnabled
    public static List<LinkableCallOption> getLinkableCalls(Id planId) {
        List<Account_Plan__c> plans = [SELECT Id, HCO__c, HCP__c FROM Account_Plan__c WHERE Id = :planId WITH USER_MODE LIMIT 1];
        if (plans.isEmpty()) {
            throw new AuraHandledException('Account Plan not found or not accessible.');
        }
        Account_Plan__c plan = plans[0];

        Set<Id> hcpIds = new Set<Id>();
        Set<Id> hcoIds = new Set<Id>();
        if (plan.HCP__c != null) hcpIds.add(plan.HCP__c);
        if (plan.HCO__c != null) {
            hcoIds.add(plan.HCO__c);
            List<Affiliation__c> affiliations = [
                SELECT HCP__c FROM Affiliation__c WHERE HCO__c = :plan.HCO__c WITH USER_MODE
            ];
            for (Affiliation__c a : affiliations) {
                if (a.HCP__c != null) hcpIds.add(a.HCP__c);
            }
        }

        List<LinkableCallOption> options = new List<LinkableCallOption>();

        List<Planned_Call__c> plannedCalls = [
            SELECT Id, HCP__r.Name, HCO__r.Name, Call_Type__c, Call_DateTime__c
            FROM Planned_Call__c
            WHERE Plan__c = null AND (HCP__c IN :hcpIds OR HCO__c IN :hcoIds)
            WITH USER_MODE
            ORDER BY Call_DateTime__c DESC
            LIMIT 50
        ];
        for (Planned_Call__c pc : plannedCalls) {
            LinkableCallOption o = new LinkableCallOption();
            o.id = pc.Id;
            o.kind = 'Planned Call';
            o.label = pc.HCP__r != null ? pc.HCP__r.Name : (pc.HCO__r != null ? pc.HCO__r.Name : 'Unknown');
            o.subLabel = (pc.Call_Type__c != null ? pc.Call_Type__c + ' · ' : '') +
                (pc.Call_DateTime__c != null ? pc.Call_DateTime__c.format() : '');
            options.add(o);
        }

        List<Call_Visit_Report__c> visitReports = [
            SELECT Id, HCP__r.Name, HCO__r.Name, Call_Type__c, Visit_Date__c
            FROM Call_Visit_Report__c
            WHERE Plan__c = null AND (HCP__c IN :hcpIds OR HCO__c IN :hcoIds)
            WITH USER_MODE
            ORDER BY Visit_Date__c DESC
            LIMIT 50
        ];
        for (Call_Visit_Report__c cvr : visitReports) {
            LinkableCallOption o = new LinkableCallOption();
            o.id = cvr.Id;
            o.kind = 'Call Visit Report';
            o.label = cvr.HCP__r != null ? cvr.HCP__r.Name : (cvr.HCO__r != null ? cvr.HCO__r.Name : 'Unknown');
            o.subLabel = (cvr.Call_Type__c != null ? cvr.Call_Type__c + ' · ' : '') +
                (cvr.Visit_Date__c != null ? cvr.Visit_Date__c.format() : '');
            options.add(o);
        }

        return options;
    }

    @AuraEnabled
    public static void linkCallToPlan(Id callId, String kind, Id planId) {
        if (kind == 'Planned Call') {
            update new Planned_Call__c(Id = callId, Plan__c = planId);
        } else if (kind == 'Call Visit Report') {
            update new Call_Visit_Report__c(Id = callId, Plan__c = planId);
        } else {
            throw new AuraHandledException('Unknown call kind: ' + kind);
        }
    }

    @AuraEnabled
    public static void unlinkCallFromPlan(Id callId, String kind) {
        if (kind == 'Planned Call') {
            update new Planned_Call__c(Id = callId, Plan__c = null);
        } else if (kind == 'Call Visit Report') {
            update new Call_Visit_Report__c(Id = callId, Plan__c = null);
        } else {
            throw new AuraHandledException('Unknown call kind: ' + kind);
        }
    }
}