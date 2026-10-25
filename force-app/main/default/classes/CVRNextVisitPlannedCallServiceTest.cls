@isTest
private class CVRNextVisitPlannedCallServiceTest {

    private static Datetime nearestNonSundayAt(Integer dayOffset, Integer hour) {
        Date d = Date.today().addDays(dayOffset);
        Datetime candidate = Datetime.newInstance(d, Time.newInstance(hour, 0, 0, 0));
        if (candidate.format('EEEE') == 'Sunday') {
            d = d.addDays(1);
        }
        return Datetime.newInstance(d, Time.newInstance(hour, 0, 0, 0));
    }

    private static Date nearestNonSundayDate(Integer dayOffset) {
        return nearestNonSundayAt(dayOffset, 10).date();
    }

    @testSetup
    static void setup() {
        Sciagen_Account__c hcp = new Sciagen_Account__c(
            Type__c = 'HCP', Name = 'Dr. Next Visit Test', Prefix__c = 'Dr.', First_Name__c = 'Next',
            Last_Name__c = 'Visit', Specialty__c = 'Cardiology', HCP_Type__c = 'Physician'
        );
        insert hcp;
    }

    @isTest
    static void settingNextVisitDateCreatesAFollowUpPlannedCall() {
        Sciagen_Account__c hcp = [SELECT Id FROM Sciagen_Account__c LIMIT 1];
        Call_Visit_Report__c cvr = new Call_Visit_Report__c(
            HCP__c = hcp.Id, Visit_Date__c = Date.today(), Call_Type__c = 'Detailing', Record_Status__c = 'Draft'
        );
        insert cvr;

        Test.startTest();
        cvr.Next_Visit_Date__c = nearestNonSundayDate(10);
        update cvr;
        Test.stopTest();

        Call_Visit_Report__c updated = [SELECT Next_Visit_Planned_Call__c FROM Call_Visit_Report__c WHERE Id = :cvr.Id];
        System.assertNotEquals(null, updated.Next_Visit_Planned_Call__c, 'A follow-up Planned Call should be linked back to the CVR');

        Planned_Call__c nextCall = [SELECT HCP__c, Call_Type__c, Status__c, Call_DateTime__c FROM Planned_Call__c WHERE Id = :updated.Next_Visit_Planned_Call__c];
        System.assertEquals(hcp.Id, nextCall.HCP__c);
        System.assertEquals('Detailing', nextCall.Call_Type__c);
        System.assertEquals('Planned', nextCall.Status__c);
        System.assertEquals(cvr.Next_Visit_Date__c, nextCall.Call_DateTime__c.date());
    }

    @isTest
    static void savingTheSameNextVisitDateTwiceDoesNotCreateADuplicateCall() {
        Sciagen_Account__c hcp = [SELECT Id FROM Sciagen_Account__c LIMIT 1];
        Call_Visit_Report__c cvr = new Call_Visit_Report__c(
            HCP__c = hcp.Id, Visit_Date__c = Date.today(), Call_Type__c = 'Detailing', Record_Status__c = 'Draft',
            Next_Visit_Date__c = nearestNonSundayDate(15)
        );
        insert cvr;

        Test.startTest();
        cvr.Pre_Call_Notes__c = 'Unrelated edit, same Next Visit Date';
        update cvr;
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM Planned_Call__c WHERE HCP__c = :hcp.Id], 'Only one follow-up call should ever be created for this CVR');
    }

    @isTest
    static void aRejectedFollowUpCallDoesNotBlockTheCvrSave() {
        Sciagen_Account__c hcp = [SELECT Id FROM Sciagen_Account__c LIMIT 1];
        Call_Visit_Report__c cvr = new Call_Visit_Report__c(
            HCP__c = hcp.Id, Visit_Date__c = Date.today(), Call_Type__c = 'Detailing', Record_Status__c = 'Draft'
        );
        insert cvr;

        // A follow-up dated further back than the backdate limit is rejected by PlannedCallScheduleGuard
        // (non-working days and hours no longer reject it) -- and that rejection must not roll back the CVR
        // update itself.
        PlannedCallScheduleGuardService.testBackdateLimitDays = 1;
        Date sunday = Date.today().addDays(-10);

        Test.startTest();
        cvr.Next_Visit_Date__c = sunday;
        update cvr;
        Test.stopTest();

        Call_Visit_Report__c updated = [SELECT Next_Visit_Date__c, Next_Visit_Planned_Call__c FROM Call_Visit_Report__c WHERE Id = :cvr.Id];
        System.assertEquals(sunday, updated.Next_Visit_Date__c, 'The CVR save must succeed even though the follow-up call was rejected');
        System.assertEquals(null, updated.Next_Visit_Planned_Call__c, 'No follow-up call should be linked when creation was rejected');
    }
}