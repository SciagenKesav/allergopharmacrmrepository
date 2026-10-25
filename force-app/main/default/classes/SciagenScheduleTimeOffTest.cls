@isTest
private class SciagenScheduleTimeOffTest {

    @isTest
    static void getTimeOffReturnsOverlappingPendingAndApprovedLeaveOnly() {
        Date start = Date.today().toStartOfWeek();
        insert new List<Leave_Request__c>{
            new Leave_Request__c(Type__c = 'Casual Leave', Status__c = 'Approved', From_Date__c = start.addDays(1), To_Date__c = start.addDays(2)),
            new Leave_Request__c(Type__c = 'Sick Leave', Status__c = 'Rejected', From_Date__c = start.addDays(1), To_Date__c = start.addDays(2)),
            new Leave_Request__c(Type__c = 'Casual Leave', Status__c = 'Approved', From_Date__c = start.addDays(60), To_Date__c = start.addDays(61))
        };
        List<SciagenScheduleController.TimeOffItem> items =
            SciagenScheduleController.getTimeOff(start, start.addDays(6), null);
        System.assertEquals(1, items.size(), 'Only the overlapping Approved/Pending leave is returned');
        System.assertEquals('Approved', items[0].status);
        System.assertEquals('Casual Leave', items[0].leaveType);
    }

    @isTest
    static void getTimeOffRejectsAnotherUserForANonManager() {
        User other = [SELECT Id FROM User WHERE IsActive = true AND Id != :UserInfo.getUserId() LIMIT 1];
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User plain = new User(
            Alias = 'tofftst', Email = 'tofftst@example.com', EmailEncodingKey = 'UTF-8', LastName = 'TimeOffTest',
            LanguageLocaleKey = 'en_US', LocaleSidKey = 'en_US', ProfileId = p.Id, TimeZoneSidKey = 'Asia/Kolkata',
            Username = 'tofftst' + System.currentTimeMillis() + '@example.com'
        );
        insert plain;
        Boolean threw = false;
        System.runAs(plain) {
            try {
                SciagenScheduleController.getTimeOff(Date.today(), Date.today().addDays(6), other.Id);
            } catch (AuraHandledException e) {
                threw = true;
            }
        }
        System.assert(threw, 'A non-manager cannot read another user\'s time off');
    }

    @isTest
    static void crossUserReaderReturnsLeaveAndWalkInsForAnOwner() {
        Date start = Date.today().toStartOfWeek();
        insert new Leave_Request__c(Type__c = 'Casual Leave', Status__c = 'Pending', From_Date__c = start, To_Date__c = start.addDays(1));
        System.assertEquals(1, ScheduleCrossUserReader.leaveForOwner(UserInfo.getUserId(), start, start.addDays(6)).size());
        System.assertEquals(0, ScheduleCrossUserReader.walkInsForOwner(UserInfo.getUserId(), start, start.addDays(6)).size());
    }
}
