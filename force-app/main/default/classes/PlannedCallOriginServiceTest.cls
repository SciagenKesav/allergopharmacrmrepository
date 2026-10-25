@isTest
private class PlannedCallOriginServiceTest {

    private static Datetime at(Integer dayOffset) {
        Date d = Date.today().addDays(dayOffset);
        while (Datetime.newInstance(d, Time.newInstance(12, 0, 0, 0)).format('EEEE') == 'Sunday') d = d.addDays(1);
        return Datetime.newInstance(d, Time.newInstance(11, 0, 0, 0));
    }

    @isTest
    static void plannedCallKeepsItsOriginalDateAndTypeWhenCompleted() {
        Datetime planned = at(3);
        Planned_Call__c pc = new Planned_Call__c(Call_DateTime__c = planned, Call_Type__c = 'Detailing', Status__c = 'Planned');
        insert pc;
        pc = [SELECT Origin__c, Original_Call_DateTime__c, Original_Call_Type__c FROM Planned_Call__c WHERE Id = :pc.Id];
        System.assertEquals('Planned', pc.Origin__c);
        System.assertEquals(planned, pc.Original_Call_DateTime__c);
        System.assertEquals('Detailing', pc.Original_Call_Type__c);

        // The app overwrites date and type with the actuals when the call is done.
        pc.Call_DateTime__c = at(5);
        pc.Call_Type__c = 'Sampling';
        pc.Status__c = 'Completed';
        update pc;
        pc = [SELECT Origin__c, Original_Call_DateTime__c, Original_Call_Type__c, Call_Type__c FROM Planned_Call__c WHERE Id = :pc.Id];
        System.assertEquals('Planned', pc.Origin__c);
        System.assertEquals(planned, pc.Original_Call_DateTime__c, 'the plan is frozen');
        System.assertEquals('Detailing', pc.Original_Call_Type__c);
        System.assertEquals('Sampling', pc.Call_Type__c);
    }

    @isTest
    static void rowCreatedAlreadyCompletedIsACallLogNotAPlan() {
        Planned_Call__c pc = new Planned_Call__c(Call_DateTime__c = at(-2), Call_Type__c = 'Detailing', Status__c = 'Completed');
        insert pc;
        pc = [SELECT Origin__c, Original_Call_DateTime__c FROM Planned_Call__c WHERE Id = :pc.Id];
        System.assertEquals('Call log', pc.Origin__c);
        System.assertEquals(null, pc.Original_Call_DateTime__c);
    }

    @isTest
    static void suppliedOriginalIsKeptAndCannotBeOverwritten() {
        Datetime original = at(4);
        Planned_Call__c pc = new Planned_Call__c(Call_DateTime__c = at(6), Call_Type__c = 'Visit', Status__c = 'Planned',
            Origin__c = 'Planned', Original_Call_DateTime__c = original, Original_Call_Type__c = 'Detailing');
        insert pc;
        pc.Original_Call_DateTime__c = at(9);
        pc.Original_Call_Type__c = 'Sampling';
        update pc;
        pc = [SELECT Original_Call_DateTime__c, Original_Call_Type__c FROM Planned_Call__c WHERE Id = :pc.Id];
        System.assertEquals(original, pc.Original_Call_DateTime__c);
        System.assertEquals('Detailing', pc.Original_Call_Type__c);
    }

    @isTest
    static void legacyRowWithoutOriginIsFrozenOnFirstEdit() {
        Datetime planned = at(3);
        Planned_Call__c pc = new Planned_Call__c(Call_DateTime__c = planned, Call_Type__c = 'Detailing', Status__c = 'Planned');
        insert pc;
        Test.startTest();
        update new Planned_Call__c(Id = pc.Id, Origin__c = null, Original_Call_DateTime__c = null, Original_Call_Type__c = null);
        Test.stopTest();
        pc = [SELECT Origin__c, Original_Call_DateTime__c FROM Planned_Call__c WHERE Id = :pc.Id];
        System.assertEquals('Planned', pc.Origin__c);
        System.assertEquals(planned, pc.Original_Call_DateTime__c);
    }
}