@isTest
private class SciagenAppConfigTest {

    private static Datetime at(Date d, Integer hour) { return Datetime.newInstance(d, Time.newInstance(hour, 0, 0, 0)); }

    /** Next date (after today) that falls on the given weekday name. */
    private static Date next(String weekday) {
        Date d = Date.today().addDays(1);
        while (at(d, 12).format('EEEE') != weekday) d = d.addDays(1);
        return d;
    }

    @isTest static void defaultsWhenBlank() {
        SciagenAppConfig.testRecord = new Sciagen_App_Config__mdt();
        System.assertEquals(9, SciagenAppConfig.dayStartHour());
        System.assertEquals(18, SciagenAppConfig.dayEndHour());
        System.assertEquals(new Set<String>{ 'Sunday' }, SciagenAppConfig.nonWorkingDays());
        System.assertEquals('9:00 AM - 6:00 PM', SciagenAppConfig.callHoursLabel());
        System.assertEquals(30, SciagenAppConfig.plannerCallMinutes());
        System.assertEquals(30, SciagenAppConfig.plannerGapMinutes());
        System.assertEquals(30, SciagenAppConfig.plannerStepMinutes());
        System.assertEquals('Detailing', SciagenAppConfig.plannerDefaultCallType());
        System.assertEquals(1, SciagenAppConfig.planFreezeMinCalls());
        System.assertEquals(14, SciagenAppConfig.planVsActualGraceDays());
        System.assertEquals(10, SciagenAppConfig.followUpCallHour());
        System.assertEquals(SciagenAppConfig.DEFAULT_GROUP_MIRRORED_FIELDS, SciagenAppConfig.groupCallMirroredFields());
        System.assertEquals(14, PlanVsActualService.GRACE_DAYS);
    }

    @isTest static void orgValuesAreUsedAndBadOnesIgnored() {
        SciagenAppConfig.testRecord = new Sciagen_App_Config__mdt(
            Call_Day_Start_Hour__c = 8, Call_Day_End_Hour__c = 20, Non_Working_Days__c = 'saturday, Sunday, Funday',
            Planner_Call_Minutes__c = 45, Planner_Gap_Minutes__c = 0, Planner_Slot_Step_Minutes__c = 15,
            Planner_Default_Call_Type__c = 'Follow-up', Plan_Freeze_Enabled__c = false, Plan_Freeze_Min_Calls__c = 5,
            Allow_Past_Month_Freeze__c = true, Group_Calls_Enabled__c = false, Plan_Vs_Actual_Grace_Days__c = 7,
            Follow_Up_Call_Hour__c = 23, Group_Call_Mirrored_Fields__c = 'Visit_Date__c, Not_A_Field__c, HCP__c, Duration_Min__c');
        System.assertEquals(8, SciagenAppConfig.dayStartHour());
        System.assertEquals(20, SciagenAppConfig.dayEndHour());
        System.assertEquals(new Set<String>{ 'Saturday', 'Sunday' }, SciagenAppConfig.nonWorkingDays());
        System.assertEquals('Saturday or Sunday', SciagenAppConfig.nonWorkingDaysLabel());
        System.assertEquals('8:00 AM - 8:00 PM', SciagenAppConfig.callHoursLabel());
        System.assertEquals(45, SciagenAppConfig.plannerCallMinutes());
        System.assertEquals(0, SciagenAppConfig.plannerGapMinutes());
        System.assertEquals(15, SciagenAppConfig.plannerStepMinutes());
        System.assertEquals('Follow-up', SciagenAppConfig.plannerDefaultCallType());
        System.assertEquals(false, SciagenAppConfig.planFreezeEnabled());
        System.assertEquals(5, SciagenAppConfig.planFreezeMinCalls());
        System.assertEquals(true, SciagenAppConfig.allowPastMonthFreeze());
        System.assertEquals(false, SciagenAppConfig.groupCallsEnabled());
        System.assertEquals(7, SciagenAppConfig.planVsActualGraceDays());
        System.assertEquals(8, SciagenAppConfig.followUpCallHour(), 'outside the call day falls back to the start');
        // Unknown, formula and managed fields are dropped.
        System.assertEquals(new List<String>{ 'Visit_Date__c' }, SciagenAppConfig.groupCallMirroredFields());

        // An impossible window falls back to the defaults as a pair.
        SciagenAppConfig.testRecord = new Sciagen_App_Config__mdt(Call_Day_Start_Hour__c = 19, Call_Day_End_Hour__c = 10);
        System.assertEquals(9, SciagenAppConfig.dayStartHour());
        System.assertEquals(18, SciagenAppConfig.dayEndHour());
    }

    @isTest static void theScheduleGuardFollowsTheSettings() {
        SciagenAppConfig.testRecord = new Sciagen_App_Config__mdt(Call_Day_Start_Hour__c = 9, Call_Day_End_Hour__c = 18,
                                                                 Non_Working_Days__c = 'Saturday,Sunday');
        Planned_Call__c saturday = new Planned_Call__c(Call_DateTime__c = at(next('Saturday'), 11), Call_Type__c = 'Detailing', Status__c = 'Planned');
        // Non-working days are a soft warning on the schedule form now (PlannedCallScheduleGuardService no longer
        // blocks them), so the setting is read correctly but the call itself still saves.
        System.assert(SciagenAppConfig.nonWorkingDays().contains('Saturday'), 'Saturday is a non-working day now');
        Database.SaveResult r = Database.insert(saturday, false);
        System.assert(r.isSuccess(), 'a call on a non-working day is allowed (the form only warns)');

        SciagenAppConfig.testRecord = new Sciagen_App_Config__mdt(Call_Day_Start_Hour__c = 7, Call_Day_End_Hour__c = 18, Non_Working_Days__c = 'Sunday');
        Planned_Call__c early = new Planned_Call__c(Call_DateTime__c = at(next('Monday'), 7), Call_Type__c = 'Detailing', Status__c = 'Planned');
        System.assert(Database.insert(early, false).isSuccess(), '7:00 is inside a 7-18 call day');
    }

    @isTest static void freezeFollowsTheSettings() {
        User rep = SciagenTestUsers.mobileRep('cfgrep');
        Date month = Date.today().toStartOfMonth().addMonths(1);
        SciagenAppConfig.testRecord = new Sciagen_App_Config__mdt(Plan_Freeze_Enabled__c = false);
        MonthlyCallPlanService.FreezeResult off;
        System.runAs(rep) { off = MonthlyCallPlanService.freeze(rep.Id, month); }
        System.assert(!off.success && off.message.contains('turned off'), off.message);

        SciagenAppConfig.testRecord = new Sciagen_App_Config__mdt(Plan_Freeze_Enabled__c = true, Plan_Freeze_Min_Calls__c = 3);
        Date d = month;
        while (at(d, 12).format('EEEE') == 'Sunday') d = d.addDays(1);
        System.runAs(rep) {
            insert new Planned_Call__c(Call_DateTime__c = at(d, 11), Call_Type__c = 'Detailing', Status__c = 'Planned');
        }
        MonthlyCallPlanService.FreezeResult few;
        System.runAs(rep) { few = MonthlyCallPlanService.freeze(rep.Id, month); }
        System.assert(!few.success && few.message.contains('at least 3'), few.message);
    }
}