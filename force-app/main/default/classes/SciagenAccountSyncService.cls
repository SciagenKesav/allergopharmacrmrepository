/**
 * Inbound REST API for the iPad app to sync Sciagen_Account__c (HCP/HCO) data
 * bidirectionally with Salesforce — an alternative, lighter-weight transport to the
 * MobileSync-based sync already wired via Resources/userstore.json + usersyncs.json.
 *
 * GET  /services/apexrest/sciagen/v1/accounts   -> sync DOWN: pull accounts the calling
 *      user can see (territory-based sharing applies automatically via TerritorySharingService —
 *      this endpoint runs `with sharing`, so a rep only gets accounts in their own territory).
 *      Query params (all optional):
 *        type      - "HCP" or "HCO", filters to one kind
 *        territory - Territory__c Name, filters to one territory
 *        since     - ISO 8601 datetime; only accounts modified at/after this time
 *
 * POST /services/apexrest/sciagen/v1/accounts   -> sync UP: submit locally-created/edited
 *      accounts. Deliberately does NOT write Sciagen_Account__c directly — every submission
 *      becomes a Data_Change_Request__c for a data steward to review, exactly like the
 *      iPad app's own local DCR workflow (DCRView.swift / Data_Change_Request__c). This
 *      keeps both sync paths (MobileSync's syncUpDataChangeRequests and this REST
 *      endpoint) writing through the same governance gate rather than two different
 *      paths with different rules.
 *
 * Both verbs run `with sharing` and enforce FLS/CRUD via WITH USER_MODE / AccessLevel.USER_MODE,
 * so the endpoint's data access is exactly what the authenticated caller's profile,
 * permission sets, and territory assignment already allow — nothing more.
 */
@RestResource(urlMapping='/sciagen/v1/accounts/*')
global with sharing class SciagenAccountSyncService {

    // ===================== GET: sync down =====================

    global class AccountSyncRecord {
        public String salesforceId;
        public String type;              // HCP / HCO
        public String name;
        public String accountCode;
        public String territory;
        public String phone;
        public String email;
        public String parentAccountId;   // HCO parent, for HCO hierarchy
        public String lastModifiedDate;  // ISO 8601
    }

    global class SyncDownResult {
        public Boolean success;
        public String message;
        public List<AccountSyncRecord> records;
        public String serverTimestamp;   // echo back as the next call's `since`
    }

    @HttpGet
    global static SyncDownResult syncDown() {
        SyncDownResult result = new SyncDownResult();
        try {
            result = doSyncDown(RestContext.request.params);
        } catch (Exception e) {
            result.success = false;
            result.message = 'Sync down failed: ' + e.getMessage();
            result.records = new List<AccountSyncRecord>();
            RestContext.response.statusCode = 400;
        }
        return result;
    }

    @TestVisible
    private static SyncDownResult doSyncDown(Map<String, String> params) {
        SyncDownResult result = new SyncDownResult();

        String typeFilter = params.get('type');
        String territoryFilter = params.get('territory');
        String sinceParam = params.get('since');

        if (String.isNotBlank(typeFilter) && typeFilter != 'HCP' && typeFilter != 'HCO') {
            throw new SciagenSyncException('type must be "HCP" or "HCO"');
        }

        List<String> whereClauses = new List<String>();
        Map<String, Object> binds = new Map<String, Object>();

        if (String.isNotBlank(typeFilter)) {
            whereClauses.add('Type__c = :typeFilter');
            binds.put('typeFilter', typeFilter);
        }
        if (String.isNotBlank(sinceParam)) {
            Datetime since = parseIso8601(sinceParam);
            whereClauses.add('LastModifiedDate >= :since');
            binds.put('since', since);
        }

        String query = 'SELECT Id, Name, Type__c, Account_Code__c, Phone__c, Email__c, Parent_Account__c, LastModifiedDate ' +
            'FROM Sciagen_Account__c';
        if (!whereClauses.isEmpty()) {
            query += ' WHERE ' + String.join(whereClauses, ' AND ');
        }
        query += ' ORDER BY LastModifiedDate DESC LIMIT 2000';

        List<Sciagen_Account__c> accounts = Database.queryWithBinds(query, binds, AccessLevel.USER_MODE);

        Set<Id> accountIds = new Set<Id>();
        for (Sciagen_Account__c a : accounts) accountIds.add(a.Id);

        Map<Id, String> territoryByAccountId = new Map<Id, String>();
        if (!accountIds.isEmpty()) {
            for (Account_Territory__c at : [
                SELECT Account__c, Territory__r.Name
                FROM Account_Territory__c
                WHERE Account__c IN :accountIds
                WITH USER_MODE
            ]) {
                if (at.Territory__r != null) {
                    territoryByAccountId.put(at.Account__c, at.Territory__r.Name);
                }
            }
        }

        List<AccountSyncRecord> outRecords = new List<AccountSyncRecord>();
        for (Sciagen_Account__c a : accounts) {
            String territoryName = territoryByAccountId.get(a.Id);
            if (String.isNotBlank(territoryFilter) && territoryFilter != territoryName) {
                continue; // post-filter: territory name isn't queryable directly off Sciagen_Account__c
            }
            AccountSyncRecord rec = new AccountSyncRecord();
            rec.salesforceId = a.Id;
            rec.type = a.Type__c;
            rec.name = a.Name;
            rec.accountCode = a.Account_Code__c;
            rec.territory = territoryName;
            rec.phone = a.Phone__c;
            rec.email = a.Email__c;
            rec.parentAccountId = a.Parent_Account__c;
            rec.lastModifiedDate = a.LastModifiedDate.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');
            outRecords.add(rec);
        }

        result.success = true;
        result.message = 'Synced ' + outRecords.size() + ' account(s).';
        result.records = outRecords;
        result.serverTimestamp = Datetime.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');
        return result;
    }

    private static Datetime parseIso8601(String iso) {
        // Datetime.valueOfGmt expects 'yyyy-MM-dd HH:mm:ss'; accept the standard
        // 'yyyy-MM-ddTHH:mm:ssZ' the client sends and reshape it.
        String cleaned = iso.replace('T', ' ').replace('Z', '');
        try {
            return Datetime.valueOfGmt(cleaned);
        } catch (Exception e) {
            throw new SciagenSyncException('since must be an ISO 8601 datetime, e.g. 2026-08-16T10:00:00Z');
        }
    }

    // ===================== POST: sync up (creates DCRs) =====================

    global class AccountUpsertRequest {
        public String localId;           // client-generated id, echoed back for correlation
        public String type;              // HCP / HCO
        public String mode;              // "new" or "edit"
        public String subjectAccountId;  // Salesforce Id, required when mode = "edit"
        public String relatedHCOId;      // Salesforce Id of the HCO, for a New HCP
        public String subjectName;
        public String summary;
        public Map<String, String> fields;
        public String photoBase64;       // optional proof photo (visiting card / Rx pad / name board)
        public String photoFileName;
        // Edit HCP/HCO only: per-field {"current": ..., "requested": ...} diff, changed fields
        // only. Additive alongside `fields` (used by New HCP/HCO) rather than retyping it, so
        // existing callers/tests serializing a flat Map<String,String> keep working unchanged.
        //
        // MUST stay a concrete Map<String, Map<String, String>> — not Map<String, Object>.
        // syncUp() parses the whole request body with the strongly-typed JSON.deserialize(String,
        // Type), and that API throws "Apex Type unsupported in JSON: Object" the instant it hits
        // an Object-typed field, unconditionally, for the entire request — not a per-field or
        // per-record failure. That silently rejected every single Edit HCP/HCO DCR the iPad ever
        // submitted (New HCP/HCO requests only use `fields` above, a plain Map<String,String>,
        // which is why those always worked while Edit never did). The client (SalesforceRest
        // DataService.swift's submitDataChangeRequest) only ever sends {"current": <string>,
        // "requested": <string>} per field, so this concrete shape loses nothing.
        public Map<String, Map<String, String>> fieldDiffs;
    }

    global class AccountSyncPushRequest {
        public List<AccountUpsertRequest> records;
    }

    global class AccountUpsertResult {
        public String localId;
        public Boolean success;
        public String dcrId;
        public String message;
    }

    global class SyncUpResult {
        public Boolean success;
        public List<AccountUpsertResult> results;
    }

    @HttpPost
    global static SyncUpResult syncUp() {
        SyncUpResult result = new SyncUpResult();
        result.results = new List<AccountUpsertResult>();
        try {
            AccountSyncPushRequest payload =
                (AccountSyncPushRequest) JSON.deserialize(RestContext.request.requestBody.toString(), AccountSyncPushRequest.class);
            result = doSyncUp(payload);
        } catch (Exception e) {
            result.success = false;
            RestContext.response.statusCode = 400;
        }
        return result;
    }

    @TestVisible
    private static SyncUpResult doSyncUp(AccountSyncPushRequest payload) {
        SyncUpResult result = new SyncUpResult();
        result.results = new List<AccountUpsertResult>();

        if (payload == null || payload.records == null || payload.records.isEmpty()) {
            result.success = false;
            return result;
        }

        // Submitted_By__c is sized (Text 18) for a Salesforce User Id and is always set
        // from the authenticated session — never trusted from the request body — so a
        // caller can't attribute a DCR to a different user than the one that's actually
        // authenticated.
        Id runningUserId = UserInfo.getUserId();

        List<Data_Change_Request__c> toInsert = new List<Data_Change_Request__c>();
        List<Integer> indexForRow = new List<Integer>(); // toInsert index -> payload.records index
        List<AccountUpsertResult> rowResults = new List<AccountUpsertResult>();

        for (Integer i = 0; i < payload.records.size(); i++) {
            AccountUpsertRequest req = payload.records[i];
            AccountUpsertResult rowResult = new AccountUpsertResult();
            rowResult.localId = req.localId;
            rowResults.add(rowResult);

            String validationError = validate(req);
            if (validationError != null) {
                rowResult.success = false;
                rowResult.message = validationError;
                continue;
            }

            Data_Change_Request__c dcr = new Data_Change_Request__c(
                Type__c = mapType(req.type, req.mode),
                Status__c = 'Pending Approval',
                Subject_Name__c = req.subjectName,
                Summary__c = req.summary,
                Fields_Payload__c = (req.fieldDiffs != null && !req.fieldDiffs.isEmpty())
                    ? JSON.serialize(req.fieldDiffs)
                    : (req.fields != null ? JSON.serialize(req.fields) : '{}'),
                Submitted_By__c = runningUserId,
                Submitted_At__c = Datetime.now()
            );
            if (String.isNotBlank(req.relatedHCOId)) {
                dcr.Related_HCO__c = req.relatedHCOId;
            }
            if (req.mode == 'edit' && String.isNotBlank(req.subjectAccountId)) {
                dcr.Subject_Account__c = req.subjectAccountId;
            }
            // City__c/State__c/Pincode__c/Phone__c/Full_Address__c surface the New
            // HCO/HCP form's address+phone fields as real, list-view-visible fields —
            // before this, a reviewer could only see them by decoding the raw JSON in
            // Fields_Payload__c. `req.fields` is empty for edit-mode requests (those
            // carry `fieldDiffs` instead), so these simply stay blank there, same as
            // for a New HCP request (which never collects an address).
            if (req.fields != null) {
                dcr.City__c = req.fields.get('city');
                dcr.State__c = req.fields.get('state');
                dcr.Pincode__c = req.fields.get('pincode');
                dcr.Phone__c = req.fields.get('phone');
                dcr.Full_Address__c = buildFullAddress(req.fields.get('city'), req.fields.get('state'), req.fields.get('pincode'));
            }

            toInsert.add(dcr);
            indexForRow.add(i);
        }

        if (!toInsert.isEmpty()) {
            List<Database.SaveResult> saveResults = Database.insert(toInsert, false, AccessLevel.USER_MODE);
            List<ContentVersion> photosToInsert = new List<ContentVersion>();

            for (Integer j = 0; j < saveResults.size(); j++) {
                Database.SaveResult sr = saveResults[j];
                AccountUpsertResult rowResult = rowResults[indexForRow[j]];
                rowResult.success = sr.isSuccess();
                if (sr.isSuccess()) {
                    rowResult.dcrId = sr.getId();
                    rowResult.message = 'Created';
                    AccountUpsertRequest req = payload.records[indexForRow[j]];
                    if (String.isNotBlank(req.photoBase64)) {
                        ContentVersion cv = buildProofPhoto(req, sr.getId());
                        if (cv != null) {
                            photosToInsert.add(cv);
                        }
                    }
                } else {
                    rowResult.message = sr.getErrors().isEmpty() ? 'Unknown error' : sr.getErrors()[0].getMessage();
                }
            }

            if (!photosToInsert.isEmpty()) {
                // Best-effort: the DCR itself already succeeded above, so a photo-attach
                // failure (e.g. malformed base64) shouldn't fail the whole request.
                Database.insert(photosToInsert, false, AccessLevel.USER_MODE);
            }
        }

        result.results = rowResults;
        result.success = true; // batch-level success; check each row's own `success` for per-record outcome
        return result;
    }

    private static String validate(AccountUpsertRequest req) {
        if (req.type != 'HCP' && req.type != 'HCO') {
            return 'type must be "HCP" or "HCO"';
        }
        if (req.mode != 'new' && req.mode != 'edit') {
            return 'mode must be "new" or "edit"';
        }
        if (String.isBlank(req.subjectName)) {
            return 'subjectName is required';
        }
        if (req.mode == 'edit' && String.isBlank(req.subjectAccountId)) {
            return 'subjectAccountId is required when mode is "edit"';
        }
        if (req.mode == 'edit' && (req.fieldDiffs == null || req.fieldDiffs.isEmpty())
                && (req.fields == null || req.fields.isEmpty())) {
            return 'at least one changed field is required for an edit request';
        }
        return null;
    }

    /// Decodes the optional proof photo and builds a ContentVersion linked to the
    /// DCR via FirstPublishLocationId — same base64->ContentVersion pattern used by
    /// CMSContentReceiver.cls. Returns null (rather than throwing) on malformed
    /// base64 so one bad photo doesn't derail the rest of the batch.
    private static ContentVersion buildProofPhoto(AccountUpsertRequest req, Id dcrId) {
        try {
            String fileName = String.isNotBlank(req.photoFileName) ? req.photoFileName : (req.subjectName + '_proof.jpg');
            return new ContentVersion(
                Title = fileName,
                PathOnClient = fileName,
                VersionData = EncodingUtil.base64Decode(req.photoBase64),
                FirstPublishLocationId = dcrId
            );
        } catch (Exception e) {
            return null;
        }
    }

    private static String mapType(String type, String mode) {
        if (type == 'HCP') return mode == 'new' ? 'New HCP' : 'Edit HCP';
        return mode == 'new' ? 'New HCO' : 'Edit HCO';
    }

    /// "City, State - Pincode", skipping any blank part and its separator —
    /// e.g. just "Bangalore, Karnataka" if pincode wasn't entered. Blank
    /// when all three are blank (New HCP requests, which don't collect one).
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

    public class SciagenSyncException extends Exception {}
}