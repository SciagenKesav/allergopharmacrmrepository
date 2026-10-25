@isTest
private class SupportPlanUnlockTest {
    // The agent is built in @testSetup: custom-permission checks do not see an assignment made in the same transaction.
    @testSetup static void setup() {
        Profile admin = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];
        User agent = new User(FirstName = 'Plan', LastName = 'Agent', Alias = 'plagent', Email = 'plan.agent@sciagen-test.invalid',
            Username = 'plan.agent.unlock@sciagen-new-dev.invalid', TimeZoneSidKey = 'Asia/Kolkata', LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US', ProfileId = admin.Id, IsActive = true);
        User rep = new User(FirstName = 'Plan', LastName = 'Rep', Alias = 'planrep', Email = 'plan.rep@sciagen-test.invalid',
            Username = 'plan.rep.unlock@sciagen-new-dev.invalid', TimeZoneSidKey = 'Asia/Kolkata', LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US', ProfileId = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1].Id, IsActive = true);
        insert new List<User>{ agent, rep };
        insert new List<PermissionSetAssignment>{
            new PermissionSetAssignment(AssigneeId = agent.Id, PermissionSetId = [SELECT Id FROM PermissionSet WHERE Name = 'Sciagen_Support_Agent'].Id),
            new PermissionSetAssignment(AssigneeId = agent.Id, PermissionSetId = [SELECT Id FROM PermissionSet WHERE Name = 'Business_Admin_Full_Access'].Id)
        };
    }
    private static User rep() { return [SELECT Id FROM User WHERE Username = 'plan.rep.unlock@sciagen-new-dev.invalid']; }
    private static User agent() { return [SELECT Id FROM User WHERE Username = 'plan.agent.unlock@sciagen-new-dev.invalid']; }
    private static Support_Request__c request(Id planId, String category) {
        Support_Request__c r = new Support_Request__c(Subject__c = 'Please unlock my plan', Category__c = category,
            Description__c = 'Need to change the plan', Requester__c = rep().Id, Monthly_Call_Plan__c = planId, Source__c = 'Web');
        insert r;
        return r;
    }
    private static Id frozenPlan() {
        Monthly_Call_Plan__c p = new Monthly_Call_Plan__c(OwnerId = rep().Id, Month__c = Date.today().toStartOfMonth(), Status__c = 'Frozen',
            Frozen_At__c = Datetime.now(), Plan_Key__c = MonthlyCallPlanService.planKey(rep().Id, Date.today()));
        insert p;
        return p.Id;
    }
    @isTest static void adminUnlocksPlanAndRequestIsAnswered() {
        System.runAs(agent()) {
            Id planId = frozenPlan(); Support_Request__c r = request(planId, MonthlyCallPlanService.CAT_UNLOCK_PLAN);
            System.assertEquals('Frozen', SupportConsoleController.getPlanInfo(r.Id).status);
            SupportConsoleController.unlockPlan(r.Id, 'Segmentation corrections');
            System.assertEquals('Draft', [SELECT Status__c FROM Monthly_Call_Plan__c WHERE Id = :planId].Status__c);
            Support_Request__c after = [SELECT Unlock_Outcome__c, Status__c FROM Support_Request__c WHERE Id = :r.Id];
            System.assertEquals('Unlocked', after.Unlock_Outcome__c); System.assertEquals('Waiting on Rep', after.Status__c);
        }
    }
    @isTest static void reasonIsRequiredAndWrongCategoryRefused() {
        System.runAs(agent()) {
            Id planId = frozenPlan(); Support_Request__c r = request(planId, MonthlyCallPlanService.CAT_UNLOCK_PLAN);
            try { SupportConsoleController.unlockPlan(r.Id, ' '); System.assert(false, 'reason required'); } catch (AuraHandledException e) { System.assert(true); }
            System.assertEquals('Frozen', [SELECT Status__c FROM Monthly_Call_Plan__c WHERE Id = :planId].Status__c);
            Support_Request__c other = request(null, 'Other');
            try { SupportConsoleController.unlockPlan(other.Id, 'why'); System.assert(false, 'wrong category'); } catch (AuraHandledException e) { System.assert(true); }
        }
    }
    @isTest static void adminDeclinesPlanUnlock() {
        System.runAs(agent()) {
            Id planId = frozenPlan(); Support_Request__c r = request(planId, MonthlyCallPlanService.CAT_UNLOCK_PLAN);
            try { SupportConsoleController.declinePlanUnlock(r.Id, ''); System.assert(false, 'reason required'); } catch (AuraHandledException e) { System.assert(true); }
            SupportConsoleController.declinePlanUnlock(r.Id, 'Cut-off passed');
            System.assertEquals('Frozen', [SELECT Status__c FROM Monthly_Call_Plan__c WHERE Id = :planId].Status__c);
            Support_Request__c after = [SELECT Unlock_Outcome__c, Status__c FROM Support_Request__c WHERE Id = :r.Id];
            System.assertEquals('Declined', after.Unlock_Outcome__c); System.assertEquals('Resolved', after.Status__c);
            System.assertEquals(true, SupportConsoleController.getContext().canUnlockPlan);
        }
    }
}