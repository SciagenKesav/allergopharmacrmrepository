@isTest
private class GeofenceSettingResolverTest {

    private static Territory__c territory(String name, Id parentId) {
        Territory__c t = new Territory__c(Name = name, Type__c = 'Territory', Parent_Territory__c = parentId);
        insert t;
        return t;
    }

    private static Geofence_Rule__c terrRule(Territory__c t, Boolean enabled, Boolean enforce, Decimal radius) {
        Geofence_Rule__c g = new Geofence_Rule__c(
            Scope__c = 'Territory', Territory__c = t.Id, Rule_Key__c = 'Territory:' + t.Id,
            Active__c = true, Enabled__c = enabled, Enforce_Check_In__c = enforce, Default_Radius_M__c = radius);
        insert g;
        return g;
    }

    private static void member(Id territoryId, Boolean primary) {
        insert new User_Territory__c(User__c = UserInfo.getUserId(), Territory__c = territoryId, Is_Primary__c = primary);
    }

    @isTest
    static void noRulesFallsBackToBuiltInDefault() {
        GeofenceSettingResolver.Resolved r = GeofenceSettingResolver.resolveForUser(UserInfo.getUserId());
        System.assertEquals(true, r.enabled);
        System.assertEquals(true, r.enforce);
        System.assertEquals(200, r.defaultRadiusM);
        System.assertEquals('Built-in default', r.source);
    }

    @isTest
    static void orgDefaultRowIsUsedWhenNoRule() {
        insert new Geofence_Setting__c(SetupOwnerId = UserInfo.getOrganizationId(), Enabled__c = true, Enforce_Check_In__c = false, Default_Radius_M__c = 300);
        GeofenceSettingResolver.Resolved r = GeofenceSettingResolver.resolveForUser(UserInfo.getUserId());
        System.assertEquals(false, r.enforce);
        System.assertEquals(300, r.defaultRadiusM);
        System.assertEquals('Organization default', r.source);
    }

    @isTest
    static void territoryRuleAppliesToItsReps() {
        Territory__c north = territory('North', null);
        terrRule(north, true, false, 450);
        member(north.Id, true);
        GeofenceSettingResolver.Resolved r = GeofenceSettingResolver.resolveForUser(UserInfo.getUserId());
        System.assertEquals(true, r.enabled);
        System.assertEquals(false, r.enforce);
        System.assertEquals(450, r.defaultRadiusM);
        System.assertEquals('Territory rule: North', r.source);
    }

    @isTest
    static void territoryRuleForSomeoneElsesTerritoryIsIgnored() {
        Territory__c north = territory('North', null);
        Territory__c south = territory('South', null);
        terrRule(south, false, false, 900);
        member(north.Id, true);
        System.assertEquals('Built-in default', GeofenceSettingResolver.resolveForUser(UserInfo.getUserId()).source);
    }

    @isTest
    static void userRuleBeatsTerritoryRule() {
        Territory__c north = territory('North', null);
        terrRule(north, true, true, 450);
        member(north.Id, true);
        insert new Geofence_Rule__c(Scope__c = 'User', User__c = UserInfo.getUserId(), Rule_Key__c = 'User:' + UserInfo.getUserId(),
            Active__c = true, Enabled__c = false, Enforce_Check_In__c = false);
        GeofenceSettingResolver.Resolved r = GeofenceSettingResolver.resolveForUser(UserInfo.getUserId());
        System.assertEquals(false, r.enabled);
        System.assertEquals('User rule', r.source);
        System.assertEquals(200, r.defaultRadiusM, 'blank radius keeps the level below');
    }

    @isTest
    static void inactiveRulesAreIgnored() {
        Territory__c north = territory('North', null);
        Geofence_Rule__c g = terrRule(north, false, false, 900);
        g.Active__c = false;
        update g;
        member(north.Id, true);
        System.assertEquals('Built-in default', GeofenceSettingResolver.resolveForUser(UserInfo.getUserId()).source);
    }

    @isTest
    static void childTerritoryInheritsParentRule() {
        Territory__c region = territory('Region', null);
        Territory__c child = territory('Child', region.Id);
        terrRule(region, true, true, 600);
        member(child.Id, true);
        GeofenceSettingResolver.Resolved r = GeofenceSettingResolver.resolveForUser(UserInfo.getUserId());
        System.assertEquals(600, r.defaultRadiusM);
        System.assertEquals('Territory rule: Region', r.source);
    }

    @isTest
    static void primaryTerritoryWinsOverOthers() {
        Territory__c a = territory('Alpha', null);
        Territory__c b = territory('Bravo', null);
        terrRule(a, true, true, 150);
        terrRule(b, true, false, 800);
        member(a.Id, false);
        member(b.Id, true);
        GeofenceSettingResolver.Resolved r = GeofenceSettingResolver.resolveForUser(UserInfo.getUserId());
        System.assertEquals(800, r.defaultRadiusM);
        System.assertEquals('Territory rule: Bravo', r.source);
    }

    @isTest
    static void strictestWinsWhenNoPrimaryHasARule() {
        Territory__c primary = territory('Primary', null);
        Territory__c a = territory('Alpha', null);
        Territory__c b = territory('Bravo', null);
        terrRule(a, true, false, 500);
        terrRule(b, true, true, 250);
        member(primary.Id, true);
        member(a.Id, false);
        member(b.Id, false);
        GeofenceSettingResolver.Resolved r = GeofenceSettingResolver.resolveForUser(UserInfo.getUserId());
        System.assertEquals(true, r.enabled);
        System.assertEquals(true, r.enforce);
        System.assertEquals(250, r.defaultRadiusM);
        System.assert(r.source.startsWith('Territory rules, strictest of'));
    }

    @isTest
    static void strictestIgnoresSwitchedOffTerritories() {
        Territory__c a = territory('Alpha', null);
        Territory__c b = territory('Bravo', null);
        terrRule(a, false, false, 100);
        terrRule(b, true, true, 700);
        member(a.Id, false);
        member(b.Id, false);
        GeofenceSettingResolver.Resolved r = GeofenceSettingResolver.resolveForUser(UserInfo.getUserId());
        System.assertEquals(true, r.enabled);
        System.assertEquals(700, r.defaultRadiusM);

        Territory__c c = territory('Charlie', null);
        Territory__c d = territory('Delta', null);
        terrRule(c, false, false, 100);
        terrRule(d, false, false, 100);
        delete [SELECT Id FROM User_Territory__c];
        member(c.Id, false);
        member(d.Id, false);
        System.assertEquals(false, GeofenceSettingResolver.resolveForUser(UserInfo.getUserId()).enabled);
    }

    @isTest
    static void restEndpointReturnsTheRunningUsersRule() {
        Territory__c north = territory('North', null);
        terrRule(north, true, false, 275);
        member(north.Id, true);
        GeofenceSettingsService.Payload p = GeofenceSettingsService.getSettings();
        System.assertEquals(true, p.enabled);
        System.assertEquals(false, p.enforce);
        System.assertEquals(275, p.defaultRadiusM);
        System.assertEquals('Territory rule: North', p.source);
    }
}