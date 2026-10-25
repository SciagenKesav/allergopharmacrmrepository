/**
 * Business Admin page "Monthly Plans" (LWC monthlyPlanAdmin): every rep's
 * monthly call plan for a month, the ones with an open unlock request first,
 * and the Unlock action (MonthlyCallPlanService.unlock).
 *
 * Without sharing, behind the Unlock_Monthly_Plans permission (or Modify All
 * Data): the admin must see every rep's plan whatever the role hierarchy.
 */
public without sharing class MonthlyPlanAdminController {

    public class PlanRow {
        @AuraEnabled public Id id;
        @AuraEnabled public String repName;
        @AuraEnabled public String territory;
        @AuraEnabled public String month;
        @AuraEnabled public String status;
        @AuraEnabled public Datetime frozenAt;
        @AuraEnabled public Integer callCount;
        @AuraEnabled public Integer hcpCount;
        @AuraEnabled public Integer emptyDays;
        @AuraEnabled public Integer unlockCount;
        @AuraEnabled public Datetime lastUnlockedAt;
        @AuraEnabled public String lastUnlockedBy;
        @AuraEnabled public String unlockReason;
        @AuraEnabled public Id requestId;
        @AuraEnabled public String requestNumber;
        @AuraEnabled public String requestNote;
        @AuraEnabled public Boolean canUnlock;
    }

    public class PageData {
        @AuraEnabled public Boolean allowed;
        @AuraEnabled public List<PlanRow> plans = new List<PlanRow>();
        @AuraEnabled public Integer frozen = 0;
        @AuraEnabled public Integer draft = 0;
        @AuraEnabled public Integer requested = 0;
    }

    @AuraEnabled(cacheable=false)
    public static PageData getPlans(String monthStart, String search) {
        PageData d = new PageData();
        d.allowed = MonthlyCallPlanService.canUnlock();
        if (!d.allowed) return d;
        Date month = (String.isBlank(monthStart) ? Date.today() : Date.valueOf(monthStart)).toStartOfMonth();
        Boolean past = month < Date.today().toStartOfMonth() && !SciagenAppConfig.allowPastMonthFreeze();
        String term = String.isBlank(search) ? null : '%' + String.escapeSingleQuotes(search.trim()) + '%';

        List<Monthly_Call_Plan__c> plans = term == null
            ? [SELECT Id, OwnerId, Owner.Name, Month__c, Status__c, Frozen_At__c, Frozen_Call_Count__c, Frozen_HCP_Count__c,
                      Working_Days_Without_Calls__c, Unlock_Count__c, Last_Unlocked_At__c, Last_Unlocked_By__r.Name, Unlock_Reason__c
               FROM Monthly_Call_Plan__c WHERE Month__c = :month ORDER BY Owner.Name LIMIT 2000]
            : [SELECT Id, OwnerId, Owner.Name, Month__c, Status__c, Frozen_At__c, Frozen_Call_Count__c, Frozen_HCP_Count__c,
                      Working_Days_Without_Calls__c, Unlock_Count__c, Last_Unlocked_At__c, Last_Unlocked_By__r.Name, Unlock_Reason__c
               FROM Monthly_Call_Plan__c WHERE Month__c = :month AND Owner.Name LIKE :term ORDER BY Owner.Name LIMIT 2000];

        Set<Id> planIds = new Map<Id, Monthly_Call_Plan__c>(plans).keySet();
        Set<Id> owners = new Set<Id>();
        for (Monthly_Call_Plan__c p : plans) owners.add(p.OwnerId);
        Map<Id, Support_Request__c> openRequest = new Map<Id, Support_Request__c>();
        for (Support_Request__c r : [SELECT Id, Name, Subject__c, Monthly_Call_Plan__c FROM Support_Request__c
                                     WHERE Monthly_Call_Plan__c IN :planIds AND Is_Open__c = true
                                     AND Category__c = :MonthlyCallPlanService.CAT_UNLOCK_PLAN ORDER BY CreatedDate]) {
            openRequest.put(r.Monthly_Call_Plan__c, r);
        }
        Map<Id, String> territories = SampleTerritoryService.namesFor(owners);

        List<PlanRow> requested = new List<PlanRow>(), others = new List<PlanRow>();
        for (Monthly_Call_Plan__c p : plans) {
            PlanRow row = new PlanRow();
            row.id = p.Id;
            row.repName = p.Owner.Name;
            row.territory = territories.get(p.OwnerId);
            row.month = Datetime.newInstance(p.Month__c, Time.newInstance(12, 0, 0, 0)).format('MMMM yyyy');
            row.status = p.Status__c;
            row.frozenAt = p.Frozen_At__c;
            row.callCount = toInt(p.Frozen_Call_Count__c);
            row.hcpCount = toInt(p.Frozen_HCP_Count__c);
            row.emptyDays = toInt(p.Working_Days_Without_Calls__c);
            row.unlockCount = toInt(p.Unlock_Count__c);
            row.lastUnlockedAt = p.Last_Unlocked_At__c;
            row.lastUnlockedBy = p.Last_Unlocked_By__r?.Name;
            row.unlockReason = p.Unlock_Reason__c;
            Support_Request__c r = openRequest.get(p.Id);
            if (r != null) { row.requestId = r.Id; row.requestNumber = r.Name; row.requestNote = r.Subject__c; }
            row.canUnlock = p.Status__c == MonthlyCallPlanService.FROZEN && !past;
            if (p.Status__c == MonthlyCallPlanService.FROZEN) d.frozen++; else d.draft++;
            if (r != null) { d.requested++; requested.add(row); } else { others.add(row); }
        }
        d.plans.addAll(requested);
        d.plans.addAll(others);
        return d;
    }

    @AuraEnabled
    public static void unlockPlan(Id planId, String reason) {
        try {
            MonthlyCallPlanService.unlock(planId, reason);
        } catch (MonthlyCallPlanService.UnlockException e) {
            throw new AuraHandledException(e.getMessage());
        } catch (DmlException e) {
            throw new AuraHandledException(e.getDmlMessage(0));
        }
    }

    private static Integer toInt(Decimal d) { return d == null ? 0 : d.intValue(); }
}