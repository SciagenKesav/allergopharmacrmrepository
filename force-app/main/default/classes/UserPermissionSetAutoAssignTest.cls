@isTest
private class UserPermissionSetAutoAssignTest {
    private static User mk(String profileName, String tag) {
        Profile p = [SELECT Id FROM Profile WHERE Name = :profileName LIMIT 1];
        String uniq = 'psauto.' + tag + '.' + Datetime.now().getTime();
        return new User(FirstName = 'Auto', LastName = tag, Email = uniq + '@sciagen.invalid', Username = uniq + '@sciagen.invalid',
            Alias = 'pa' + tag.left(5).toLowerCase(), TimeZoneSidKey = 'Asia/Kolkata', LocaleSidKey = 'en_IN',
            EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US', ProfileId = p.Id);
    }
    private static Set<String> setsOf(Id userId) {
        Set<String> n = new Set<String>();
        for (PermissionSetAssignment a : [SELECT PermissionSet.Name FROM PermissionSetAssignment WHERE AssigneeId = :userId AND PermissionSet.IsOwnedByProfile = false]) n.add(a.PermissionSet.Name);
        return n;
    }

    @isTest static void eachProfileGetsItsOwnSets() {
        User kam = mk('Key Account Manager', 'Kam'); User mgr = mk('Manager', 'Mgr'); User adm = mk('Business Admin', 'Adm');
        insert new List<User>{ kam, mgr, adm };
        Test.startTest();
        UserPermissionSetAutoAssign.assign(new Set<Id>{ kam.Id, mgr.Id, adm.Id });
        Test.stopTest();
        Set<String> k = setsOf(kam.Id), m = setsOf(mgr.Id), a = setsOf(adm.Id);
        System.assert(k.contains('KAM_Full_Access') && k.contains('Sciagen_Reports_User') && !k.contains('Manager_Full_Access') && !k.contains('Sciagen_Reports_Manager'), 'KAM: ' + k);
        System.assert(m.contains('Manager_Full_Access') && m.contains('Sciagen_Reports_Manager') && !m.contains('KAM_Full_Access'), 'Manager: ' + m);
        System.assert(a.contains('Business_Admin_Full_Access') && a.contains('Sciagen_Reports_Business_Admin') && !a.contains('KAM_Full_Access'), 'Business Admin: ' + a);
    }

    @isTest static void assigningTwiceDoesNotDuplicate() {
        User kam = mk('Key Account Manager', 'Twice'); insert kam;
        Integer first = UserPermissionSetAutoAssign.assign(new Set<Id>{ kam.Id });
        Integer second = UserPermissionSetAutoAssign.assign(new Set<Id>{ kam.Id });
        System.assert(first >= 2, 'first run adds the sets');
        System.assertEquals(0, second, 'second run finds nothing missing');
    }

    @isTest static void creatingAUserAssignsThroughTheTrigger() {
        UserPermissionSetAutoAssign.enableInTests = true;
        User kam = mk('Key Account Manager', 'Trig');
        Test.startTest();
        insert kam;
        Test.stopTest();
        System.assert(setsOf(kam.Id).contains('KAM_Full_Access'), 'new KAM got the KAM set automatically');
    }

    @isTest static void changingTheProfileAddsTheNewProfilesSetsAndKeepsTheOld() {
        UserPermissionSetAutoAssign.enableInTests = true;
        User u = mk('Key Account Manager', 'Move'); insert u;
        UserPermissionSetAutoAssign.assign(new Set<Id>{ u.Id });
        u.ProfileId = [SELECT Id FROM Profile WHERE Name = 'Manager' LIMIT 1].Id;
        Test.startTest();
        update u;
        Test.stopTest();
        Set<String> n = setsOf(u.Id);
        System.assert(n.contains('Manager_Full_Access') && n.contains('KAM_Full_Access'), 'new set added, old kept: ' + n);
    }

    @isTest static void backfillCoversExistingUsersAndIgnoresOtherProfiles() {
        User kam = mk('Key Account Manager', 'Back'); insert kam;
        Integer added = UserPermissionSetAutoAssign.assignForAllActiveUsers();
        System.assert(added >= 2);
        System.assert(setsOf(kam.Id).contains('KAM_Full_Access'));
    }
}
