@isTest
private class PlannedCallOfficeHoursValidatorTest {

    @testSetup
    static void setup() {
        Sciagen_Account__c hco = new Sciagen_Account__c(
            Type__c = 'HCO', Name = 'Office Hours Test Hospital', HCO_Type__c = 'Hospital', Speciality__c = 'Other'
        );
        insert hco;
    }

    @isTest
    static void allowsCallFullyInsideOfficeHours() {
        Sciagen_Account__c hco = [SELECT Id FROM Sciagen_Account__c LIMIT 1];
        Planned_Call__c pc = new Planned_Call__c(
            HCO__c = hco.Id, Call_Type__c = 'Visit', Status__c = 'Planned', Duration_Min__c = 30,
            Call_DateTime__c = Datetime.newInstance(Date.today().addDays(1), Time.newInstance(11, 0, 0, 0))
        );

        Test.startTest();
        insert pc;
        Test.stopTest();

        System.assertNotEquals(null, [SELECT Id FROM Planned_Call__c WHERE Id = :pc.Id].Id,
            'A call fully inside 8 AM - 8 PM should be allowed to save');
    }

    @isTest
    static void blocksCallStartingBeforeOfficeHoursOpen() {
        Sciagen_Account__c hco = [SELECT Id FROM Sciagen_Account__c LIMIT 1];
        Planned_Call__c pc = new Planned_Call__c(
            HCO__c = hco.Id, Call_Type__c = 'Visit', Status__c = 'Planned', Duration_Min__c = 30,
            Call_DateTime__c = Datetime.newInstance(Date.today().addDays(1), Time.newInstance(7, 30, 0, 0))
        );

        Test.startTest();
        Boolean threw = false;
        try {
            insert pc;
        } catch (DmlException e) {
            threw = true;
            System.assert(e.getMessage().contains('office hours'), 'Expected an office-hours error, got: ' + e.getMessage());
        }
        Test.stopTest();

        System.assertEquals(true, threw, 'A call starting before 8 AM should be blocked');
    }

    @isTest
    static void blocksCallEndingAfterOfficeHoursClose() {
        Sciagen_Account__c hco = [SELECT Id FROM Sciagen_Account__c LIMIT 1];
        Planned_Call__c pc = new Planned_Call__c(
            HCO__c = hco.Id, Call_Type__c = 'Visit', Status__c = 'Planned', Duration_Min__c = 45,
            // Starts inside the window (7:45 PM) but runs 45 min past 8 PM close.
            Call_DateTime__c = Datetime.newInstance(Date.today().addDays(1), Time.newInstance(19, 45, 0, 0))
        );

        Test.startTest();
        Boolean threw = false;
        try {
            insert pc;
        } catch (DmlException e) {
            threw = true;
        }
        Test.stopTest();

        System.assertEquals(true, threw, 'A call whose start + duration runs past 8 PM should be blocked');
    }

    @isTest
    static void allowsRescheduleUnaffectedFieldEditAfterValidSave() {
        Sciagen_Account__c hco = [SELECT Id FROM Sciagen_Account__c LIMIT 1];
        Planned_Call__c pc = new Planned_Call__c(
            HCO__c = hco.Id, Call_Type__c = 'Visit', Status__c = 'Planned', Duration_Min__c = 30,
            Call_DateTime__c = Datetime.newInstance(Date.today().addDays(1), Time.newInstance(11, 0, 0, 0))
        );
        insert pc;

        Test.startTest();
        pc.Status__c = 'Completed'; // Call_DateTime__c/Duration_Min__c untouched
        update pc;
        Test.stopTest();

        System.assertEquals('Completed', [SELECT Status__c FROM Planned_Call__c WHERE Id = :pc.Id].Status__c,
            'Editing an unrelated field on an already-valid call should not re-trigger the office-hours check');
    }

    @isTest
    static void blocksReschedulingAnExistingCallOutsideOfficeHours() {
        Sciagen_Account__c hco = [SELECT Id FROM Sciagen_Account__c LIMIT 1];
        Planned_Call__c pc = new Planned_Call__c(
            HCO__c = hco.Id, Call_Type__c = 'Visit', Status__c = 'Planned', Duration_Min__c = 30,
            Call_DateTime__c = Datetime.newInstance(Date.today().addDays(1), Time.newInstance(11, 0, 0, 0))
        );
        insert pc;

        Test.startTest();
        pc.Call_DateTime__c = Datetime.newInstance(Date.today().addDays(1), Time.newInstance(21, 0, 0, 0));
        Boolean threw = false;
        try {
            update pc;
        } catch (DmlException e) {
            threw = true;
        }
        Test.stopTest();

        System.assertEquals(true, threw, 'Moving an existing call to 9 PM should be blocked');
    }
}
