/**
 * When a data steward approves a "New HCO" or "New HCP" Data_Change_Request__c
 * (Status__c -> 'Approved'), creates the real Sciagen_Account__c record from the
 * request's Fields_Payload__c — this is the step that makes the DCR governance
 * gate actually produce master data, not just a request that sits there. Once the
 * Account exists, the iPad app's regular Accounts pull (fetchHCPs/fetchHCOs, part
 * of every autosync cycle) picks it up on its own — no separate "push approval to
 * iPad" path is needed.
 *
 * The new Account is owned by the DCR's *submitter*, not the approving steward — this
 * one line is the actual fix for a real production bug where an approved "New HCP/HCO"
 * looked like it worked (Status flipped to Approved) but the rep who'd submitted it
 * never saw the resulting Account anywhere, on iPad or online. The Account was really
 * being created — just always owned by whichever admin clicked Approve, and the
 * pre-existing AccountTerritoryAutoAssign trigger (AccountTerritoryAutoAssignService)
 * only ever assigns a brand-new Account to its *owner's* primary territory. With the
 * owner wrong, that trigger silently no-op'd (an admin has no field territory), so the
 * Account ended up with zero Account_Territory__c rows — Private OWD then made it
 * invisible to everyone but the admin who happened to own it. Fixing OwnerId here means
 * that existing trigger now does the right thing on its own; no separate territory
 * logic needed in this class.
 *
 * "Edit HCP"/"Edit HCO" requests ARE now handled here too (applyApprovedEdit):
 * Fields_Payload__c is a {field: {current, requested}} diff (same shape
 * DCRReviewController.DCRDetail.diffFields reads for the review UI), so approval
 * writes each requested value onto the real Account — same "the change isn't
 * reflecting" bug, different cause: this used to require a steward to separately,
 * manually edit the Account by hand after approving, and nothing enforced that they
 * actually did.
 *
 * "Territory Unassign" requests ARE handled here (applyApprovedTerritoryUnassign):
 * unlike an Edit, there's exactly one mechanical action a steward's approval means —
 * delete the Account_Territory__c link(s) AccountTerritoryUnassignService stashed as
 * Fields_Payload__c.territoryIds when the request was filed. Nothing to apply on Reject;
 * the link is simply left in place.
 *
 * The app's local picklist-like option lists (DCRView.swift's hcoTypes/hcpTypes)
 * don't fully overlap with HCO_Type__c/HCP_Type__c's Salesforce values, and
 * Speciality__c/Specialty__c is genuinely free text on the app side with no
 * defined vocabulary at all. Rather than fail Account creation over a picklist
 * mismatch, an unrecognized value is just left blank on the Account for a
 * steward to fill in — the request's original text is never lost, since
 * Fields_Payload__c and Summary__c stay on the DCR regardless.
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

    public static void handleApprovals(List<Data_Change_Request__c> newList, Map<Id, Data_Change_Request__c> oldMap) {
        Boolean isAdmin;
        for (Data_Change_Request__c dcr : newList) {
            Data_Change_Request__c old = oldMap.get(dcr.Id);
            // Only a data steward (or an admin) may decide a request, and nobody
            // but an admin may decide their own — otherwise a rep with Edit on
            // Data_Change_Request__c could approve their own New HCP/HCO and
            // create master data with no review.
            Boolean decided = dcr.Status__c != old.Status__c
                && (dcr.Status__c == 'Approved' || dcr.Status__c == 'Rejected');
            if (decided) {
                if (isAdmin == null) isAdmin = hasModifyAllData();
                Boolean steward = isAdmin || FeatureManagement.checkPermission('Approve_Data_Change_Requests');
                Boolean ownRequest = String.isNotBlank(dcr.Submitted_By__c)
                    && dcr.Submitted_By__c.left(15) == String.valueOf(UserInfo.getUserId()).left(15);
                if (!steward) {
                    dcr.Status__c.addError('Only a data steward can approve or reject data change requests.');
                    continue;
                }
                if (ownRequest && !isAdmin) {
                    dcr.Status__c.addError('You can\'t approve or reject your own data change request.');
                    continue;
                }
            }
            Boolean justApproved = dcr.Status__c == 'Approved' && old.Status__c != 'Approved';
            Boolean isNewRecordRequest = dcr.Type__c == 'New HCO' || dcr.Type__c == 'New HCP';
            if (justApproved && isNewRecordRequest && dcr.Subject_Account__c == null) {
                createAccountForApprovedDcr(dcr);
            }
            Boolean isEditRequest = dcr.Type__c == 'Edit HCO' || dcr.Type__c == 'Edit HCP';
            if (justApproved && isEditRequest) {
                applyApprovedEdit(dcr);
            }
            if (justApproved && dcr.Type__c == 'Territory Unassign') {
                applyApprovedTerritoryUnassign(dcr);
            }
        }
    }

    /** Savepoint-guarded for the same reason as createAccountForApprovedDcr — a failure here
     * (e.g. malformed Fields_Payload__c) rejects the approval with a clear inline error
     * instead of silently leaving the account still assigned. */
    private static void applyApprovedTerritoryUnassign(Data_Change_Request__c dcr) {
        Savepoint sp = Database.setSavepoint();
        try {
            if (dcr.Subject_Account__c == null) {
                throw new DcrApprovalException('This request has no account on file.');
            }
            Map<String, Object> fields = (Map<String, Object>) JSON.deserializeUntyped(
                String.isBlank(dcr.Fields_Payload__c) ? '{}' : dcr.Fields_Payload__c);
            List<Object> rawIds = (List<Object>) fields.get('territoryIds');
            if (rawIds == null || rawIds.isEmpty()) {
                throw new DcrApprovalException('This request has no territory on file to remove.');
            }
            Set<Id> territoryIds = new Set<Id>();
            for (Object rawId : rawIds) {
                territoryIds.add((Id) String.valueOf(rawId));
            }
            // Re-queried rather than trusted from the payload: the link may already have been
            // removed some other way between filing and approval, which is a harmless no-op
            // here, not an error.
            List<Account_Territory__c> links = [
                SELECT Id FROM Account_Territory__c
                WHERE Account__c = :dcr.Subject_Account__c AND Territory__c IN :territoryIds
            ];
            if (!links.isEmpty()) {
                Database.delete(links, AccessLevel.USER_MODE);
            }
        } catch (Exception e) {
            Database.rollback(sp);
            dcr.addError('Could not apply the approved territory removal: ' + e.getMessage());
        }
    }

    private static Boolean hasModifyAllData() {
        return ![
            SELECT Id FROM PermissionSetAssignment
            WHERE AssigneeId = :UserInfo.getUserId() AND PermissionSet.PermissionsModifyAllData = true
            LIMIT 1
        ].isEmpty();
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
            if (String.isNotBlank(dcr.Submitted_By__c)) {
                acc.OwnerId = Id.valueOf(dcr.Submitted_By__c);
            }
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

    /**
     * Applies an approved Edit HCP/HCO's diff straight onto the real Account —
     * previously this was a no-op and a steward had to separately, manually replicate
     * the change by hand, with nothing enforcing that they actually did. Only fields
     * present in Fields_Payload__c are touched; a picklist-backed field whose requested
     * value doesn't validate is left alone (never blanked — unlike a brand-new record,
     * there's an existing value here worth not destroying).
     */
    private static void applyApprovedEdit(Data_Change_Request__c dcr) {
        if (dcr.Subject_Account__c == null) {
            dcr.addError('This request has no account on file to apply the edit to.');
            return;
        }
        Savepoint sp = Database.setSavepoint();
        try {
            Map<String, Object> fields = (Map<String, Object>) JSON.deserializeUntyped(
                String.isBlank(dcr.Fields_Payload__c) ? '{}' : dcr.Fields_Payload__c);

            Sciagen_Account__c acc = [
                SELECT Id, Type__c, Prefix__c, First_Name__c, Last_Name__c
                FROM Sciagen_Account__c WHERE Id = :dcr.Subject_Account__c
                WITH USER_MODE
                LIMIT 1
            ];
            Boolean isHCO = acc.Type__c == 'HCO';
            Boolean touchedName = false;

            for (String key : fields.keySet()) {
                Object raw = fields.get(key);
                if (!(raw instanceof Map<String, Object>)) continue;
                String requested = displayRequestedValue((Map<String, Object>) raw);
                if (requested == null) continue; // blank/unchanged requested value — nothing to write

                if (isHCO) {
                    if (key == 'name') { acc.Name = truncate(requested, 255); }
                    else if (key == 'type') { applyPicklist(acc, Sciagen_Account__c.HCO_Type__c, requested, VALID_HCO_TYPES); }
                    else if (key == 'speciality') { applyPicklist(acc, Sciagen_Account__c.Speciality__c, requested, VALID_SPECIALTIES); }
                    else if (key == 'city') { acc.Billing_City__c = truncate(requested, 255); }
                    else if (key == 'state') { acc.Billing_State__c = truncate(requested, 80); }
                    else if (key == 'pincode') { acc.Billing_Postal_Code__c = truncate(requested, 20); }
                    else if (key == 'phone') { acc.Phone__c = requested; }
                    else if (key == 'email') { acc.Email__c = requested; }
                    else if (key == 'website') { acc.Website__c = requested; }
                    else if (key == 'accountCode') { acc.Account_Code__c = truncate(requested, 30); }
                    else if (key == 'street') { acc.Billing_Street__c = truncate(requested, 255); }
                    else if (key == 'country') { acc.Billing_Country__c = truncate(requested, 80); }
                } else {
                    if (key == 'prefix') { acc.Prefix__c = requested; touchedName = true; }
                    else if (key == 'firstName') { acc.First_Name__c = requested; touchedName = true; }
                    else if (key == 'lastName') { acc.Last_Name__c = requested; touchedName = true; }
                    else if (key == 'specialty') { applyPicklist(acc, Sciagen_Account__c.Specialty__c, requested, VALID_SPECIALTIES); }
                    else if (key == 'hcpType') { applyPicklist(acc, Sciagen_Account__c.HCP_Type__c, requested, VALID_HCP_TYPES); }
                    else if (key == 'email') { acc.Email__c = requested; }
                    else if (key == 'phone') { acc.Phone__c = requested; }
                    else if (key == 'degree1') { acc.Degree_1__c = requested; }
                    else if (key == 'focusArea') { acc.Focus_Area__c = requested; }
                    else if (key == 'licenseNumber') { acc.License_Number__c = requested; }
                    else if (key == 'licensingBody') { acc.Licensing_Body__c = requested; }
                    else if (key == 'primaryCountry') { acc.Primary_Country__c = requested; }
                    else if (key == 'accountCode') { acc.Account_Code__c = truncate(requested, 30); }
                    else if (key == 'street') { acc.Billing_Street__c = truncate(requested, 255); }
                    else if (key == 'city') { acc.Billing_City__c = truncate(requested, 255); }
                    else if (key == 'state') { acc.Billing_State__c = truncate(requested, 80); }
                    else if (key == 'pincode') { acc.Billing_Postal_Code__c = truncate(requested, 20); }
                    else if (key == 'country') { acc.Billing_Country__c = truncate(requested, 80); }
                    else if (key == 'affiliationHCO') { applyAffiliationChange(acc.Id, requested); }
                }
            }

            if (touchedName) {
                String fullName = joinNonBlank(new List<String>{ acc.Prefix__c, acc.First_Name__c, acc.Last_Name__c });
                if (String.isNotBlank(fullName)) {
                    acc.Name = truncate(fullName, 255);
                }
            }

            Database.update(acc, AccessLevel.USER_MODE);
        } catch (Exception e) {
            Database.rollback(sp);
            dcr.addError('Could not apply the approved edit to the Account: ' + e.getMessage());
        }
    }

    /** Only writes a picklist field when the requested value is in the app's known
     * vocabulary — leaving a perfectly good existing value in place beats blanking it
     * out over a value Salesforce and the iPad's local option list simply disagree on. */
    private static void applyPicklist(Sciagen_Account__c acc, Schema.SObjectField field, String requested, Set<String> validValues) {
        if (validValues.contains(requested)) {
            acc.put(field, requested);
        }
    }

    /** Re-points the HCP's Affiliation__c to the requested HCO. Best-effort: an
     * unrecognized/invalid HCO id is skipped rather than failing the whole edit. */
    private static void applyAffiliationChange(Id hcpId, String requestedHcoId) {
        Id hcoId;
        try {
            hcoId = Id.valueOf(requestedHcoId);
        } catch (Exception e) {
            return;
        }
        List<Affiliation__c> existing = [SELECT Id, HCO__c FROM Affiliation__c WHERE HCP__c = :hcpId WITH USER_MODE];
        if (existing.isEmpty()) {
            Database.insert(new Affiliation__c(HCP__c = hcpId, HCO__c = hcoId), AccessLevel.USER_MODE);
        } else {
            existing[0].HCO__c = hcoId;
            Database.update(existing[0], AccessLevel.USER_MODE);
        }
    }

    /** Mirrors DCRReviewController's own displayValue()/"(blank)" convention for a
     * diff pair, but returns null (nothing to write) instead of the literal string
     * "(blank)" — approving an edit should never write that placeholder text onto a
     * real field. */
    private static String displayRequestedValue(Map<String, Object> pair) {
        Object raw = pair.get('requested');
        if (raw == null) return null;
        String s = String.valueOf(raw).trim();
        return String.isNotBlank(s) ? s : null;
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
        // Street and country come from the web "New Request" form (the iPad's request has no such keys).
        acc.Billing_Street__c = truncate(strVal(fields, 'street', null), 255);
        acc.Billing_Country__c = truncate(strVal(fields, 'country', null), 80);
        acc.Phone__c = strVal(fields, 'phone', null);
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
        acc.Phone__c = strVal(fields, 'phone', null);
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