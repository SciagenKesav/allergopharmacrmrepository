@isTest
private class MonthlyCallPlanServiceTest {

    private static User rep() { return SciagenTestUsers.mobileRep('mcprep'); }

    /** Next month: always in the future, so every day can be planned. */
    private static Date nextMonth() { return Date.today().toStartOfMonth().addMonths(1); }

    /** 11:00 on the n-th working day (Mon–Sat) of next month. */
    private static Datetime workDay(Integer n) {
        Date d = nextMonth();
        Integer seen = 0;
        while (true) {
            if (Datetime.newInstance(d, Time.newInstance(12, 0, 0, 0)).format('EEEE') != 'Sunday') {
                seen++;
                if (seen == n) return Datetime.newInstance(d, Time.newInstance(11, 0, 0, 0));
            }
            d = d.addDays(1);
        }
        return null;
    }

    private static Sciagen_Account__c doctor(User r, String name) {
        Sciagen_Account__c d;
        System.runAs(r) { d = SampleTestData.doctor(name); }
        return d;
    }

    private static Planned_Call__c plan(User r, Sciagen_Account__c hcp, Datetime at) {
        Planned_Call__c pc = new Planned_Call__c(HCP__c = hcp.Id, Call_DateTime__c = at, Call_Type__c = 'Detailing', Status__c = 'Planned');
        System.runAs(r) { insert pc; }
        return pc;
    }

    private static Planned_Call__c reload(Id id) {
        return [SELECT Id, Call_DateTime__c, Status__c, In_Frozen_Plan__c, Frozen_Call_DateTime__c, Frozen_Call_Type__c,
                       Monthly_Plan__c, Plan_Deviation__c FROM Planned_Call__c WHERE Id = :id];
    }

    private static MonthlyCallPlanService.FreezeResult freeze(User r, Date month) {
        MonthlyCallPlanService.FreezeResult res;
        System.runAs(r) { res = MonthlyCallPlanService.freeze(UserInfo.getUserId(), month); }
        return res;
    }

    @isTest static void freezingStampsTheMonthAsTheBaseline() {
        User r = rep();
        Sciagen_Account__c a = doctor(r, 'Dr Freeze A'), b = doctor(r, 'Dr Freeze B');
        Planned_Call__c c1 = plan(r, a, workDay(1)), c2 = plan(r, b, workDay(2)), c3 = plan(r, a, workDay(3));
        Planned_Call__c other = plan(r, a, SciagenTestTime.nextBusinessSlot());   // another month (this one)

        Test.startTest();
        MonthlyCallPlanService.FreezeResult res = freeze(r, nextMonth().addDays(9));
        Test.stopTest();

        System.assert(res.success, res.message);
        System.assertEquals(3, res.callCount);
        System.assertEquals(2, res.hcpCount);
        Monthly_Call_Plan__c p = [SELECT OwnerId, Month__c, Status__c, Frozen_At__c, Frozen_Call_Count__c, Frozen_HCP_Count__c,
                                         Working_Days_Without_Calls__c, Plan_Key__c FROM Monthly_Call_Plan__c WHERE Id = :res.planId];
        System.assertEquals(r.Id, p.OwnerId, 'the rep owns their plan');
        System.assertEquals(nextMonth(), p.Month__c);
        System.assertEquals('Frozen', p.Status__c);
        System.assertNotEquals(null, p.Frozen_At__c);
        System.assertEquals(res.emptyDays, p.Working_Days_Without_Calls__c.intValue());
        System.assert(res.emptyDays >= 20, 'three planned days out of ~26 working days');

        for (Id id : new List<Id>{ c1.Id, c2.Id, c3.Id }) {
            Planned_Call__c c = reload(id);
            System.assertEquals(true, c.In_Frozen_Plan__c);
            System.assertEquals(c.Call_DateTime__c, c.Frozen_Call_DateTime__c);
            System.assertEquals('Detailing', c.Frozen_Call_Type__c);
            System.assertEquals(p.Id, c.Monthly_Plan__c);
            System.assertEquals(null, c.Plan_Deviation__c);
        }
        System.assertEquals(false, reload(other.Id).In_Frozen_Plan__c, 'other months are untouched');
    }

    @isTest static void aPlanIsFrozenOnceAndNeedsCalls() {
        User r = rep();
        System.assert(!freeze(r, nextMonth()).success, 'an empty month can not be frozen');
        System.assert(!freeze(r, Date.today().toStartOfMonth().addMonths(-1)).success, 'a past month can not be frozen');
        plan(r, doctor(r, 'Dr Freeze C'), workDay(2));
        System.assert(freeze(r, nextMonth()).success);
        MonthlyCallPlanService.FreezeResult again = freeze(r, nextMonth());
        System.assert(!again.success);
        System.assert(again.message.contains('already frozen'), again.message);
        System.assertEquals(1, again.callCount);
    }

    @isTest static void changesAfterTheFreezeAreRecordedAsDeviations() {
        User r = rep();
        Sciagen_Account__c a = doctor(r, 'Dr Freeze D'), b = doctor(r, 'Dr Freeze E');
        Planned_Call__c moved = plan(r, a, workDay(2)), cancelled = plan(r, b, workDay(3)), done = plan(r, a, workDay(4));
        freeze(r, nextMonth());

        Test.startTest();
        System.runAs(r) {
            update new Planned_Call__c(Id = moved.Id, Call_DateTime__c = workDay(5));
            update new Planned_Call__c(Id = cancelled.Id, Status__c = 'Cancelled');
            update new Planned_Call__c(Id = done.Id, Call_DateTime__c = workDay(6), Status__c = 'Completed');
        }
        Planned_Call__c added = plan(r, b, workDay(7));
        Test.stopTest();

        System.assertEquals('Rescheduled', reload(moved.Id).Plan_Deviation__c);
        System.assertEquals(workDay(2), reload(moved.Id).Frozen_Call_DateTime__c, 'the baseline keeps the frozen day');
        System.assertEquals('Cancelled', reload(cancelled.Id).Plan_Deviation__c);
        System.assertEquals('Done on another day', reload(done.Id).Plan_Deviation__c);
        Planned_Call__c a2 = reload(added.Id);
        System.assertEquals('Added after freeze', a2.Plan_Deviation__c);
        System.assertEquals(false, a2.In_Frozen_Plan__c);
        System.assertNotEquals(null, a2.Monthly_Plan__c);

        // Moving back to the frozen day clears the deviation.
        System.runAs(r) { update new Planned_Call__c(Id = moved.Id, Call_DateTime__c = workDay(2)); }
        System.assertEquals(null, reload(moved.Id).Plan_Deviation__c);
    }

    @isTest static void theRepCanNotRewriteTheBaselineOrDeleteAFrozenCall() {
        User r = rep();
        Sciagen_Account__c a = doctor(r, 'Dr Freeze F');
        Planned_Call__c pc = plan(r, a, workDay(2));
        freeze(r, nextMonth());
        Datetime frozenAt = reload(pc.Id).Frozen_Call_DateTime__c;

        System.runAs(r) {
            update new Planned_Call__c(Id = pc.Id, In_Frozen_Plan__c = false, Frozen_Call_DateTime__c = workDay(9),
                                       Plan_Deviation__c = null, Call_DateTime__c = workDay(8));
        }
        Planned_Call__c after = reload(pc.Id);
        System.assertEquals(true, after.In_Frozen_Plan__c, 'baseline restored');
        System.assertEquals(frozenAt, after.Frozen_Call_DateTime__c);
        System.assertEquals('Rescheduled', after.Plan_Deviation__c, 'the deviation is computed, not taken from the client');

        String error;
        System.runAs(r) {
            try { delete new Planned_Call__c(Id = pc.Id); } catch (DmlException e) { error = e.getDmlMessage(0); }
        }
        System.assert(error != null && error.contains('Cancel it instead'), error);

        // A call that isn't in the frozen plan can still be deleted.
        Planned_Call__c extra = plan(r, a, workDay(10));
        System.runAs(r) { delete new Planned_Call__c(Id = extra.Id); }
        System.assertEquals(0, [SELECT COUNT() FROM Planned_Call__c WHERE Id = :extra.Id]);
    }

    @isTest static void newCallInAFrozenMonthStartsAsTheBaselineOnlyThroughFreeze() {
        User r = rep();
        Sciagen_Account__c a = doctor(r, 'Dr Freeze G');
        plan(r, a, workDay(2));
        freeze(r, nextMonth());
        // A client that tries to insert straight into the frozen baseline is ignored.
        Planned_Call__c sneaky = new Planned_Call__c(HCP__c = a.Id, Call_DateTime__c = workDay(3), Call_Type__c = 'Detailing',
            Status__c = 'Planned', In_Frozen_Plan__c = true, Frozen_Call_DateTime__c = workDay(3));
        System.runAs(r) { insert sneaky; }
        Planned_Call__c s = reload(sneaky.Id);
        System.assertEquals(false, s.In_Frozen_Plan__c);
        System.assertEquals(null, s.Frozen_Call_DateTime__c);
        System.assertEquals('Added after freeze', s.Plan_Deviation__c);
    }

    @isTest static void planVsActualMeasuresAFrozenMonthAgainstTheFrozenPlan() {
        User r = rep();
        Sciagen_Account__c a = doctor(r, 'Dr Freeze H');
        plan(r, a, workDay(2));
        plan(r, a, workDay(3));
        freeze(r, nextMonth());
        plan(r, a, workDay(4));   // added after the freeze: not a plan

        Test.startTest();
        PlanVsActualController.Overview o = PlanVsActualController.getOverview(String.valueOf(nextMonth()), null, r.Id);
        Test.stopTest();
        System.assertEquals(2, o.planned, 'only the frozen calls are the plan');
    }

    @isTest static void restEndpointFreezesForTheCallingRep() {
        User r = rep();
        plan(r, doctor(r, 'Dr Freeze I'), workDay(2));
        RestContext.request = new RestRequest();
        RestContext.response = new RestResponse();
        RestContext.request.requestBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{
            'action' => 'freeze', 'month' => String.valueOf(nextMonth()) }));
        System.runAs(r) { MonthlyCallPlanApi.post(); }
        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(RestContext.response.responseBody.toString());
        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals(true, body.get('success'), String.valueOf(body));
        System.assertEquals(1, body.get('callCount'));

        RestContext.request.requestBody = Blob.valueOf('{"action":"thaw","month":"2026-01-01"}');
        System.runAs(r) { MonthlyCallPlanApi.post(); }
        System.assertEquals(400, RestContext.response.statusCode);
        RestContext.request.requestBody = Blob.valueOf('not json');
        System.runAs(r) { MonthlyCallPlanApi.post(); }
        System.assertEquals(400, RestContext.response.statusCode);
    }

    // ------------------------------------------------------------------ unlock by a Business Admin

    private static User businessAdmin() { return SciagenTestUsers.rep('mcpadm', new List<String>{ 'Sciagen_Support_Agent' }); }

    private static Support_Request__c askToUnlock(User r, Id planId) {
        Support_Request__c req = new Support_Request__c(Subject__c = 'Please unlock my October plan', Description__c = 'Doctor moved city',
            Category__c = MonthlyCallPlanService.CAT_UNLOCK_PLAN, Monthly_Call_Plan__c = planId);
        System.runAs(r) { insert req; }
        return req;
    }

    @isTest static void businessAdminUnlocksAndTheRepFreezesAgain() {
        User r = rep();
        User admin = businessAdmin();
        Sciagen_Account__c a = doctor(r, 'Dr Unlock A');
        Planned_Call__c keep = plan(r, a, workDay(2)), drop = plan(r, a, workDay(3));
        Id planId = freeze(r, nextMonth()).planId;
        Support_Request__c req = askToUnlock(r, planId);
        System.assert([SELECT Call_Summary__c FROM Support_Request__c WHERE Id = :req.Id].Call_Summary__c.startsWith('Monthly plan'));

        Test.startTest();
        System.runAs(admin) {
            MonthlyPlanAdminController.PageData d = MonthlyPlanAdminController.getPlans(String.valueOf(nextMonth()), null);
            System.assertEquals(true, d.allowed);
            System.assertEquals(1, d.requested);
            System.assertEquals(planId, d.plans[0].id, 'requested plans come first');
            System.assertEquals(req.Id, d.plans[0].requestId);
            System.assertEquals(true, d.plans[0].canUnlock);
            MonthlyPlanAdminController.unlockPlan(planId, 'Territory change approved');
        }
        Test.stopTest();

        Monthly_Call_Plan__c p = [SELECT Status__c, Unlock_Count__c, Last_Unlocked_By__c, Last_Unlocked_At__c, Unlock_Reason__c
                                  FROM Monthly_Call_Plan__c WHERE Id = :planId];
        System.assertEquals('Draft', p.Status__c);
        System.assertEquals(1, p.Unlock_Count__c);
        System.assertEquals(admin.Id, p.Last_Unlocked_By__c);
        System.assertEquals('Territory change approved', p.Unlock_Reason__c);
        Planned_Call__c k = reload(keep.Id);
        System.assertEquals(false, k.In_Frozen_Plan__c, 'baseline cleared');
        System.assertEquals(null, k.Frozen_Call_DateTime__c);
        System.assertEquals(null, k.Monthly_Plan__c);
        Support_Request__c after = [SELECT Status__c, Unlock_Outcome__c, (SELECT Body__c FROM Comments__r) FROM Support_Request__c WHERE Id = :req.Id];
        System.assertEquals('Waiting on Rep', after.Status__c);
        System.assertEquals('Unlocked', after.Unlock_Outcome__c);

        // The rep changes the plan freely, then freezes it again.
        System.runAs(r) { delete new Planned_Call__c(Id = drop.Id); }
        plan(r, a, workDay(5));
        MonthlyCallPlanService.FreezeResult again = freeze(r, nextMonth());
        System.assert(again.success, again.message);
        System.assertEquals(2, again.callCount);
        System.assertEquals('Resolved', [SELECT Status__c FROM Support_Request__c WHERE Id = :req.Id].Status__c, 'the refreeze closes the request');
        System.assertEquals(true, reload(keep.Id).In_Frozen_Plan__c);
    }

    @isTest static void onlyABusinessAdminCanUnlock() {
        User r = rep();
        plan(r, doctor(r, 'Dr Unlock B'), workDay(2));
        Id planId = freeze(r, nextMonth()).planId;
        String error;
        System.runAs(r) {
            try { MonthlyCallPlanService.unlock(planId, 'please'); } catch (MonthlyCallPlanService.UnlockException e) { error = e.getMessage(); }
            System.assertEquals(false, MonthlyPlanAdminController.getPlans(null, null).allowed);
        }
        System.assert(error != null && error.contains('Business Admin'), error);

        User admin = businessAdmin();
        System.runAs(admin) {
            try { MonthlyCallPlanService.unlock(planId, '  '); error = null; } catch (MonthlyCallPlanService.UnlockException e) { error = e.getMessage(); }
            System.assert(error != null && error.contains('reason'), error);
            MonthlyCallPlanService.unlock(planId, 'ok');
            try { MonthlyPlanAdminController.unlockPlan(planId, 'again'); error = null; } catch (AuraHandledException e) { error = e.getMessage(); }
            System.assertNotEquals(null, error, 'a draft plan can not be unlocked again');
        }
    }

    @isTest static void unlockRequestsAreChecked() {
        User r = rep();
        plan(r, doctor(r, 'Dr Unlock C'), workDay(2));
        String error;
        System.runAs(r) {
            try { insert new Support_Request__c(Subject__c = 'Unlock', Category__c = MonthlyCallPlanService.CAT_UNLOCK_PLAN); }
            catch (DmlException e) { error = e.getDmlMessage(0); }
        }
        System.assert(error != null && error.contains('Choose the monthly plan'), error);

        Id planId = freeze(r, nextMonth()).planId;
        askToUnlock(r, planId);
        error = null;
        System.runAs(r) {
            try { insert new Support_Request__c(Subject__c = 'Again', Category__c = MonthlyCallPlanService.CAT_UNLOCK_PLAN, Monthly_Call_Plan__c = planId); }
            catch (DmlException e) { error = e.getDmlMessage(0); }
        }
        System.assert(error != null && error.contains('already an open request'), error);
    }
}