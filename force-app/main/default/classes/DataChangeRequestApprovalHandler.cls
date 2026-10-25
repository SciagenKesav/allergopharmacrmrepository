/**
 * When a data steward approves a Data_Change_Request__c (Status__c -> 'Approved'),
 * applies the request's Fields_Payload__c onto real master data — this is the step
 * that makes the DCR governance gate actually produce data changes, not just a
 * request that sits there. Once the Account is created/updated, the iPad app's
 * regular Accounts pull (fetchHCPs/fetchHCOs, part of every autosync cycle) picks
 * it up on its own — no separate "push approval to iPad" path is needed.
 *
 * "New HCO"/"New HCP" requests create a new Sciagen_Account__c from a flat
 * {key: value} Fields_Payload__c. "Edit HCP"/"Edit HCO" requests instead write
 * onto the EXISTING Subject_Account__c from a {key: {current, requested}}
 * Fields_Payload__c (see SciagenAccountSyncService and DCRView.swift's
 * buildDiff/editedValues, which is the field-key vocabulary mirrored here) —
 * only the "requested" side of each changed key is applied.
 *
 * The app's local picklist-like option lists (DCRView.swift's hcoTypes/hcpTypes)
 * don't fully overlap with HCO_Type__c/HCP_Type__c's Salesforce values, and
 * Speciality__c/Specialty__c is genuinely free text on the app side with no
 * defined vocabulary at all. Rather than fail the whole approval over a picklist
 * mismatch, an unrecognized value is just left as-is (blank on a new Account,
 * unchanged on an edit) for a steward to fill in by hand — the request's original
 * text is never lost, since Fields_Payload__c and Summary__c stay on the DCR
 * regardless.
 */
public with sharing class DataChangeRequestApprovalHandler {

    private static final Set<String> VALID_HCO_TYPES = new Set<String>{
        'Hospital', 'Clinic', 'Nursing Home', 'Pharmacy', 'Medical Shop', 'Chemist Shop', 'Stockist',
        'Health System', 'Diagnostic Centre'
    };
    private static final Set<String> VALID_HCP_TYPES = new Set<String>{
        'Physician', 'Surgeon', 'Consultant', 'General Practitioner', 'Other',
        'Specialist', 'Super Specialist'
    };
    private static final Set<String> VALID_SPECIALTIES = new Set<String>{
        'Cardiology', 'Endocrinology', 'Oncology', 'Pulmonology', 'Immunology', 'General Physician',
        'Internal Medicine', 'Nephrology', 'Neurology', 'Other'
    };
    private static final Pattern PHONE_PATTERN = Pattern.compile('^(\\+?91)?[0-9]{10}$');

    public static void handleApprovals(List<Data_Change_Request__c> newList, Map<Id, Data_Change_Request__c> oldMap) {
        for (Data_Change_Request__c dcr : newList) {
            Data_Change_Request__c old = oldMap.get(dcr.Id);
            Boolean justApproved = dcr.Status__c == 'Approved' && old.Status__c != 'Approved';
            Boolean isNewRecordRequest = dcr.Type__c == 'New HCO' || dcr.Type__c == 'New HCP';
            Boolean isEditRequest = dcr.Type__c == 'Edit HCO' || dcr.Type__c == 'Edit HCP';
            Boolean isUnassignRequest = dcr.Type__c == 'Unassign HCO' || dcr.Type__c == 'Unassign HCP';
            if (justApproved && isNewRecordRequest && dcr.Subject_Account__c == null) {
                createAccountForApprovedDcr(dcr);
            } else if (justApproved && isEditRequest && dcr.Subject_Account__c != null) {
                applyEditForApprovedDcr(dcr);
            } else if (justApproved && isUnassignRequest && dcr.Subject_Account__c != null) {
                applyUnassignForApprovedDcr(dcr);
            }
        }
    }

    /** Savepoint-guarded so a failure here (e.g. a missing related HCO) never
     * leaves an orphaned Account/Affiliation behind — the whole attempt for
     * this one DCR rolls back and the approval itself is rejected with a
     * clear inline error, rather than silently succeeding halfway. */
    private static void createAccountForApprovedDcr(Data_Change_Request__c dcr) {
        Savepoint sp = Database.setSavepoint();
        try {
            Map<String, Object> fields = (Map<String, Object>) JSON.deserializeUntyped(
                String.isBlank(dcr.Fields_Payload__c) ? '{}' : dcr.Fields_Payload__c);

            Sciagen_Account__c acc = dcr.Type__c == 'New HCO' ? buildHCO(fields, dcr) : buildHCP(fields, dcr);
            Database.insert(acc, AccessLevel.USER_MODE);

            carryProofPhotoToAccount(dcr.Id, acc.Id);

            if (dcr.Type__c == 'New HCP') {
                if (dcr.Related_HCO__c == null) {
                    throw new DcrApprovalException('This HCP request has no affiliated HCO on file.');
                }
                Database.insert(new Affiliation__c(HCP__c = acc.Id, HCO__c = dcr.Related_HCO__c), AccessLevel.USER_MODE);
            }

            dcr.Subject_Account__c = acc.Id;
        } catch (Exception e) {
            Database.rollback(sp);
            dcr.addError('Could not auto-create the Account for this approval: ' + e.getMessage());
        }
    }

    /** Mirrors createAccountForApprovedDcr but for "Edit HCP"/"Edit HCO"
     * requests: writes the requested value of each changed field from
     * Fields_Payload__c (a {key: {current, requested}} map) onto the existing
     * Subject_Account__c record. Savepoint-guarded the same way, so a bad
     * value (e.g. a missing HCO match for an affiliation change) never leaves
     * a half-applied edit behind — the whole attempt rolls back and the
     * approval is rejected with a clear inline error. */
    private static void applyEditForApprovedDcr(Data_Change_Request__c dcr) {
        Savepoint sp = Database.setSavepoint();
        try {
            Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(
                String.isBlank(dcr.Fields_Payload__c) ? '{}' : dcr.Fields_Payload__c);

            List<Sciagen_Account__c> existing = [
                SELECT Id, Type__c, Name, HCO_Type__c, Speciality__c, Billing_City__c,
                       Billing_State__c, Billing_Postal_Code__c, Phone__c,
                       Prefix__c, First_Name__c, Last_Name__c, Specialty__c,
                       HCP_Type__c, Email__c, Degree_1__c
                FROM Sciagen_Account__c
                WHERE Id = :dcr.Subject_Account__c
                WITH USER_MODE
                LIMIT 1
            ];
            if (existing.isEmpty()) {
                throw new DcrApprovalException('The Account for this edit no longer exists.');
            }
            Sciagen_Account__c acc = existing[0];

            if (dcr.Type__c == 'Edit HCO') {
                applyHCOEdits(acc, payload);
            } else {
                applyHCPEdits(acc, payload);
            }

            Database.update(acc, AccessLevel.USER_MODE);
        } catch (Exception e) {
            Database.rollback(sp);
            dcr.addError('Could not apply this edit to the Account: ' + e.getMessage());
        }
    }

    /** "Unassign HCP"/"Unassign HCO": removes the Account_Territory__c link(s)
     * recorded on submit (see SciagenAccountTerritoryController.submitUnassignDcr's
     * {"territoryIds": [...]} payload) — the Account record itself is never
     * touched. Savepoint-guarded the same way as the other apply* methods, so
     * a bad/stale territory Id never leaves a half-applied removal behind. */
    private static void applyUnassignForApprovedDcr(Data_Change_Request__c dcr) {
        Savepoint sp = Database.setSavepoint();
        try {
            Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(
                String.isBlank(dcr.Fields_Payload__c) ? '{}' : dcr.Fields_Payload__c);
            List<Object> rawIds = (List<Object>) payload.get('territoryIds');
            if (rawIds == null || rawIds.isEmpty()) {
                throw new DcrApprovalException('This request has no territory recorded to remove it from.');
            }
            Set<Id> territoryIds = new Set<Id>();
            for (Object o : rawIds) {
                territoryIds.add((Id) String.valueOf(o));
            }

            List<Account_Territory__c> links = [
                SELECT Id
                FROM Account_Territory__c
                WHERE Account__c = :dcr.Subject_Account__c AND Territory__c IN :territoryIds
                WITH USER_MODE
            ];
            if (!links.isEmpty()) {
                Database.delete(links, AccessLevel.USER_MODE);
            }
        } catch (Exception e) {
            Database.rollback(sp);
            dcr.addError('Could not remove this Account from the territory: ' + e.getMessage());
        }
    }

    /// Reads the "requested" side of one changed field out of a
    /// {key: {current, requested}} diff payload; null if the key wasn't
    /// part of this diff at all (vs. blank, which means "cleared").
    private static String requestedVal(Map<String, Object> payload, String key) {
        Object raw = payload.get(key);
        if (!(raw instanceof Map<String, Object>)) return null;
        Object req = ((Map<String, Object>) raw).get('requested');
        return req != null ? String.valueOf(req).trim() : null;
    }

    private static void applyHCOEdits(Sciagen_Account__c acc, Map<String, Object> payload) {
        String name = requestedVal(payload, 'name');
        if (String.isNotBlank(name)) acc.Name = truncate(name, 255);

        String type = requestedVal(payload, 'type');
        if (type != null) {
            String picked = pickOrNull(type, VALID_HCO_TYPES);
            if (picked != null) acc.HCO_Type__c = picked;
        }

        String speciality = requestedVal(payload, 'speciality');
        if (speciality != null) {
            String picked = pickOrNull(speciality, VALID_SPECIALTIES);
            if (picked != null) acc.Speciality__c = picked;
        }

        String city = requestedVal(payload, 'city');
        if (city != null) acc.Billing_City__c = truncate(city, 255);

        String state = requestedVal(payload, 'state');
        if (state != null) acc.Billing_State__c = truncate(state, 80);

        String pincode = requestedVal(payload, 'pincode');
        if (pincode != null) acc.Billing_Postal_Code__c = truncate(pincode, 20);

        String phone = requestedVal(payload, 'phone');
        if (phone != null) {
            String normalized = normalizePhone(phone);
            if (normalized != null) acc.Phone__c = normalized;
        }

        String street = requestedVal(payload, 'street');
        if (street != null) acc.Billing_Street__c = truncate(street, 255);

        String country = requestedVal(payload, 'country');
        if (country != null) acc.Billing_Country__c = truncate(country, 80);

        String accountCode = requestedVal(payload, 'accountCode');
        if (accountCode != null) acc.Account_Code__c = truncate(accountCode, 30);

        String emailVal = requestedVal(payload, 'email');
        if (emailVal != null) acc.Email__c = emailVal;

        String website = requestedVal(payload, 'website');
        if (website != null) acc.Website__c = website;
    }

    private static void applyHCPEdits(Sciagen_Account__c acc, Map<String, Object> payload) {
        String prefix = requestedVal(payload, 'prefix');
        if (prefix != null) acc.Prefix__c = prefix;

        String firstName = requestedVal(payload, 'firstName');
        if (firstName != null) acc.First_Name__c = firstName;

        String lastName = requestedVal(payload, 'lastName');
        if (lastName != null) acc.Last_Name__c = lastName;

        if (prefix != null || firstName != null || lastName != null) {
            String fullName = joinNonBlank(new List<String>{
                acc.Prefix__c, acc.First_Name__c, acc.Last_Name__c
            });
            if (String.isNotBlank(fullName)) acc.Name = truncate(fullName, 255);
        }

        String specialty = requestedVal(payload, 'specialty');
        if (specialty != null) {
            String picked = pickOrNull(specialty, VALID_SPECIALTIES);
            if (picked != null) acc.Specialty__c = picked;
        }

        String hcpType = requestedVal(payload, 'hcpType');
        if (hcpType != null) {
            String picked = pickOrNull(hcpType, VALID_HCP_TYPES);
            if (picked != null) acc.HCP_Type__c = picked;
        }

        String email = requestedVal(payload, 'email');
        if (email != null) acc.Email__c = email;

        String phone = requestedVal(payload, 'phone');
        if (phone != null) {
            String normalized = normalizePhone(phone);
            if (normalized != null) acc.Phone__c = normalized;
        }

        String degree = requestedVal(payload, 'degree1');
        if (degree != null) acc.Degree_1__c = degree;

        String street = requestedVal(payload, 'street');
        if (street != null) acc.Billing_Street__c = truncate(street, 255);

        String country = requestedVal(payload, 'country');
        if (country != null) acc.Billing_Country__c = truncate(country, 80);

        String accountCode = requestedVal(payload, 'accountCode');
        if (accountCode != null) acc.Account_Code__c = truncate(accountCode, 30);

        String focusArea = requestedVal(payload, 'focusArea');
        if (focusArea != null) acc.Focus_Area__c = focusArea;

        String licenseNumber = requestedVal(payload, 'licenseNumber');
        if (licenseNumber != null) acc.License_Number__c = licenseNumber;

        String licensingBody = requestedVal(payload, 'licensingBody');
        if (licensingBody != null) acc.Licensing_Body__c = licensingBody;

        String primaryCountry = requestedVal(payload, 'primaryCountry');
        if (primaryCountry != null) acc.Primary_Country__c = primaryCountry;

        String affiliationHCO = requestedVal(payload, 'affiliationHCO');
        if (String.isNotBlank(affiliationHCO)) {
            applyPrimaryAffiliationChange(acc.Id, affiliationHCO);
        }
    }

    /** Re-points this HCP's primary Affiliation__c at the requested HCO,
     * looked up by Name — that's all the app's diff carries (see
     * DCRView.swift's editedValues(), which stores the HCO's display name,
     * not its Id). An unmatched or ambiguous name is skipped rather than
     * failing the whole edit, since the rest of the HCP's fields may still
     * be valid and worth applying. */
    private static void applyPrimaryAffiliationChange(Id hcpAccountId, String hcoName) {
        List<Sciagen_Account__c> targets = [
            SELECT Id FROM Sciagen_Account__c
            WHERE Type__c = 'HCO' AND Name = :hcoName
            WITH USER_MODE
            LIMIT 2
        ];
        if (targets.size() != 1) return;
        Id targetHCOId = targets[0].Id;

        List<Affiliation__c> primary = [
            SELECT Id, HCO__c FROM Affiliation__c
            WHERE HCP__c = :hcpAccountId AND Is_Primary__c = true
            WITH USER_MODE
            LIMIT 1
        ];
        if (!primary.isEmpty()) {
            if (primary[0].HCO__c != targetHCOId) {
                primary[0].HCO__c = targetHCOId;
                Database.update(primary[0], AccessLevel.USER_MODE);
            }
        } else {
            Database.insert(
                new Affiliation__c(HCP__c = hcpAccountId, HCO__c = targetHCOId, Is_Primary__c = true),
                AccessLevel.USER_MODE
            );
        }
    }

    private static Sciagen_Account__c buildHCO(Map<String, Object> fields, Data_Change_Request__c dcr) {
        Sciagen_Account__c acc = new Sciagen_Account__c();
        acc.Type__c = 'HCO';
        acc.Name = truncate(strVal(fields, 'name', dcr.Subject_Name__c), 255);
        acc.HCO_Type__c = pickOrNull(strVal(fields, 'type', null), VALID_HCO_TYPES);
        acc.Speciality__c = pickOrNull(strVal(fields, 'speciality', null), VALID_SPECIALTIES);
        // The rep's "City" field has no length limit on the iOS form and, in
        // practice, often carries a full landmark-based Indian address (e.g.
        // "Hales Clinics, Near Pizza Hut, Road No 25, Alkapur Township,
        // Manikonda, Hyderabad 500") rather than just a city name — truncating
        // defensively here means a long entry gets clipped instead of hard-
        // failing the whole approval with STRING_TOO_LONG.
        acc.Billing_City__c = truncate(strVal(fields, 'city', null), 255);
        acc.Billing_State__c = truncate(strVal(fields, 'state', null), 80);
        acc.Billing_Postal_Code__c = truncate(strVal(fields, 'pincode', null), 20);
        acc.Phone__c = normalizePhone(strVal(fields, 'phone', null));
        return acc;
    }

    private static Sciagen_Account__c buildHCP(Map<String, Object> fields, Data_Change_Request__c dcr) {
        String prefix = strVal(fields, 'prefix', null);
        String firstName = strVal(fields, 'firstName', null);
        String lastName = strVal(fields, 'lastName', null);

        Sciagen_Account__c acc = new Sciagen_Account__c();
        acc.Type__c = 'HCP';
        acc.Prefix__c = prefix;
        acc.First_Name__c = firstName;
        acc.Last_Name__c = lastName;
        String fullName = joinNonBlank(new List<String>{ prefix, firstName, lastName });
        acc.Name = truncate(String.isNotBlank(fullName) ? fullName : dcr.Subject_Name__c, 255);
        acc.Specialty__c = pickOrNull(strVal(fields, 'specialty', null), VALID_SPECIALTIES);
        acc.HCP_Type__c = pickOrNull(strVal(fields, 'hcpType', null), VALID_HCP_TYPES);
        acc.Email__c = strVal(fields, 'email', null);
        acc.Phone__c = normalizePhone(strVal(fields, 'phone', null));
        acc.Degree_1__c = strVal(fields, 'degree1', null);
        return acc;
    }

    /** Best-effort: re-links whatever proof photo was attached at DCR-submit time
     * (see SciagenAccountSyncService.buildProofPhoto) onto the newly created
     * Account, so it stays with the permanent record instead of only living on
     * the (eventually stale) request. Never fails the approval — a missing or
     * duplicate link here shouldn't block Account creation, which already
     * succeeded above. */
    private static void carryProofPhotoToAccount(Id dcrId, Id accountId) {
        try {
            List<ContentDocumentLink> existingLinks = [
                SELECT ContentDocumentId
                FROM ContentDocumentLink
                WHERE LinkedEntityId = :dcrId
                WITH USER_MODE
            ];
            if (existingLinks.isEmpty()) return;
            List<ContentDocumentLink> toInsert = new List<ContentDocumentLink>();
            for (ContentDocumentLink cdl : existingLinks) {
                toInsert.add(new ContentDocumentLink(
                    ContentDocumentId = cdl.ContentDocumentId,
                    LinkedEntityId = accountId,
                    ShareType = 'V'
                ));
            }
            Database.insert(toInsert, AccessLevel.USER_MODE);
        } catch (Exception e) {
            // Swallow — the Account itself was still created successfully.
        }
    }

    private static String strVal(Map<String, Object> fields, String key, String fallback) {
        Object v = fields.get(key);
        if (v == null) return fallback;
        String s = String.valueOf(v).trim();
        return String.isNotBlank(s) ? s : fallback;
    }

    private static String pickOrNull(String value, Set<String> validValues) {
        return (value != null && validValues.contains(value)) ? value : null;
    }

    /// Normalizes a rep-typed phone number down to the exact digits-only shape
    /// the Phone__c validation rule (10 digits, optional +91/91 prefix)
    /// requires, stripping spaces/dashes/parens along the way. A value that
    /// still doesn't fit that shape after normalizing is left off entirely
    /// (Phone__c keeps its prior value on an edit, stays blank on a new
    /// Account) rather than failing the whole approval — the same soft-fail
    /// treatment already given to an unrecognized HCO_Type__c/HCP_Type__c/
    /// Specialty__c value above.
    private static String normalizePhone(String raw) {
        if (String.isBlank(raw)) return null;
        String digitsOnly = raw.replaceAll('[^0-9+]', '');
        return PHONE_PATTERN.matcher(digitsOnly).matches() ? digitsOnly : null;
    }

    /// Defensive clip to a field's max length — the rep-typed free text these
    /// values come from has no length limit on the iOS form, so without this
    /// an unusually long entry throws STRING_TOO_LONG and blocks the whole
    /// approval outright rather than just losing a few trailing characters.
    private static String truncate(String value, Integer maxLen) {
        return (value != null && value.length() > maxLen) ? value.substring(0, maxLen) : value;
    }

    private static String joinNonBlank(List<String> parts) {
        List<String> out = new List<String>();
        for (String p : parts) {
            if (String.isNotBlank(p)) out.add(p.trim());
        }
        return String.join(out, ' ');
    }

    public class DcrApprovalException extends Exception {}
}