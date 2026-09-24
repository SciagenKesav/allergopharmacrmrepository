/**
 * Keeps the Dedupe_*_Key__c match keys on Sciagen_Account__c current. The keys are what let the
 * scan find candidates with indexed queries instead of comparing every record with every other.
 * Runs from the SciagenAccountDedupe trigger, before insert/update.
 */
public without sharing class DuplicateKeyService {

    // Any change to one of these means the record must be compared again.
    private static final List<String> WATCHED = new List<String>{
        'Name', 'First_Name__c', 'Last_Name__c', 'Type__c', 'Phone__c', 'Email__c', 'License_Number__c', 'Licensing_Body__c',
        'Speciality__c', 'Specialty__c', 'Billing_Street__c', 'Billing_City__c', 'Billing_Postal_Code__c', 'Plus_Code__c',
        'Website__c', 'Account_Code__c', 'External_Ids__c', 'Parent_Account__c', 'HCO_Type__c',
        'Geolocation__Latitude__s', 'Geolocation__Longitude__s'
    };

    public static void apply(List<Sciagen_Account__c> records, Map<Id, Sciagen_Account__c> oldMap) {
        for (Sciagen_Account__c a : records) {
            if (a.Is_Merged__c == true) continue;
            Sciagen_Account__c old = oldMap == null ? null : oldMap.get(a.Id);
            Boolean changed = old == null;
            if (!changed) {
                for (String f : WATCHED) {
                    if (a.get(f) != old.get(f)) { changed = true; break; }
                }
            }
            if (!changed) continue;
            computeKeys(a);
            a.Dedupe_Checked_At__c = null;
        }
    }

    public static void computeKeys(Sciagen_Account__c a) {
        Boolean isHco = a.Type__c == 'HCO';
        List<String> tokens;
        if (isHco) {
            tokens = DuplicateText.orgTokens(a.Name);
        } else {
            String full = String.isNotBlank(a.First_Name__c) || String.isNotBlank(a.Last_Name__c)
                ? (a.First_Name__c == null ? '' : a.First_Name__c) + ' ' + (a.Last_Name__c == null ? '' : a.Last_Name__c)
                : a.Name;
            tokens = DuplicateText.nameTokens(full);
        }
        a.Dedupe_Name_Key__c = emptyToNull(DuplicateText.nameKey(tokens));
        a.Dedupe_Sound_Key__c = emptyToNull(DuplicateText.soundKey(tokens));
        a.Dedupe_Phone_Key__c = DuplicateText.phoneKey(a.Phone__c);
        a.Dedupe_Email_Key__c = DuplicateText.emailKey(a.Email__c);
        a.Dedupe_License_Key__c = isHco ? null : DuplicateText.licenseKey(a.License_Number__c);
        a.Dedupe_Geo_Key__c = isHco ? DuplicateText.geoCell(a.Geolocation__Latitude__s, a.Geolocation__Longitude__s) : null;
    }

    /** Clear the keys so a merged (losing) record never shows up as a candidate again. */
    public static void clearKeys(Sciagen_Account__c a) {
        a.Dedupe_Name_Key__c = null;
        a.Dedupe_Sound_Key__c = null;
        a.Dedupe_Phone_Key__c = null;
        a.Dedupe_Email_Key__c = null;
        a.Dedupe_License_Key__c = null;
        a.Dedupe_Geo_Key__c = null;
    }

    private static String emptyToNull(String s) { return String.isBlank(s) ? null : s; }
}