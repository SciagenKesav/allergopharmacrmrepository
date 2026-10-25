@isTest
private class CVRPlannedCallLinkServiceTest {

    private static Datetime nearestNonSundayAt(Integer dayOffset, Integer hour) {
        Date d = Date.today().addDays(dayOffset);
        Datetime candidate = Datetime.newInstance(d, Time.newInstance(hour, 0, 0, 0));
        if (candidate.format('EEEE') == 'Sunday') {
            d = d.addDays(1);
        }
        return Datetime.newInstance(d, Time.newInstance(hour, 0, 0, 0));
    }

    @testSetup
    static void setup() {
        Sciagen_Account__c hcp = new Sciagen_Account__c(
            Type__c = 'HCP', Name = 'Dr. Link Test', Prefix__c = 'Dr.', First_Name__c = 'Link',
            Last_Name__c = 'Test', Specialty__c = 'Cardiology', HCP_Type__c = 'Physician'
        );
        insert hcp;
        insert new Planned_Call__c(
            HCP__c = hcp.Id, Call_DateTime__c = nearestNonSundayAt(1, 11), Duration_Min__c = 30,
            Call_Type__c = 'Detailing', Status__c = 'Planned'
        );
    }

    private static Call_Visit_Report__c newCvr(Id hcpId, Id sourceCallId, String status) {
        return new Call_Visit_Report__c(
            HCP__c = hcpId, Visit_Date__c = Date.today(), Call_Type__c = 'Detailing',
            Record_Status__c = status, Source_Planned_Call__c = sourceCallId
        );
    }

    @isTest
    static void aReportPointsItsPlannedCallBackAtIt() {
        Planned_Call__c pc = [SELECT Id, HCP__c FROM Planned_Call__c LIMIT 1];
        Call_Visit_Report__c cvr = newCvr(pc.HCP__c, pc.Id, 'Draft');

        Test.startTest();
        insert cvr;
        Test.stopTest();

        Planned_Call__c after = [SELECT Resulting_CVR__c, Status__c FROM Planned_Call__c WHERE Id = :pc.Id];
        System.assertEquals(cvr.Id, after.Resulting_CVR__c, 'The planned call must link to the report created from it');
        System.assertEquals('Planned', after.Status__c, 'A draft report must not complete the planned call');
    }

    @isTest
    static void submittingTheReportCompletesThePlannedCall() {
        Planned_Call__c pc = [SELECT Id, HCP__c FROM Planned_Call__c LIMIT 1];
        Call_Visit_Report__c cvr = newCvr(pc.HCP__c, pc.Id, 'Draft');
        insert cvr;

        Test.startTest();
        cvr.Record_Status__c = 'Submitted';
        update cvr;
        Test.stopTest();

        Planned_Call__c after = [SELECT Resulting_CVR__c, Status__c FROM Planned_Call__c WHERE Id = :pc.Id];
        System.assertEquals(cvr.Id, after.Resulting_CVR__c);
        System.assertEquals('Completed', after.Status__c, 'A submitted report completes its still-Planned call');
    }

    @isTest
    static void aSecondReportNeverReplacesTheExistingLink() {
        Planned_Call__c pc = [SELECT Id, HCP__c FROM Planned_Call__c LIMIT 1];
        Call_Visit_Report__c first = newCvr(pc.HCP__c, pc.Id, 'Draft');
        insert first;

        Test.startTest();
        insert newCvr(pc.HCP__c, pc.Id, 'Draft');
        Test.stopTest();

        System.assertEquals(first.Id, [SELECT Resulting_CVR__c FROM Planned_Call__c WHERE Id = :pc.Id].Resulting_CVR__c,
            'A call that already points at a report must not be re-pointed');
    }

    @isTest
    static void aReportWithNoPlannedCallIsLeftAlone() {
        Planned_Call__c pc = [SELECT Id, HCP__c FROM Planned_Call__c LIMIT 1];

        Test.startTest();
        insert newCvr(pc.HCP__c, null, 'Submitted');
        Test.stopTest();

        Planned_Call__c after = [SELECT Resulting_CVR__c, Status__c FROM Planned_Call__c WHERE Id = :pc.Id];
        System.assertEquals(null, after.Resulting_CVR__c);
        System.assertEquals('Planned', after.Status__c);
    }
}