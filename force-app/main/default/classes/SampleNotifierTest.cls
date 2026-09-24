@isTest
private class SampleNotifierTest {

    @isTest
    static void notifyNeverThrowsAndIgnoresEmptyInput() {
        SampleNotifier.notify(null, 'x', 'y', UserInfo.getUserId());
        SampleNotifier.notify(new Set<Id>(), 'x', 'y', UserInfo.getUserId());
        SampleNotifier.notify(new Set<Id>{ UserInfo.getUserId() }, 'x', 'y', null);
        SampleNotifier.notify(new Set<Id>{ UserInfo.getUserId() }, 'Test alert', 'Body', UserInfo.getUserId());
        System.assert(true);
    }

    @isTest
    static void managersAreFoundFromTheUserRecord() {
        User me = [SELECT Id, ManagerId FROM User WHERE Id = :UserInfo.getUserId()];
        Set<Id> managers = SampleNotifier.managersOf(new Set<Id>{ me.Id });
        System.assertEquals(me.ManagerId == null ? 0 : 1, managers.size());
        System.assertEquals(0, SampleNotifier.managersOf(null).size());
    }

    @isTest
    static void adminLookupReturnsAssignees() {
        System.assertNotEquals(null, SampleNotifier.sampleAdmins());
    }
}