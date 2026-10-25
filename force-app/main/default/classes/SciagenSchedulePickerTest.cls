@isTest
private class SciagenSchedulePickerTest {
    private static User mk(String profileName, String role, String tag) {
        Profile p = [SELECT Id FROM Profile WHERE Name = :profileName LIMIT 1];
        String uniq = 'schedpick.' + tag + '.' + Datetime.now().getTime();
        User u = new User(FirstName = 'Pick', LastName = tag, Email = uniq + '@sciagen.invalid', Username = uniq + '@sciagen.invalid',
            Alias = 'sp' + tag.left(5).toLowerCase(), TimeZoneSidKey = 'Asia/Kolkata', LocaleSidKey = 'en_IN',
            EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US', ProfileId = p.Id);
        if (role != null) {
            List<UserRole> r = [SELECT Id FROM UserRole WHERE Name = :role LIMIT 1];
            if (!r.isEmpty()) u.UserRoleId = r[0].Id;
        }
        return u;
    }

    @TestSetup
    static void setup() {
        User kam = mk('Key Account Manager', 'Key Account Manager', 'KamA');
        User kam2 = mk('Key Account Manager', 'Key Account Manager', 'KamB');
        User mgr = mk('Manager', 'Manager', 'Mgr');
        User adm = mk('Business Admin', 'Business Unit Head', 'Adm');
        System.runAs(new User(Id = UserInfo.getUserId())) { insert new List<User>{ kam, kam2, mgr, adm }; }
        Territory__c region = new Territory__c(Name = 'SP Region', Territory_Code__c = 'SPR', Type__c = 'Region');
        insert region;
        Territory__c t1 = new Territory__c(Name = 'SP Terr One', Territory_Code__c = 'SP1', Type__c = 'Territory', Parent_Territory__c = region.Id);
        Territory__c t2 = new Territory__c(Name = 'SP Terr Two', Territory_Code__c = 'SP2', Type__c = 'Territory', Parent_Territory__c = region.Id);
        insert new List<Territory__c>{ t1, t2 };
        insert new List<User_Territory__c>{
            new User_Territory__c(User__c = kam.Id, Territory__c = t1.Id),
            new User_Territory__c(User__c = kam2.Id, Territory__c = t2.Id),
            new User_Territory__c(User__c = mgr.Id, Territory__c = region.Id)
        };
    }
    private static User named(String last) { return [SELECT Id FROM User WHERE LastName = :last AND FirstName = 'Pick' LIMIT 1]; }

    @isTest static void kamGetsNoPickerAndCannotViewAPeer() {
        User kam = named('KamA'); User peer = named('KamB');
        System.runAs(kam) {
            System.assertEquals(false, SciagenScheduleController.isManagerOrHasManagerRole(), 'a KAM is not a manager');
            SciagenScheduleController.SchedulePickerData d = SciagenScheduleController.getSchedulePickerData();
            System.assertEquals('SELF', d.mode); System.assertEquals(0, d.kams.size());
            try { SciagenScheduleController.getPlannedCallsForUser(Date.today(), Date.today().addDays(7), peer.Id); System.assert(false, 'must refuse'); }
            catch (AuraHandledException e) { System.assert(true); }
        }
    }
    @isTest static void managerSeesOnlyKamsInTheirOwnTerritories() {
        User mgr = named('Mgr');
        System.runAs(mgr) {
            SciagenScheduleController.SchedulePickerData d = SciagenScheduleController.getSchedulePickerData();
            System.assertEquals('MANAGER', d.mode);
            Set<String> names = new Set<String>(); for (SciagenScheduleController.KamUserOption k : d.kams) names.add(k.name);
            System.assert(names.contains('Pick KamA') && names.contains('Pick KamB'), 'both KAMs sit under the manager region: ' + names);
            System.assertEquals(0, d.territories.size());
        }
    }
    @isTest static void businessAdminGetsRegionTerritoryKamData() {
        User adm = named('Adm'); User kam = named('KamA');
        System.runAs(adm) {
            SciagenScheduleController.SchedulePickerData d = SciagenScheduleController.getSchedulePickerData();
            System.assertEquals('ADMIN', d.mode);
            Boolean region = false, terr = false;
            for (SciagenScheduleController.TerritoryOption t : d.territories) { if (t.name == 'SP Region' && t.type == 'Region') region = true; if (t.name == 'SP Terr One' && t.parentId != null) terr = true; }
            System.assert(region && terr, 'territories carry region + child with parent');
            Boolean found = false; for (SciagenScheduleController.KamUserOption k : d.kams) if (k.id == kam.Id) { found = true; System.assertEquals(1, k.territoryIds.size()); }
            System.assert(found);
            // may read a KAM's schedule (cross-user path, includes Call Category without error)
            List<SciagenScheduleController.PlannedCallItem> items = SciagenScheduleController.getPlannedCallsForUser(Date.today(), Date.today().addDays(7), kam.Id);
            System.assertNotEquals(null, items);
        }
    }
}