/**
 * GET /services/apexrest/sciagen/v1/geofence-settings
 * The geofence rule that applies to the signed-in rep (User rule, Territory
 * rule, or the org default). The iPad calls it on every sync and caches the
 * answer so the rule is still enforced offline.
 */
@RestResource(urlMapping='/sciagen/v1/geofence-settings')
global with sharing class GeofenceSettingsService {

    global class Payload {
        global Boolean enabled;
        global Boolean enforce;
        global Decimal defaultRadiusM;
        global String source;
    }

    @HttpGet
    global static Payload getSettings() {
        GeofenceSettingResolver.Resolved r = GeofenceSettingResolver.resolveForUser(UserInfo.getUserId());
        Payload p = new Payload();
        p.enabled = r.enabled;
        p.enforce = r.enforce;
        p.defaultRadiusM = r.defaultRadiusM;
        p.source = r.source;
        return p;
    }
}