/**
 * Finds duplicate candidates. For each record it uses the indexed Dedupe_*_Key__c fields to pull a
 * small pool of possible matches (blocking), scores each pair with DuplicateMatchService, and
 * records pairs at or above the minimum score as Duplicate_Candidate__c rows.
 * A record is never compared with the whole table, so this scales to large HCP/HCO books.
 */
public without sharing class DuplicateEngine {

    public class Settings {
        public Boolean enabled = true;
        public Decimal minScore = DuplicateMatchService.DEFAULT_MIN_SCORE;
        public Decimal highScore = DuplicateMatchService.DEFAULT_HIGH_SCORE;
        public Boolean autoMerge = false;
        public Decimal autoMergeScore = 95;
    }

    public class Pair {
        public Sciagen_Account__c a;
        public Sciagen_Account__c b;
        public DuplicateMatchService.Result result;
    }

    // Blocks bigger than this (a very common surname, say) are ignored on the name-sound route.
    private static final Integer MAX_SOUND_BLOCK = 300;
    private static final Integer POOL_LIMIT = 5000;

    /** Duplicate_Setting__c resolved for the running user: user row, else profile row, else org row, else built-in defaults. */
    public static Settings loadSettings() {
        Settings s = new Settings();
        Id userId = UserInfo.getUserId(), profileId = UserInfo.getProfileId(), orgId = UserInfo.getOrganizationId();
        Duplicate_Setting__c pick = null;
        Integer rank = 0;
        for (Duplicate_Setting__c c : [SELECT SetupOwnerId, Enabled__c, Min_Candidate_Score__c, High_Confidence_Score__c, Auto_Merge_Enabled__c, Auto_Merge_Score__c
                                       FROM Duplicate_Setting__c WHERE SetupOwnerId IN (:userId, :profileId, :orgId)]) {
            Integer r = c.SetupOwnerId == userId ? 3 : (c.SetupOwnerId == profileId ? 2 : 1);
            if (r > rank) { rank = r; pick = c; }
        }
        if (pick != null) {
            s.enabled = pick.Enabled__c == true;
            if (pick.Min_Candidate_Score__c != null) s.minScore = pick.Min_Candidate_Score__c;
            if (pick.High_Confidence_Score__c != null) s.highScore = pick.High_Confidence_Score__c;
            s.autoMerge = pick.Auto_Merge_Enabled__c == true;
            if (pick.Auto_Merge_Score__c != null) s.autoMergeScore = pick.Auto_Merge_Score__c;
        }
        return s;
    }

    public static DuplicateMatchService.Context contextFor(Settings s) {
        DuplicateMatchService.Context ctx = new DuplicateMatchService.Context();
        ctx.minScore = s.minScore;
        ctx.highScore = s.highScore;
        return ctx;
    }

    /** Compare the given records with the rest of the table and return every pair that scores as a candidate. */
    public static List<Pair> findPairs(List<Sciagen_Account__c> subjects, Settings s) {
        List<Pair> out = new List<Pair>();
        Map<String, List<Sciagen_Account__c>> byType = new Map<String, List<Sciagen_Account__c>>();
        for (Sciagen_Account__c a : subjects) {
            if (a.Is_Merged__c == true || String.isBlank(a.Type__c)) continue;
            if (!byType.containsKey(a.Type__c)) byType.put(a.Type__c, new List<Sciagen_Account__c>());
            byType.get(a.Type__c).add(a);
        }
        Set<String> seen = new Set<String>();
        for (String type : byType.keySet()) {
            out.addAll(findPairsForType(type, byType.get(type), s, seen));
        }
        return out;
    }

    private static List<Pair> findPairsForType(String type, List<Sciagen_Account__c> subjects, Settings s, Set<String> seen) {
        Set<String> phones = new Set<String>(), emails = new Set<String>(), lics = new Set<String>();
        Set<String> names = new Set<String>(), sounds = new Set<String>(), cells = new Set<String>();
        for (Sciagen_Account__c a : subjects) {
            addIf(phones, a.Dedupe_Phone_Key__c); addIf(emails, a.Dedupe_Email_Key__c); addIf(lics, a.Dedupe_License_Key__c);
            addIf(names, a.Dedupe_Name_Key__c); addIf(sounds, a.Dedupe_Sound_Key__c);
            if (type == 'HCO') cells.addAll(DuplicateText.geoCellsAround(a.Geolocation__Latitude__s, a.Geolocation__Longitude__s));
        }

        String soql = 'SELECT ' + DuplicateMatchService.MATCH_FIELDS + ' FROM Sciagen_Account__c WHERE Type__c = :type AND Is_Merged__c = false AND (' +
            'Dedupe_Phone_Key__c IN :phones OR Dedupe_Email_Key__c IN :emails OR Dedupe_License_Key__c IN :lics OR ' +
            'Dedupe_Name_Key__c IN :names OR Dedupe_Sound_Key__c IN :sounds OR Dedupe_Geo_Key__c IN :cells) LIMIT ' + POOL_LIMIT;
        List<Sciagen_Account__c> pool = Database.query(soql);

        // Index the pool by each key so every subject finds its candidates in constant time.
        Map<String, List<Sciagen_Account__c>> byPhone = new Map<String, List<Sciagen_Account__c>>();
        Map<String, List<Sciagen_Account__c>> byEmail = new Map<String, List<Sciagen_Account__c>>();
        Map<String, List<Sciagen_Account__c>> byLic = new Map<String, List<Sciagen_Account__c>>();
        Map<String, List<Sciagen_Account__c>> byName = new Map<String, List<Sciagen_Account__c>>();
        Map<String, List<Sciagen_Account__c>> bySound = new Map<String, List<Sciagen_Account__c>>();
        Map<String, List<Sciagen_Account__c>> byCell = new Map<String, List<Sciagen_Account__c>>();
        for (Sciagen_Account__c p : pool) {
            index(byPhone, p.Dedupe_Phone_Key__c, p); index(byEmail, p.Dedupe_Email_Key__c, p); index(byLic, p.Dedupe_License_Key__c, p);
            index(byName, p.Dedupe_Name_Key__c, p); index(bySound, p.Dedupe_Sound_Key__c, p); index(byCell, p.Dedupe_Geo_Key__c, p);
        }

        DuplicateMatchService.Context ctx = contextFor(s);
        for (String k : byPhone.keySet()) ctx.phoneFreq.put(k, byPhone.get(k).size());
        for (String k : byEmail.keySet()) ctx.emailFreq.put(k, byEmail.get(k).size());
        if (type == 'HCP') {
            Set<Id> hcpIds = new Set<Id>();
            for (Sciagen_Account__c p : pool) hcpIds.add(p.Id);
            for (Sciagen_Account__c a : subjects) hcpIds.add(a.Id);
            for (Affiliation__c af : [SELECT HCP__c, HCO__c FROM Affiliation__c WHERE HCP__c IN :hcpIds LIMIT 20000]) {
                if (!ctx.hcoByHcp.containsKey(af.HCP__c)) ctx.hcoByHcp.put(af.HCP__c, new Set<Id>());
                ctx.hcoByHcp.get(af.HCP__c).add(af.HCO__c);
            }
        }

        List<Pair> out = new List<Pair>();
        for (Sciagen_Account__c a : subjects) {
            Map<Id, Sciagen_Account__c> cand = new Map<Id, Sciagen_Account__c>();
            collect(cand, byPhone.get(a.Dedupe_Phone_Key__c), a, false);
            collect(cand, byEmail.get(a.Dedupe_Email_Key__c), a, false);
            collect(cand, byLic.get(a.Dedupe_License_Key__c), a, false);
            collect(cand, byName.get(a.Dedupe_Name_Key__c), a, false);
            List<Sciagen_Account__c> block = bySound.get(a.Dedupe_Sound_Key__c);
            if (block != null && block.size() <= MAX_SOUND_BLOCK) collect(cand, block, a, true);
            if (type == 'HCO') {
                for (String cell : DuplicateText.geoCellsAround(a.Geolocation__Latitude__s, a.Geolocation__Longitude__s)) collect(cand, byCell.get(cell), a, false);
            }
            for (Sciagen_Account__c b : cand.values()) {
                String pk = pairKey(a.Id, b.Id);
                if (!seen.add(pk)) continue;
                DuplicateMatchService.Result r = DuplicateMatchService.compare(a, b, ctx);
                if (!r.isCandidate) continue;
                Pair p = new Pair();
                p.a = a; p.b = b; p.result = r;
                out.add(p);
            }
        }
        return out;
    }

    /** Scan the given accounts and save candidate rows. Returns how many candidates were created or refreshed. */
    public static Integer scan(Set<Id> ids, Boolean markChecked) {
        Settings s = loadSettings();
        if (!s.enabled || ids.isEmpty()) return 0;
        String soql = 'SELECT ' + DuplicateMatchService.MATCH_FIELDS + ' FROM Sciagen_Account__c WHERE Id IN :ids AND Is_Merged__c = false';
        List<Sciagen_Account__c> subjects = Database.query(soql);
        List<Pair> pairs = findPairs(subjects, s);
        Integer saved = saveCandidates(pairs);
        if (markChecked) {
            List<Sciagen_Account__c> upd = new List<Sciagen_Account__c>();
            for (Sciagen_Account__c a : subjects) upd.add(new Sciagen_Account__c(Id = a.Id, Dedupe_Checked_At__c = System.now()));
            Database.update(upd, false);
        }
        return saved;
    }

    public static Integer saveCandidates(List<Pair> pairs) {
        if (pairs.isEmpty()) return 0;
        Map<String, Pair> byKey = new Map<String, Pair>();
        for (Pair p : pairs) byKey.put(pairKey(p.a.Id, p.b.Id), p);

        // Pairs a steward already decided on stay decided.
        Map<String, Duplicate_Candidate__c> existing = new Map<String, Duplicate_Candidate__c>();
        for (Duplicate_Candidate__c d : [SELECT Id, Pair_Key__c, Status__c FROM Duplicate_Candidate__c WHERE Pair_Key__c IN :byKey.keySet()]) {
            existing.put(d.Pair_Key__c, d);
        }
        Set<Id> acctIds = new Set<Id>();
        for (Pair p : pairs) { acctIds.add(p.a.Id); acctIds.add(p.b.Id); }
        Map<Id, Map<String, Integer>> activity = DuplicateSurvivorship.loadActivity(acctIds);

        List<Duplicate_Candidate__c> rows = new List<Duplicate_Candidate__c>();
        for (String pk : byKey.keySet()) {
            Duplicate_Candidate__c ex = existing.get(pk);
            if (ex != null && ex.Status__c != 'Open') continue;
            Pair p = byKey.get(pk);
            Boolean aFirst = String.valueOf(p.a.Id) < String.valueOf(p.b.Id);
            Sciagen_Account__c first = aFirst ? p.a : p.b;
            Sciagen_Account__c second = aFirst ? p.b : p.a;
            DuplicateSurvivorship.Suggestion sug = DuplicateSurvivorship.suggest(first, second, activity);
            String reasons = p.result.reasonText();
            rows.add(new Duplicate_Candidate__c(
                Pair_Key__c = pk,
                Record_A__c = first.Id,
                Record_B__c = second.Id,
                Object_Type__c = first.Type__c,
                Match_Score__c = p.result.score,
                Confidence__c = p.result.confidence,
                Match_Reasons__c = reasons.length() > 4000 ? reasons.substring(0, 4000) : reasons,
                Suggested_Winner__c = sug.winnerId,
                Strong_Identifier__c = p.result.strongIdentifier,
                Status__c = 'Open'
            ));
        }
        if (rows.isEmpty()) return 0;
        Database.UpsertResult[] res = Database.upsert(rows, Duplicate_Candidate__c.Pair_Key__c, false);
        Integer ok = 0;
        for (Database.UpsertResult r : res) if (r.isSuccess()) ok++;
        return ok;
    }

    public static String pairKey(Id x, Id y) {
        String a = String.valueOf(x), b = String.valueOf(y);
        return a < b ? a + '|' + b : b + '|' + a;
    }

    // ---------------------------------------------------------------- helpers

    private static void addIf(Set<String> s, String v) { if (String.isNotBlank(v)) s.add(v); }

    private static void index(Map<String, List<Sciagen_Account__c>> m, String key, Sciagen_Account__c rec) {
        if (String.isBlank(key)) return;
        if (!m.containsKey(key)) m.put(key, new List<Sciagen_Account__c>());
        m.get(key).add(rec);
    }

    private static void collect(Map<Id, Sciagen_Account__c> dest, List<Sciagen_Account__c> src, Sciagen_Account__c subject, Boolean requireLocation) {
        if (src == null) return;
        for (Sciagen_Account__c c : src) {
            if (c.Id == subject.Id) continue;
            if (requireLocation && !locationCompatible(subject, c)) continue;
            dest.put(c.Id, c);
        }
    }

    /** Same-sounding names are only worth comparing when they could be in the same place. */
    private static Boolean locationCompatible(Sciagen_Account__c a, Sciagen_Account__c b) {
        String za = DuplicateText.postalKey(a.Billing_Postal_Code__c), zb = DuplicateText.postalKey(b.Billing_Postal_Code__c);
        if (za != null && zb != null && za == zb) return true;
        String ca = DuplicateText.normText(a.Billing_City__c), cb = DuplicateText.normText(b.Billing_City__c);
        if (ca == '' || cb == '') return true;
        return ca == cb || ca.contains(cb) || cb.contains(ca);
    }
}