@isTest
private class ScheduleWalkInDraftTest {
    @isTest
    static void unassignedDraftCallShowsAsDraftNotCompleted() {
        Sciagen_Account__c hcp = new Sciagen_Account__c(Name = 'Dr. Walk In Test', Type__c = 'HCP');
        insert hcp;
        insert new Call_Visit_Report__c(HCP__c = hcp.Id, Visit_Date__c = Date.today(), Call_Type__c = 'Detailing',
            Call_Status__c = 'Completed', Record_Status__c = 'Draft');

        List<SciagenScheduleController.PlannedCallItem> items =
            SciagenScheduleController.getPlannedCallsForUser(Date.today(), Date.today(), UserInfo.getUserId());
        Integer walkIns = 0;
        for (SciagenScheduleController.PlannedCallItem i : items) {
            if (i.isReportOnly == true) {
                walkIns++;
                System.assertEquals('Draft', i.status, 'An unassigned call with an unsubmitted report must show as Draft');
            }
        }
        System.assertEquals(1, walkIns);
    }

    @isTest
    static void unassignedClmPlaceholderShowsAsDraftUntilAReportExists() {
        Sciagen_Account__c hcp = new Sciagen_Account__c(Name = 'Dr. Clm Placeholder', Type__c = 'HCP');
        insert hcp;
        insert new Planned_Call__c(HCP__c = hcp.Id, Call_DateTime__c = SciagenTestTime.nextBusinessSlot(), Status__c = 'Completed',
            Is_Event__c = true, Event_Title__c = 'Unassigned CLM: Test deck', Origin__c = 'Call log');

        Date d = SciagenTestTime.nextBusinessSlot().date();
        List<SciagenScheduleController.PlannedCallItem> items =
            SciagenScheduleController.getPlannedCallsForUser(d, d, UserInfo.getUserId());
        Boolean found = false;
        for (SciagenScheduleController.PlannedCallItem i : items) {
            if (i.eventTitle == 'Unassigned CLM: Test deck') {
                found = true;
                System.assertEquals('Draft', i.status);
            }
        }
        System.assert(found, 'Expected the placeholder call in the schedule');
    }
}