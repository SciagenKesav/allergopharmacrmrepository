/**
 * Works out which geofence rule applies to one rep. Order, most specific first:
 *   1. an active User rule for that rep
 *   2. an active Territory rule for the rep's territories - the primary
 *      territory wins; a territory with no rule inherits from its nearest
 *      parent; if several non-primary territories match, the strictest wins
 *   3. the Geofence Setting custom setting (User, then Profile, then org default)
 * Runs without sharing because it only ever returns the resolved values, never
 * the rule records, and reps have no read access to the rule object.
 */
public without sharing class GeofenceSettingResolver {

    public static final Decimal FALLBACK_RADIUS_M = 200;
    private static final Integer MAX_PARENT_HOPS = 10;

    public class Resolved {
        public Boolean enabled = true;
        public Boolean enforce = true;
        public Decimal defaultRadiusM = FALLBACK_RADIUS_M;
        public String source = 'Organization default';
    }

    public static Resolved resolveForUser(Id userId) {
        Resolved base = baseFor(userId);

        List<Geofence_Rule__c> userRules = [
            SELECT Enabled__c, Enforce_Check_In__c, Default_Radius_M__c
            FROM Geofence_Rule__c
            WHERE Active__c = true AND Scope__c = 'User' AND User__c = :userId
            LIMIT 1
        ];
        if (!userRules.isEmpty()) return apply(base, userRules[0], 'User rule');

        List<User_Territory__c> memberships = [
            SELECT Territory__c, Is_Primary__c
            FROM User_Territory__c
            WHERE User__c = :userId AND Territory__c != null
        ];
        if (memberships.isEmpty()) return base;

        Map<Id, Geofence_Rule__c> ruleByTerritory = new Map<Id, Geofence_Rule__c>();
        for (Geofence_Rule__c g : [
            SELECT Territory__c, Territory__r.Name, Enabled__c, Enforce_Check_In__c, Default_Radius_M__c
            FROM Geofence_Rule__c
            WHERE Active__c = true AND Scope__c = 'Territory' AND Territory__c != null
        ]) {
            ruleByTerritory.put(g.Territory__c, g);
        }
        if (ruleByTerritory.isEmpty()) return base;

        Map<Id, Id> parentOf = new Map<Id, Id>();
        for (Territory__c t : [SELECT Id, Parent_Territory__c FROM Territory__c WHERE Parent_Territory__c != null]) {
            parentOf.put(t.Id, t.Parent_Territory__c);
        }

        Geofence_Rule__c primaryRule = null;
        Map<Id, Geofence_Rule__c> matched = new Map<Id, Geofence_Rule__c>();
        for (User_Territory__c m : memberships) {
            Id current = m.Territory__c;
            Integer hops = 0;
            while (current != null && hops < MAX_PARENT_HOPS) {
                Geofence_Rule__c g = ruleByTerritory.get(current);
                if (g != null) {
                    matched.put(g.Id, g);
                    if (m.Is_Primary__c == true && primaryRule == null) primaryRule = g;
                    break;
                }
                current = parentOf.get(current);
                hops++;
            }
        }
        if (matched.isEmpty()) return base;
        if (primaryRule != null) return apply(base, primaryRule, 'Territory rule: ' + primaryRule.Territory__r.Name);
        if (matched.size() == 1) {
            Geofence_Rule__c only = matched.values()[0];
            return apply(base, only, 'Territory rule: ' + only.Territory__r.Name);
        }
        return strictest(base, matched.values());
    }

    private static Resolved baseFor(Id userId) {
        Resolved r = new Resolved();
        Id profileId = UserInfo.getUserId() == userId ? UserInfo.getProfileId() : null;
        if (profileId == null) {
            List<User> users = [SELECT ProfileId FROM User WHERE Id = :userId LIMIT 1];
            if (!users.isEmpty()) profileId = users[0].ProfileId;
        }
        Id orgId = UserInfo.getOrganizationId();
        Geofence_Setting__c pick = null;
        Integer rank = 0;
        for (Geofence_Setting__c c : [
            SELECT SetupOwnerId, Enabled__c, Enforce_Check_In__c, Default_Radius_M__c
            FROM Geofence_Setting__c WHERE SetupOwnerId IN (:userId, :profileId, :orgId)
        ]) {
            Integer level = c.SetupOwnerId == userId ? 3 : (c.SetupOwnerId == profileId ? 2 : 1);
            if (level > rank) { rank = level; pick = c; }
        }
        if (pick == null) {
            r.source = 'Built-in default';
            return r;
        }
        r.enabled = pick.Enabled__c == true;
        r.enforce = pick.Enforce_Check_In__c == true;
        r.defaultRadiusM = (pick.Default_Radius_M__c != null && pick.Default_Radius_M__c > 0) ? pick.Default_Radius_M__c : FALLBACK_RADIUS_M;
        r.source = rank == 3 ? 'User setting' : (rank == 2 ? 'Profile setting' : 'Organization default');
        return r;
    }

    private static Resolved apply(Resolved base, Geofence_Rule__c rule, String source) {
        Resolved r = new Resolved();
        r.enabled = rule.Enabled__c == true;
        r.enforce = rule.Enforce_Check_In__c == true;
        r.defaultRadiusM = (rule.Default_Radius_M__c != null && rule.Default_Radius_M__c > 0) ? rule.Default_Radius_M__c : base.defaultRadiusM;
        r.source = source;
        return r;
    }

    private static Resolved strictest(Resolved base, List<Geofence_Rule__c> rules) {
        Resolved r = new Resolved();
        List<String> names = new List<String>();
        Decimal radius = null;
        Boolean anyOn = false;
        Boolean anyBlock = false;
        for (Geofence_Rule__c g : rules) {
            names.add(g.Territory__r.Name);
            if (g.Enabled__c != true) continue;
            anyOn = true;
            if (g.Enforce_Check_In__c == true) anyBlock = true;
            Decimal rad = (g.Default_Radius_M__c != null && g.Default_Radius_M__c > 0) ? g.Default_Radius_M__c : base.defaultRadiusM;
            if (radius == null || rad < radius) radius = rad;
        }
        names.sort();
        r.enabled = anyOn;
        r.enforce = anyOn && anyBlock;
        r.defaultRadiusM = radius != null ? radius : base.defaultRadiusM;
        r.source = 'Territory rules, strictest of: ' + String.join(names, ', ');
        return r;
    }
}