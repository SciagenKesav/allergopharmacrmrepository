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
        // Optional table-view columns (accountBrowser.js's "Add Column" picker,
        // hidden by default) — Specialty__c/Speciality__c and HCP_Type__c/
        // HCO_Type__c already feed `subtitle` above, but a rep who wants them
        // as their own sortable/scannable column needs the raw value too.
        @AuraEnabled public String specialty;
        @AuraEnabled public String subType;
        @AuraEnabled public String accountCode;
        @AuraEnabled public String website;
        @AuraEnabled public String focusArea;
        @AuraEnabled public String licenseNumber;
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
        @AuraEnabled public Id affiliationId;
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

    public class SegmentationInfo {
        @AuraEnabled public Id id;
        @AuraEnabled public String classification;
        @AuraEnabled public String tier;
        @AuraEnabled public String priority;
        @AuraEnabled public String potential;
        @AuraEnabled public Boolean isKOL;
        @AuraEnabled public String ownerRep;
        @AuraEnabled public String tags;
    }

    public class CVRItem {
        @AuraEnabled public Id id;
        @AuraEnabled public String visitDate;
        @AuraEnabled public String callType;
        @AuraEnabled public String status;
        @AuraEnabled public String rep;
        @AuraEnabled public String discussionSummary;
        // False for the Planned_Call__c-sourced "Completed" rows merged into
        // this same list below — those have no Call_Visit_Report__c behind
        // them at all, so `id` is a Planned_Call__c Id and there's no CVR
        // detail to open in the read-only view modal. Only true rows are
        // clickable in accountDetail's Activity tab.
        @AuraEnabled public Boolean isCVR;
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

    // Merges real Call_Visit_Report__c rows with completed-but-never-written-up
    // Planned_Call__c rows into one chronological Activity feed (see the CVR/
    // Planned_Call__c loops below) — same sort-wrapper shape as TimelineEntry.
    private class CVREntry implements Comparable {
        Date sortAt;
        CVRItem item;
        CVREntry(Date sortAt, CVRItem item) {
            this.sortAt = sortAt;
            this.item = item;
        }
        public Integer compareTo(Object other) {
            Date otherAt = ((CVREntry) other).sortAt;
            if (sortAt == otherAt) return 0;
            if (sortAt == null) return 1;
            if (otherAt == null) return -1;
            return sortAt > otherAt ? -1 : 1;
        }
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

        // AccessLevel.USER_MODE (passed to queryWithBinds below) enforces FLS/CRUD here —
        // a query string can't also carry `WITH USER_MODE` alongside an explicit AccessLevel.
        // Sorting is applied after this query (see below), once territory/KOL are known —
        // Territory isn't a direct field (it comes from the junction map further down), so
        // it can't be an ORDER BY target in SOQL.
        String query = 'SELECT Id, Name, Type__c, HCP_Type__c, Specialty__c, HCO_Type__c, Speciality__c, ' +
            'Billing_City__c, Phone__c, Email__c, Emerging_Expert__c, Geolocation__Latitude__s, Geolocation__Longitude__s, ' +
            'Account_Code__c, Website__c, Focus_Area__c, License_Number__c ' +
            'FROM Sciagen_Account__c WHERE ' + String.join(whereClauses, ' AND ') + ' ORDER BY Name LIMIT 200';

        List<Sciagen_Account__c> accounts = Database.queryWithBinds(query, binds, AccessLevel.USER_MODE);

        Map<Id, String> territoryByAccountId = territoryNamesByAccountId(idsOf(accounts));
        if (String.isNotBlank(territoryFilter)) {
            List<Sciagen_Account__c> filtered = new List<Sciagen_Account__c>();
            for (Sciagen_Account__c acc : accounts) {
                if (territoryFilter.equals(territoryByAccountId.get(acc.Id))) {
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

    /// A System Administrator (Profile.PermissionsViewAllData = true — the same
    /// check TerritorySharingService/PlannedCallTerritorySharingService/
    /// RCPAAuditTerritorySharingService already use to mean "sees everything,
    /// doesn't need territory-based sharing") gets every Territory__c in the
    /// org and the "All Territories" search; everyone else only gets the
    /// territory(ies) they're actually assigned via User_Territory__c — they
    /// shouldn't be able to see, let alone filter by, a territory that isn't
    /// theirs. A Key Account Manager or Zonal Manager always falls in the
    /// latter group on this page, even if their Profile happens to carry View
    /// All Data (common in sandboxes where field users are provisioned on an
    /// admin-equivalent profile for convenience) — their role, not their
    /// profile, decides it for those two roles specifically. A genuine
    /// admin's own view (any other View All Data profile, regardless of role)
    /// is unaffected — see canSeeAllTerritories.
    @AuraEnabled(cacheable=true)
    public static List<String> getTerritoryOptions() {
        List<String> names = new List<String>();
        if (canSeeAllTerritories()) {
            for (Territory__c t : [SELECT Name FROM Territory__c WITH USER_MODE ORDER BY Name]) {
                names.add(t.Name);
            }
        } else {
            Set<String> ownNames = new Set<String>();
            for (User_Territory__c ut : [
                SELECT Territory__r.Name
                FROM User_Territory__c
                WHERE User__c = :UserInfo.getUserId() AND Territory__c != null
                WITH USER_MODE
            ]) {
                ownNames.add(ut.Territory__r.Name);
            }
            names.addAll(ownNames);
            names.sort();
        }
        return names;
    }

    /// Profile.PermissionsViewAllData always wins first — a genuine System
    /// Administrator (or any other profile granted View All Data) sees every
    /// territory no matter what role they happen to be assigned, since that
    /// role is often just there for hierarchy/sharing purposes and shouldn't
    /// narrow an admin's own view. Only once that's ruled out does a Key
    /// Account Manager or Zonal Manager's role step in to force the
    /// restricted, own-territory-only view for everyone else on those roles,
    /// even if a lower-privilege profile has View All Data by mistake.
    @AuraEnabled(cacheable=true)
    public static Boolean canSeeAllTerritories() {
        List<User> matches = [
            SELECT Profile.PermissionsViewAllData, UserRole.Name FROM User WHERE Id = :UserInfo.getUserId() WITH USER_MODE LIMIT 1
        ];
        if (matches.isEmpty() || matches[0].Profile == null || matches[0].Profile.PermissionsViewAllData != true) return false;

        // Profile grants View All Data — normally enough on its own, but a Key
        // Account Manager or Zonal Manager is still held to their own
        // territory(ies), since those two field roles should never see the
        // unrestricted "All Territories" search regardless of profile. Any
        // other profile with View All Data (System Administrator and the
        // like) sees everything, as before.
        String roleName = matches[0].UserRole != null ? matches[0].UserRole.Name : null;
        Boolean isKamOrZonalManager = roleName == 'Key Account Manager' || roleName == 'Zonal Manager';
        return !isKamOrZonalManager;
    }

    @AuraEnabled(cacheable=true)
    public static List<String> getSpecialtyOptions() {
        return picklistValues(Sciagen_Account__c.Specialty__c.getDescribe());
    }

    @AuraEnabled(cacheable=true)
    public static List<String> getHCOTypeOptions() {
        return picklistValues(Sciagen_Account__c.HCO_Type__c.getDescribe());
    }

    /// Speciality__c (HCO) is a distinct field/picklist from Specialty__c (HCP) —
    /// same spelling difference the object itself uses — so this is a separate
    /// method from getSpecialtyOptions() above, not a typo/duplicate of it.
    @AuraEnabled(cacheable=true)
    public static List<String> getHCOSpecialityOptions() {
        return picklistValues(Sciagen_Account__c.Speciality__c.getDescribe());
    }

    @AuraEnabled(cacheable=true)
    public static List<String> getHCPTypeOptions() {
        return picklistValues(Sciagen_Account__c.HCP_Type__c.getDescribe());
    }

    @AuraEnabled(cacheable=true)
    public static List<String> getSegmentationOptions() {
        return picklistValues(Segmentation__c.Classification__c.getDescribe());
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

    // MARK: - Saved Views

    /// Looks up Business Admin-owned Saved_Filter__c rows regardless of the
    /// running user's own record-level sharing. Deliberately `without
    /// sharing` (this object's actual configured org-wide default is more
    /// restrictive than "everyone can read everyone's" — record ownership
    /// otherwise hides another user's row entirely) and deliberately *not*
    /// `WITH USER_MODE`: empirically, USER_MODE re-applies that same
    /// ownership-based visibility check even inside a `without sharing`
    /// context, silently dropping the very rows this lookup exists to cross
    /// into — confirmed directly (a test asserting a non-admin can see an
    /// admin's shared view only passed once USER_MODE was removed here).
    /// Object/field CRUD is still safe to skip for this one query: every
    /// permission set already grants broad Read on Saved_Filter__c and its
    /// fields, and this only ever returns Business-Admin-owned rows, never a
    /// user's own private data. Kept as its own tiny class rather than
    /// changing SciagenAccountController's own `with sharing` declaration,
    /// which stays exactly as restrictive as before for everything else in
    /// this file.
    private without sharing class BusinessAdminSavedViewLookup {
        List<Saved_Filter__c> run(Id excludingOwnerId) {
            return [
                SELECT Id, View_Name__c, Filter_JSON__c, Sort_Field__c, Sort_Ascending__c, Layout__c, Is_Default__c
                FROM Saved_Filter__c
                WHERE Owner.Profile.Name = 'Business Admin' AND OwnerId != :excludingOwnerId
            ];
        }
    }

    /// Own-rows and Business-Admin-rows come from two separate queries (see
    /// getSavedViews), so a single ORDER BY can't span both — sorted here
    /// instead once they're merged.
    private class ByViewName implements Comparator<Saved_Filter__c> {
        public Integer compare(Saved_Filter__c a, Saved_Filter__c b) {
            if (a.View_Name__c == b.View_Name__c) return 0;
            return a.View_Name__c > b.View_Name__c ? 1 : -1;
        }
    }

    /// A rep's own saved views, plus every view a Business Admin has created
    /// — Business Admin-authored views are org-shared reference views (e.g.
    /// a standard territory or specialty cut everyone should use), so they're
    /// visible to any user, not locked to just the admin who made them. A
    /// non-admin's own saved views stay private to them, same as before —
    /// only the Business Admin lookup above bypasses normal record sharing;
    /// this method's own query (the user's own rows) stays fully sharing-
    /// enforced, same as it always was.
    @AuraEnabled(cacheable=true)
    public static List<SavedViewItem> getSavedViews() {
        List<Saved_Filter__c> rows = [
            SELECT Id, View_Name__c, Filter_JSON__c, Sort_Field__c, Sort_Ascending__c, Layout__c, Is_Default__c
            FROM Saved_Filter__c
            WHERE OwnerId = :UserInfo.getUserId()
            WITH USER_MODE
        ];
        rows.addAll(new BusinessAdminSavedViewLookup().run(UserInfo.getUserId()));
        rows.sort(new ByViewName());

        List<SavedViewItem> results = new List<SavedViewItem>();
        for (Saved_Filter__c f : rows) {
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
            item.affiliationId = aff.Id;
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
                SELECT Id, Classification__c, Tier__c, Priority__c, Potential__c, Is_KOL__c, Owner_Rep__c, Tags__c
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

        // Activity feed = real Call_Visit_Report__c rows PLUS completed
        // Planned_Call__c rows that never got written up into one — a rep
        // marking a call "Completed" in My Schedule only flips
        // Planned_Call__c.Status__c, nothing auto-creates a Call_Visit_Report__c,
        // so without this merge a completed call simply vanishes from both the
        // upcoming list below (no longer 'Planned') and this Activity tab (no
        // CVR ever existed). Both sources are collected here and sorted
        // together so the merged list still reads newest-first.
        List<CVREntry> cvrEntries = new List<CVREntry>();

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
            item.isCVR = true;
            cvrEntries.add(new CVREntry(cvr.Visit_Date__c, item));

            if (cvr.Visit_Date__c != null) {
                TimelineItem tItem = new TimelineItem();
                tItem.kind = 'CVR';
                tItem.occurredAt = item.visitDate;
                tItem.title = 'Call Visit' + (cvr.Call_Type__c != null ? ' — ' + cvr.Call_Type__c : '');
                tItem.subtitle = cvr.Rep__c;
                timelineEntries.add(new TimelineEntry(Datetime.newInstance(cvr.Visit_Date__c, Time.newInstance(0, 0, 0, 0)), tItem));
            }
        }

        for (Planned_Call__c pc : [
            SELECT Id, Call_DateTime__c, Call_Type__c
            FROM Planned_Call__c
            WHERE (HCP__c = :accountId OR HCO__c = :accountId) AND Status__c = 'Completed'
            WITH USER_MODE
            ORDER BY Call_DateTime__c DESC
            LIMIT 50
        ]) {
            CVRItem item = new CVRItem();
            item.id = pc.Id;
            item.visitDate = pc.Call_DateTime__c != null ? pc.Call_DateTime__c.date().format() : null;
            item.callType = pc.Call_Type__c;
            item.status = 'Completed';
            item.isCVR = false;
            cvrEntries.add(new CVREntry(pc.Call_DateTime__c != null ? pc.Call_DateTime__c.date() : null, item));
            // Deliberately NOT added to timelineEntries — the Timeline tab
            // only shows still-upcoming Appointments (Status__c = 'Planned',
            // below) and DCR/Email entries; completed calls belong on the
            // Activity tab only, not duplicated here.
        }

        cvrEntries.sort();
        detail.callVisitReports = new List<CVRItem>();
        for (CVREntry entry : cvrEntries) {
            detail.callVisitReports.add(entry.item);
            // List is now sorted newest-first, so the first entry with a date
            // is the most recent visit — no separate MAX() query needed.
            if (detail.lastVisit == null && entry.item.visitDate != null) {
                detail.lastVisit = entry.item.visitDate;
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

        // Still-upcoming visits (My Schedule) — only 'Planned' status; once a
        // call is marked 'Completed' it moves into the Activity merge above
        // instead, so it doesn't show in both places.
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

    // MARK: - New Account via DCR (Key Account Manager only)
    //
    // A Key Account Manager's "New" action in the web Accounts page is
    // deliberately NOT a direct Sciagen_Account__c create (unlike a Zonal
    // Manager/Admin's, which still uses the plain lightning-record-edit-form
    // in accountBrowser.js) — it goes through the same Data_Change_Request__c
    // governance gate the iPad app's NewAccountRequestView already uses, so a
    // data steward reviews/approves it before it becomes real master data.
    // isKeyAccountManager() is a hardcoded Role check, not a permission check,
    // per explicit instruction — this is about who this specific workflow
    // applies to, not a generalized "lacks create access" fallback.

    public class HCOOption {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String type;
        @AuraEnabled public String city;
    }

    @AuraEnabled(cacheable=true)
    public static Boolean isKeyAccountManager() {
        List<User> matches = [
            SELECT UserRole.Name FROM User WHERE Id = :UserInfo.getUserId() WITH USER_MODE LIMIT 1
        ];
        return !matches.isEmpty() && matches[0].UserRole != null && matches[0].UserRole.Name == 'Key Account Manager';
    }

    /// Every existing HCO, for the New HCP request's required-affiliation
    /// picker — mirrors the iPad app's own approach (store.hcos, filtered
    /// client-side by a search box) rather than a server-side search endpoint,
    /// since the org's HCO count is small enough for that to be practical.
    @AuraEnabled(cacheable=true)
    public static List<HCOOption> getHCOOptionsForAffiliation() {
        List<HCOOption> results = new List<HCOOption>();
        for (Sciagen_Account__c hco : [
            SELECT Id, Name, HCO_Type__c, Billing_City__c
            FROM Sciagen_Account__c
            WHERE Type__c = 'HCO'
            WITH USER_MODE
            ORDER BY Name
            LIMIT 1000
        ]) {
            HCOOption opt = new HCOOption();
            opt.id = hco.Id;
            opt.name = hco.Name;
            opt.type = hco.HCO_Type__c;
            opt.city = hco.Billing_City__c;
            results.add(opt);
        }
        return results;
    }

    /// Inserts a Data_Change_Request__c for a "New HCO"/"New HCP" ask — never
    /// touches Sciagen_Account__c directly. `fields` uses the exact same key
    /// vocabulary as the iPad app (name/type/speciality/city/state/pincode/phone
    /// for HCO; prefix/firstName/lastName/specialty/hcpType/email/phone/degree1
    /// for HCP, plus affiliationHCO for display) so DataChangeRequestApprovalHandler
    /// already knows how to apply it on approval — see that class's buildHCO/buildHCP.
    @AuraEnabled
    public static Id submitAccountDcr(String type, Map<String, String> fields, Id relatedHCOId) {
        if (!isKeyAccountManager()) {
            throw new AuraHandledException('This request type is only available for Key Account Managers.');
        }
        if (type != 'New HCO' && type != 'New HCP') {
            throw new AuraHandledException('Unsupported request type.');
        }
        if (type == 'New HCP' && relatedHCOId == null) {
            throw new AuraHandledException('An HCP must be affiliated with an existing HCO.');
        }

        String subjectName;
        String summary;
        if (type == 'New HCO') {
            subjectName = fields.get('name');
            summary = 'New HCO · ' + blankAsDash(fields.get('type')) + ' · ' +
                blankAsDash(fields.get('city')) + ', ' + blankAsDash(fields.get('state'));
        } else {
            subjectName = String.join(new List<String>{
                fields.get('prefix'), fields.get('firstName'), fields.get('lastName')
            }, ' ').trim().replaceAll('\\s+', ' ');
            summary = 'New HCP · ' + blankAsDash(fields.get('specialty')) +
                ' · affiliated to ' + blankAsDash(fields.get('affiliationHCO'));
        }
        if (String.isBlank(subjectName)) {
            throw new AuraHandledException('Name is required.');
        }

        Data_Change_Request__c dcr = new Data_Change_Request__c(
            Type__c = type,
            Status__c = 'Pending Approval',
            Subject_Name__c = subjectName.abbreviate(180),
            Summary__c = summary,
            Fields_Payload__c = JSON.serialize(fields),
            Submitted_By__c = UserInfo.getUserId(),
            Submitted_At__c = Datetime.now()
        );
        if (type == 'New HCP') {
            dcr.Related_HCO__c = relatedHCOId;
        } else {
            dcr.City__c = fields.get('city');
            dcr.State__c = fields.get('state');
            dcr.Pincode__c = fields.get('pincode');
            dcr.Phone__c = fields.get('phone');
            dcr.Full_Address__c = buildFullAddress(fields.get('city'), fields.get('state'), fields.get('pincode'));
        }
        Database.insert(dcr, AccessLevel.USER_MODE);
        return dcr.Id;
    }

    private static String blankAsDash(String s) {
        return String.isBlank(s) ? '—' : s;
    }

    /// Mirrors SciagenAccountSyncService.buildFullAddress exactly (kept as its
    /// own private copy rather than made public there, to not widen that
    /// class's surface for a two-line helper).
    private static String buildFullAddress(String city, String state, String pincode) {
        List<String> parts = new List<String>();
        if (String.isNotBlank(city)) parts.add(city);
        if (String.isNotBlank(state)) parts.add(state);
        String address = String.join(parts, ', ');
        if (String.isNotBlank(pincode)) {
            address = String.isNotBlank(address) ? (address + ' - ' + pincode) : pincode;
        }
        return String.isBlank(address) ? null : address;
    }
}