/**
 * Backend for the Geofence Settings admin page. Reads and writes the
 * org-default Geofence_Setting__c (master on/off, block-outside-radius,
 * default radius), the Territory- and User-level Geofence_Rule__c overrides,
 * and the per-HCO radius override on Sciagen_Account__c. The iPad resolves the
 * same records through GeofenceSettingResolver, so a change here reaches each
 * rep's device on its next sync.
 */
public with sharing class GeofenceAdminController {

    public static final Decimal DEFAULT_RADIUS_M = 200;
    public static final Decimal MIN_RADIUS_M = 25;
    public static final Decimal MAX_RADIUS_M = 5000;

    public class SettingsDTO {
        @AuraEnabled public Boolean enabled;
        @AuraEnabled public Boolean enforce;
        @AuraEnabled public Decimal defaultRadiusM;
    }

    public class RuleDTO {
        @AuraEnabled public Id id;
        @AuraEnabled public String scope;
        @AuraEnabled public Id territoryId;
        @AuraEnabled public String territoryName;
        @AuraEnabled public Id userId;
        @AuraEnabled public String userName;
        @AuraEnabled public Boolean active;
        @AuraEnabled public Boolean enabled;
        @AuraEnabled public Boolean enforce;
        @AuraEnabled public Decimal radiusM;
        @AuraEnabled public String note;
        @AuraEnabled public List<Id> memberTerritoryIds;
        @AuraEnabled public String memberTerritoryNames;
    }

    public class OptionDTO {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
    }

    public class EffectiveDTO {
        @AuraEnabled public String userName;
        @AuraEnabled public Boolean enabled;
        @AuraEnabled public Boolean enforce;
        @AuraEnabled public Decimal radiusM;
        @AuraEnabled public String source;
    }

    public class HcoDTO {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String city;
        @AuraEnabled public Boolean hasLocation;
        @AuraEnabled public Decimal radiusOverrideM;
    }

    @AuraEnabled(cacheable=false)
    public static SettingsDTO getSettings() {
        Geofence_Setting__c s = Geofence_Setting__c.getOrgDefaults();
        SettingsDTO dto = new SettingsDTO();
        Boolean saved = s.Id != null;
        dto.enabled = saved ? s.Enabled__c == true : true;
        dto.enforce = saved ? s.Enforce_Check_In__c == true : true;
        dto.defaultRadiusM = (saved && s.Default_Radius_M__c != null) ? s.Default_Radius_M__c : DEFAULT_RADIUS_M;
        return dto;
    }

    @AuraEnabled
    public static SettingsDTO saveSettings(Boolean enabled, Boolean enforce, Decimal defaultRadiusM) {
        requireEditable(Geofence_Setting__c.SObjectType.getDescribe().isUpdateable());
        validateRadius(defaultRadiusM);
        Geofence_Setting__c s = Geofence_Setting__c.getOrgDefaults();
        s.Enabled__c = enabled == true;
        s.Enforce_Check_In__c = enforce == true;
        s.Default_Radius_M__c = defaultRadiusM;
        upsert s;
        return getSettings();
    }

    @AuraEnabled(cacheable=false)
    public static List<HcoDTO> searchHcos(String term, Id territoryId, Boolean customOnly, Boolean missingLocationOnly) {
        String pattern = '%' + String.escapeSingleQuotes(String.isBlank(term) ? '' : term.trim()) + '%';
        Boolean byTerritory = territoryId != null;
        Set<Id> hcoIds = new Set<Id>();
        if (byTerritory) {
            for (Account_Territory__c link : [
                SELECT Account__c FROM Account_Territory__c
                WHERE Territory__c = :territoryId AND Account__r.Type__c = 'HCO'
                WITH USER_MODE LIMIT 10000
            ]) {
                hcoIds.add(link.Account__c);
            }
        }
        String soql = 'SELECT Id, Name, Billing_City__c, Geolocation__Latitude__s, Geolocation__Longitude__s, Geofence_Radius_M__c '
            + 'FROM Sciagen_Account__c WHERE Type__c = \'HCO\' AND Is_Merged__c = false '
            + 'AND (Name LIKE :pattern OR Billing_City__c LIKE :pattern)';
        if (byTerritory) soql += ' AND Id IN :hcoIds';
        if (customOnly == true) soql += ' AND Geofence_Radius_M__c != null';
        if (missingLocationOnly == true) soql += ' AND Geolocation__Latitude__s = null';
        soql += ' ORDER BY Name LIMIT 100';
        List<Sciagen_Account__c> rows = Database.queryWithBinds(
            soql, new Map<String, Object>{ 'pattern' => pattern, 'hcoIds' => hcoIds }, AccessLevel.USER_MODE);
        List<HcoDTO> out = new List<HcoDTO>();
        for (Sciagen_Account__c a : rows) {
            HcoDTO d = new HcoDTO();
            d.id = a.Id;
            d.name = a.Name;
            d.city = a.Billing_City__c;
            d.hasLocation = a.Geolocation__Latitude__s != null && a.Geolocation__Longitude__s != null;
            d.radiusOverrideM = a.Geofence_Radius_M__c;
            out.add(d);
        }
        return out;
    }

    @AuraEnabled(cacheable=false)
    public static List<OptionDTO> getTerritories() {
        List<OptionDTO> out = new List<OptionDTO>();
        for (Territory__c t : [SELECT Id, Name FROM Territory__c WITH USER_MODE ORDER BY Name LIMIT 1000]) {
            OptionDTO o = new OptionDTO();
            o.id = t.Id;
            o.name = t.Name;
            out.add(o);
        }
        return out;
    }

    @AuraEnabled(cacheable=false)
    public static List<RuleDTO> getRules() {
        List<Geofence_Rule__c> rows = [
            SELECT Id, Scope__c, Territory__c, Territory__r.Name, User__c, User__r.Name, Active__c,
                   Enabled__c, Enforce_Check_In__c, Default_Radius_M__c, Note__c
            FROM Geofence_Rule__c
            WITH USER_MODE
            ORDER BY Scope__c, Territory__r.Name, User__r.Name
            LIMIT 2000
        ];
        Set<Id> ruleUsers = new Set<Id>();
        for (Geofence_Rule__c g : rows) {
            if (g.User__c != null) ruleUsers.add(g.User__c);
        }
        Map<Id, List<User_Territory__c>> membership = new Map<Id, List<User_Territory__c>>();
        if (!ruleUsers.isEmpty()) {
            for (User_Territory__c m : [
                SELECT User__c, Territory__c, Territory__r.Name FROM User_Territory__c
                WHERE User__c IN :ruleUsers AND Territory__c != null
                WITH USER_MODE
            ]) {
                if (!membership.containsKey(m.User__c)) membership.put(m.User__c, new List<User_Territory__c>());
                membership.get(m.User__c).add(m);
            }
        }
        List<RuleDTO> out = new List<RuleDTO>();
        for (Geofence_Rule__c g : rows) {
            RuleDTO d = new RuleDTO();
            d.id = g.Id;
            d.scope = g.Scope__c;
            d.territoryId = g.Territory__c;
            d.territoryName = g.Territory__r?.Name;
            d.userId = g.User__c;
            d.userName = g.User__r?.Name;
            d.active = g.Active__c == true;
            d.enabled = g.Enabled__c == true;
            d.enforce = g.Enforce_Check_In__c == true;
            d.radiusM = g.Default_Radius_M__c;
            d.note = g.Note__c;
            d.memberTerritoryIds = new List<Id>();
            List<String> names = new List<String>();
            for (User_Territory__c m : membership.containsKey(g.User__c) ? membership.get(g.User__c) : new List<User_Territory__c>()) {
                d.memberTerritoryIds.add(m.Territory__c);
                names.add(m.Territory__r.Name);
            }
            names.sort();
            d.memberTerritoryNames = String.join(names, ', ');
            out.add(d);
        }
        return out;
    }

    /** One rule per Territory and one per User. Pass ruleId to edit; the target of an existing rule can't change. */
    @AuraEnabled
    public static Id saveRule(Id ruleId, String scope, Id territoryId, Id userId, Boolean active,
                              Boolean enabled, Boolean enforce, Decimal radiusM, String note) {
        requireEditable(Geofence_Rule__c.SObjectType.getDescribe().isCreateable());
        if (scope != 'Territory' && scope != 'User') throw new AuraHandledException('Choose whether the rule applies to a Territory or a User.');
        Id target = scope == 'Territory' ? territoryId : userId;
        if (target == null) throw new AuraHandledException('Choose the ' + scope.toLowerCase() + ' this rule applies to.');
        if (radiusM != null) validateRadius(radiusM);
        String key = scope + ':' + String.valueOf(target);

        Geofence_Rule__c rule;
        if (ruleId != null) {
            rule = [SELECT Id, Rule_Key__c FROM Geofence_Rule__c WHERE Id = :ruleId WITH USER_MODE LIMIT 1];
            if (rule.Rule_Key__c != key) throw new AuraHandledException('A rule can\'t be moved to a different ' + scope.toLowerCase() + '. Create a new rule instead.');
        } else {
            if (![SELECT Id FROM Geofence_Rule__c WHERE Rule_Key__c = :key LIMIT 1].isEmpty()) {
                throw new AuraHandledException('There is already a rule for this ' + scope.toLowerCase() + '. Edit that rule instead.');
            }
            rule = new Geofence_Rule__c(Rule_Key__c = key, Scope__c = scope);
            if (scope == 'Territory') rule.Territory__c = territoryId; else rule.User__c = userId;
        }
        rule.Active__c = active != false;
        rule.Enabled__c = enabled == true;
        rule.Enforce_Check_In__c = enforce == true;
        rule.Default_Radius_M__c = radiusM;
        rule.Note__c = String.isBlank(note) ? null : note.trim().left(255);
        if (ruleId == null) insert as user rule; else update as user rule;
        return rule.Id;
    }

    @AuraEnabled
    public static void deleteRule(Id ruleId) {
        requireEditable(Geofence_Rule__c.SObjectType.getDescribe().isDeletable());
        List<Geofence_Rule__c> rows = [SELECT Id FROM Geofence_Rule__c WHERE Id = :ruleId WITH USER_MODE LIMIT 1];
        if (!rows.isEmpty()) delete as user rows;
    }

    /** What a specific rep gets, and which level of the hierarchy decided it. */
    @AuraEnabled(cacheable=false)
    public static EffectiveDTO previewForUser(Id userId) {
        if (userId == null) throw new AuraHandledException('Choose a user.');
        User u = [SELECT Name FROM User WHERE Id = :userId WITH USER_MODE LIMIT 1];
        GeofenceSettingResolver.Resolved r = GeofenceSettingResolver.resolveForUser(userId);
        EffectiveDTO d = new EffectiveDTO();
        d.userName = u.Name;
        d.enabled = r.enabled;
        d.enforce = r.enforce;
        d.radiusM = r.defaultRadiusM;
        d.source = r.source;
        return d;
    }

    /** radiusM null clears the override so the HCO uses the default radius. */
    @AuraEnabled
    public static void saveHcoRadius(Id hcoId, Decimal radiusM) {
        if (radiusM != null) validateRadius(radiusM);
        Sciagen_Account__c a = new Sciagen_Account__c(Id = hcoId, Geofence_Radius_M__c = radiusM);
        update as user a;
    }

    private static void validateRadius(Decimal radiusM) {
        if (radiusM == null || radiusM < MIN_RADIUS_M || radiusM > MAX_RADIUS_M) {
            throw new AuraHandledException('Radius must be between ' + MIN_RADIUS_M + ' and ' + MAX_RADIUS_M + ' metres.');
        }
    }

    private static void requireEditable(Boolean ok) {
        if (!ok) throw new AuraHandledException('You do not have permission to change geofence settings.');
    }
}