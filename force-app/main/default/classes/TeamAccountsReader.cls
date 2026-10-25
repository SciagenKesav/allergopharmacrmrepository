/**
 * Reads the HCPs / HCOs in a KAM's territories for SciagenTeamScheduleApi's accounts endpoint
 * (the iPad's manager "view a KAM's accounts" picker on the Accounts tab).
 *
 * `without sharing` for the same reason as ScheduleCrossUserReader: Sciagen_Account__c is Private
 * and shared only by exact territory, so a manager cannot read a KAM's accounts through normal
 * sharing -- and `WITH USER_MODE` would re-apply sharing and return nothing. Field-level security
 * is still enforced for the manager (WITH SECURITY_ENFORCED). The caller is solely responsible for
 * authorising the manager -> KAM relationship; this class runs for whatever territories it is given.
 *
 * "A KAM's accounts" = the accounts linked (Account_Territory__c) to the KAM's own territories --
 * the same rule TerritorySharingService uses to give the KAM their own list. It is a territory
 * list, so KAMs who share a territory see (and are shown) the same accounts.
 */
public without sharing class TeamAccountsReader {

    // The fields the iPad already maps for the user's own Accounts list (hcpQuery / hcoQuery).
    private static final String HCP_FIELDS = 'Id, Prefix__c, First_Name__c, Last_Name__c, Primary_Country__c, HCP_Type__c, '
        + 'Age__c, Experience_Years__c, Specialty__c, Degree_1__c, Degree_2__c, Degree_3__c, Degree_4__c, Degree_5__c, '
        + 'Graduation_Year__c, Email__c, License_Number__c, Licensing_Body__c, Licensing_Year__c, Focus_Area__c, '
        + 'Profile_Summary__c, Phone__c, Account_Code__c, LinkedIn_URL__c, YouTube_URL__c, Twitter_URL__c, '
        + 'Instagram_URL__c, Reach_Flag__c, Emerging_Expert__c, Total_Articles__c, Unique_Journal_Count__c, '
        + 'Total_Citations__c, Avg_Citations_Per_Article__c, Guideline_Count__c, Actively_Published_Years__c, '
        + 'Avg_Coauthors_Per_Article__c, Last_Visit__c';
    private static final String HCO_FIELDS = 'Id, Name, Speciality__c, HCO_Type__c, Billing_Street__c, Billing_City__c, '
        + 'Billing_State__c, Billing_Postal_Code__c, Plus_Code__c, Geolocation__Latitude__s, Geolocation__Longitude__s, '
        + 'Website__c, Phone__c, Email__c, Account_Code__c, Parent_Account__c';

    public class AccountPage {
        public List<Map<String, Object>> rows = new List<Map<String, Object>>();
        public Integer total = 0;
        public Boolean hasMore = false;
        public Id lastId;
    }

    /// One page of a KAM's HCPs ('HCP') or HCOs ('HCO'), ordered by Id. Page with `offset`
    /// (SOQL caps it at 2,000) or, for big territories, `afterId` = the previous page's lastId.
    public static AccountPage page(String type, Set<Id> territoryIds, Integer pageSize, Integer pageOffset, Id afterId) {
        AccountPage result = new AccountPage();
        Set<Id> accountIds = new Set<Id>();
        if (territoryIds != null && !territoryIds.isEmpty()) {
            for (Account_Territory__c at : [SELECT Account__c FROM Account_Territory__c WHERE Territory__c IN :territoryIds]) {
                accountIds.add(at.Account__c);
            }
        }
        if (accountIds.isEmpty()) { return result; }

        String fields = type == 'HCP' ? HCP_FIELDS : HCO_FIELDS;
        Map<String, Object> binds = new Map<String, Object>{ 'type' => type, 'accountIds' => accountIds };
        String base = ' FROM Sciagen_Account__c WHERE Type__c = :type AND Id IN :accountIds';
        result.total = Database.countQueryWithBinds('SELECT COUNT()' + base, binds, AccessLevel.SYSTEM_MODE);

        String soql = 'SELECT ' + fields + base;
        if (afterId != null) { soql += ' AND Id > :afterId'; binds.put('afterId', afterId); }
        soql += ' WITH SECURITY_ENFORCED ORDER BY Id LIMIT :lim OFFSET :off';
        binds.put('lim', pageSize + 1); // one extra row tells us whether another page exists
        binds.put('off', afterId != null ? 0 : pageOffset);
        List<Sciagen_Account__c> found = Database.queryWithBinds(soql, binds, AccessLevel.SYSTEM_MODE);
        if (found.size() > pageSize) {
            result.hasMore = true;
            found.remove(found.size() - 1);
        }

        Set<Id> pageIds = new Set<Id>();
        for (Sciagen_Account__c a : found) { pageIds.add(a.Id); }
        Map<Id, String> territoryNames = territoryNamesFor(pageIds, territoryIds);
        Map<Id, Affiliation__c> primaryAffiliation = type == 'HCP' ? primaryAffiliations(pageIds) : new Map<Id, Affiliation__c>();
        Map<Id, Map<String, Object>> segmentation = type == 'HCP' ? segmentationFor(pageIds) : new Map<Id, Map<String, Object>>();

        for (Sciagen_Account__c a : found) {
            Map<String, Object> row = new Map<String, Object>(a.getPopulatedFieldsAsMap());
            row.remove('attributes');
            row.put('territory', territoryNames.get(a.Id));
            if (type == 'HCP') {
                Affiliation__c aff = primaryAffiliation.get(a.Id);
                row.put('primaryHcoId', aff != null ? aff.HCO__c : null);
                row.put('primaryHcoName', aff != null && aff.HCO__r != null ? aff.HCO__r.Name : null);
                row.put('segmentation', segmentation.get(a.Id));
            }
            result.rows.add(row);
            result.lastId = a.Id;
        }
        return result;
    }

    private static Map<Id, String> territoryNamesFor(Set<Id> accountIds, Set<Id> territoryIds) {
        Map<Id, List<String>> names = new Map<Id, List<String>>();
        for (Account_Territory__c at : [
            SELECT Account__c, Territory__r.Name FROM Account_Territory__c
            WHERE Account__c IN :accountIds AND Territory__c IN :territoryIds
        ]) {
            if (!names.containsKey(at.Account__c)) { names.put(at.Account__c, new List<String>()); }
            names.get(at.Account__c).add(at.Territory__r.Name);
        }
        Map<Id, String> joined = new Map<Id, String>();
        for (Id accountId : names.keySet()) { joined.put(accountId, String.join(names.get(accountId), ', ')); }
        return joined;
    }

    private static Map<Id, Affiliation__c> primaryAffiliations(Set<Id> hcpIds) {
        Map<Id, Affiliation__c> out = new Map<Id, Affiliation__c>();
        for (Affiliation__c aff : [
            SELECT HCP__c, HCO__c, HCO__r.Name FROM Affiliation__c
            WHERE HCP__c IN :hcpIds AND Is_Primary__c = true ORDER BY CreatedDate
        ]) {
            if (!out.containsKey(aff.HCP__c)) { out.put(aff.HCP__c, aff); }
        }
        return out;
    }

    // Segmentation is per HCP; if more than one row exists the oldest is used.
    private static Map<Id, Map<String, Object>> segmentationFor(Set<Id> hcpIds) {
        Map<Id, Segmentation__c> chosen = new Map<Id, Segmentation__c>();
        for (Segmentation__c s : [
            SELECT HCP__c, Classification__c, Potential__c, Priority__c, Tier__c, Is_KOL__c, Tags__c,
                   Adoption_Ladder__c, Behaviour_Segmentation__c, Customer_Profile__c, Relationship__c, AIT_Preference__c, Prescription_Pattern__c
            FROM Segmentation__c WHERE HCP__c IN :hcpIds ORDER BY CreatedDate
        ]) {
            if (!chosen.containsKey(s.HCP__c)) { chosen.put(s.HCP__c, s); }
        }
        Map<Id, Map<String, Object>> out = new Map<Id, Map<String, Object>>();
        for (Id hcpId : chosen.keySet()) {
            Segmentation__c s = chosen.get(hcpId);
            out.put(hcpId, new Map<String, Object>{
                'Classification__c' => s.Classification__c, 'Potential__c' => s.Potential__c, 'Priority__c' => s.Priority__c,
                'Tier__c' => s.Tier__c, 'Is_KOL__c' => s.Is_KOL__c, 'Tags__c' => s.Tags__c,
                'Adoption_Ladder__c' => s.Adoption_Ladder__c, 'Behaviour_Segmentation__c' => s.Behaviour_Segmentation__c,
                'Customer_Profile__c' => s.Customer_Profile__c, 'Relationship__c' => s.Relationship__c,
                'AIT_Preference__c' => s.AIT_Preference__c, 'Prescription_Pattern__c' => s.Prescription_Pattern__c
            });
        }
        return out;
    }
}