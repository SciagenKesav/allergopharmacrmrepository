@isTest
private class SegmentationLockServiceTest {

    private static User rep() { return SciagenTestUsers.mobileRep('seglock'); }

    private static Segmentation__c segment(User r) {
        Sciagen_Account__c doc;
        Segmentation__c s;
        System.runAs(r) {
            doc = SampleTestData.doctor('Dr Lock Test');
            s = new Segmentation__c(HCP__c = doc.Id, Classification__c = 'V2');
            insert s;
        }
        return s;
    }

    // The lock is a setting (Sciagen App Config), and an org may have it switched off. These tests are about
    // the lock itself, so they state it as on rather than inheriting the org's record.
    private static void lockOn() {
        SciagenAppConfig.testRecord = new Sciagen_App_Config__mdt(Lock_Segmentation_On_Freeze__c = true);
    }

    private static void freezeThisMonth(User r) {
        insert new Monthly_Call_Plan__c(OwnerId = r.Id, Month__c = Date.today().toStartOfMonth(),
                                        Plan_Key__c = MonthlyCallPlanService.planKey(r.Id, Date.today()),
                                        Status__c = MonthlyCallPlanService.FROZEN);
    }

    @isTest static void repCannotChangeSegmentationOnceTheMonthIsFrozen() {
        lockOn();
        User r = rep();
        Segmentation__c s = segment(r);
        freezeThisMonth(r);

        Database.SaveResult res;
        System.runAs(r) {
            s.Classification__c = 'V3';
            res = Database.update(s, false);
        }
        System.assert(!res.isSuccess(), 'A frozen month locks segmentation');
        System.assert(res.getErrors()[0].getMessage().contains('locked'), res.getErrors()[0].getMessage());
    }

    @isTest static void unchangedResaveIsAllowed() {
        lockOn();
        User r = rep();
        Segmentation__c s = segment(r);
        freezeThisMonth(r);
        Database.SaveResult res;
        System.runAs(r) { res = Database.update(new Segmentation__c(Id = s.Id, Classification__c = 'V2'), false); }
        System.assert(res.isSuccess(), 'Saving the same values is not a change');
    }

    @isTest static void repCanChangeSegmentationWhileThePlanIsNotFrozen() {
        lockOn();
        User r = rep();
        Segmentation__c s = segment(r);
        System.runAs(r) {
            s.Classification__c = 'V3';
            update s;
        }
        System.assertEquals('V3', [SELECT Classification__c FROM Segmentation__c WHERE Id = :s.Id].Classification__c);
    }

    @isTest static void businessAdminCanStillEdit() {
        lockOn();
        User r = rep();
        Segmentation__c s = segment(r);
        freezeThisMonth(r);
        // Running as the test's admin user (Modify All Data).
        s.Classification__c = 'V1';
        update s;
        System.assertEquals('V1', [SELECT Classification__c FROM Segmentation__c WHERE Id = :s.Id].Classification__c);
    }

    @isTest static void theLockCanBeTurnedOff() {
        User r = rep();
        Segmentation__c s = segment(r);
        freezeThisMonth(r);
        SciagenAppConfig.testRecord = new Sciagen_App_Config__mdt(Lock_Segmentation_On_Freeze__c = false);
        Database.SaveResult res;
        System.runAs(r) {
            s.Classification__c = 'V3';
            res = Database.update(s, false);
        }
        System.assert(res.isSuccess(), 'Lock Segmentation On Freeze = off');
    }

    @isTest static void lockedMonthIsFoundPerOwner() {
        lockOn();
        User r = rep();
        freezeThisMonth(r);
        Map<Id, String> locked = SegmentationLockService.lockedMonthByOwner(new Set<Id>{ r.Id, UserInfo.getUserId() });
        System.assert(locked.containsKey(r.Id));
        System.assert(!locked.containsKey(UserInfo.getUserId()));
    }

    @isTest static void perProductClassIsLockedToo() {
        lockOn();
        User r = rep();
        Segmentation__c s = segment(r);
        Product__c prod = SampleTestData.product('Lockbrand');
        Segmentation_Product__c sp;
        System.runAs(r) {
            sp = new Segmentation_Product__c(Segmentation__c = s.Id, Product__c = prod.Id, Classification__c = 'B');
            insert sp;
        }
        freezeThisMonth(r);
        Database.SaveResult upd;
        Database.DeleteResult del;
        System.runAs(r) {
            upd = Database.update(new Segmentation_Product__c(Id = sp.Id, Classification__c = 'A'), false);
            del = Database.delete(sp.Id, false);
        }
        System.assert(!upd.isSuccess(), 'Product class change is locked');
        System.assert(!del.isSuccess(), 'Removing a product class is locked');
    }
}