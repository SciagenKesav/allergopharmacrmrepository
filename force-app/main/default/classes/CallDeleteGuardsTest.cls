@isTest
private class CallDeleteGuardsTest {

    @TestSetup
    static void setup() {
        insert new Sciagen_Account__c(Name = 'Test Delete Guard HCP', Type__c = 'HCP');
    }

    @isTest
    static void submittedCallVisitReportCannotBeDeleted() {
        Sciagen_Account__c hcp = [SELECT Id FROM Sciagen_Account__c LIMIT 1];
        Call_Visit_Report__c cvr = new Call_Visit_Report__c(
            HCP__c = hcp.Id, Visit_Date__c = Date.today(), Call_Type__c = 'Detailing', Record_Status__c = 'Submitted'
        );
        insert cvr;

        Test.startTest();
        try {
            delete cvr;
            System.assert(false, 'Expected deleting a Submitted Call Visit Report to be blocked');
        } catch (DmlException e) {
            System.assert(e.getMessage().contains('submitted'), 'Expected the submitted-record error message, got: ' + e.getMessage());
        }
        Test.stopTest();

        System.assertEquals(1, [SELECT Id FROM Call_Visit_Report__c WHERE Id = :cvr.Id].size(),
            'The Submitted Call Visit Report must still exist');
    }

    @isTest
    static void draftCallVisitReportCanBeDeleted() {
        Sciagen_Account__c hcp = [SELECT Id FROM Sciagen_Account__c LIMIT 1];
        Call_Visit_Report__c cvr = new Call_Visit_Report__c(
            HCP__c = hcp.Id, Visit_Date__c = Date.today(), Call_Type__c = 'Detailing', Record_Status__c = 'Draft'
        );
        insert cvr;

        Test.startTest();
        delete cvr;
        Test.stopTest();

        System.assertEquals(0, [SELECT Id FROM Call_Visit_Report__c WHERE Id = :cvr.Id].size(),
            'A Draft Call Visit Report should delete normally');
    }

    @isTest
    static void plannedCallLinkedToSubmittedReportCannotBeDeleted() {
        Sciagen_Account__c hcp = [SELECT Id FROM Sciagen_Account__c LIMIT 1];
        Call_Visit_Report__c cvr = new Call_Visit_Report__c(
            HCP__c = hcp.Id, Visit_Date__c = Date.today(), Call_Type__c = 'Detailing', Record_Status__c = 'Submitted'
        );
        insert cvr;
        Planned_Call__c pc = new Planned_Call__c(
            HCP__c = hcp.Id, Call_Type__c = 'Detailing', Call_DateTime__c = SciagenTestTime.nextBusinessSlot(),
            Status__c = 'Completed', Resulting_CVR__c = cvr.Id
        );
        insert pc;

        Test.startTest();
        try {
            delete pc;
            System.assert(false, 'Expected deleting a Planned Call linked to a Submitted report to be blocked');
        } catch (DmlException e) {
            System.assert(e.getMessage().contains('submitted'), 'Expected the submitted-record error message, got: ' + e.getMessage());
        }
        Test.stopTest();

        System.assertEquals(1, [SELECT Id FROM Planned_Call__c WHERE Id = :pc.Id].size(),
            'The Planned Call must still exist');
    }

    @isTest
    static void plannedCallWithoutSubmittedReportCanBeDeleted() {
        Sciagen_Account__c hcp = [SELECT Id FROM Sciagen_Account__c LIMIT 1];
        Planned_Call__c pc = new Planned_Call__c(
            HCP__c = hcp.Id, Call_Type__c = 'Detailing', Call_DateTime__c = SciagenTestTime.nextBusinessSlot(), Status__c = 'Planned'
        );
        insert pc;

        Test.startTest();
        delete pc;
        Test.stopTest();

        System.assertEquals(0, [SELECT Id FROM Planned_Call__c WHERE Id = :pc.Id].size(),
            'A Planned Call with no linked (or non-submitted) report should delete normally');
    }
}