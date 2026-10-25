@isTest
private class GeofenceAdminControllerTest {

    @isTest
    static void defaultsWhenNothingSaved() {
        GeofenceAdminController.SettingsDTO s = GeofenceAdminController.getSettings();
        System.assertEquals(true, s.enabled);
        System.assertEquals(true, s.enforce);
        System.assertEquals(200, s.defaultRadiusM);
    }

    @isTest
    static void saveThenReadBack() {
        GeofenceAdminController.saveSettings(false, false, 350);
        GeofenceAdminController.SettingsDTO s = GeofenceAdminController.getSettings();
        System.assertEquals(false, s.enabled);
        System.assertEquals(false, s.enforce);
        System.assertEquals(350, s.defaultRadiusM);
    }

    @isTest
    static void rejectsOutOfRangeRadius() {
        for (Decimal bad : new List<Decimal>{ null, 5, 6000 }) {
            try {
                GeofenceAdminController.saveSettings(true, true, bad);
                System.assert(false, 'expected radius validation to fail for ' + bad);
            } catch (AuraHandledException e) {
                System.assert(true);
            }
        }
    }

    @isTest
    static void hcoRadiusOverrideSetAndCleared() {
        Sciagen_Account__c hco = new Sciagen_Account__c(Name = 'Geo Test HCO', Type__c = 'HCO', Billing_City__c = 'Delhi');
        insert hco;
        GeofenceAdminController.saveHcoRadius(hco.Id, 500);
        List<GeofenceAdminController.HcoDTO> found = GeofenceAdminController.searchHcos('Geo Test', null, false, false);
        System.assertEquals(1, found.size());
        System.assertEquals(500, found[0].radiusOverrideM);
        GeofenceAdminController.saveHcoRadius(hco.Id, null);
        System.assertEquals(null, GeofenceAdminController.searchHcos('Geo Test', null, false, false)[0].radiusOverrideM);
    }

    @isTest
    static void hcoFiltersByTerritoryCustomRadiusAndMissingLocation() {
        Territory__c north = new Territory__c(Name = 'North', Type__c = 'Territory');
        insert north;
        Sciagen_Account__c inTerritory = new Sciagen_Account__c(Name = 'Filter HCO In', Type__c = 'HCO', Billing_City__c = 'Delhi', Geofence_Radius_M__c = 400);
        Sciagen_Account__c outside = new Sciagen_Account__c(Name = 'Filter HCO Out', Type__c = 'HCO', Billing_City__c = 'Delhi');
        insert new List<Sciagen_Account__c>{ inTerritory, outside };
        insert new Account_Territory__c(Account__c = inTerritory.Id, Territory__c = north.Id);

        System.assertEquals(2, GeofenceAdminController.searchHcos('Filter HCO', null, false, false).size());
        List<GeofenceAdminController.HcoDTO> scoped = GeofenceAdminController.searchHcos('Filter HCO', north.Id, false, false);
        System.assertEquals(1, scoped.size());
        System.assertEquals(inTerritory.Id, scoped[0].id);
        List<GeofenceAdminController.HcoDTO> custom = GeofenceAdminController.searchHcos('Filter HCO', null, true, false);
        System.assertEquals(1, custom.size());
        System.assertEquals(2, GeofenceAdminController.searchHcos('Filter HCO', null, false, true).size(), 'neither has coordinates');
        System.assertEquals(1, GeofenceAdminController.getTerritories().size());
    }

    @isTest
    static void ruleLifecycleTerritoryAndUser() {
        Territory__c north = new Territory__c(Name = 'North', Type__c = 'Territory');
        insert north;
        Id ruleId = GeofenceAdminController.saveRule(null, 'Territory', north.Id, null, true, true, false, 350, 'metro clinics');
        Id userRuleId = GeofenceAdminController.saveRule(null, 'User', null, UserInfo.getUserId(), true, false, false, null, null);

        List<GeofenceAdminController.RuleDTO> rules = GeofenceAdminController.getRules();
        System.assertEquals(2, rules.size());
        GeofenceAdminController.RuleDTO t;
        GeofenceAdminController.RuleDTO u;
        for (GeofenceAdminController.RuleDTO r : rules) { if (r.id == ruleId) t = r; else u = r; }
        System.assertEquals('Territory', t.scope);
        System.assertEquals('North', t.territoryName);
        System.assertEquals(350, t.radiusM);
        System.assertEquals(false, t.enforce);
        System.assertEquals('User', u.scope);
        System.assertEquals(false, u.enabled);

        GeofenceAdminController.saveRule(ruleId, 'Territory', north.Id, null, false, true, true, 500, null);
        for (GeofenceAdminController.RuleDTO r : GeofenceAdminController.getRules()) {
            if (r.id == ruleId) { System.assertEquals(false, r.active); System.assertEquals(500, r.radiusM); }
        }

        try {
            GeofenceAdminController.saveRule(null, 'Territory', north.Id, null, true, true, true, 300, null);
            System.assert(false, 'expected duplicate rule to be refused');
        } catch (AuraHandledException e) { System.assert(true); }
        try {
            GeofenceAdminController.saveRule(ruleId, 'User', null, UserInfo.getUserId(), true, true, true, 300, null);
            System.assert(false, 'expected retargeting to be refused');
        } catch (AuraHandledException e) { System.assert(true); }
        try {
            GeofenceAdminController.saveRule(null, 'Territory', null, null, true, true, true, 300, null);
            System.assert(false, 'expected missing target to be refused');
        } catch (AuraHandledException e) { System.assert(true); }
        try {
            GeofenceAdminController.saveRule(null, 'User', null, UserInfo.getUserId(), true, true, true, 5, null);
            System.assert(false, 'expected radius validation');
        } catch (AuraHandledException e) { System.assert(true); }

        GeofenceAdminController.EffectiveDTO eff = GeofenceAdminController.previewForUser(UserInfo.getUserId());
        System.assertEquals(false, eff.enabled);
        System.assertEquals('User rule', eff.source);

        GeofenceAdminController.deleteRule(userRuleId);
        System.assertEquals(1, GeofenceAdminController.getRules().size());
    }

    @isTest
    static void userRuleShowsRepsTerritoriesForFiltering() {
        Territory__c north = new Territory__c(Name = 'North', Type__c = 'Territory');
        insert north;
        insert new User_Territory__c(User__c = UserInfo.getUserId(), Territory__c = north.Id, Is_Primary__c = true);
        GeofenceAdminController.saveRule(null, 'User', null, UserInfo.getUserId(), true, true, true, 250, null);
        GeofenceAdminController.RuleDTO r = GeofenceAdminController.getRules()[0];
        System.assertEquals(new List<Id>{ north.Id }, r.memberTerritoryIds);
        System.assertEquals('North', r.memberTerritoryNames);
    }
}