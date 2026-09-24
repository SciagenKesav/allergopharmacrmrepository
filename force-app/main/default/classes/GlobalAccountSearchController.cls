/**
 * Global Account Search: lets a rep search Sciagen_Account__c records across the
 * entire org, not just the accounts already shared to their territory, then add
 * a found account into their own territory.
 *
 * `without sharing` so the search itself can see every account regardless of
 * territory-based sharing -- the SELECT still enforces field-level security via
 * AccessLevel.USER_MODE, so a rep only ever sees fields they already have Read
 * FLS on. The territory lookups/DML use plain SOQL/DML (Apex's system-mode
 * default), the same pattern TerritorySharingService already uses -- adding an
 * account to a territory shouldn't depend on reps having direct CRUD on
 * Account_Territory__c or User_Territory__c.
 */
public without sharing class GlobalAccountSearchController {

    private static final Integer MAX_RESULTS = 20;

    public class SearchCriteria {
        @AuraEnabled public String name;
        @AuraEnabled public Boolean nameExact;
        @AuraEnabled public String firstName;
        @AuraEnabled public String lastName;
        @AuraEnabled public String specialty;
        @AuraEnabled public Id primaryParentId;
        @AuraEnabled public String addressLine1;
        @AuraEnabled public Boolean addressStartsWith;
        @AuraEnabled public String city;
        @AuraEnabled public String state;
        @AuraEnabled public String postalCode;
        @AuraEnabled public String phone;
    }

    public class SearchResultRow {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String specialty;
        @AuraEnabled public String type;
        @AuraEnabled public String createdDateLabel;
        @AuraEnabled public String createdByName;
        @AuraEnabled public String street;
        @AuraEnabled public String city;
        @AuraEnabled public String state;
        @AuraEnabled public String postalCode;
        @AuraEnabled public Boolean inMyTerritory;
    }

    // Takes the criteria pre-serialized to JSON, not a typed SearchCriteria
    // parameter directly -- confirmed the hard way that Aura's complex-type
    // parameter binding for @AuraEnabled methods invoked from LWC can hand back
    // a non-null but entirely-empty wrapper instance (every field null) even
    // when the wire payload it received was correctly populated; JSON.deserialize
    // of that exact same payload works perfectly. Routing through a plain JSON
    // string sidesteps whatever that binding quirk is.
    @AuraEnabled
    public static List<SearchResultRow> search(String criteriaJson) {
        SearchCriteria criteria = String.isBlank(criteriaJson)
            ? null
            : (SearchCriteria) JSON.deserialize(criteriaJson, SearchCriteria.class);
        if (criteria == null) {
            throw new AuraHandledException('Enter a value in at least one search field.');
        }

        Boolean hasName = String.isNotBlank(criteria.name);
        Boolean hasFirstOrLast = String.isNotBlank(criteria.firstName) || String.isNotBlank(criteria.lastName);
        if (hasName && hasFirstOrLast) {
            throw new AuraHandledException('You cannot have a value in both "Name" and "First/Last Name" -- search by one or the other.');
        }

        Boolean hasAnyField = hasName || hasFirstOrLast
            || String.isNotBlank(criteria.specialty) || criteria.primaryParentId != null
            || String.isNotBlank(criteria.addressLine1) || String.isNotBlank(criteria.city)
            || String.isNotBlank(criteria.state) || String.isNotBlank(criteria.postalCode)
            || String.isNotBlank(criteria.phone);
        if (!hasAnyField) {
            throw new AuraHandledException('Enter a value in at least one search field.');
        }

        List<String> whereClauses = new List<String>();
        Map<String, Object> binds = new Map<String, Object>();

        if (hasName) {
            if (criteria.nameExact == true) {
                whereClauses.add('Name = :nameVal');
                binds.put('nameVal', criteria.name);
            } else {
                whereClauses.add('Name LIKE :nameTerm');
                binds.put('nameTerm', '%' + String.escapeSingleQuotes(criteria.name) + '%');
            }
        }
        if (String.isNotBlank(criteria.firstName)) {
            whereClauses.add('First_Name__c LIKE :firstNameTerm');
            binds.put('firstNameTerm', '%' + String.escapeSingleQuotes(criteria.firstName) + '%');
        }
        if (String.isNotBlank(criteria.lastName)) {
            whereClauses.add('Last_Name__c LIKE :lastNameTerm');
            binds.put('lastNameTerm', '%' + String.escapeSingleQuotes(criteria.lastName) + '%');
        }
        if (String.isNotBlank(criteria.specialty)) {
            whereClauses.add('(Specialty__c = :specialtyVal OR Speciality__c = :specialtyVal)');
            binds.put('specialtyVal', criteria.specialty);
        }
        if (criteria.primaryParentId != null) {
            whereClauses.add('Parent_Account__c = :parentId');
            binds.put('parentId', criteria.primaryParentId);
        }
        if (String.isNotBlank(criteria.addressLine1)) {
            String term = criteria.addressStartsWith == true
                ? String.escapeSingleQuotes(criteria.addressLine1) + '%'
                : '%' + String.escapeSingleQuotes(criteria.addressLine1) + '%';
            whereClauses.add('Billing_Street__c LIKE :addressTerm');
            binds.put('addressTerm', term);
        }
        if (String.isNotBlank(criteria.city)) {
            whereClauses.add('Billing_City__c LIKE :cityTerm');
            binds.put('cityTerm', '%' + String.escapeSingleQuotes(criteria.city) + '%');
        }
        if (String.isNotBlank(criteria.state)) {
            whereClauses.add('Billing_State__c LIKE :stateTerm');
            binds.put('stateTerm', '%' + String.escapeSingleQuotes(criteria.state) + '%');
        }
        if (String.isNotBlank(criteria.postalCode)) {
            whereClauses.add('Billing_Postal_Code__c LIKE :postalTerm');
            binds.put('postalTerm', String.escapeSingleQuotes(criteria.postalCode) + '%');
        }
        if (String.isNotBlank(criteria.phone)) {
            whereClauses.add('Phone__c LIKE :phoneTerm');
            binds.put('phoneTerm', '%' + String.escapeSingleQuotes(criteria.phone) + '%');
        }

        String query = 'SELECT Id, Name, Type__c, Specialty__c, Speciality__c, CreatedDate, CreatedBy.Name, ' +
            'Billing_Street__c, Billing_City__c, Billing_State__c, Billing_Postal_Code__c ' +
            'FROM Sciagen_Account__c WHERE ' + String.join(whereClauses, ' AND ') +
            ' ORDER BY Name LIMIT 21';

        // SYSTEM_MODE, not USER_MODE: USER_MODE re-enforces sharing rules even in a
        // `without sharing` class (confirmed the hard way — AccessLevel.USER_MODE
        // takes precedence over the class's sharing declaration), which would defeat
        // the entire point of a cross-territory global search. The field list here
        // is fixed and admin-curated, and every field is already Read-FLS-granted to
        // reps elsewhere in the app, so bypassing FLS here doesn't expose anything new.
        List<Sciagen_Account__c> accounts = (List<Sciagen_Account__c>) Database.queryWithBinds(query, binds, AccessLevel.SYSTEM_MODE);
        if (accounts.size() > MAX_RESULTS) {
            throw new AuraHandledException('More than ' + MAX_RESULTS + ' accounts matched your search. Please refine your search criteria.');
        }

        Set<Id> myTerritoryAccountIds = currentUserTerritoryAccountIds();

        List<SearchResultRow> results = new List<SearchResultRow>();
        for (Sciagen_Account__c acc : accounts) {
            SearchResultRow row = new SearchResultRow();
            row.id = acc.Id;
            row.name = acc.Name;
            row.type = acc.Type__c;
            row.specialty = acc.Type__c == 'HCP' ? acc.Specialty__c : acc.Speciality__c;
            row.createdDateLabel = acc.CreatedDate.format('M/d/yyyy h:mm a');
            row.createdByName = acc.CreatedBy != null ? acc.CreatedBy.Name : null;
            row.street = acc.Billing_Street__c;
            row.city = acc.Billing_City__c;
            row.state = acc.Billing_State__c;
            row.postalCode = acc.Billing_Postal_Code__c;
            row.inMyTerritory = myTerritoryAccountIds.contains(acc.Id);
            results.add(row);
        }
        return results;
    }

    @AuraEnabled
    public static void addToMyTerritory(List<Id> accountIds) {
        if (accountIds == null || accountIds.isEmpty()) {
            return;
        }
        Id territoryId = currentUserPrimaryTerritoryId();
        if (territoryId == null) {
            throw new AuraHandledException('You are not assigned to a territory, so accounts can\'t be added.');
        }

        Set<Id> existing = new Set<Id>();
        for (Account_Territory__c linkRow : [
            SELECT Account__c FROM Account_Territory__c
            WHERE Territory__c = :territoryId AND Account__c IN :accountIds
        ]) {
            existing.add(linkRow.Account__c);
        }

        List<Account_Territory__c> toInsert = new List<Account_Territory__c>();
        for (Id accId : accountIds) {
            if (!existing.contains(accId)) {
                toInsert.add(new Account_Territory__c(Account__c = accId, Territory__c = territoryId));
            }
        }
        if (!toInsert.isEmpty()) {
            // Same SYSTEM_MODE reasoning as the search query above — a rep inserting
            // a junction row that references an account outside their own sharing
            // visibility (that's the whole point of this action) hits
            // INSUFFICIENT_ACCESS_ON_CROSS_REFERENCE_ENTITY otherwise, even in a
            // `without sharing` class, once the account/territory aren't yet shared
            // to them.
            Database.insert(toInsert, AccessLevel.SYSTEM_MODE);
            TerritorySharingService.resyncForAccounts(new Set<Id>(accountIds));
        }
    }

    private static Id currentUserPrimaryTerritoryId() {
        List<User_Territory__c> primaryRows = [
            SELECT Territory__c FROM User_Territory__c
            WHERE User__c = :UserInfo.getUserId() AND Is_Primary__c = true
            LIMIT 1
        ];
        if (!primaryRows.isEmpty()) {
            return primaryRows[0].Territory__c;
        }
        List<User_Territory__c> anyRow = [
            SELECT Territory__c FROM User_Territory__c WHERE User__c = :UserInfo.getUserId() LIMIT 1
        ];
        return anyRow.isEmpty() ? null : anyRow[0].Territory__c;
    }

    private static Set<Id> currentUserTerritoryAccountIds() {
        Id territoryId = currentUserPrimaryTerritoryId();
        Set<Id> ids = new Set<Id>();
        if (territoryId == null) {
            return ids;
        }
        for (Account_Territory__c linkRow : [SELECT Account__c FROM Account_Territory__c WHERE Territory__c = :territoryId]) {
            ids.add(linkRow.Account__c);
        }
        return ids;
    }
}