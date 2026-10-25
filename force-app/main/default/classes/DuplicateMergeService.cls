/**
 * Merges a losing HCP/HCO into a winning one.
 *
 *  - Field survivorship: the winner's value is kept unless it is blank (then the loser's fills the gap)
 *    or the steward chose the loser's. Phone / email / licence values that are discarded are kept on
 *    the winner as ALT_* identifiers so a later record carrying them still matches.
 *  - Every child record (call reports, consents, plans, territories, affiliations...) is re-pointed
 *    from the loser to the winner, with de-duplication where a junction record already exists.
 *  - The loser is soft-merged (Is_Merged__c, Merged_Into__c), never deleted, so nothing is lost.
 *  - A Merge_Log__c records every decision and every moved record, which is what makes Undo possible.
 *
 * All-or-nothing: any failure rolls the whole merge back.
 */
public without sharing class DuplicateMergeService {

    public class MergeException extends Exception {}

    public class MergeResult {
        public Id logId;
        public Id winnerId;
        public Id loserId;
        public Integer movedTotal = 0;
        public Map<String, Integer> moved = new Map<String, Integer>();
        public List<String> warnings = new List<String>();
    }

    /** A child relationship that must follow the winner. */
    private class Rel {
        String obj; String field; String types; String strategy; String keyField;
        Rel(String obj, String field, String types, String strategy, String keyField) {
            this.obj = obj; this.field = field; this.types = types; this.strategy = strategy; this.keyField = keyField;
        }
    }

    // MOVE: re-point. UNIQUE: skip loser rows whose keyField already exists on the winner.
    // COPY_UNIQUE: give the winner any territory it lacks but leave the loser's rows, so the reps who could see the
    // loser keep seeing it, and their iPads learn it was merged.
    // IF_EMPTY: move only when the winner has none. AFFILIATION: UNIQUE plus primary-flag handling.
    private static List<Rel> relationships() {
        return new List<Rel>{
            new Rel('Account_Plan__c', 'HCP__c', 'HCP', 'MOVE', null),
            new Rel('Account_Plan__c', 'HCO__c', 'HCO', 'MOVE', null),
            new Rel('Account_Territory__c', 'Account__c', 'BOTH', 'COPY_UNIQUE', 'Territory__c'),
            new Rel('Action_Item__c', 'Account__c', 'BOTH', 'MOVE', null),
            new Rel('Affiliation__c', 'HCP__c', 'HCP', 'AFFILIATION', 'HCO__c'),
            new Rel('Affiliation__c', 'HCO__c', 'HCO', 'AFFILIATION', 'HCP__c'),
            new Rel('CVR_Attendee__c', 'HCP__c', 'HCP', 'MOVE', null),
            new Rel('Call_Visit_Report__c', 'HCP__c', 'HCP', 'MOVE', null),
            new Rel('Call_Visit_Report__c', 'HCO__c', 'HCO', 'MOVE', null),
            new Rel('Clinical_Trial__c', 'HCP__c', 'HCP', 'MOVE', null),
            new Rel('Congress_Event__c', 'HCP__c', 'HCP', 'MOVE', null),
            new Rel('Consent__c', 'HCP__c', 'HCP', 'MOVE', null),
            new Rel('Custom_List_Member__c', 'HCP__c', 'HCP', 'UNIQUE', 'List__c'),
            new Rel('Data_Change_Request__c', 'Subject_Account__c', 'BOTH', 'MOVE', null),
            new Rel('Data_Change_Request__c', 'Related_HCO__c', 'HCO', 'MOVE', null),
            new Rel('Influence_Peer__c', 'HCP__c', 'HCP', 'MOVE', null),
            new Rel('Influence_Peer__c', 'Peer_HCP__c', 'HCP', 'MOVE', null),
            new Rel('Office_Window__c', 'HCP__c', 'HCP', 'MOVE', null),
            new Rel('Office_Window__c', 'HCO__c', 'HCO', 'MOVE', null),
            new Rel('Plan_Activity__c', 'Linked_Account__c', 'BOTH', 'MOVE', null),
            new Rel('Plan_Stakeholder__c', 'HCP__c', 'HCP', 'MOVE', null),
            new Rel('Planned_Call__c', 'HCP__c', 'HCP', 'MOVE', null),
            new Rel('Planned_Call__c', 'HCO__c', 'HCO', 'MOVE', null),
            new Rel('Publication__c', 'HCP__c', 'HCP', 'MOVE', null),
            new Rel('RCPA_Audit__c', 'Chemist__c', 'HCO', 'MOVE', null),
            new Rel('RCPA_Line__c', 'Prescriber__c', 'HCP', 'MOVE', null),
            new Rel('RCPA_Target__c', 'Target_HCP__c', 'HCP', 'MOVE', null),
            new Rel('Sales_Transaction__c', 'Stockist__c', 'HCO', 'MOVE', null),
            // UCPMP sample history must follow the doctor, or the survivor's annual limits start from zero (audit H4).
            // Sample_Expenditure_Tracking__c is merged separately (mergeExpenditure): one row per FY + HCP + product.
            new Rel('Sample_Transaction__c', 'HCP_Account__c', 'HCP', 'MOVE', null),
            new Rel('Sample_Blocked_Attempt__c', 'HCP_Account__c', 'HCP', 'MOVE', null),
            new Rel('Sample_Limit_Override__c', 'Target_Account__c', 'BOTH', 'MOVE', null),
            new Rel('Call_Visit_Report__c', 'Signee_Account__c', 'HCP', 'MOVE', null),
            new Rel('Segmentation__c', 'HCP__c', 'HCP', 'IF_EMPTY', null),
            new Rel('Sent_Email__c', 'HCP__c', 'HCP', 'MOVE', null),
            new Rel('Sciagen_Account__c', 'Parent_Account__c', 'HCO', 'MOVE', null),
            new Rel('Sciagen_Account__c', 'Merged_Into__c', 'BOTH', 'MOVE', null)
        };
    }

    // ---------------------------------------------------------------- field catalogue

    public class FieldDef {
        @AuraEnabled public String api;
        @AuraEnabled public String label;
        @AuraEnabled public String groupKey;   // choice key: a group name or the field API name
        @AuraEnabled public String type;
    }

    private static final Set<String> NAME_GROUP = new Set<String>{ 'Name', 'Prefix__c', 'First_Name__c', 'Last_Name__c' };
    private static final Set<String> ADDRESS_GROUP = new Set<String>{ 'Billing_Street__c', 'Billing_City__c', 'Billing_State__c',
        'Billing_Postal_Code__c', 'Billing_Country__c', 'Geolocation__Latitude__s', 'Geolocation__Longitude__s', 'Plus_Code__c' };
    private static final Set<String> EXCLUDED = new Set<String>{ 'Id', 'OwnerId', 'Type__c', 'Is_Merged__c', 'Merged_Into__c', 'Merged_At__c',
        'Dedupe_Name_Key__c', 'Dedupe_Sound_Key__c', 'Dedupe_Phone_Key__c', 'Dedupe_Email_Key__c', 'Dedupe_License_Key__c',
        'Dedupe_Geo_Key__c', 'Dedupe_Checked_At__c', 'Geofence_Radius_M__c' };
    private static final Set<String> MAX_NUMERIC = new Set<String>{ 'Total_Articles__c', 'Total_Citations__c', 'Guideline_Count__c',
        'Unique_Journal_Count__c', 'Avg_Citations_Per_Article__c', 'Avg_Coauthors_Per_Article__c', 'Actively_Published_Years__c' };

    private static List<FieldDef> cachedDefs;

    public static List<FieldDef> mergeFields() {
        if (cachedDefs != null) return cachedDefs;
        List<FieldDef> defs = new List<FieldDef>();
        Map<String, Schema.SObjectField> all = Schema.SObjectType.Sciagen_Account__c.fields.getMap();
        List<String> names = new List<String>(all.keySet());
        names.sort();
        for (String n : names) {
            Schema.DescribeFieldResult d = all.get(n).getDescribe();
            String api = d.getName();
            // Custom fields and Name only; the merge runs in system mode so the steward's own FLS must not silently drop fields.
            if (EXCLUDED.contains(api) || d.isCalculated() || d.isAutoNumber()) continue;
            if (api != 'Name' && !api.endsWith('__c') && !api.endsWith('__s')) continue;
            Schema.DisplayType t = d.getType();
            if (t == Schema.DisplayType.LOCATION || t == Schema.DisplayType.ADDRESS) continue;
            if (t == Schema.DisplayType.REFERENCE && api != 'Parent_Account__c') continue;
            FieldDef f = new FieldDef();
            f.api = api;
            f.label = api == 'Geolocation__Latitude__s' ? 'Latitude' : (api == 'Geolocation__Longitude__s' ? 'Longitude' : d.getLabel());
            f.groupKey = NAME_GROUP.contains(api) ? 'NAME' : (ADDRESS_GROUP.contains(api) ? 'ADDRESS' : api);
            f.type = String.valueOf(t);
            defs.add(f);
        }
        cachedDefs = defs;
        return defs;
    }

    private static String selectAll() {
        List<String> cols = new List<String>{ 'Id', 'CreatedDate', 'LastModifiedDate', 'Type__c', 'Is_Merged__c', 'Merged_Into__c' };
        Set<String> have = new Set<String>(cols);
        for (FieldDef f : mergeFields()) if (have.add(f.api)) cols.add(f.api);
        for (String extra : new List<String>{ 'Dedupe_Name_Key__c', 'Dedupe_Phone_Key__c', 'Dedupe_Email_Key__c' }) if (have.add(extra)) cols.add(extra);
        return String.join(cols, ', ');
    }

    public static Map<Id, Sciagen_Account__c> loadFull(Set<Id> ids) {
        String soql = 'SELECT ' + selectAll() + ' FROM Sciagen_Account__c WHERE Id IN :ids';
        return new Map<Id, Sciagen_Account__c>((List<Sciagen_Account__c>) Database.query(soql));
    }

    // ---------------------------------------------------------------- merge

    public static MergeResult mergeRecords(Id winnerId, Id loserId, Map<String, String> choices, String method, Decimal score, Id candidateId) {
        if (winnerId == null || loserId == null || winnerId == loserId) throw new MergeException('Choose two different records to merge.');
        Map<Id, Sciagen_Account__c> recs = loadFull(new Set<Id>{ winnerId, loserId });
        Sciagen_Account__c w = recs.get(winnerId), l = recs.get(loserId);
        if (w == null || l == null) throw new MergeException('One of the records no longer exists.');
        if (w.Type__c != l.Type__c) throw new MergeException('An HCP can only be merged with an HCP, and an HCO with an HCO.');
        if (w.Is_Merged__c == true || l.Is_Merged__c == true) throw new MergeException('One of these records has already been merged.');
        if (choices == null) choices = new Map<String, String>();

        MergeResult res = new MergeResult();
        res.winnerId = winnerId; res.loserId = loserId;
        Savepoint sp = Database.setSavepoint();
        try {
            Map<String, List<Id>> movedIds = new Map<String, List<Id>>();
            List<Id> demotedPrimary = new List<Id>();
            Map<String, List<Id>> createdIds = new Map<String, List<Id>>();
            List<Map<String, Object>> expenditure = new List<Map<String, Object>>();
            SciagenAccess.mergeInProgress = true;
            try {
                moveChildren(w, l, res, movedIds, demotedPrimary, createdIds);
                expenditure = mergeExpenditure(winnerId, loserId, res);
            } finally {
                SciagenAccess.mergeInProgress = false;
            }

            List<Map<String, Object>> decisions = new List<Map<String, Object>>();
            Sciagen_Account__c upd = survive(w, l, choices, decisions);
            Boolean hasChange = false;
            for (Map<String, Object> d : decisions) if (d.get('changed') == true) { hasChange = true; break; }
            if (w.Parent_Account__c == loserId) { upd.Parent_Account__c = null; hasChange = true; }
            if (hasChange) update upd;

            Sciagen_Account__c loserUpd = new Sciagen_Account__c(Id = loserId, Is_Merged__c = true, Merged_Into__c = winnerId, Merged_At__c = System.now());
            DuplicateKeyService.clearKeys(loserUpd);
            update loserUpd;

            Merge_Log__c log = new Merge_Log__c(
                Winner__c = winnerId, Loser__c = loserId,
                Winner_Name__c = w.Name, Loser_Name__c = l.Name, Object_Type__c = w.Type__c,
                Merged_By__c = UserInfo.getUserId(), Merged_At__c = System.now(),
                Method__c = method == null ? 'Manual' : method, Score__c = score, Status__c = 'Merged',
                Field_Decisions__c = cap(JSON.serialize(decisions), 32000),
                Loser_Snapshot__c = cap(JSON.serialize(snapshot(l)), 131072),
                Moved_Records__c = cap(JSON.serialize(new Map<String, Object>{ 'moved' => movedIds, 'demotedPrimary' => demotedPrimary, 'created' => createdIds, 'expenditure' => expenditure }), 131072),
                Summary__c = summary(w, l, res)
            );
            insert log;
            res.logId = log.Id;

            closeCandidates(candidateId, winnerId, loserId, log.Id);
        } catch (Exception e) {
            Database.rollback(sp);
            if (e instanceof MergeException) throw e;
            throw new MergeException('Merge failed and was rolled back: ' + e.getMessage());
        }
        // Re-check the winner against the rest of the table now that it holds the combined data.
        if (!System.isBatch() && !System.isQueueable() && !System.isFuture() && Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
            System.enqueueJob(new DuplicateScanQueueable(new Set<Id>{ winnerId }));
        }
        return res;
    }

    // ---------------------------------------------------------------- children

    private static void moveChildren(Sciagen_Account__c w, Sciagen_Account__c l, MergeResult res, Map<String, List<Id>> movedIds, List<Id> demotedPrimary, Map<String, List<Id>> createdIds) {
        Id winnerId = w.Id, loserId = l.Id;
        for (Rel rel : relationships()) {
            if (rel.types != 'BOTH' && rel.types != w.Type__c) continue;
            Set<String> cols = new Set<String>{ 'Id', rel.field };
            if (rel.keyField != null) cols.add(rel.keyField);
            if (rel.obj == 'Affiliation__c') cols.add('Is_Primary__c');
            if (rel.obj == 'Influence_Peer__c') { cols.add('HCP__c'); cols.add('Peer_HCP__c'); }
            String soql = 'SELECT ' + String.join(new List<String>(cols), ', ') + ' FROM ' + rel.obj + ' WHERE ' + rel.field + ' = :loserId';
            List<SObject> rows = Database.query(soql);
            if (rows.isEmpty()) continue;

            Set<Object> winnerKeys = new Set<Object>();
            Boolean winnerHasPrimary = false;
            if (rel.strategy == 'UNIQUE' || rel.strategy == 'AFFILIATION' || rel.strategy == 'COPY_UNIQUE') {
                String ws = 'SELECT ' + rel.keyField + (rel.obj == 'Affiliation__c' ? ', Is_Primary__c' : '') + ' FROM ' + rel.obj + ' WHERE ' + rel.field + ' = :winnerId';
                for (SObject s : Database.query(ws)) {
                    winnerKeys.add(s.get(rel.keyField));
                    if (rel.obj == 'Affiliation__c' && s.get('Is_Primary__c') == true) winnerHasPrimary = true;
                }
            }
            if (rel.strategy == 'IF_EMPTY') {
                String cs = 'SELECT Id FROM ' + rel.obj + ' WHERE ' + rel.field + ' = :winnerId LIMIT 1';
                if (!Database.query(cs).isEmpty()) {
                    res.warnings.add(rel.obj + ': the winner already has one, so the loser\'s stayed on the merged record.');
                    continue;
                }
            }

            if (rel.strategy == 'COPY_UNIQUE') {
                List<Account_Territory__c> clones = new List<Account_Territory__c>();
                for (SObject row : rows) {
                    Object k = row.get(rel.keyField);
                    if (winnerKeys.contains(k)) continue;
                    winnerKeys.add(k);
                    clones.add(new Account_Territory__c(Account__c = winnerId, Territory__c = (Id) k));
                }
                if (!clones.isEmpty()) {
                    insert clones;
                    List<Id> ids = new List<Id>();
                    for (Account_Territory__c c : clones) ids.add(c.Id);
                    createdIds.put('Account_Territory__c', ids);
                    res.moved.put('Account_Territory__c.Account__c', ids.size());
                    res.movedTotal += ids.size();
                }
                continue;
            }

            List<SObject> toMove = new List<SObject>();
            for (SObject row : rows) {
                if (rel.strategy == 'UNIQUE' || rel.strategy == 'AFFILIATION') {
                    Object k = row.get(rel.keyField);
                    if (winnerKeys.contains(k)) continue;
                    winnerKeys.add(k);
                }
                // A peer link that would end up pointing at itself is meaningless.
                if (rel.obj == 'Influence_Peer__c' && rel.field == 'Peer_HCP__c' && row.get('HCP__c') == winnerId) continue;
                if (rel.obj == 'Influence_Peer__c' && rel.field == 'HCP__c' && row.get('Peer_HCP__c') == winnerId) continue;
                if (rel.obj == 'Sciagen_Account__c' && rel.field == 'Parent_Account__c' && row.Id == winnerId) {
                    // The winner was a child of the loser: it can't stay its own ancestor.
                    toMove.add(new Sciagen_Account__c(Id = winnerId, Parent_Account__c = null));
                    continue;
                }
                if (rel.obj == 'Affiliation__c' && row.get('Is_Primary__c') == true && winnerHasPrimary) {
                    row.put('Is_Primary__c', false);
                    demotedPrimary.add(row.Id);
                } else if (rel.obj == 'Affiliation__c' && row.get('Is_Primary__c') == true) {
                    winnerHasPrimary = true;
                }
                row.put(rel.field, winnerId);
                toMove.add(row);
            }
            if (toMove.isEmpty()) continue;
            Integer remaining = Limits.getLimitDmlRows() - Limits.getDmlRows() - 200;
            if (toMove.size() > remaining) {
                throw new MergeException('Too many related ' + rel.obj + ' records (' + toMove.size() + ') to merge in one step. Split the work or contact an administrator.');
            }
            update toMove;
            String key = rel.obj + '.' + rel.field;
            List<Id> ids = new List<Id>();
            for (SObject s : toMove) if (!(rel.obj == 'Sciagen_Account__c' && s.Id == winnerId)) ids.add(s.Id);
            if (!ids.isEmpty()) {
                movedIds.put(key, ids);
                res.moved.put(key, ids.size());
                res.movedTotal += ids.size();
            }
        }
    }

    // ---------------------------------------------------------------- UCPMP expenditure

    /**
     * Sample_Expenditure_Tracking__c holds one row per FY + HCP + product (unique Tracking_Key__c). A loser row
     * with no counterpart on the winner is re-keyed to the winner; one that clashes is added into the winner's
     * row and zeroed (kept, so Undo can restore it). Returns what was done, for the merge log.
     */
    private static List<Map<String, Object>> mergeExpenditure(Id winnerId, Id loserId, MergeResult res) {
        List<Map<String, Object>> log = new List<Map<String, Object>>();
        List<Sample_Expenditure_Tracking__c> loserRows = [
            SELECT Id, Tracking_Key__c, Financial_Year__c, Product__c, Total_Packs_Given__c, Total_Units_Given__c, Total_Value_INR__c, Last_Sample_Date__c
            FROM Sample_Expenditure_Tracking__c WHERE HCP_Account__c = :loserId
        ];
        if (loserRows.isEmpty()) return log;
        Set<String> winnerKeys = new Set<String>();
        for (Sample_Expenditure_Tracking__c e : loserRows) winnerKeys.add(SampleExpenditureService.keyFor(e.Financial_Year__c, winnerId, e.Product__c));
        Map<String, Sample_Expenditure_Tracking__c> winnerRows = new Map<String, Sample_Expenditure_Tracking__c>();
        for (Sample_Expenditure_Tracking__c e : [
            SELECT Id, Tracking_Key__c, Total_Packs_Given__c, Total_Units_Given__c, Total_Value_INR__c, Last_Sample_Date__c
            FROM Sample_Expenditure_Tracking__c WHERE Tracking_Key__c IN :winnerKeys FOR UPDATE
        ]) winnerRows.put(e.Tracking_Key__c.toLowerCase(), e);

        Map<Id, Sample_Expenditure_Tracking__c> winnerUpdates = new Map<Id, Sample_Expenditure_Tracking__c>();
        for (Sample_Expenditure_Tracking__c e : loserRows) {
            String newKey = SampleExpenditureService.keyFor(e.Financial_Year__c, winnerId, e.Product__c);
            Sample_Expenditure_Tracking__c w = winnerRows.get(newKey.toLowerCase());
            if (w == null) {
                log.add(new Map<String, Object>{ 'mode' => 'moved', 'id' => e.Id, 'oldKey' => e.Tracking_Key__c });
                e.HCP_Account__c = winnerId;
                e.Tracking_Key__c = newKey;
            } else {
                log.add(new Map<String, Object>{ 'mode' => 'summed', 'id' => e.Id, 'winnerRowId' => w.Id,
                    'packs' => nz(e.Total_Packs_Given__c), 'units' => nz(e.Total_Units_Given__c), 'value' => nz(e.Total_Value_INR__c),
                    'winnerLastDate' => w.Last_Sample_Date__c == null ? null : String.valueOf(w.Last_Sample_Date__c) });
                w.Total_Packs_Given__c = nz(w.Total_Packs_Given__c) + nz(e.Total_Packs_Given__c);
                w.Total_Units_Given__c = nz(w.Total_Units_Given__c) + nz(e.Total_Units_Given__c);
                w.Total_Value_INR__c = nz(w.Total_Value_INR__c) + nz(e.Total_Value_INR__c);
                if (e.Last_Sample_Date__c != null && (w.Last_Sample_Date__c == null || w.Last_Sample_Date__c < e.Last_Sample_Date__c)) w.Last_Sample_Date__c = e.Last_Sample_Date__c;
                winnerUpdates.put(w.Id, w);
                e.Total_Packs_Given__c = 0;
                e.Total_Units_Given__c = 0;
                e.Total_Value_INR__c = 0;
            }
        }
        // Winner totals first, then the loser rows (their new keys never clash: checked above).
        if (!winnerUpdates.isEmpty()) update winnerUpdates.values();
        update loserRows;
        res.moved.put('Sample_Expenditure_Tracking__c.HCP_Account__c', loserRows.size());
        res.movedTotal += loserRows.size();
        return log;
    }

    private static void revertExpenditure(Object raw, Id loserId) {
        if (raw == null) return;
        Map<Id, Sample_Expenditure_Tracking__c> updates = new Map<Id, Sample_Expenditure_Tracking__c>();
        Set<Id> ids = new Set<Id>();
        List<Map<String, Object>> entries = new List<Map<String, Object>>();
        for (Object o : (List<Object>) raw) {
            Map<String, Object> m = (Map<String, Object>) o;
            entries.add(m);
            ids.add((Id) m.get('id'));
            if (m.get('winnerRowId') != null) ids.add((Id) m.get('winnerRowId'));
        }
        Map<Id, Sample_Expenditure_Tracking__c> rows = new Map<Id, Sample_Expenditure_Tracking__c>([
            SELECT Id, Total_Packs_Given__c, Total_Units_Given__c, Total_Value_INR__c, Last_Sample_Date__c
            FROM Sample_Expenditure_Tracking__c WHERE Id IN :ids FOR UPDATE
        ]);
        List<Sample_Expenditure_Tracking__c> movedBack = new List<Sample_Expenditure_Tracking__c>();
        for (Map<String, Object> m : entries) {
            Id rowId = (Id) m.get('id');
            if (!rows.containsKey(rowId)) continue;
            if (m.get('mode') == 'moved') {
                movedBack.add(new Sample_Expenditure_Tracking__c(Id = rowId, HCP_Account__c = loserId, Tracking_Key__c = (String) m.get('oldKey')));
                continue;
            }
            Decimal packs = toDecimal(m.get('packs')), units = toDecimal(m.get('units')), value = toDecimal(m.get('value'));
            updates.put(rowId, new Sample_Expenditure_Tracking__c(Id = rowId, Total_Packs_Given__c = packs, Total_Units_Given__c = units, Total_Value_INR__c = value));
            Sample_Expenditure_Tracking__c w = rows.get((Id) m.get('winnerRowId'));
            if (w != null) {
                Sample_Expenditure_Tracking__c wu = updates.containsKey(w.Id) ? updates.get(w.Id) : new Sample_Expenditure_Tracking__c(Id = w.Id,
                    Total_Packs_Given__c = nz(w.Total_Packs_Given__c), Total_Units_Given__c = nz(w.Total_Units_Given__c), Total_Value_INR__c = nz(w.Total_Value_INR__c));
                wu.Total_Packs_Given__c = Math.max(0, wu.Total_Packs_Given__c - packs);
                wu.Total_Units_Given__c = Math.max(0, wu.Total_Units_Given__c - units);
                wu.Total_Value_INR__c = Math.max(0, wu.Total_Value_INR__c - value);
                wu.Last_Sample_Date__c = m.get('winnerLastDate') == null ? null : Date.valueOf((String) m.get('winnerLastDate'));
                updates.put(w.Id, wu);
            }
        }
        if (!updates.isEmpty()) update updates.values();
        if (!movedBack.isEmpty()) update movedBack;
    }

    private static Decimal nz(Decimal d) { return d == null ? 0 : d; }
    private static Decimal toDecimal(Object o) { return o == null ? 0 : Decimal.valueOf(String.valueOf(o)); }

    // ---------------------------------------------------------------- survivorship

    /** Build the winner update. Fills `decisions` with one entry per field that differs between the two records. */
    public static Sciagen_Account__c survive(Sciagen_Account__c w, Sciagen_Account__c l, Map<String, String> choices, List<Map<String, Object>> decisions) {
        Sciagen_Account__c upd = new Sciagen_Account__c(Id = w.Id);

        Map<String, Boolean> groupTakeLoser = new Map<String, Boolean>();
        for (String g : new List<String>{ 'NAME', 'ADDRESS' }) {
            Boolean wHas = false, lHas = false;
            for (FieldDef f : mergeFields()) {
                if (f.groupKey != g) continue;
                if (isFilled(w.get(f.api))) wHas = true;
                if (isFilled(l.get(f.api))) lHas = true;
            }
            String chosen = choices.get(g);
            groupTakeLoser.put(g, chosen == 'loser' || (chosen == null && !wHas && lHas));
        }

        for (FieldDef f : mergeFields()) {
            if (f.api == 'External_Ids__c') continue;   // handled below: always records the merge, even when both are blank
            Object wv = w.get(f.api), lv = l.get(f.api);
            if (!isFilled(wv) && !isFilled(lv)) continue;
            Object after = wv;
            String kept = 'winner';
            if (f.api == 'Emerging_Expert__c') {
                after = (wv == true || lv == true);
                kept = 'merged';
            } else if (f.api == 'Last_Visit__c' && wv instanceof Date && lv instanceof Date) {
                after = (Date) lv > (Date) wv ? lv : wv;
                kept = (Date) lv > (Date) wv ? 'loser' : 'winner';
            } else if (MAX_NUMERIC.contains(f.api) && wv instanceof Decimal && lv instanceof Decimal) {
                after = (Decimal) lv > (Decimal) wv ? lv : wv;
                kept = (Decimal) lv > (Decimal) wv ? 'loser' : 'winner';
            } else if (f.groupKey == 'NAME' || f.groupKey == 'ADDRESS') {
                if (groupTakeLoser.get(f.groupKey) == true) { after = lv; kept = 'loser'; }
            } else {
                String c = choices.get(f.api);
                if (c == 'loser' || (c == null && !isFilled(wv) && isFilled(lv))) { after = lv; kept = 'loser'; }
            }
            Boolean changed = String.valueOf(after) != String.valueOf(wv);
            if (changed) upd.put(f.api, after);
            if (changed || String.valueOf(wv) != String.valueOf(lv)) {
                decisions.add(new Map<String, Object>{
                    'field' => f.api, 'label' => f.label, 'kept' => kept, 'changed' => changed,
                    'winnerBefore' => valueText(wv), 'loserValue' => valueText(lv), 'after' => valueText(after)
                });
            }
        }
        // External IDs: union of both, plus the phone/email/licence this merge discards, plus a MERGED_FROM marker.
        String wExt = w.External_Ids__c;
        String mergedExt = unionExternalIds(wExt, l.External_Ids__c, w, l);
        if (mergedExt != wExt) {
            upd.External_Ids__c = mergedExt;
            decisions.add(new Map<String, Object>{
                'field' => 'External_Ids__c', 'label' => 'External IDs', 'kept' => 'merged', 'changed' => true,
                'winnerBefore' => wExt, 'loserValue' => l.External_Ids__c, 'after' => mergedExt
            });
        }
        return upd;
    }

    private static Boolean isFilled(Object v) {
        if (v == null) return false;
        if (v instanceof Boolean) return v == true;
        return String.valueOf(v).trim() != '';
    }

    private static String valueText(Object v) { return v == null ? null : String.valueOf(v); }

    /**
     * Union of both records' External_Ids__c as a JSON object (the format the account detail page reads):
     * the winner's value wins a clash, the loser's other IDs are added, the phone/email/licence this merge
     * discards are kept as ALT_* keys, and MERGED_FROM lists every record folded into this one.
     */
    private static String unionExternalIds(String wRaw, String lRaw, Sciagen_Account__c w, Sciagen_Account__c l) {
        Map<String, Object> out = parseExternalIds(wRaw);
        Map<String, Object> loserIds = parseExternalIds(lRaw);
        for (String k : loserIds.keySet()) {
            if (k == 'MERGED_FROM') continue;
            if (!out.containsKey(k)) out.put(k, loserIds.get(k));
            else if (String.valueOf(out.get(k)) != String.valueOf(loserIds.get(k))) out.put(k + '_ALT', loserIds.get(k));
        }
        addAlt(out, 'ALT_PHONE', l.Phone__c, w.Phone__c);
        addAlt(out, 'ALT_EMAIL', l.Email__c, w.Email__c);
        addAlt(out, 'ALT_LICENSE', l.License_Number__c, w.License_Number__c);
        Set<String> sources = new Set<String>();
        for (String src : new List<String>{ String.valueOf(out.get('MERGED_FROM')), String.valueOf(loserIds.get('MERGED_FROM')) }) {
            if (src != null && src != 'null') for (String srcId : src.split(',')) if (String.isNotBlank(srcId)) sources.add(srcId.trim());
        }
        sources.add(String.valueOf(l.Id));
        out.put('MERGED_FROM', String.join(new List<String>(sources), ','));
        String jsonText = JSON.serialize(out);
        return jsonText.length() > 32768 ? jsonText.substring(0, 32768) : jsonText;
    }

    /** JSON object as-is; the older "KEY:value" line format is converted so nothing is lost. */
    private static Map<String, Object> parseExternalIds(String raw) {
        Map<String, Object> out = new Map<String, Object>();
        if (String.isBlank(raw)) return out;
        try {
            Object parsed = JSON.deserializeUntyped(raw.trim());
            if (parsed instanceof Map<String, Object>) return new Map<String, Object>((Map<String, Object>) parsed);
        } catch (Exception e) { /* line format */ }
        Integer n = 1;
        for (String line : raw.split('[\\n;]')) {
            String t = line.trim();
            if (t == '') continue;
            Integer i = t.indexOf(':');
            if (i > 0) out.put(t.substring(0, i).trim(), t.substring(i + 1).trim());
            else out.put('ID_' + (n++), t);
        }
        return out;
    }

    private static void addAlt(Map<String, Object> out, String key, String loserVal, String winnerVal) {
        if (String.isBlank(loserVal)) return;
        if (String.isNotBlank(winnerVal) && winnerVal.trim().equalsIgnoreCase(loserVal.trim())) return;
        String cur = out.get(key) == null ? null : String.valueOf(out.get(key));
        if (cur == null) out.put(key, loserVal.trim());
        else if (!cur.toUpperCase().contains(loserVal.trim().toUpperCase())) out.put(key, cur + ', ' + loserVal.trim());
    }

    // ---------------------------------------------------------------- bookkeeping

    private static void closeCandidates(Id candidateId, Id winnerId, Id loserId, Id logId) {
        List<Duplicate_Candidate__c> touch = new List<Duplicate_Candidate__c>();
        Set<Id> done = new Set<Id>();
        if (candidateId != null) {
            touch.add(new Duplicate_Candidate__c(Id = candidateId, Status__c = 'Merged', Merge_Log__c = logId, Reviewed_By__c = UserInfo.getUserId(), Reviewed_At__c = System.now()));
            done.add(candidateId);
        }
        // The pair itself (when merged without opening a candidate) and any other open pair that involved the loser.
        for (Duplicate_Candidate__c d : [SELECT Id, Record_A__c, Record_B__c FROM Duplicate_Candidate__c
                                         WHERE Status__c = 'Open' AND (Record_A__c = :loserId OR Record_B__c = :loserId OR Record_A__c = :winnerId OR Record_B__c = :winnerId)]) {
            if (done.contains(d.Id)) continue;
            Boolean thisPair = (d.Record_A__c == winnerId && d.Record_B__c == loserId) || (d.Record_A__c == loserId && d.Record_B__c == winnerId);
            touch.add(new Duplicate_Candidate__c(Id = d.Id,
                Status__c = thisPair ? 'Merged' : (d.Record_A__c == loserId || d.Record_B__c == loserId ? 'Superseded' : 'Open'),
                Merge_Log__c = thisPair ? logId : null,
                Reviewed_By__c = thisPair ? UserInfo.getUserId() : null,
                Reviewed_At__c = thisPair ? System.now() : null));
        }
        List<Duplicate_Candidate__c> real = new List<Duplicate_Candidate__c>();
        for (Duplicate_Candidate__c t : touch) if (t.Status__c != 'Open') real.add(t);
        if (!real.isEmpty()) update real;
    }

    private static Map<String, Object> snapshot(Sciagen_Account__c l) {
        Map<String, Object> m = new Map<String, Object>();
        for (FieldDef f : mergeFields()) {
            Object v = l.get(f.api);
            if (v != null) m.put(f.api, String.valueOf(v));
        }
        m.put('Id', l.Id);
        return m;
    }

    private static String summary(Sciagen_Account__c w, Sciagen_Account__c l, MergeResult r) {
        List<String> parts = new List<String>();
        for (String k : r.moved.keySet()) parts.add(k.substringBefore('.') + ' x' + r.moved.get(k));
        parts.sort();
        return '"' + l.Name + '" merged into "' + w.Name + '". ' + r.movedTotal + ' related record(s) moved' + (parts.isEmpty() ? '.' : ': ' + String.join(parts, ', ') + '.');
    }

    private static String cap(String s, Integer max) { return s != null && s.length() > max ? s.substring(0, max) : s; }

    // ---------------------------------------------------------------- undo

    public static void revert(Id logId) {
        Merge_Log__c log = [SELECT Id, Winner__c, Loser__c, Status__c, Field_Decisions__c, Moved_Records__c FROM Merge_Log__c WHERE Id = :logId];
        if (log.Status__c != 'Merged') throw new MergeException('This merge has already been undone.');
        if (log.Winner__c == null || log.Loser__c == null) throw new MergeException('The winner or loser record no longer exists, so this merge cannot be undone.');
        Id winnerId = log.Winner__c, loserId = log.Loser__c;
        Savepoint sp = Database.setSavepoint();
        try {
            Map<String, Object> moved = (Map<String, Object>) JSON.deserializeUntyped(log.Moved_Records__c == null ? '{}' : log.Moved_Records__c);
            Map<String, Object> byRel = moved.get('moved') == null ? new Map<String, Object>() : (Map<String, Object>) moved.get('moved');
            Set<Id> demoted = new Set<Id>();
            if (moved.get('created') != null) {
                for (Object grp : ((Map<String, Object>) moved.get('created')).values()) {
                    Set<Id> createdSet = new Set<Id>();
                    for (Object o : (List<Object>) grp) createdSet.add((Id) o);
                    delete [SELECT Id FROM Account_Territory__c WHERE Id IN :createdSet AND Account__c = :winnerId];
                }
            }
            if (moved.get('demotedPrimary') != null) for (Object o : (List<Object>) moved.get('demotedPrimary')) demoted.add((Id) o);

            // Un-merge the loser first: children moved back to it must not be redirected to the winner again.
            Sciagen_Account__c loser = ((List<Sciagen_Account__c>) Database.query('SELECT ' + selectAll() + ' FROM Sciagen_Account__c WHERE Id = :loserId'))[0];
            loser.Is_Merged__c = false;
            loser.Merged_Into__c = null;
            loser.Merged_At__c = null;
            DuplicateKeyService.computeKeys(loser);
            loser.Dedupe_Checked_At__c = null;
            update new Sciagen_Account__c(Id = loserId, Is_Merged__c = false, Merged_Into__c = null, Merged_At__c = null,
                Dedupe_Name_Key__c = loser.Dedupe_Name_Key__c, Dedupe_Sound_Key__c = loser.Dedupe_Sound_Key__c,
                Dedupe_Phone_Key__c = loser.Dedupe_Phone_Key__c, Dedupe_Email_Key__c = loser.Dedupe_Email_Key__c,
                Dedupe_License_Key__c = loser.Dedupe_License_Key__c, Dedupe_Geo_Key__c = loser.Dedupe_Geo_Key__c, Dedupe_Checked_At__c = null);


            SciagenAccess.mergeInProgress = true;
            revertExpenditure(moved.get('expenditure'), loserId);
            for (String key : byRel.keySet()) {
                String obj = key.substringBefore('.'), field = key.substringAfter('.');
                Set<Id> ids = new Set<Id>();
                for (Object o : (List<Object>) byRel.get(key)) ids.add((Id) o);
                List<SObject> back = new List<SObject>();
                for (SObject s : Database.query('SELECT Id, ' + field + ' FROM ' + obj + ' WHERE Id IN :ids AND ' + field + ' = :winnerId')) {
                    s.put(field, loserId);
                    if (obj == 'Affiliation__c' && demoted.contains(s.Id)) s.put('Is_Primary__c', true);
                    back.add(s);
                }
                if (!back.isEmpty()) update back;
            }
            SciagenAccess.mergeInProgress = false;

            // Put back the winner's own values, but only where nobody has edited them since.
            Sciagen_Account__c w = ((List<Sciagen_Account__c>) Database.query('SELECT ' + selectAll() + ' FROM Sciagen_Account__c WHERE Id = :winnerId'))[0];
            Sciagen_Account__c restore = new Sciagen_Account__c(Id = winnerId);
            Boolean anyChange = false;
            if (String.isNotBlank(log.Field_Decisions__c)) {
                for (Object o : (List<Object>) JSON.deserializeUntyped(log.Field_Decisions__c)) {
                    Map<String, Object> d = (Map<String, Object>) o;
                    if (d.get('changed') != true) continue;
                    String api = (String) d.get('field');
                    if (String.valueOf(w.get(api)) != (String) d.get('after')) continue;
                    Object before = fromText(api, (String) d.get('winnerBefore'));
                    restore.put(api, before);
                    anyChange = true;
                }
            }
            if (anyChange) update restore;

            update new Merge_Log__c(Id = logId, Status__c = 'Reverted', Reverted_At__c = System.now(), Reverted_By__c = UserInfo.getUserId());
            List<Duplicate_Candidate__c> cands = [SELECT Id FROM Duplicate_Candidate__c WHERE Merge_Log__c = :logId];
            for (Duplicate_Candidate__c c : cands) { c.Status__c = 'Open'; c.Merge_Log__c = null; c.Reviewed_By__c = null; c.Reviewed_At__c = null; }
            if (!cands.isEmpty()) update cands;
        } catch (Exception e) {
            SciagenAccess.mergeInProgress = false;
            Database.rollback(sp);
            if (e instanceof MergeException) throw e;
            throw new MergeException('Undo failed and was rolled back: ' + e.getMessage());
        }
    }

    private static Object fromText(String api, String text) {
        if (text == null) return null;
        Schema.DescribeFieldResult d = Schema.SObjectType.Sciagen_Account__c.fields.getMap().get(api).getDescribe();
        Schema.DisplayType t = d.getType();
        if (t == Schema.DisplayType.BOOLEAN) return text == 'true';
        if (t == Schema.DisplayType.DATE) return Date.valueOf(text);
        if (t == Schema.DisplayType.DATETIME) return (Datetime) JSON.deserialize('"' + text + '"', Datetime.class);
        if (t == Schema.DisplayType.DOUBLE || t == Schema.DisplayType.INTEGER || t == Schema.DisplayType.PERCENT || t == Schema.DisplayType.CURRENCY) return Decimal.valueOf(text);
        return text;
    }
}