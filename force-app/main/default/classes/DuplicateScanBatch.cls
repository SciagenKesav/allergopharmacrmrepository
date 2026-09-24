/**
 * Background duplicate scan, in three chained stages:
 *   KEYS      computes match keys for any record that has none
 *   SCAN      compares every record not yet checked (or all of them for a full rescan)
 *   AUTOMERGE merges only the pairs that are High confidence, above the auto-merge score and share a
 *             strong identifier, and only when an admin has switched auto-merge on
 */
public without sharing class DuplicateScanBatch implements Database.Batchable<SObject>, Database.Stateful {
    private String stage;
    private Boolean full;
    public Integer candidatesSaved = 0;

    public DuplicateScanBatch(String stage, Boolean full) {
        this.stage = stage;
        this.full = full;
    }

    public static Id run(Boolean full) {
        return Database.executeBatch(new DuplicateScanBatch('KEYS', full), 200);
    }

    public Database.QueryLocator start(Database.BatchableContext bc) {
        if (stage == 'KEYS') {
            return Database.getQueryLocator('SELECT ' + DuplicateMatchService.MATCH_FIELDS + ' FROM Sciagen_Account__c WHERE Is_Merged__c = false AND Dedupe_Name_Key__c = null');
        }
        if (stage == 'SCAN') {
            String q = 'SELECT Id FROM Sciagen_Account__c WHERE Is_Merged__c = false' + (full == true ? '' : ' AND Dedupe_Checked_At__c = null');
            return Database.getQueryLocator(q);
        }
        return Database.getQueryLocator('SELECT Id, Record_A__c, Record_B__c, Suggested_Winner__c, Match_Score__c FROM Duplicate_Candidate__c ' +
            'WHERE Status__c = \'Open\' AND Confidence__c = \'High\' AND Strong_Identifier__c = true');
    }

    public void execute(Database.BatchableContext bc, List<SObject> scope) {
        if (stage == 'KEYS') {
            List<Sciagen_Account__c> upd = new List<Sciagen_Account__c>();
            for (SObject o : scope) {
                Sciagen_Account__c a = (Sciagen_Account__c) o;
                DuplicateKeyService.computeKeys(a);
                upd.add(new Sciagen_Account__c(Id = a.Id, Dedupe_Name_Key__c = a.Dedupe_Name_Key__c, Dedupe_Sound_Key__c = a.Dedupe_Sound_Key__c,
                    Dedupe_Phone_Key__c = a.Dedupe_Phone_Key__c, Dedupe_Email_Key__c = a.Dedupe_Email_Key__c,
                    Dedupe_License_Key__c = a.Dedupe_License_Key__c, Dedupe_Geo_Key__c = a.Dedupe_Geo_Key__c, Dedupe_Checked_At__c = null));
            }
            Database.update(upd, false);
        } else if (stage == 'SCAN') {
            Set<Id> ids = new Set<Id>();
            for (SObject o : scope) ids.add(o.Id);
            candidatesSaved += DuplicateEngine.scan(ids, true);
        } else {
            DuplicateEngine.Settings s = DuplicateEngine.loadSettings();
            if (!s.enabled || !s.autoMerge) return;
            for (SObject o : scope) {
                Duplicate_Candidate__c c = (Duplicate_Candidate__c) o;
                if (c.Match_Score__c < s.autoMergeScore || c.Suggested_Winner__c == null) continue;
                Id loser = c.Suggested_Winner__c == c.Record_A__c ? c.Record_B__c : c.Record_A__c;
                try {
                    DuplicateMergeService.mergeRecords(c.Suggested_Winner__c, loser, null, 'Auto', c.Match_Score__c, c.Id);
                } catch (Exception e) {
                    update new Duplicate_Candidate__c(Id = c.Id, Review_Note__c = ('Auto-merge skipped: ' + e.getMessage()).left(255));
                }
            }
        }
    }

    public void finish(Database.BatchableContext bc) {
        if (Test.isRunningTest()) return;
        if (stage == 'KEYS') {
            Database.executeBatch(new DuplicateScanBatch('SCAN', full), 50);
        } else if (stage == 'SCAN') {
            DuplicateEngine.Settings s = DuplicateEngine.loadSettings();
            if (s.enabled && s.autoMerge) Database.executeBatch(new DuplicateScanBatch('AUTOMERGE', false), 1);
        }
    }
}