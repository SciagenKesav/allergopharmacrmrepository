@isTest
private class PlannedCallScheduleGuardTest {

    @TestSetup
    static void setup() {
        insert new Sciagen_Account__c(Name = 'Test Schedule Guard HCP', Type__c = 'HCP');
    }

    // Walks forward from today to the next date matching the given
    // Datetime.format('EEEE') label, so the test never goes stale.
    private static Date nextDateOnWeekday(String weekdayLabel) {
        Date d = Date.today();
        for (Integer i = 0; i < 8; i++) {
            Datetime dt = Datetime.newInstance(d, Time.newInstance(12, 0, 0, 0));
            if (dt.format('EEEE') == weekdayLabel) {
                return d;
            }
            d = d.addDays(1);
        }
        throw new AssertException('Could not find a ' + weekdayLabel + ' within 8 days');
    }

    @isTest
    static void sundayCallIsAllowed() {
        // Sunday used to be a hard block; it is now only a soft warning in the schedule form.
        SciagenAppConfig.testRecord = new Sciagen_App_Config__mdt(
            Call_Day_Start_Hour__c = 9, Call_Day_End_Hour__c = 18, Non_Working_Days__c = 'Sunday'
        );
        Sciagen_Account__c hcp = [SELECT Id FROM Sciagen_Account__c LIMIT 1];
        Date sunday = nextDateOnWeekday('Sunday');
        Planned_Call__c pc = new Planned_Call__c(
            HCP__c = hcp.Id, Call_Type__c = 'Detailing', Status__c = 'Planned',
            Call_DateTime__c = Datetime.newInstance(sunday, Time.newInstance(11, 0, 0, 0))
        );
        insert pc;
        System.assertEquals(1, [SELECT COUNT() FROM Planned_Call__c WHERE Id = :pc.Id], 'A Sunday call must now be saved');
    }

    @isTest
    static void outsideBusinessHoursIsRejected() {
        // The org's live Sciagen App Config can be widened (this org runs a 24-hour call day),
        // so pin the classic 9-18 window here rather than depending on it.
        SciagenAppConfig.testRecord = new Sciagen_App_Config__mdt(
            Call_Day_Start_Hour__c = 9, Call_Day_End_Hour__c = 18, Non_Working_Days__c = 'Sunday'
        );
        Sciagen_Account__c hcp = [SELECT Id FROM Sciagen_Account__c LIMIT 1];
        Date monday = nextDateOnWeekday('Monday');
        Planned_Call__c pc = new Planned_Call__c(
            HCP__c = hcp.Id, Call_Type__c = 'Detailing', Status__c = 'Planned',
            Call_DateTime__c = Datetime.newInstance(monday, Time.newInstance(20, 0, 0, 0))
        );
        try {
            insert pc;
            System.assert(false, 'Expected an 8 PM call to be rejected');
        } catch (DmlException e) {
            System.assert(e.getMessage().contains('business hours'), 'Expected the business-hours error message, got: ' + e.getMessage());
        }
    }

    @isTest
    static void weekdayDuringBusinessHoursIsAllowed() {
        Sciagen_Account__c hcp = [SELECT Id FROM Sciagen_Account__c LIMIT 1];
        Date monday = nextDateOnWeekday('Monday');
        Planned_Call__c pc = new Planned_Call__c(
            HCP__c = hcp.Id, Call_Type__c = 'Detailing', Status__c = 'Planned',
            Call_DateTime__c = Datetime.newInstance(monday, Time.newInstance(11, 0, 0, 0))
        );
        Test.startTest();
        insert pc;
        Test.stopTest();

        System.assertEquals(1, [SELECT Id FROM Planned_Call__c WHERE Id = :pc.Id].size());
    }

    // Walks back from `minDaysBack` days ago until it lands off Sunday, so the
    // date is guaranteed at least that far in the past and never fails the
    // separate non-working-day check.
    private static Date pastWeekday(Integer minDaysBack) {
        Date d = Date.today().addDays(-minDaysBack);
        while (Datetime.newInstance(d, Time.newInstance(12, 0, 0, 0)).format('EEEE') == 'Sunday') {
            d = d.addDays(-1);
        }
        return d;
    }

    @isTest
    static void callDatedBeyondTheBackdateLimitIsRejected() {
        SciagenAppConfig.testRecord = new Sciagen_App_Config__mdt(
            Call_Day_Start_Hour__c = 9, Call_Day_End_Hour__c = 18, Non_Working_Days__c = 'Sunday'
        );
        PlannedCallScheduleGuardService.testBackdateLimitDays = 4;
        Sciagen_Account__c hcp = [SELECT Id FROM Sciagen_Account__c LIMIT 1];
        Planned_Call__c pc = new Planned_Call__c(
            HCP__c = hcp.Id, Call_Type__c = 'Detailing', Status__c = 'Planned',
            Call_DateTime__c = Datetime.newInstance(pastWeekday(10), Time.newInstance(11, 0, 0, 0))
        );
        try {
            insert pc;
            System.assert(false, 'Expected a call dated beyond the backdate limit to be rejected');
        } catch (DmlException e) {
            System.assert(e.getMessage().contains('in the past'), 'Got: ' + e.getMessage());
        }
    }

    @isTest
    static void callDatedWithinTheBackdateLimitIsAllowed() {
        SciagenAppConfig.testRecord = new Sciagen_App_Config__mdt(
            Call_Day_Start_Hour__c = 9, Call_Day_End_Hour__c = 18, Non_Working_Days__c = 'Sunday'
        );
        PlannedCallScheduleGuardService.testBackdateLimitDays = 4;
        Sciagen_Account__c hcp = [SELECT Id FROM Sciagen_Account__c LIMIT 1];
        Planned_Call__c pc = new Planned_Call__c(
            HCP__c = hcp.Id, Call_Type__c = 'Detailing', Status__c = 'Planned',
            Call_DateTime__c = Datetime.newInstance(pastWeekday(2), Time.newInstance(11, 0, 0, 0))
        );
        Test.startTest();
        insert pc;
        Test.stopTest();

        System.assertEquals(1, [SELECT Id FROM Planned_Call__c WHERE Id = :pc.Id].size());
    }

    @isTest
    static void medicalEventOnSundayIsExempt() {
        Sciagen_Account__c hcp = [SELECT Id FROM Sciagen_Account__c LIMIT 1];
        Date sunday = nextDateOnWeekday('Sunday');
        Planned_Call__c pc = new Planned_Call__c(
            HCP__c = hcp.Id, Call_Type__c = 'Detailing', Status__c = 'Planned', Is_Event__c = true,
            Event_Title__c = 'Sunday Symposium',
            Call_DateTime__c = Datetime.newInstance(sunday, Time.newInstance(19, 0, 0, 0))
        );
        Test.startTest();
        insert pc;
        Test.stopTest();

        System.assertEquals(1, [SELECT Id FROM Planned_Call__c WHERE Id = :pc.Id].size());
    }
}