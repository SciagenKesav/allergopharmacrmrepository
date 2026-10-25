/**
 * Backend for the unified Account experience (list/search/filter/detail/related info)
 * built on Sciagen_Account__c — the custom object that replaced Standard Account.
 *
 * Security: `with sharing` enforces record-level sharing; every SOQL query uses
 * `WITH USER_MODE` so field- and object-level security (FLS/CRUD) are enforced
 * per running user, not just sharing rules. Read-only methods are marked
 * cacheable so the LWC's @wire calls benefit from client-side caching.
 */
public with sharing class SciagenAccountController {

    // MARK: - Wrapper types

    public class AccountSummary {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String type;
        @AuraEnabled public String subtitle;
        @AuraEnabled public String city;
        @AuraEnabled public String territory;
        @AuraEnabled public String phone;
        @AuraEnabled public String email;
        @AuraEnabled public Boolean isKOL;
        @AuraEnabled public Boolean isEmergingExpert;
        @AuraEnabled public Decimal latitude;
        @AuraEnabled public Decimal longitude;
        // Optional list/table columns the rep can switch on with "Add Column" in the Accounts page.
        @AuraEnabled public String specialty;
        @AuraEnabled public String subType;
        @AuraEnabled public String accountCode;
        @AuraEnabled public String website;
        @AuraEnabled public String focusArea;
        @AuraEnabled public String licenseNumber;
        @AuraEnabled public String licensingBody;
        @AuraEnabled public String licenseStatus;
        @AuraEnabled public Date licenseExpiry;
        @AuraEnabled public String reachFlag;
        @AuraEnabled public String street;
        @AuraEnabled public String state;
        @AuraEnabled public String postalCode;
        @AuraEnabled public String country;
        @AuraEnabled public Date lastVisit;
        @AuraEnabled public Decimal experienceYears;
        @AuraEnabled public Decimal graduationYear;
        @AuraEnabled public String councilRegNumber;
    }

    public class SavedViewItem {
        @AuraEnabled public Id id;
        @AuraEnabled public String viewName;
        @AuraEnabled public String filterJson;
        @AuraEnabled public String sortField;
        @AuraEnabled public Boolean sortAscending;
        @AuraEnabled public String layout;
        @AuraEnabled public Boolean isDefault;
    }

    public class CustomListItem {
        @AuraEnabled public Id id;
        @AuraEnabled public String listName;
    }

    public class RelatedAccountItem {
        @AuraEnabled public Id accountId;
        @AuraEnabled public String name;
        @AuraEnabled public String type;
        @AuraEnabled public String subtitle;
        @AuraEnabled public String phone;
        @AuraEnabled public String city;
        @AuraEnabled public String website;
        @AuraEnabled public Boolean isPrimary;
        // Full address + coordinates — only populated for an HCP's affiliated HCOs
        // (the map on an HCP's own Profile section shows its primary affiliation's
        // location, mirroring the iPad app's Address card).
        @AuraEnabled public String street;
        @AuraEnabled public String state;
        @AuraEnabled public String postalCode;
        @AuraEnabled public String plusCode;
        @AuraEnabled public Decimal latitude;
        @AuraEnabled public Decimal longitude;
    }

    // Multichannel consent summary for an HCP's Profile section — mirrors the
    // iPad app's ConsentRecord (UserModels.swift) without the raw signature/OTP
    // detail, which stays a mobile-only capture flow.
    public class ConsentInfo {
        @AuraEnabled public Id id;
        @AuraEnabled public Datetime capturedAt;
        @AuraEnabled public Boolean signed;
        @AuraEnabled public Boolean emailOptedIn;
        @AuraEnabled public Integer subscribedChannelCount;
    }

    public class PublicationItem {
        @AuraEnabled public Id id;
        @AuraEnabled public String title;
        @AuraEnabled public String pmid;
        @AuraEnabled public String publicationDate;
        @AuraEnabled public Integer citations;
        @AuraEnabled public String publicationType;
        @AuraEnabled public String link;
        @AuraEnabled public String coauthors;
        @AuraEnabled public String meshTerms;
    }

    public class CongressEventItem {
        @AuraEnabled public Id id;
        @AuraEnabled public String eventName;
        @AuraEnabled public String startDate;
        @AuraEnabled public String endDate;
        @AuraEnabled public String location;
        @AuraEnabled public String role;
        @AuraEnabled public String organizedBy;
        @AuraEnabled public String topic;
        @AuraEnabled public String link;
    }

    public class ClinicalTrialItem {
        @AuraEnabled public Id id;
        @AuraEnabled public String title;
        @AuraEnabled public String registryId;
        @AuraEnabled public String phase;
        @AuraEnabled public String sponsor;
        @AuraEnabled public String registry;
        @AuraEnabled public String studyType;
        @AuraEnabled public String condition;
        @AuraEnabled public String startDate;
        @AuraEnabled public String completionDate;
        @AuraEnabled public String locations;
        @AuraEnabled public String endpoints;
    }

    public class AcaroidInfo {
        @AuraEnabled public String brandName;           // from the Product master, see AcaroidConfig.brandName
        @AuraEnabled public String tier;               // HCO: Acaroid_Tier__c; HCP: Acaroid_Target_Tier__c
        @AuraEnabled public Decimal score;              // HCO: Acaroid_Potential_Score__c; HCP: Acaroid_Score_Total__c
        @AuraEnabled public String segment;             // HCP only: Acaroid_Segment__c
        @AuraEnabled public String readinessStatus;      // HCO only: Acaroid_Admin_Readiness_Status__c
        @AuraEnabled public String canAdminister;        // HCP only: Acaroid_Can_Administer_SCIT__c
        @AuraEnabled public Integer recommendedCallsMonth; // HCP only
        @AuraEnabled public String lastScoredDate;
    }

    public class SegmentationInfo {
        @AuraEnabled public Id id;
        @AuraEnabled public String classification;
        @AuraEnabled public String tier;
        @AuraEnabled public String priority;
        @AuraEnabled public String potential;
        @AuraEnabled public Boolean isKOL;
        @AuraEnabled public String ownerRep;
        @AuraEnabled public String tags;
        @AuraEnabled public String relationship;
        @AuraEnabled public String adoptionLadder;
        @AuraEnabled public String prescriptionPattern;
        @AuraEnabled public String aitPreference;
        @AuraEnabled public String behaviourSegmentation;
        @AuraEnabled public String customerProfile;
    }

    public class CVRItem {
        @AuraEnabled public Id id;
        @AuraEnabled public String visitDate;
        @AuraEnabled public String callType;
        @AuraEnabled public String status;
        @AuraEnabled public String rep;
        @AuraEnabled public String discussionSummary;
    }

    public class DCRItem {
        @AuraEnabled public Id id;
        @AuraEnabled public String type;
        @AuraEnabled public String status;
        @AuraEnabled public String summary;
        @AuraEnabled public String submittedBy;
        @AuraEnabled public String submittedAt;
    }

    // A merged, chronological feed of this account's Call Visit Reports and Data
    // Change Requests — the two related objects with a real (non-Text) date field
    // to sort by. Publications/Congress Events are left out of the timeline: their
    // date fields are free-text on this org, so merging them into one sorted feed
    // would risk a silently wrong order rather than a genuinely useful one.
    public class TimelineItem {
        @AuraEnabled public String kind; // 'CVR' or 'DCR'
        @AuraEnabled public String occurredAt;
        @AuraEnabled public String title;
        @AuraEnabled public String subtitle;
    }

    private class TimelineEntry implements Comparable {
        Datetime sortAt;
        TimelineItem item;
        TimelineEntry(Datetime sortAt, TimelineItem item) {
            this.sortAt = sortAt;
            this.item = item;
        }
        // Descending — most recent first. A null date sorts last.
        public Integer compareTo(Object other) {
            Datetime otherAt = ((TimelineEntry) other).sortAt;
            if (sortAt == otherAt) return 0;
            if (sortAt == null) return 1;
            if (otherAt == null) return -1;
            return sortAt > otherAt ? -1 : 1;
        }
    }

    public class AccountDetail {
        @AuraEnabled public Id id;
        @AuraEnabled public String type;
        @AuraEnabled public String name;
        @AuraEnabled public String accountCode;
        @AuraEnabled public String email;
        @AuraEnabled public String phone;
        @AuraEnabled public String territory;
        @AuraEnabled public Map<String, String> externalIds;
        @AuraEnabled public String lastVisit;
        @AuraEnabled public Datetime lastModified;
        @AuraEnabled public String createdByName;
        @AuraEnabled public String lastModifiedByName;

        // HCP fields (null when type = HCO)
        @AuraEnabled public String prefix;
        @AuraEnabled public String firstName;
        @AuraEnabled public String lastName;
        @AuraEnabled public String hcpType;
        @AuraEnabled public String specialty;
        @AuraEnabled public String focusArea;
        @AuraEnabled public String licenseNumber;
        @AuraEnabled public String licensingBody;
        @AuraEnabled public String primaryCountry;
        @AuraEnabled public Integer age;
        @AuraEnabled public Integer experienceYears;
        @AuraEnabled public List<String> degrees;
        @AuraEnabled public Integer graduationYear;
        @AuraEnabled public Integer licensingYear;
        @AuraEnabled public String linkedInUrl;
        @AuraEnabled public String twitterUrl;
        @AuraEnabled public String youtubeUrl;
        @AuraEnabled public String instagramUrl;
        @AuraEnabled public Integer totalArticles;
        @AuraEnabled public Integer totalCitations;
        @AuraEnabled public Decimal avgCitationsPerArticle;
        @AuraEnabled public Decimal avgCoauthorsPerArticle;
        @AuraEnabled public Integer uniqueJournalCount;
        @AuraEnabled public Integer guidelineCount;
        @AuraEnabled public Integer activelyPublishedYears;
        @AuraEnabled public Boolean emergingExpert;
        @AuraEnabled public String reachFlag;

        // HCO fields (null when type = HCP)
        @AuraEnabled public String hcoType;
        @AuraEnabled public String speciality;
        @AuraEnabled public String billingStreet;
        @AuraEnabled public String billingCity;
        @AuraEnabled public String billingState;
        @AuraEnabled public String billingCountry;
        @AuraEnabled public String billingPostalCode;
        @AuraEnabled public String website;
        @AuraEnabled public String plusCode;
        @AuraEnabled public String geolocation;
        @AuraEnabled public Decimal latitude;
        @AuraEnabled public Decimal longitude;
        @AuraEnabled public String parentAccountId;
        @AuraEnabled public String parentAccountName;

        @AuraEnabled public SegmentationInfo segmentation;
        @AuraEnabled public AcaroidInfo acaroid;
        @AuraEnabled public ConsentInfo consent;
        @AuraEnabled public List<RelatedAccountItem> affiliations;
        @AuraEnabled public List<PublicationItem> publications;
        @AuraEnabled public List<CongressEventItem> congressEvents;
        @AuraEnabled public List<ClinicalTrialItem> clinicalTrials;
        @AuraEnabled public List<CVRItem> callVisitReports;
        @AuraEnabled public List<DCRItem> dataChangeRequests;
        @AuraEnabled public List<TimelineItem> timeline;
        @AuraEnabled public List<OfficeWindowItem> officeWindows;
    }

    public class OfficeWindowItem {
        @AuraEnabled public Id id;
        @AuraEnabled public String day;
        @AuraEnabled public String timeWindow;
        @AuraEnabled public String preference;
        @AuraEnabled public String hcoName;
    }

    // MARK: - List / search / filter

    // Not cacheable: this is re-invoked right after create/edit saves (from accountBrowser's
    // handleAccountSaved), and a client-side-cached imperative call would keep showing the
    // pre-edit list — cacheable Apex methods are cached the same whether called via @wire or
    // imperatively, so `cacheable=true` here would silently defeat that refresh.
    @AuraEnabled
    public static List<AccountSummary> searchAccounts(
        String searchTerm, String typeFilter, String territoryFilter,
        String specialtyFilter, String hcoTypeFilter, String cityFilter,
        Boolean kolOnly, Boolean emergingOnly, String sortField, Boolean sortAscending,
        String segmentationFilter
    ) {
        String term = '%' + String.escapeSingleQuotes(searchTerm == null ? '' : searchTerm) + '%';

        // City has its own dedicated filter box below — kept out of the general
        // search term so the two don't overlap/compete for the same keystrokes.
        List<String> whereClauses = new List<String>{
            '(Name LIKE :term OR Specialty__c LIKE :term OR Speciality__c LIKE :term)'
        };
        Map<String, Object> binds = new Map<String, Object>{ 'term' => term };
        if (String.isNotBlank(typeFilter)) {
            whereClauses.add('Type__c = :typeFilter');
            binds.put('typeFilter', typeFilter);
        }
        if (String.isNotBlank(specialtyFilter)) {
            whereClauses.add('(Specialty__c = :specialtyFilter OR Speciality__c = :specialtyFilter)');
            binds.put('specialtyFilter', specialtyFilter);
        }
        if (String.isNotBlank(hcoTypeFilter)) {
            whereClauses.add('HCO_Type__c = :hcoTypeFilter');
            binds.put('hcoTypeFilter', hcoTypeFilter);
        }
        if (String.isNotBlank(cityFilter)) {
            String cityTerm = '%' + String.escapeSingleQuotes(cityFilter) + '%';
            whereClauses.add('Billing_City__c LIKE :cityTerm');
            binds.put('cityTerm', cityTerm);
        }
        if (emergingOnly == true) {
            whereClauses.add('Emerging_Expert__c = true');
        }
        // Territory (or a Region, which includes every territory under it) is applied inside the query,
        // before the row cap below -- filtering the capped list afterwards returned only whichever few
        // accounts of that territory happened to fall within the first rows alphabetically.
        if (String.isNotBlank(territoryFilter)) {
            Set<Id> territoryAccountIds = accountIdsInTerritoryNames(territoryNamesWithChildren(territoryFilter));
            whereClauses.add('Id IN :territoryAccountIds');
            binds.put('territoryAccountIds', territoryAccountIds);
        }

        // AccessLevel.USER_MODE (passed to queryWithBinds below) enforces FLS/CRUD here —
        // a query string can't also carry `WITH USER_MODE` alongside an explicit AccessLevel.
        // Sorting is applied after this query (see below), once territory/KOL are known —
        // Territory isn't a direct field (it comes from the junction map further down), so
        // it can't be an ORDER BY target in SOQL.
        String query = 'SELECT Id, Name, Type__c, HCP_Type__c, Specialty__c, HCO_Type__c, Speciality__c, ' +
            'Billing_City__c, Phone__c, Email__c, Emerging_Expert__c, Geolocation__Latitude__s, Geolocation__Longitude__s, ' +
            'Account_Code__c, Website__c, Focus_Area__c, License_Number__c, Licensing_Body__c, License_Verification_Status__c, ' +
            'License_Expiry_Date__c, Reach_Flag__c, Billing_Street__c, Billing_State__c, Billing_Postal_Code__c, Billing_Country__c, ' +
            'Last_Visit__c, Experience_Years__c, Graduation_Year__c, Medical_Council_Reg_Number__c ' +
            'FROM Sciagen_Account__c WHERE ' + String.join(whereClauses, ' AND ') + ' ORDER BY Name LIMIT 500';

        List<Sciagen_Account__c> accounts = Database.queryWithBinds(query, binds, AccessLevel.USER_MODE);

        Map<Id, String> territoryByAccountId = territoryNamesByAccountId(idsOf(accounts));

        // Baseline territory scoping for non-admin users: never show an account with no
        // territory link at all, or one outside the user's own territories, even one they
        // happen to own -- Private OWD ownership alone shouldn't leak unassigned/seed data
        // into the Accounts list just because the owner's territory assignment changed (or
        // was never set) after the record was created. Independent of the optional
        // territoryFilter param below, which only narrows further once this baseline applies.
        if (!isViewAllDataUser()) {
            Set<String> myTerritories = myVisibleTerritoryNames();
            List<Sciagen_Account__c> inTerritory = new List<Sciagen_Account__c>();
            for (Sciagen_Account__c acc : accounts) {
                String t = territoryByAccountId.get(acc.Id);
                if (t != null && myTerritories.contains(t)) {
                    inTerritory.add(acc);
                }
            }
            accounts = inTerritory;
        }

        if (String.isNotBlank(territoryFilter)) {
            // A region (e.g. North) has no accounts of its own -- they sit on its child territories --
            // so picking a region matches every territory underneath it as well. A normal territory
            // has no children, so it still matches only itself.
            Set<String> filterNames = territoryNamesWithChildren(territoryFilter);
            List<Sciagen_Account__c> filtered = new List<Sciagen_Account__c>();
            for (Sciagen_Account__c acc : accounts) {
                if (filterNames.contains(territoryByAccountId.get(acc.Id))) {
                    filtered.add(acc);
                }
            }
            accounts = filtered;
        }

        Set<Id> hcpIds = new Set<Id>();
        for (Sciagen_Account__c acc : accounts) {
            if (acc.Type__c == 'HCP') {
                hcpIds.add(acc.Id);
            }
        }
        Set<Id> kolIds = new Set<Id>();
        if (!hcpIds.isEmpty()) {
            for (Segmentation__c seg : [
                SELECT HCP__c FROM Segmentation__c WHERE HCP__c IN :hcpIds AND Is_KOL__c = true WITH USER_MODE
            ]) {
                kolIds.add(seg.HCP__c);
            }
        }
        if (kolOnly == true) {
            List<Sciagen_Account__c> filtered = new List<Sciagen_Account__c>();
            for (Sciagen_Account__c acc : accounts) {
                if (kolIds.contains(acc.Id)) {
                    filtered.add(acc);
                }
            }
            accounts = filtered;
        }

        // Segmentation (Classification__c on Segmentation__c) is an HCP-only
        // concept — this naturally drops every HCO row when the filter is set,
        // same as kolOnly above.
        if (String.isNotBlank(segmentationFilter) && !hcpIds.isEmpty()) {
            Set<Id> segmentedHcpIds = new Set<Id>();
            for (Segmentation__c seg : [
                SELECT HCP__c FROM Segmentation__c
                WHERE HCP__c IN :hcpIds AND Classification__c = :segmentationFilter
                WITH USER_MODE
            ]) {
                segmentedHcpIds.add(seg.HCP__c);
            }
            List<Sciagen_Account__c> filtered = new List<Sciagen_Account__c>();
            for (Sciagen_Account__c acc : accounts) {
                if (segmentedHcpIds.contains(acc.Id)) {
                    filtered.add(acc);
                }
            }
            accounts = filtered;
        } else if (String.isNotBlank(segmentationFilter)) {
            accounts = new List<Sciagen_Account__c>();
        }

        List<AccountSummary> results = new List<AccountSummary>();
        for (Sciagen_Account__c acc : accounts) {
            AccountSummary summary = new AccountSummary();
            summary.id = acc.Id;
            summary.name = acc.Name;
            summary.type = acc.Type__c;
            summary.subtitle = acc.Type__c == 'HCP'
                ? String.join(new List<String>{ acc.Specialty__c, acc.HCP_Type__c }, ' · ')
                : String.join(new List<String>{ acc.HCO_Type__c, acc.Speciality__c }, ' · ');
            summary.city = acc.Billing_City__c;
            summary.territory = territoryByAccountId.get(acc.Id);
            summary.phone = acc.Phone__c;
            summary.email = acc.Email__c;
            summary.isKOL = kolIds.contains(acc.Id);
            summary.isEmergingExpert = acc.Emerging_Expert__c;
            summary.latitude = acc.Geolocation__Latitude__s;
            summary.longitude = acc.Geolocation__Longitude__s;
            summary.specialty = acc.Type__c == 'HCP' ? acc.Specialty__c : acc.Speciality__c;
            summary.subType = acc.Type__c == 'HCP' ? acc.HCP_Type__c : acc.HCO_Type__c;
            summary.accountCode = acc.Account_Code__c;
            summary.website = acc.Website__c;
            summary.focusArea = acc.Focus_Area__c;
            summary.licenseNumber = acc.License_Number__c;
            summary.licensingBody = acc.Licensing_Body__c;
            summary.licenseStatus = acc.License_Verification_Status__c;
            summary.licenseExpiry = acc.License_Expiry_Date__c;
            summary.reachFlag = acc.Reach_Flag__c;
            summary.street = acc.Billing_Street__c;
            summary.state = acc.Billing_State__c;
            summary.postalCode = acc.Billing_Postal_Code__c;
            summary.country = acc.Billing_Country__c;
            summary.lastVisit = acc.Last_Visit__c;
            summary.experienceYears = acc.Experience_Years__c;
            summary.graduationYear = acc.Graduation_Year__c;
            summary.councilRegNumber = acc.Medical_Council_Reg_Number__c;
            results.add(summary);
        }

        return sortSummaries(results, sortField, sortAscending);
    }

    private class SummaryEntry implements Comparable {
        String sortKey;
        AccountSummary item;
        SummaryEntry(String sortKey, AccountSummary item) {
            this.sortKey = sortKey;
            this.item = item;
        }
        public Integer compareTo(Object other) {
            // Case-insensitive: String.compareTo() is ASCII-ordinal (all uppercase letters
            // sort before all lowercase), which would put "AIIMS" before "Action Cancer
            // Clinic" — not the alphabetical order a user expects.
            String a = (sortKey == null ? '' : sortKey).toLowerCase();
            String b = (((SummaryEntry) other).sortKey == null ? '' : ((SummaryEntry) other).sortKey).toLowerCase();
            return a.compareTo(b);
        }
    }

    private static List<AccountSummary> sortSummaries(List<AccountSummary> summaries, String sortField, Boolean sortAscending) {
        String field = String.isBlank(sortField) ? 'Name' : sortField;
        List<SummaryEntry> entries = new List<SummaryEntry>();
        for (AccountSummary s : summaries) {
            String key = field == 'City' ? s.city : (field == 'Territory' ? s.territory : s.name);
            entries.add(new SummaryEntry(key, s));
        }
        entries.sort();
        List<AccountSummary> sorted = new List<AccountSummary>();
        if (sortAscending == false) {
            for (Integer i = entries.size() - 1; i >= 0; i--) {
                sorted.add(entries[i].item);
            }
        } else {
            for (SummaryEntry e : entries) {
                sorted.add(e.item);
            }
        }
        return sorted;
    }

    /// The accounts linked (Account_Territory__c) to any of the named territories.
    @TestVisible
    private static Set<Id> accountIdsInTerritoryNames(Set<String> territoryNames) {
        Set<Id> ids = new Set<Id>();
        for (Account_Territory__c at : [
            SELECT Account__c FROM Account_Territory__c WHERE Territory__r.Name IN :territoryNames WITH USER_MODE
        ]) {
            ids.add(at.Account__c);
        }
        return ids;
    }

    /// The territory itself plus every territory below it, by name -- the Accounts page territory
    /// filter uses this so picking a Region returns the accounts of all its child territories.
    @TestVisible
    private static Set<String> territoryNamesWithChildren(String territoryName) {
        Set<String> names = new Set<String>{ territoryName };
        Set<Id> ids = new Set<Id>();
        for (Territory__c t : [SELECT Id FROM Territory__c WHERE Name = :territoryName WITH USER_MODE]) ids.add(t.Id);
        if (ids.isEmpty()) return names;
        for (Territory__c t : [SELECT Name FROM Territory__c WHERE Id IN :TerritoryHierarchyUtil.withDescendants(ids) WITH USER_MODE]) {
            names.add(t.Name);
        }
        return names;
    }

    /// True for a user with view-all-data access (e.g. System Administrator, or a Business Admin) -- already sees
    /// every account regardless of territory, via sharing, so territory scoping doesn't apply
    /// to them (getTerritoryOptions' full unfiltered list, and searchAccounts' baseline
    /// restriction below, both key off this).
    private static Boolean isViewAllDataUser() {
        User runningUser = [SELECT Profile.Name, Profile.PermissionsViewAllData FROM User WHERE Id = :UserInfo.getUserId() WITH USER_MODE];
        // A Business Admin sees every account too (View All via Business_Admin_Full_Access), though the
        // profile itself lacks View All Data -- without this they were limited to their own (usually
        // no) territories and saw zero HCPs/HCOs.
        return runningUser.Profile.PermissionsViewAllData == true || runningUser.Profile.Name == 'Business Admin';
    }

    /// The running user's own territory names, including every descendant territory
    /// (TerritoryHierarchyUtil) -- a manager assigned to the "North" parent territory gets
    /// "North" and every territory under it, same as the sharing model those assignments
    /// already grant. Empty for a user with no territory assignment. Shared by
    /// getTerritoryOptions() (the filter dropdown) and searchAccounts() (the baseline
    /// restriction that keeps a non-admin from ever seeing an account with no territory
    /// link at all, even one they happen to own).
    private static Set<String> myVisibleTerritoryNames() {
        Set<Id> myTerritoryIds = new Set<Id>();
        for (User_Territory__c ut : [
            SELECT Territory__c FROM User_Territory__c
            WHERE User__c = :UserInfo.getUserId() AND Territory__c != null
            WITH USER_MODE
        ]) {
            myTerritoryIds.add(ut.Territory__c);
        }

        Set<String> names = new Set<String>();
        if (myTerritoryIds.isEmpty()) return names;

        Set<Id> visibleTerritoryIds = TerritoryHierarchyUtil.withDescendants(myTerritoryIds);
        for (Territory__c t : [SELECT Name FROM Territory__c WHERE Id IN :visibleTerritoryIds WITH USER_MODE]) {
            names.add(t.Name);
        }
        return names;
    }

    /// Territory filter options for the Accounts (and RCPA Audits, via RCPAController's
    /// delegate) browser sidebar. A view-all-data user (e.g. System Administrator) gets every
    /// territory in the org; anyone else gets only their own (see myVisibleTerritoryNames).
    @AuraEnabled(cacheable=true)
    public static List<String> getTerritoryOptions() {
        if (isViewAllDataUser()) {
            List<String> names = new List<String>();
            for (Territory__c t : [SELECT Name FROM Territory__c WITH USER_MODE ORDER BY Name]) {
                names.add(t.Name);
            }
            return names;
        }

        List<String> sorted = new List<String>(myVisibleTerritoryNames());
        sorted.sort();
        return sorted;
    }

    /// Territory name(s) the running user belongs to (User_Territory__c) --
    /// shown on the Accounts page so a rep sees at a glance which territory
    /// they're in right after logging in. Purely a "here's where I am" label;
    /// the account list itself is already scoped to the rep's territory by
    /// sharing (AccountTerritoryShareSync), not by this value.
    @AuraEnabled(cacheable=true)
    public static List<String> getMyTerritoryNames() {
        Set<String> names = new Set<String>();
        for (User_Territory__c ut : [
            SELECT Territory__r.Name
            FROM User_Territory__c
            WHERE User__c = :UserInfo.getUserId() AND Territory__c != null
            WITH USER_MODE
        ]) {
            names.add(ut.Territory__r.Name);
        }
        List<String> sorted = new List<String>(names);
        sorted.sort();
        return sorted;
    }

    @AuraEnabled(cacheable=true)
    public static List<String> getSpecialtyOptions() {
        return picklistValues(Sciagen_Account__c.Specialty__c.getDescribe());
    }

    @AuraEnabled(cacheable=true)
    public static List<String> getHCOTypeOptions() {
        return picklistValues(Sciagen_Account__c.HCO_Type__c.getDescribe());
    }

    @AuraEnabled(cacheable=true)
    public static List<String> getSegmentationOptions() {
        return picklistValues(Segmentation__c.Classification__c.getDescribe());
    }

    @AuraEnabled(cacheable=true)
    public static List<String> getHCPTypeOptions() {
        return picklistValues(Sciagen_Account__c.HCP_Type__c.getDescribe());
    }

    // HCO's own free-text-picklist ("Speciality__c") is a distinct field from an HCP's
    // "Specialty__c" — see HCO_CREATE_FIELDS/HCP_CREATE_FIELDS in accountBrowser.js.
    @AuraEnabled(cacheable=true)
    public static List<String> getHCOSpecialtyOptions() {
        return picklistValues(Sciagen_Account__c.Speciality__c.getDescribe());
    }

    private static List<String> picklistValues(Schema.DescribeFieldResult describe) {
        List<String> values = new List<String>();
        for (Schema.PicklistEntry entry : describe.getPicklistValues()) {
            if (entry.isActive()) {
                values.add(entry.getValue());
            }
        }
        return values;
    }

    // MARK: - New Account Request (KAM gate)

    // KAM profiles have full CRUD on Sciagen_Account__c (needed for editing accounts
    // already in their territory), but creating a brand-new HCP/HCO straight from the
    // web should still go through the same DCR governance gate the iPad app enforces —
    // see DataChangeRequestApprovalHandler. accountBrowser.js swaps its "New" button for
    // "New Request" based on this flag.
    @AuraEnabled(cacheable=true)
    public static Boolean isKeyAccountManager() {
        List<User> me = [SELECT Profile.Name FROM User WHERE Id = :UserInfo.getUserId() WITH USER_MODE LIMIT 1];
        return !me.isEmpty() && me[0].Profile.Name == 'Key Account Manager';
    }

    /**
     * Submits a "New HCP"/"New HCO" Data_Change_Request__c instead of creating the
     * Sciagen_Account__c directly — the fields map must use the same keys
     * DataChangeRequestApprovalHandler.buildHCP/buildHCO read (prefix/firstName/
     * lastName/specialty/hcpType/email/phone/degree1 for HCP; name/type/speciality/
     * city/state/pincode/phone for HCO), so the account it auto-creates on approval
     * comes out right. relatedHCOId is required for a New HCP request — the approval
     * handler can't create the Affiliation__c without it.
     */
    @AuraEnabled
    public static Id submitNewAccountRequest(String acctType, Map<String, String> fields, Id relatedHCOId) {
        if (acctType != 'HCP' && acctType != 'HCO') {
            throw new AuraHandledException('Type must be HCP or HCO.');
        }
        if (acctType == 'HCP' && relatedHCOId == null) {
            throw new AuraHandledException('Select the HCO this HCP is affiliated with.');
        }

        String subjectName = acctType == 'HCO'
            ? (fields.get('name') != null ? fields.get('name').trim() : null)
            : joinNonBlank(new List<String>{ fields.get('prefix'), fields.get('firstName'), fields.get('lastName') });
        if (String.isBlank(subjectName)) {
            throw new AuraHandledException('Name is required.');
        }

        Data_Change_Request__c dcr = new Data_Change_Request__c(
            Type__c = acctType == 'HCO' ? 'New HCO' : 'New HCP',
            Subject_Name__c = subjectName.left(255),
            Fields_Payload__c = JSON.serialize(fields),
            Status__c = 'Pending Approval',
            Submitted_By__c = UserInfo.getUserId(),
            Submitted_At__c = Datetime.now(),
            Related_HCO__c = acctType == 'HCP' ? relatedHCOId : null
        );
        Database.insert(dcr, AccessLevel.USER_MODE);
        return dcr.Id;
    }

    private static String joinNonBlank(List<String> parts) {
        List<String> out = new List<String>();
        for (String p : parts) {
            if (String.isNotBlank(p)) out.add(p.trim());
        }
        return String.join(out, ' ');
    }

    // MARK: - Saved Views

    @AuraEnabled(cacheable=true)
    public static List<SavedViewItem> getSavedViews() {
        List<SavedViewItem> results = new List<SavedViewItem>();
        for (Saved_Filter__c f : [
            SELECT Id, View_Name__c, Filter_JSON__c, Sort_Field__c, Sort_Ascending__c, Layout__c, Is_Default__c
            FROM Saved_Filter__c
            WHERE OwnerId = :UserInfo.getUserId()
            WITH USER_MODE
            ORDER BY View_Name__c
        ]) {
            SavedViewItem item = new SavedViewItem();
            item.id = f.Id;
            item.viewName = f.View_Name__c;
            item.filterJson = f.Filter_JSON__c;
            item.sortField = f.Sort_Field__c;
            item.sortAscending = f.Sort_Ascending__c;
            item.layout = f.Layout__c;
            item.isDefault = f.Is_Default__c;
            results.add(item);
        }
        return results;
    }

    @AuraEnabled
    public static Id saveView(Id viewId, String viewName, String filterJson, String sortField, Boolean sortAscending, String layout) {
        Saved_Filter__c f = new Saved_Filter__c(
            View_Name__c = viewName,
            Filter_JSON__c = filterJson,
            Sort_Field__c = sortField,
            Sort_Ascending__c = sortAscending == true,
            Layout__c = String.isBlank(layout) ? 'List' : layout
        );
        if (viewId != null) {
            f.Id = viewId;
            Database.update(f, AccessLevel.USER_MODE);
        } else {
            Database.insert(f, AccessLevel.USER_MODE);
        }
        return f.Id;
    }

    @AuraEnabled
    public static void deleteSavedView(Id viewId) {
        Database.delete(new Saved_Filter__c(Id = viewId), AccessLevel.USER_MODE);
    }

    // MARK: - Custom Lists (bulk "Add to List")

    // Must stay cacheable=true — accountBrowser.js consumes it via @wire, and
    // Lightning requires @wire'd Apex methods to be cacheable. The staleness
    // this caused (a just-created list not appearing in either the "add to"
    // dropdown or the Custom List filter until a full page reload — and why
    // this org ended up with two separate "Cardiologist" lists, since the
    // first didn't look reusable when the second was created) is fixed on the
    // LWC side instead, via refreshApex() invalidating the shared Apex cache
    // entry after a create/add — see accountBrowser.js's handleConfirmAddToList.
    @AuraEnabled(cacheable=true)
    public static List<CustomListItem> getCustomLists() {
        List<CustomListItem> results = new List<CustomListItem>();
        for (Custom_List__c l : [SELECT Id, List_Name__c FROM Custom_List__c WITH USER_MODE ORDER BY List_Name__c]) {
            CustomListItem item = new CustomListItem();
            item.id = l.Id;
            item.listName = l.List_Name__c;
            results.add(item);
        }
        return results;
    }

    @AuraEnabled
    public static Id createCustomList(String listName) {
        Custom_List__c l = new Custom_List__c(List_Name__c = listName);
        Database.insert(l, AccessLevel.USER_MODE);
        return l.Id;
    }

    @AuraEnabled
    public static void addAccountsToList(Id listId, List<Id> accountIds) {
        Set<Id> existingMemberAccountIds = new Set<Id>();
        for (Custom_List_Member__c m : [
            SELECT HCP__c FROM Custom_List_Member__c WHERE List__c = :listId AND HCP__c IN :accountIds WITH USER_MODE
        ]) {
            existingMemberAccountIds.add(m.HCP__c);
        }
        List<Custom_List_Member__c> toInsert = new List<Custom_List_Member__c>();
        for (Id accId : accountIds) {
            if (!existingMemberAccountIds.contains(accId)) {
                toInsert.add(new Custom_List_Member__c(List__c = listId, HCP__c = accId));
            }
        }
        if (!toInsert.isEmpty()) {
            Database.insert(toInsert, AccessLevel.USER_MODE);
        }
    }

    // MARK: - Detail

    // Not cacheable, for the same reason as searchAccounts above: accountDetail.js re-calls
    // this immediately after a successful edit save to refresh the read-only view, and a
    // cached imperative call would keep returning the pre-edit snapshot.
    @AuraEnabled
    public static AccountDetail getAccountDetail(Id accountId) {
        List<Sciagen_Account__c> matches = [
            SELECT Id, Type__c, Name, Account_Code__c, Email__c, Phone__c, External_Ids__c, LastModifiedDate,
                   Last_Visit__c, CreatedById, CreatedBy.Name, LastModifiedById, LastModifiedBy.Name,
                   Prefix__c, First_Name__c, Last_Name__c, HCP_Type__c, Specialty__c, Focus_Area__c,
                   License_Number__c, Licensing_Body__c, Primary_Country__c,
                   Age__c, Experience_Years__c, Degree_1__c, Degree_2__c, Degree_3__c, Degree_4__c, Degree_5__c,
                   Graduation_Year__c, Licensing_Year__c, LinkedIn_URL__c, Twitter_URL__c, YouTube_URL__c, Instagram_URL__c,
                   Total_Articles__c, Total_Citations__c, Avg_Citations_Per_Article__c, Avg_Coauthors_Per_Article__c,
                   Unique_Journal_Count__c, Guideline_Count__c, Actively_Published_Years__c, Emerging_Expert__c, Reach_Flag__c,
                   HCO_Type__c, Speciality__c, Billing_Street__c, Billing_City__c, Billing_State__c,
                   Billing_Country__c, Billing_Postal_Code__c, Website__c, Plus_Code__c,
                   Geolocation__Latitude__s, Geolocation__Longitude__s,
                   Parent_Account__c, Parent_Account__r.Name
            FROM Sciagen_Account__c
            WHERE Id = :accountId
            WITH USER_MODE
            LIMIT 1
        ];
        if (matches.isEmpty()) {
            throw new AuraHandledException('Account not found or not accessible.');
        }
        Sciagen_Account__c acc = matches[0];

        AccountDetail detail = new AccountDetail();
        detail.id = acc.Id;
        detail.type = acc.Type__c;
        detail.name = acc.Name;
        detail.accountCode = acc.Account_Code__c;
        detail.email = acc.Email__c;
        detail.phone = acc.Phone__c;
        detail.lastModified = acc.LastModifiedDate;
        detail.createdByName = acc.CreatedBy != null ? acc.CreatedBy.Name : null;
        detail.lastModifiedByName = acc.LastModifiedBy != null ? acc.LastModifiedBy.Name : null;
        // Prefer the real field — the iPad app reads this directly. The CVR-derived
        // fallback further below (detail.lastVisit == null check) only fires when
        // this field itself is blank, preserving today's behavior for records that
        // predate this field being populated.
        detail.lastVisit = acc.Last_Visit__c != null ? acc.Last_Visit__c.format() : null;
        detail.externalIds = new Map<String, String>();
        if (String.isNotBlank(acc.External_Ids__c)) {
            try {
                Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(acc.External_Ids__c);
                for (String key : parsed.keySet()) {
                    if (parsed.get(key) != null) {
                        detail.externalIds.put(key, String.valueOf(parsed.get(key)));
                    }
                }
            } catch (Exception e) {
                // Malformed External_Ids__c shouldn't break the whole detail page — just
                // surface nothing rather than an error.
            }
        }
        detail.prefix = acc.Prefix__c;
        detail.firstName = acc.First_Name__c;
        detail.lastName = acc.Last_Name__c;
        detail.hcpType = acc.HCP_Type__c;
        detail.specialty = acc.Specialty__c;
        detail.focusArea = acc.Focus_Area__c;
        detail.licenseNumber = acc.License_Number__c;
        detail.licensingBody = acc.Licensing_Body__c;
        detail.primaryCountry = acc.Primary_Country__c;
        detail.age = acc.Age__c == null ? null : acc.Age__c.intValue();
        detail.experienceYears = acc.Experience_Years__c == null ? null : acc.Experience_Years__c.intValue();
        detail.degrees = new List<String>();
        for (String degree : new List<String>{ acc.Degree_1__c, acc.Degree_2__c, acc.Degree_3__c, acc.Degree_4__c, acc.Degree_5__c }) {
            if (String.isNotBlank(degree)) {
                detail.degrees.add(degree);
            }
        }
        detail.graduationYear = acc.Graduation_Year__c == null ? null : acc.Graduation_Year__c.intValue();
        detail.licensingYear = acc.Licensing_Year__c == null ? null : acc.Licensing_Year__c.intValue();
        detail.linkedInUrl = acc.LinkedIn_URL__c;
        detail.twitterUrl = acc.Twitter_URL__c;
        detail.youtubeUrl = acc.YouTube_URL__c;
        detail.instagramUrl = acc.Instagram_URL__c;
        detail.totalArticles = acc.Total_Articles__c == null ? null : acc.Total_Articles__c.intValue();
        detail.totalCitations = acc.Total_Citations__c == null ? null : acc.Total_Citations__c.intValue();
        detail.avgCitationsPerArticle = acc.Avg_Citations_Per_Article__c == null ? null : acc.Avg_Citations_Per_Article__c.setScale(1);
        detail.avgCoauthorsPerArticle = acc.Avg_Coauthors_Per_Article__c == null ? null : acc.Avg_Coauthors_Per_Article__c.setScale(1);
        detail.uniqueJournalCount = acc.Unique_Journal_Count__c == null ? null : acc.Unique_Journal_Count__c.intValue();
        detail.guidelineCount = acc.Guideline_Count__c == null ? null : acc.Guideline_Count__c.intValue();
        detail.activelyPublishedYears = acc.Actively_Published_Years__c == null ? null : acc.Actively_Published_Years__c.intValue();
        detail.emergingExpert = acc.Emerging_Expert__c;
        detail.reachFlag = acc.Reach_Flag__c;
        detail.hcoType = acc.HCO_Type__c;
        detail.speciality = acc.Speciality__c;
        detail.billingStreet = acc.Billing_Street__c;
        detail.billingCity = acc.Billing_City__c;
        detail.billingState = acc.Billing_State__c;
        detail.billingCountry = acc.Billing_Country__c;
        detail.billingPostalCode = acc.Billing_Postal_Code__c;
        detail.website = acc.Website__c;
        detail.plusCode = acc.Plus_Code__c;
        detail.geolocation = (acc.Geolocation__Latitude__s != null && acc.Geolocation__Longitude__s != null)
            ? acc.Geolocation__Latitude__s.setScale(3) + ', ' + acc.Geolocation__Longitude__s.setScale(3)
            : null;
        detail.latitude = acc.Geolocation__Latitude__s;
        detail.longitude = acc.Geolocation__Longitude__s;
        detail.parentAccountId = acc.Parent_Account__c;
        detail.parentAccountName = acc.Parent_Account__r != null ? acc.Parent_Account__r.Name : null;

        // Acaroid targeting card. Read in its own query so an account page still loads for a user
        // who has no access to the Acaroid fields (the card then shows no data).
        detail.acaroid = new AcaroidInfo();
        detail.acaroid.brandName = AcaroidConfig.load().brandName;
        try {
            List<Sciagen_Account__c> ar = [
                SELECT Acaroid_Tier__c, Acaroid_Potential_Score__c, Acaroid_Admin_Readiness_Status__c, Acaroid_HCO_Last_Scored_Date__c,
                       Acaroid_Target_Tier__c, Acaroid_Score_Total__c, Acaroid_Segment__c, Acaroid_Can_Administer_SCIT__c,
                       Acaroid_Recommended_Calls_Month__c, Acaroid_HCP_Last_Scored_Date__c
                FROM Sciagen_Account__c WHERE Id = :accountId WITH USER_MODE LIMIT 1
            ];
            if (!ar.isEmpty()) {
                Sciagen_Account__c x = ar[0];
                if (acc.Type__c == 'HCO') {
                    detail.acaroid.tier = x.Acaroid_Tier__c;
                    detail.acaroid.score = x.Acaroid_Potential_Score__c;
                    detail.acaroid.readinessStatus = x.Acaroid_Admin_Readiness_Status__c;
                    detail.acaroid.lastScoredDate = x.Acaroid_HCO_Last_Scored_Date__c == null ? null : x.Acaroid_HCO_Last_Scored_Date__c.format();
                } else if (acc.Type__c == 'HCP') {
                    detail.acaroid.tier = x.Acaroid_Target_Tier__c;
                    detail.acaroid.score = x.Acaroid_Score_Total__c;
                    detail.acaroid.segment = x.Acaroid_Segment__c;
                    detail.acaroid.canAdminister = x.Acaroid_Can_Administer_SCIT__c;
                    detail.acaroid.recommendedCallsMonth = x.Acaroid_Recommended_Calls_Month__c == null ? null : x.Acaroid_Recommended_Calls_Month__c.intValue();
                    detail.acaroid.lastScoredDate = x.Acaroid_HCP_Last_Scored_Date__c == null ? null : x.Acaroid_HCP_Last_Scored_Date__c.format();
                }
            }
        } catch (Exception e) {
            // no access to the Acaroid fields: leave the card empty
        }

        Map<Id, String> territoryByAccountId = territoryNamesByAccountId(new Set<Id>{ accountId });
        detail.territory = territoryByAccountId.get(accountId);

        detail.affiliations = new List<RelatedAccountItem>();
        for (Affiliation__c aff : [
            SELECT HCP__c, HCP__r.Name, HCP__r.Type__c, HCP__r.Specialty__c, HCP__r.Phone__c, HCP__r.Billing_City__c,
                   HCO__c, HCO__r.Name, HCO__r.Type__c, HCO__r.HCO_Type__c, HCO__r.Phone__c, HCO__r.Billing_City__c, HCO__r.Website__c,
                   HCO__r.Billing_Street__c, HCO__r.Billing_State__c, HCO__r.Billing_Postal_Code__c, HCO__r.Plus_Code__c,
                   HCO__r.Geolocation__Latitude__s, HCO__r.Geolocation__Longitude__s, Is_Primary__c
            FROM Affiliation__c
            WHERE HCP__c = :accountId OR HCO__c = :accountId
            WITH USER_MODE
        ]) {
            Boolean thisIsHCP = aff.HCP__c == accountId;
            RelatedAccountItem item = new RelatedAccountItem();
            item.accountId = thisIsHCP ? aff.HCO__c : aff.HCP__c;
            item.name = thisIsHCP ? aff.HCO__r.Name : aff.HCP__r.Name;
            item.type = thisIsHCP ? aff.HCO__r.Type__c : aff.HCP__r.Type__c;
            item.subtitle = thisIsHCP ? aff.HCO__r.HCO_Type__c : aff.HCP__r.Specialty__c;
            item.phone = thisIsHCP ? aff.HCO__r.Phone__c : aff.HCP__r.Phone__c;
            item.city = thisIsHCP ? aff.HCO__r.Billing_City__c : aff.HCP__r.Billing_City__c;
            item.website = thisIsHCP ? aff.HCO__r.Website__c : null;
            item.isPrimary = aff.Is_Primary__c;
            if (thisIsHCP) {
                item.street = aff.HCO__r.Billing_Street__c;
                item.state = aff.HCO__r.Billing_State__c;
                item.postalCode = aff.HCO__r.Billing_Postal_Code__c;
                item.plusCode = aff.HCO__r.Plus_Code__c;
                item.latitude = aff.HCO__r.Geolocation__Latitude__s;
                item.longitude = aff.HCO__r.Geolocation__Longitude__s;
            }
            detail.affiliations.add(item);
        }

        if (acc.Type__c == 'HCP') {
            Segmentation__c[] segs = [
                SELECT Id, Classification__c, Tier__c, Priority__c, Potential__c, Is_KOL__c, Owner_Rep__c, Tags__c,
                       Relationship__c, Adoption_Ladder__c, Prescription_Pattern__c, AIT_Preference__c, Behaviour_Segmentation__c, Customer_Profile__c
                FROM Segmentation__c
                WHERE HCP__c = :accountId
                WITH USER_MODE
                LIMIT 1
            ];
            if (!segs.isEmpty()) {
                SegmentationInfo seg = new SegmentationInfo();
                seg.id = segs[0].Id;
                seg.classification = segs[0].Classification__c;
                seg.tier = segs[0].Tier__c;
                seg.priority = segs[0].Priority__c;
                seg.ownerRep = segs[0].Owner_Rep__c;
                seg.tags = segs[0].Tags__c;
                seg.potential = segs[0].Potential__c;
                seg.isKOL = segs[0].Is_KOL__c;
                seg.relationship = segs[0].Relationship__c;
                seg.adoptionLadder = segs[0].Adoption_Ladder__c;
                seg.prescriptionPattern = segs[0].Prescription_Pattern__c;
                seg.aitPreference = segs[0].AIT_Preference__c;
                seg.behaviourSegmentation = segs[0].Behaviour_Segmentation__c;
                seg.customerProfile = segs[0].Customer_Profile__c;
                detail.segmentation = seg;
            }

            List<Consent__c> consents = [
                SELECT Id, Captured_At__c, Signed__c,
                       (SELECT Opted_In__c FROM Emails__r WHERE Opted_In__c = true LIMIT 1),
                       (SELECT Id FROM Channels__r WHERE Subscribed__c = true)
                FROM Consent__c
                WHERE HCP__c = :accountId
                WITH USER_MODE
                ORDER BY Captured_At__c DESC NULLS LAST
                LIMIT 1
            ];
            if (!consents.isEmpty()) {
                Consent__c c = consents[0];
                ConsentInfo info = new ConsentInfo();
                info.id = c.Id;
                info.capturedAt = c.Captured_At__c;
                info.signed = c.Signed__c;
                info.emailOptedIn = !c.Emails__r.isEmpty();
                info.subscribedChannelCount = c.Channels__r.size();
                detail.consent = info;
            }

            detail.officeWindows = new List<OfficeWindowItem>();
            for (Office_Window__c ow : [
                SELECT Id, Day__c, Window__c, Preference__c, HCO__r.Name
                FROM Office_Window__c
                WHERE HCP__c = :accountId
                WITH USER_MODE
                ORDER BY Day__c
            ]) {
                OfficeWindowItem item = new OfficeWindowItem();
                item.id = ow.Id;
                item.day = ow.Day__c;
                item.timeWindow = ow.Window__c;
                item.preference = ow.Preference__c;
                item.hcoName = ow.HCO__r != null ? ow.HCO__r.Name : null;
                detail.officeWindows.add(item);
            }

            detail.publications = new List<PublicationItem>();
            for (Publication__c pub : [
                SELECT Id, Title__c, PMID__c, Publication_Date__c, Citations__c,
                       Publication_Type__c, Link__c, Coauthors__c, Mesh_Terms__c
                FROM Publication__c
                WHERE HCP__c = :accountId
                WITH USER_MODE
                ORDER BY Publication_Date__c DESC
            ]) {
                PublicationItem item = new PublicationItem();
                item.id = pub.Id;
                item.title = pub.Title__c;
                item.pmid = pub.PMID__c;
                item.publicationDate = pub.Publication_Date__c;
                item.citations = pub.Citations__c == null ? 0 : pub.Citations__c.intValue();
                item.publicationType = pub.Publication_Type__c;
                item.link = pub.Link__c;
                item.coauthors = pub.Coauthors__c;
                item.meshTerms = pub.Mesh_Terms__c;
                detail.publications.add(item);
            }

            detail.congressEvents = new List<CongressEventItem>();
            for (Congress_Event__c evt : [
                SELECT Id, Event_Name__c, Start_Date__c, End_Date__c, Location__c, Role__c,
                       Organized_By__c, Topic__c, Link__c
                FROM Congress_Event__c
                WHERE HCP__c = :accountId
                WITH USER_MODE
                ORDER BY Start_Date__c DESC
            ]) {
                CongressEventItem item = new CongressEventItem();
                item.id = evt.Id;
                item.eventName = evt.Event_Name__c;
                item.startDate = evt.Start_Date__c;
                item.endDate = evt.End_Date__c;
                item.location = evt.Location__c;
                item.role = evt.Role__c;
                item.organizedBy = evt.Organized_By__c;
                item.topic = evt.Topic__c;
                item.link = evt.Link__c;
                detail.congressEvents.add(item);
            }

            detail.clinicalTrials = new List<ClinicalTrialItem>();
            for (Clinical_Trial__c trial : [
                SELECT Id, Title__c, Registry_Id__c, Phase__c, Sponsor__c,
                       Registry__c, Study_Type__c, Condition__c, Start_Date__c, Completion_Date__c, Locations__c, Endpoints__c
                FROM Clinical_Trial__c
                WHERE HCP__c = :accountId
                WITH USER_MODE
                ORDER BY Start_Date__c DESC
            ]) {
                ClinicalTrialItem item = new ClinicalTrialItem();
                item.id = trial.Id;
                item.title = trial.Title__c;
                item.registryId = trial.Registry_Id__c;
                item.phase = trial.Phase__c;
                item.sponsor = trial.Sponsor__c;
                item.registry = trial.Registry__c;
                item.studyType = trial.Study_Type__c;
                item.condition = trial.Condition__c;
                item.startDate = trial.Start_Date__c;
                item.completionDate = trial.Completion_Date__c;
                item.locations = trial.Locations__c;
                item.endpoints = trial.Endpoints__c;
                detail.clinicalTrials.add(item);
            }
        } else {
            detail.publications = new List<PublicationItem>();
            detail.congressEvents = new List<CongressEventItem>();
            detail.clinicalTrials = new List<ClinicalTrialItem>();
        }

        List<TimelineEntry> timelineEntries = new List<TimelineEntry>();

        detail.callVisitReports = new List<CVRItem>();
        for (Call_Visit_Report__c cvr : [
            SELECT Id, Visit_Date__c, Call_Type__c, Record_Status__c, Rep__c, Discussion_Summary__c
            FROM Call_Visit_Report__c
            WHERE HCP__c = :accountId OR HCO__c = :accountId
            WITH USER_MODE
            ORDER BY Visit_Date__c DESC
            LIMIT 50
        ]) {
            CVRItem item = new CVRItem();
            item.id = cvr.Id;
            item.visitDate = cvr.Visit_Date__c != null ? cvr.Visit_Date__c.format() : null;
            item.callType = cvr.Call_Type__c;
            item.status = cvr.Record_Status__c;
            item.rep = cvr.Rep__c;
            item.discussionSummary = cvr.Discussion_Summary__c;
            detail.callVisitReports.add(item);
            // Query is already ORDER BY Visit_Date__c DESC, so the first row with a
            // date is the most recent visit — no separate MAX() query needed.
            if (detail.lastVisit == null && item.visitDate != null) {
                detail.lastVisit = item.visitDate;
            }

            if (cvr.Visit_Date__c != null) {
                TimelineItem tItem = new TimelineItem();
                tItem.kind = 'CVR';
                tItem.occurredAt = item.visitDate;
                tItem.title = 'Call Visit' + (cvr.Call_Type__c != null ? ' — ' + cvr.Call_Type__c : '');
                tItem.subtitle = cvr.Rep__c;
                timelineEntries.add(new TimelineEntry(Datetime.newInstance(cvr.Visit_Date__c, Time.newInstance(0, 0, 0, 0)), tItem));
            }
        }

        detail.dataChangeRequests = new List<DCRItem>();
        for (Data_Change_Request__c dcr : [
            SELECT Id, Type__c, Status__c, Summary__c, Submitted_By__c, Submitted_At__c
            FROM Data_Change_Request__c
            WHERE Subject_Account__c = :accountId
            WITH USER_MODE
            ORDER BY Submitted_At__c DESC
            LIMIT 50
        ]) {
            DCRItem item = new DCRItem();
            item.id = dcr.Id;
            item.type = dcr.Type__c;
            item.status = dcr.Status__c;
            item.summary = dcr.Summary__c;
            item.submittedBy = dcr.Submitted_By__c;
            item.submittedAt = dcr.Submitted_At__c != null ? dcr.Submitted_At__c.format() : null;
            detail.dataChangeRequests.add(item);

            if (dcr.Submitted_At__c != null) {
                TimelineItem tItem = new TimelineItem();
                tItem.kind = 'DCR';
                tItem.occurredAt = item.submittedAt;
                tItem.title = 'Data Change Request' + (dcr.Type__c != null ? ' — ' + dcr.Type__c : '');
                tItem.subtitle = dcr.Status__c;
                timelineEntries.add(new TimelineEntry(dcr.Submitted_At__c, tItem));
            }
        }

        // Upcoming/unfulfilled visits (My Schedule) — only 'Planned' status, so a
        // completed one doesn't double up with the Call_Visit_Report__c entry
        // above for the same visit once it's actually happened.
        for (Planned_Call__c pc : [
            SELECT Id, Call_DateTime__c, Call_Type__c, Status__c
            FROM Planned_Call__c
            WHERE (HCP__c = :accountId OR HCO__c = :accountId) AND Status__c = 'Planned'
            WITH USER_MODE
            ORDER BY Call_DateTime__c DESC
            LIMIT 50
        ]) {
            if (pc.Call_DateTime__c == null) {
                continue;
            }
            TimelineItem tItem = new TimelineItem();
            tItem.kind = 'Planned';
            tItem.occurredAt = pc.Call_DateTime__c.format();
            tItem.title = 'Planned Call' + (pc.Call_Type__c != null ? ' — ' + pc.Call_Type__c : '');
            tItem.subtitle = pc.Status__c;
            timelineEntries.add(new TimelineEntry(pc.Call_DateTime__c, tItem));
        }

        // Approved Email sends — mirrors the iPad app's own Timeline (which
        // already shows these via UserDataStore.sentEmails), so an HCP page
        // reads the same either place. Only actually-sent mail, not drafts.
        for (Sent_Email__c se : [
            SELECT Id, Sent_At__c, Subject__c, To_Email__c
            FROM Sent_Email__c
            WHERE HCP__c = :accountId AND Folder__c = 'Sent'
            WITH USER_MODE
            ORDER BY Sent_At__c DESC
            LIMIT 50
        ]) {
            if (se.Sent_At__c == null) {
                continue;
            }
            TimelineItem tItem = new TimelineItem();
            tItem.kind = 'Email';
            tItem.occurredAt = se.Sent_At__c.format();
            tItem.title = String.isNotBlank(se.Subject__c) ? se.Subject__c : 'Approved Email';
            tItem.subtitle = 'Sent to ' + se.To_Email__c;
            timelineEntries.add(new TimelineEntry(se.Sent_At__c, tItem));
        }

        timelineEntries.sort();
        detail.timeline = new List<TimelineItem>();
        for (TimelineEntry entry : timelineEntries) {
            detail.timeline.add(entry.item);
        }

        return detail;
    }

    // MARK: - Hierarchy (view-only)

    @AuraEnabled
    public static HierarchyInfo getAccountHierarchy(Id accountId) {
        Sciagen_Account__c acc = [
            SELECT Id, Name, Type__c, Parent_Account__c, Parent_Account__r.Name, Parent_Account__r.Type__c
            FROM Sciagen_Account__c
            WHERE Id = :accountId
            WITH USER_MODE
            LIMIT 1
        ];

        HierarchyInfo info = new HierarchyInfo();
        info.selfId = acc.Id;
        info.selfName = acc.Name;
        info.selfType = acc.Type__c;

        if (acc.Type__c == 'HCP') {
            // HCPs don't use Parent_Account__c — their "parent" node here is
            // their Primary HCO affiliation instead, matching the iPad app's
            // HCP.primaryAffiliation (the Is_Primary__c-flagged Affiliation__c
            // row, falling back to the first one if none is flagged).
            List<Affiliation__c> affiliations = [
                SELECT HCO__c, HCO__r.Name, HCO__r.Type__c, Is_Primary__c
                FROM Affiliation__c
                WHERE HCP__c = :accountId AND HCO__c != null
                WITH USER_MODE
                ORDER BY Is_Primary__c DESC, HCO__r.Name ASC
            ];
            if (!affiliations.isEmpty()) {
                Affiliation__c primaryAff = affiliations[0];
                HierarchyNode parent = new HierarchyNode();
                parent.id = primaryAff.HCO__c;
                parent.name = primaryAff.HCO__r.Name;
                parent.type = primaryAff.HCO__r.Type__c;
                parent.isPrimary = true;
                info.parent = parent;
            }
        } else if (acc.Parent_Account__c != null) {
            HierarchyNode parent = new HierarchyNode();
            parent.id = acc.Parent_Account__c;
            parent.name = acc.Parent_Account__r.Name;
            parent.type = acc.Parent_Account__r.Type__c;
            info.parent = parent;
        }

        info.children = new List<HierarchyNode>();
        for (Sciagen_Account__c child : [
            SELECT Id, Name, Type__c
            FROM Sciagen_Account__c
            WHERE Parent_Account__c = :accountId
            WITH USER_MODE
            ORDER BY Name
        ]) {
            HierarchyNode node = new HierarchyNode();
            node.id = child.Id;
            node.name = child.Name;
            node.type = child.Type__c;
            info.children.add(node);
        }

        info.affiliatedHCPs = new List<HierarchyNode>();
        if (acc.Type__c == 'HCO') {
            for (Affiliation__c aff : [
                SELECT HCP__c, HCP__r.Name, Is_Primary__c
                FROM Affiliation__c
                WHERE HCO__c = :accountId
                WITH USER_MODE
                ORDER BY Is_Primary__c DESC, HCP__r.Name ASC
            ]) {
                HierarchyNode node = new HierarchyNode();
                node.id = aff.HCP__c;
                node.name = aff.HCP__r.Name;
                node.type = 'HCP';
                // Marks HCPs for whom THIS HCO is their primary affiliation —
                // same Is_Primary__c flag as the Related tab's PRIMARY pill,
                // surfaced here too so the hierarchy view carries the same
                // "primary" signal the app shows on the HCP's own affiliation list.
                node.isPrimary = aff.Is_Primary__c;
                info.affiliatedHCPs.add(node);
            }
        }

        return info;
    }

    public class HierarchyInfo {
        @AuraEnabled public Id selfId;
        @AuraEnabled public String selfName;
        @AuraEnabled public String selfType;
        @AuraEnabled public HierarchyNode parent;
        @AuraEnabled public List<HierarchyNode> children;
        @AuraEnabled public List<HierarchyNode> affiliatedHCPs;
    }

    public class HierarchyNode {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String type;
        @AuraEnabled public Boolean isPrimary;
    }

    // MARK: - Shared helpers

    private static Set<Id> idsOf(List<Sciagen_Account__c> accounts) {
        Set<Id> ids = new Set<Id>();
        for (Sciagen_Account__c acc : accounts) {
            ids.add(acc.Id);
        }
        return ids;
    }

    /// Account_Territory__c is the Sciagen_Account__c<->Territory__c junction (see
    /// architecture doc §5) used by both HCP and HCO accounts alike. Public so
    /// SciagenScheduleController can reuse it rather than duplicating the query.
    public static Map<Id, String> territoryNamesByAccountId(Set<Id> accountIds) {
        Map<Id, String> result = new Map<Id, String>();
        for (Account_Territory__c junction : [
            SELECT Account__c, Territory__r.Name
            FROM Account_Territory__c
            WHERE Account__c IN :accountIds
            WITH USER_MODE
        ]) {
            result.put(junction.Account__c, junction.Territory__r.Name);
        }
        return result;
    }

    // MARK: - Edit existing Account via DCR (Key Account Manager only)
    //
    // A Key Account Manager's Edit on the Account record page never writes to
    // Sciagen_Account__c directly — it files an "Edit HCP"/"Edit HCO"
    // Data_Change_Request__c carrying only the fields that actually changed as
    // a {key: {current, requested}} payload, which
    // DataChangeRequestApprovalHandler.applyEditForApprovedDcr applies on
    // approval (same payload shape the iPad app's DCRView already files).

    private static final Map<String, String> HCP_EDIT_KEYS = new Map<String, String>{
        'Prefix__c' => 'prefix', 'First_Name__c' => 'firstName', 'Last_Name__c' => 'lastName',
        'HCP_Type__c' => 'hcpType', 'Specialty__c' => 'specialty', 'Focus_Area__c' => 'focusArea',
        'License_Number__c' => 'licenseNumber', 'Licensing_Body__c' => 'licensingBody',
        'Billing_Street__c' => 'street', 'Billing_City__c' => 'city', 'Billing_State__c' => 'state',
        'Billing_Postal_Code__c' => 'pincode', 'Billing_Country__c' => 'country',
        'Phone__c' => 'phone', 'Email__c' => 'email', 'Primary_Country__c' => 'primaryCountry',
        'Account_Code__c' => 'accountCode'
    };
    private static final Map<String, String> HCO_EDIT_KEYS = new Map<String, String>{
        'Name' => 'name', 'HCO_Type__c' => 'type', 'Speciality__c' => 'speciality',
        'Account_Code__c' => 'accountCode', 'Billing_Street__c' => 'street', 'Billing_City__c' => 'city',
        'Billing_State__c' => 'state', 'Billing_Postal_Code__c' => 'pincode', 'Billing_Country__c' => 'country',
        'Phone__c' => 'phone', 'Email__c' => 'email', 'Website__c' => 'website'
    };

    /// `requested` is keyed by Sciagen_Account__c field API name (as submitted
    /// by the edit form). Returns the new DCR's Id.
    @AuraEnabled
    public static Id submitEditDcr(Id accountId, Map<String, String> requested) {
        if (!isKeyAccountManager()) {
            throw new AuraHandledException('This request type is only available for Key Account Managers.');
        }
        List<Sciagen_Account__c> found = [
            SELECT Id, Name, Type__c FROM Sciagen_Account__c WHERE Id = :accountId WITH USER_MODE LIMIT 1
        ];
        if (found.isEmpty()) {
            throw new AuraHandledException('Account not found.');
        }
        Sciagen_Account__c acc = found[0];
        Boolean isHco = acc.Type__c == 'HCO';
        Map<String, String> keyMap = isHco ? HCO_EDIT_KEYS : HCP_EDIT_KEYS;

        List<String> apiNames = new List<String>(keyMap.keySet());
        Sciagen_Account__c current = Database.query(
            'SELECT ' + String.join(apiNames, ',') + ' FROM Sciagen_Account__c WHERE Id = :accountId WITH USER_MODE'
        );

        Map<String, Object> payload = new Map<String, Object>();
        List<String> changedLabels = new List<String>();
        for (String api : apiNames) {
            if (requested == null || !requested.containsKey(api)) continue;
            String oldVal = current.get(api) == null ? '' : String.valueOf(current.get(api)).trim();
            String newVal = requested.get(api) == null ? '' : requested.get(api).trim();
            if (oldVal == newVal) continue;
            payload.put(keyMap.get(api), new Map<String, Object>{ 'current' => oldVal, 'requested' => newVal });
            changedLabels.add(keyMap.get(api));
        }
        if (payload.isEmpty()) {
            throw new AuraHandledException('No changes to submit.');
        }

        Data_Change_Request__c dcr = new Data_Change_Request__c(
            Type__c = isHco ? 'Edit HCO' : 'Edit HCP',
            Status__c = 'Pending Approval',
            Subject_Account__c = acc.Id,
            Subject_Name__c = acc.Name,
            Summary__c = ('Edit ' + acc.Type__c + ' · ' + acc.Name + ' · ' + String.join(changedLabels, ', ')).abbreviate(255),
            Fields_Payload__c = JSON.serialize(payload),
            Submitted_By__c = UserInfo.getUserId(),
            Submitted_At__c = Datetime.now()
        );
        Database.insert(dcr, AccessLevel.USER_MODE);
        return dcr.Id;
    }

}