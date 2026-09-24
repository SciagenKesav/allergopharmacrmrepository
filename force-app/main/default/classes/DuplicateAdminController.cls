/**
 * Backend for the Duplicate Manager page: review candidate pairs side by side, pick the winner and
 * field values, merge, dismiss, undo, run scans and change the thresholds.
 * Every entry point requires the Manage_Duplicates custom permission (the Sciagen Data Steward set).
 */
public without sharing class DuplicateAdminController {

    @TestVisible private static Boolean testBypass = false;

    public class ApiException extends Exception {}

    /** AuraHandledException whose message is also readable server-side (getMessage() is generic unless set). */
    private static AuraHandledException aura(String message) {
        AuraHandledException e = new AuraHandledException(message);
        e.setMessage(message);
        return e;
    }

    private static void requireSteward() {
        if (testBypass || FeatureManagement.checkPermission('Manage_Duplicates')) return;
        throw aura('You need the Sciagen Data Steward permission set to manage duplicates.');
    }

    // ------------------------------------------------------------ DTOs

    public class SummaryDTO {
        @AuraEnabled public Integer openHcp = 0;
        @AuraEnabled public Integer openHco = 0;
        @AuraEnabled public Integer high = 0;
        @AuraEnabled public Integer medium = 0;
        @AuraEnabled public Integer low = 0;
        @AuraEnabled public Integer merged30d = 0;
        @AuraEnabled public Integer notDuplicate = 0;
        @AuraEnabled public Integer unchecked = 0;
        @AuraEnabled public Integer totalRecords = 0;
        @AuraEnabled public Datetime lastScanAt;
        @AuraEnabled public Boolean scheduled = false;
        @AuraEnabled public SettingsDTO settings;
    }

    public class SettingsDTO {
        @AuraEnabled public Boolean enabled;
        @AuraEnabled public Decimal minScore;
        @AuraEnabled public Decimal highScore;
        @AuraEnabled public Boolean autoMerge;
        @AuraEnabled public Decimal autoMergeScore;
    }

    public class CandidateDTO {
        @AuraEnabled public Id id;
        @AuraEnabled public String number_x;
        @AuraEnabled public String type;
        @AuraEnabled public Decimal score;
        @AuraEnabled public String confidence;
        @AuraEnabled public String status;
        @AuraEnabled public Boolean strong;
        @AuraEnabled public Id aId;
        @AuraEnabled public Id bId;
        @AuraEnabled public String aName;
        @AuraEnabled public String bName;
        @AuraEnabled public String aDetail;
        @AuraEnabled public String bDetail;
        @AuraEnabled public Id suggestedWinnerId;
        @AuraEnabled public String reasons;
        @AuraEnabled public String note;
    }

    public class FieldRow {
        @AuraEnabled public String api;
        @AuraEnabled public String label;
        @AuraEnabled public String groupKey;
        @AuraEnabled public String aValue;
        @AuraEnabled public String bValue;
        @AuraEnabled public Boolean differs;
        @AuraEnabled public Boolean auto;   // combined automatically, not a choice
    }

    public class ComparisonDTO {
        @AuraEnabled public CandidateDTO candidate;
        @AuraEnabled public List<FieldRow> rows = new List<FieldRow>();
        @AuraEnabled public Id suggestedWinnerId;
        @AuraEnabled public List<String> winnerReasons = new List<String>();
        @AuraEnabled public Map<String, Integer> aCounts = new Map<String, Integer>();
        @AuraEnabled public Map<String, Integer> bCounts = new Map<String, Integer>();
    }

    public class MergeResultDTO {
        @AuraEnabled public Id logId;
        @AuraEnabled public Integer movedTotal;
        @AuraEnabled public String summary;
        @AuraEnabled public List<String> warnings;
    }

    public class MergeLogDTO {
        @AuraEnabled public Id id;
        @AuraEnabled public String number_x;
        @AuraEnabled public String type;
        @AuraEnabled public String winnerName;
        @AuraEnabled public String loserName;
        @AuraEnabled public Id winnerId;
        @AuraEnabled public Id loserId;
        @AuraEnabled public Datetime mergedAt;
        @AuraEnabled public String mergedBy;
        @AuraEnabled public String method;
        @AuraEnabled public Decimal score;
        @AuraEnabled public String status;
        @AuraEnabled public String summary;
    }

    public class DcrMatchDTO {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String detail;
        @AuraEnabled public Decimal score;
        @AuraEnabled public String confidence;
        @AuraEnabled public String reasons;
    }

    // ------------------------------------------------------------ dashboard

    @AuraEnabled
    public static SummaryDTO getSummary() {
        requireSteward();
        SummaryDTO s = new SummaryDTO();
        for (AggregateResult r : [SELECT Object_Type__c t, Confidence__c c, COUNT(Id) n FROM Duplicate_Candidate__c WHERE Status__c = 'Open' GROUP BY Object_Type__c, Confidence__c]) {
            Integer n = (Integer) r.get('n');
            if ((String) r.get('t') == 'HCP') s.openHcp += n; else s.openHco += n;
            String c = (String) r.get('c');
            if (c == 'High') s.high += n; else if (c == 'Medium') s.medium += n; else s.low += n;
        }
        Datetime since = System.now().addDays(-30);
        s.merged30d = [SELECT COUNT() FROM Merge_Log__c WHERE Status__c = 'Merged' AND Merged_At__c >= :since];
        s.notDuplicate = [SELECT COUNT() FROM Duplicate_Candidate__c WHERE Status__c = 'Not Duplicate'];
        s.unchecked = [SELECT COUNT() FROM Sciagen_Account__c WHERE Is_Merged__c = false AND Dedupe_Checked_At__c = null];
        s.totalRecords = [SELECT COUNT() FROM Sciagen_Account__c WHERE Is_Merged__c = false];
        AggregateResult last = [SELECT MAX(Dedupe_Checked_At__c) m FROM Sciagen_Account__c];
        s.lastScanAt = (Datetime) last.get('m');
        s.scheduled = [SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name = 'Sciagen Duplicate Scan'] > 0;
        s.settings = getSettingsInternal();
        return s;
    }

    // ------------------------------------------------------------ candidate list

    @AuraEnabled
    public static List<CandidateDTO> getCandidates(String objectType, String confidence, String status, String search, Integer maxRows) {
        requireSteward();
        Integer lim = maxRows == null ? 100 : Math.max(1, Math.min(maxRows, 200));
        String st = String.isBlank(status) ? 'Open' : status;
        String q = 'SELECT Id, Name, Object_Type__c, Match_Score__c, Confidence__c, Status__c, Strong_Identifier__c, Suggested_Winner__c, Match_Reasons__c, Review_Note__c, ' +
            'Record_A__c, Record_A__r.Name, Record_A__r.Billing_City__c, Record_A__r.Specialty__c, Record_A__r.Speciality__c, Record_A__r.Phone__c, Record_A__r.Email__c, ' +
            'Record_B__c, Record_B__r.Name, Record_B__r.Billing_City__c, Record_B__r.Specialty__c, Record_B__r.Speciality__c, Record_B__r.Phone__c, Record_B__r.Email__c ' +
            'FROM Duplicate_Candidate__c WHERE Status__c = :st';
        if (String.isNotBlank(objectType) && objectType != 'All') q += ' AND Object_Type__c = :objectType';
        if (String.isNotBlank(confidence) && confidence != 'All') q += ' AND Confidence__c = :confidence';
        if (String.isNotBlank(search)) {
            String pattern = '%' + String.escapeSingleQuotes(search.trim()) + '%';
            q += ' AND (Record_A__r.Name LIKE :pattern OR Record_B__r.Name LIKE :pattern OR Record_A__r.Phone__c LIKE :pattern OR Record_B__r.Phone__c LIKE :pattern OR Record_A__r.Email__c LIKE :pattern OR Record_B__r.Email__c LIKE :pattern)';
        }
        q += ' ORDER BY Match_Score__c DESC, CreatedDate DESC LIMIT ' + lim;
        List<CandidateDTO> out = new List<CandidateDTO>();
        for (Duplicate_Candidate__c c : Database.query(q)) out.add(toDto(c));
        return out;
    }

    private static CandidateDTO toDto(Duplicate_Candidate__c c) {
        CandidateDTO d = new CandidateDTO();
        d.id = c.Id; d.number_x = c.Name; d.type = c.Object_Type__c; d.score = c.Match_Score__c; d.confidence = c.Confidence__c;
        d.status = c.Status__c; d.strong = c.Strong_Identifier__c; d.suggestedWinnerId = c.Suggested_Winner__c;
        d.reasons = c.Match_Reasons__c; d.note = c.Review_Note__c;
        d.aId = c.Record_A__c; d.bId = c.Record_B__c;
        d.aName = c.Record_A__r == null ? null : c.Record_A__r.Name;
        d.bName = c.Record_B__r == null ? null : c.Record_B__r.Name;
        d.aDetail = detail(c.Record_A__r);
        d.bDetail = detail(c.Record_B__r);
        return d;
    }

    private static String detail(Sciagen_Account__c a) {
        if (a == null) return '';
        List<String> parts = new List<String>();
        String spec = String.isNotBlank(a.Specialty__c) ? a.Specialty__c : a.Speciality__c;
        if (String.isNotBlank(spec)) parts.add(spec);
        if (String.isNotBlank(a.Billing_City__c)) parts.add(a.Billing_City__c);
        if (String.isNotBlank(a.Phone__c)) parts.add(a.Phone__c);
        if (String.isNotBlank(a.Email__c)) parts.add(a.Email__c);
        return String.join(parts, ' · ');
    }

    // ------------------------------------------------------------ comparison

    @AuraEnabled
    public static ComparisonDTO getComparison(Id candidateId) {
        requireSteward();
        Duplicate_Candidate__c c = [SELECT Id, Name, Object_Type__c, Match_Score__c, Confidence__c, Status__c, Strong_Identifier__c, Suggested_Winner__c, Match_Reasons__c, Review_Note__c,
                                           Record_A__c, Record_A__r.Name, Record_A__r.Billing_City__c, Record_A__r.Specialty__c, Record_A__r.Speciality__c, Record_A__r.Phone__c, Record_A__r.Email__c,
                                           Record_B__c, Record_B__r.Name, Record_B__r.Billing_City__c, Record_B__r.Specialty__c, Record_B__r.Speciality__c, Record_B__r.Phone__c, Record_B__r.Email__c
                                    FROM Duplicate_Candidate__c WHERE Id = :candidateId];
        if (c.Record_A__c == null || c.Record_B__c == null) throw aura('One of these records no longer exists.');
        Map<Id, Sciagen_Account__c> recs = DuplicateMergeService.loadFull(new Set<Id>{ c.Record_A__c, c.Record_B__c });
        Sciagen_Account__c a = recs.get(c.Record_A__c), b = recs.get(c.Record_B__c);
        ComparisonDTO out = new ComparisonDTO();
        out.candidate = toDto(c);

        Map<Id, Map<String, Integer>> activity = DuplicateSurvivorship.loadActivity(new Set<Id>{ a.Id, b.Id });
        DuplicateSurvivorship.Suggestion sug = DuplicateSurvivorship.suggest(a, b, activity);
        out.suggestedWinnerId = sug.winnerId;
        out.winnerReasons = sug.reasons;
        out.aCounts = activity.get(a.Id);
        out.bCounts = activity.get(b.Id);

        Set<String> autoFields = new Set<String>{ 'External_Ids__c', 'Emerging_Expert__c', 'Last_Visit__c', 'Total_Articles__c', 'Total_Citations__c',
            'Guideline_Count__c', 'Unique_Journal_Count__c', 'Avg_Citations_Per_Article__c', 'Avg_Coauthors_Per_Article__c', 'Actively_Published_Years__c' };
        for (DuplicateMergeService.FieldDef f : DuplicateMergeService.mergeFields()) {
            Object av = a.get(f.api), bv = b.get(f.api);
            String at = av == null ? null : String.valueOf(av), bt = bv == null ? null : String.valueOf(bv);
            if (String.isBlank(at) && String.isBlank(bt)) continue;
            if (av instanceof Boolean && av == false && bv instanceof Boolean && bv == false) continue;
            FieldRow r = new FieldRow();
            r.api = f.api; r.label = f.label; r.groupKey = f.groupKey; r.aValue = at; r.bValue = bt;
            r.differs = (at == null ? '' : at.trim().toLowerCase()) != (bt == null ? '' : bt.trim().toLowerCase());
            r.auto = autoFields.contains(f.api);
            out.rows.add(r);
        }
        return out;
    }

    // ------------------------------------------------------------ actions

    @AuraEnabled
    public static MergeResultDTO mergeCandidate(Id candidateId, Id winnerId, Map<String, String> choices) {
        requireSteward();
        Duplicate_Candidate__c c = [SELECT Id, Record_A__c, Record_B__c, Match_Score__c, Status__c FROM Duplicate_Candidate__c WHERE Id = :candidateId];
        if (c.Status__c != 'Open') throw aura('This pair has already been reviewed.');
        if (winnerId != c.Record_A__c && winnerId != c.Record_B__c) throw aura('The winner must be one of the two records in this pair.');
        Id loserId = winnerId == c.Record_A__c ? c.Record_B__c : c.Record_A__c;
        try {
            DuplicateMergeService.MergeResult r = DuplicateMergeService.mergeRecords(winnerId, loserId, choices, 'Manual', c.Match_Score__c, candidateId);
            MergeResultDTO out = new MergeResultDTO();
            out.logId = r.logId; out.movedTotal = r.movedTotal; out.warnings = r.warnings;
            out.summary = [SELECT Summary__c FROM Merge_Log__c WHERE Id = :r.logId].Summary__c;
            return out;
        } catch (DuplicateMergeService.MergeException e) {
            throw aura(e.getMessage());
        }
    }

    @AuraEnabled
    public static void markNotDuplicate(Id candidateId, String note) {
        requireSteward();
        update new Duplicate_Candidate__c(Id = candidateId, Status__c = 'Not Duplicate', Review_Note__c = String.isBlank(note) ? null : note.left(255),
            Reviewed_By__c = UserInfo.getUserId(), Reviewed_At__c = System.now());
    }

    @AuraEnabled
    public static void reopenCandidate(Id candidateId) {
        requireSteward();
        update new Duplicate_Candidate__c(Id = candidateId, Status__c = 'Open', Review_Note__c = null, Reviewed_By__c = null, Reviewed_At__c = null);
    }

    @AuraEnabled
    public static List<MergeLogDTO> getRecentMerges(Integer maxRows) {
        requireSteward();
        Integer lim = maxRows == null ? 50 : Math.max(1, Math.min(maxRows, 200));
        List<MergeLogDTO> out = new List<MergeLogDTO>();
        for (Merge_Log__c m : [SELECT Id, Name, Object_Type__c, Winner_Name__c, Loser_Name__c, Winner__c, Loser__c, Merged_At__c, Merged_By__r.Name, Method__c, Score__c, Status__c, Summary__c
                               FROM Merge_Log__c ORDER BY Merged_At__c DESC LIMIT :lim]) {
            MergeLogDTO d = new MergeLogDTO();
            d.id = m.Id; d.number_x = m.Name; d.type = m.Object_Type__c; d.winnerName = m.Winner_Name__c; d.loserName = m.Loser_Name__c;
            d.winnerId = m.Winner__c; d.loserId = m.Loser__c; d.mergedAt = m.Merged_At__c; d.mergedBy = m.Merged_By__r == null ? null : m.Merged_By__r.Name;
            d.method = m.Method__c; d.score = m.Score__c; d.status = m.Status__c; d.summary = m.Summary__c;
            out.add(d);
        }
        return out;
    }

    @AuraEnabled
    public static void undoMerge(Id logId) {
        requireSteward();
        try {
            DuplicateMergeService.revert(logId);
        } catch (DuplicateMergeService.MergeException e) {
            throw aura(e.getMessage());
        }
    }

    // ------------------------------------------------------------ scanning

    @AuraEnabled
    public static Id runScan(Boolean fullRescan) {
        requireSteward();
        return DuplicateScanBatch.run(fullRescan == true);
    }

    @AuraEnabled
    public static void scheduleNightly() {
        requireSteward();
        if ([SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name = 'Sciagen Duplicate Scan'] > 0) return;
        System.schedule('Sciagen Duplicate Scan', '0 0 2 * * ?', new DuplicateScanScheduler());
    }

    @AuraEnabled
    public static void unscheduleNightly() {
        requireSteward();
        for (CronTrigger t : [SELECT Id FROM CronTrigger WHERE CronJobDetail.Name = 'Sciagen Duplicate Scan']) System.abortJob(t.Id);
    }

    // ------------------------------------------------------------ settings

    private static SettingsDTO getSettingsInternal() {
        DuplicateEngine.Settings s = DuplicateEngine.loadSettings();
        SettingsDTO d = new SettingsDTO();
        d.enabled = s.enabled; d.minScore = s.minScore; d.highScore = s.highScore; d.autoMerge = s.autoMerge; d.autoMergeScore = s.autoMergeScore;
        return d;
    }

    @AuraEnabled
    public static SettingsDTO saveSettings(Boolean enabled, Decimal minScore, Decimal highScore, Boolean autoMerge, Decimal autoMergeScore) {
        requireSteward();
        if (minScore == null || minScore < 30 || minScore > 95) throw aura('Minimum score must be between 30 and 95.');
        if (highScore == null || highScore <= minScore || highScore > 100) throw aura('High-confidence score must be above the minimum and at most 100.');
        if (autoMergeScore == null || autoMergeScore < highScore || autoMergeScore > 100) throw aura('Auto-merge score must be at least the high-confidence score and at most 100.');
        Duplicate_Setting__c s = Duplicate_Setting__c.getOrgDefaults();
        s.Enabled__c = enabled == true;
        s.Min_Candidate_Score__c = minScore;
        s.High_Confidence_Score__c = highScore;
        s.Auto_Merge_Enabled__c = autoMerge == true;
        s.Auto_Merge_Score__c = autoMergeScore;
        upsert s;
        return getSettingsInternal();
    }

    // ------------------------------------------------------------ prevention: check a change request before approving it

    /** Possible existing duplicates of the HCP/HCO a "New HCP / New HCO" change request would create. */
    @AuraEnabled
    public static List<DcrMatchDTO> findDuplicatesForDcr(Id dcrId) {
        requireSteward();
        Data_Change_Request__c dcr = [SELECT Id, Type__c, Subject_Name__c, Phone__c, City__c, Pincode__c, Fields_Payload__c FROM Data_Change_Request__c WHERE Id = :dcrId];
        String type = dcr.Type__c != null && dcr.Type__c.endsWith('HCO') ? 'HCO' : 'HCP';
        Map<String, Object> f = new Map<String, Object>();
        if (String.isNotBlank(dcr.Fields_Payload__c)) {
            try { f = (Map<String, Object>) JSON.deserializeUntyped(dcr.Fields_Payload__c); } catch (Exception e) { /* free-text payload */ }
        }
        Sciagen_Account__c probe = new Sciagen_Account__c(Type__c = type);
        probe.Name = str(f, 'name') != null ? str(f, 'name') : dcr.Subject_Name__c;
        probe.Prefix__c = str(f, 'prefix');
        probe.First_Name__c = str(f, 'firstName');
        probe.Last_Name__c = str(f, 'lastName');
        probe.Phone__c = str(f, 'phone') != null ? str(f, 'phone') : dcr.Phone__c;
        probe.Email__c = str(f, 'email');
        probe.License_Number__c = str(f, 'licenseNumber') != null ? str(f, 'licenseNumber') : str(f, 'license');
        probe.Billing_City__c = str(f, 'city') != null ? str(f, 'city') : dcr.City__c;
        probe.Billing_Postal_Code__c = str(f, 'pincode') != null ? str(f, 'pincode') : dcr.Pincode__c;
        probe.Billing_Street__c = str(f, 'address');
        probe.Website__c = str(f, 'website');
        String spec = str(f, 'specialty') != null ? str(f, 'specialty') : str(f, 'speciality');
        probe.Specialty__c = spec; probe.Speciality__c = spec;
        DuplicateKeyService.computeKeys(probe);
        DuplicateEngine.Settings s = DuplicateEngine.loadSettings();
        List<DcrMatchDTO> out = new List<DcrMatchDTO>();
        List<DuplicateEngine.Pair> pairs = DuplicateEngine.findPairs(new List<Sciagen_Account__c>{ probe }, s);
        pairs.sort(new PairByScore());
        for (DuplicateEngine.Pair p : pairs) {
            if (out.size() >= 5) break;
            DcrMatchDTO m = new DcrMatchDTO();
            m.id = p.b.Id; m.name = p.b.Name; m.score = p.result.score; m.confidence = p.result.confidence; m.reasons = p.result.reasonText();
            m.detail = detail(p.b);
            out.add(m);
        }
        return out;
    }

    private static String str(Map<String, Object> m, String k) {
        Object v = m.get(k);
        return v == null || String.valueOf(v).trim() == '' ? null : String.valueOf(v);
    }

    private class PairByScore implements System.Comparator<DuplicateEngine.Pair> {
        public Integer compare(DuplicateEngine.Pair x, DuplicateEngine.Pair y) {
            return x.result.score == y.result.score ? 0 : (x.result.score > y.result.score ? -1 : 1);
        }
    }
}