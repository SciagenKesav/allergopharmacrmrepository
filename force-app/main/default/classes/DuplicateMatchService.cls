/**
 * Scores how likely two Sciagen_Account__c records (both HCP or both HCO) are the same real-world
 * person or organisation.
 *
 * There is no single trustworthy unique identifier in this data, so the score is built from many
 * weak-to-strong signals (name similarity, licence, email, phone, address, geo distance, shared
 * affiliation...) and reduced by conflicting evidence (different licence numbers, different cities,
 * hospital and its own department). No one signal decides it, and a match on a shared phone or
 * mailbox alone is capped so a family or a clinic line can't merge two different people.
 *
 * Every point added or removed is recorded in `reasons`, so a reviewer can see why a pair was flagged.
 */
public without sharing class DuplicateMatchService {

    public static final Decimal DEFAULT_MIN_SCORE = 55;
    public static final Decimal DEFAULT_HIGH_SCORE = 85;
    public static final Decimal MEDIUM_SCORE = 70;

    public static final String MATCH_FIELDS =
        'Id, Name, Type__c, Prefix__c, First_Name__c, Last_Name__c, Speciality__c, Specialty__c, Email__c, Phone__c, ' +
        'License_Number__c, Licensing_Body__c, Account_Code__c, External_Ids__c, Billing_Street__c, Billing_City__c, ' +
        'Billing_State__c, Billing_Postal_Code__c, Geolocation__Latitude__s, Geolocation__Longitude__s, Plus_Code__c, ' +
        'Website__c, HCO_Type__c, HCP_Type__c, Parent_Account__c, Degree_1__c, Degree_2__c, Degree_3__c, Degree_4__c, ' +
        'Degree_5__c, Graduation_Year__c, Is_Merged__c, Dedupe_Name_Key__c, Dedupe_Sound_Key__c, Dedupe_Phone_Key__c, ' +
        'Dedupe_Email_Key__c, Dedupe_License_Key__c, Dedupe_Geo_Key__c, CreatedDate, LastModifiedDate, Last_Visit__c';

    public class Context {
        /** How many accounts share each phone / email key in the candidate pool. High counts mean a shared line. */
        public Map<String, Integer> phoneFreq = new Map<String, Integer>();
        public Map<String, Integer> emailFreq = new Map<String, Integer>();
        /** HCO ids each HCP is affiliated with. */
        public Map<Id, Set<Id>> hcoByHcp = new Map<Id, Set<Id>>();
        public Decimal minScore = DEFAULT_MIN_SCORE;
        public Decimal highScore = DEFAULT_HIGH_SCORE;
    }

    public class Result {
        public Decimal score = 0;
        public Decimal namePoints = 0;
        public String confidence;
        public Boolean strongIdentifier = false;
        public List<String> reasons = new List<String>();
        public Boolean isCandidate = false;
        public String reasonText() { return String.join(reasons, '\n'); }
    }

    private class Acc {
        Decimal total = 0;
        List<String> reasons = new List<String>();
        void add(Decimal pts, String why) {
            if (pts == 0) return;
            total += pts;
            reasons.add(why + ' (' + (pts > 0 ? '+' : '') + pts.setScale(0) + ')');
        }
    }

    // ---------------------------------------------------------------- entry point

    public static Result compare(Sciagen_Account__c a, Sciagen_Account__c b, Context ctx) {
        if (ctx == null) ctx = new Context();
        Result r = new Result();
        if (a == null || b == null || a.Id == b.Id || a.Type__c != b.Type__c) {
            r.confidence = 'None';
            return r;
        }
        Acc acc = new Acc();
        Boolean strong = false;
        Decimal namePts;

        if (a.Type__c == 'HCP') {
            namePts = scoreHcpName(a, b, acc);
            strong = scoreHcpSignals(a, b, ctx, acc, namePts);
        } else {
            namePts = scoreHcoName(a, b, acc);
            strong = scoreHcoSignals(a, b, ctx, acc, namePts);
        }

        Decimal total = acc.total;
        // An identifier match with no real name support (shared phone, shared mailbox) is capped:
        // it can put a pair in front of a reviewer but never at High confidence.
        if (namePts < 12 && total > 60) {
            acc.reasons.add('Capped at 60: identifiers match but the names do not (shared line or mailbox?)');
            total = 60;
        }
        total = Math.max(0, Math.min(100, total));

        r.score = total.setScale(1);
        r.namePoints = namePts;
        r.strongIdentifier = strong;
        r.reasons = acc.reasons;
        r.confidence = total >= ctx.highScore ? 'High' : (total >= MEDIUM_SCORE ? 'Medium' : (total >= ctx.minScore ? 'Low' : 'None'));
        r.isCandidate = total >= ctx.minScore;
        return r;
    }

    // ---------------------------------------------------------------- HCP

    private static List<String> hcpTokens(Sciagen_Account__c a) {
        String full = String.isNotBlank(a.First_Name__c) || String.isNotBlank(a.Last_Name__c)
            ? (a.First_Name__c == null ? '' : a.First_Name__c) + ' ' + (a.Last_Name__c == null ? '' : a.Last_Name__c)
            : a.Name;
        return DuplicateText.nameTokens(full);
    }

    /** Name similarity for people: order-insensitive, tolerant of initials, spelling and middle names. */
    private static Decimal scoreHcpName(Sciagen_Account__c a, Sciagen_Account__c b, Acc acc) {
        List<String> ta = hcpTokens(a), tb = hcpTokens(b);
        Decimal sim = personNameSimilarity(ta, tb);
        Decimal pts = namePoints(sim);
        if (pts > 0) {
            acc.add(pts, 'Name ' + (sim >= 0.985 ? 'matches' : 'is similar') + ' ("' + a.Name + '" / "' + b.Name + '")');
        } else {
            acc.add(-5, 'Names differ ("' + a.Name + '" / "' + b.Name + '")');
        }
        return pts;
    }

    public static Decimal personNameSimilarity(List<String> ta, List<String> tb) {
        List<String> la = DuplicateText.longTokens(ta), lb = DuplicateText.longTokens(tb);
        if (la.isEmpty() || lb.isEmpty()) return 0;
        // Exact, order-insensitive.
        List<String> sa = la.clone(), sb = lb.clone();
        sa.sort(); sb.sort();
        if (String.join(sa, ' ') == String.join(sb, ' ')) return 1;

        List<String> shorter = la.size() <= lb.size() ? la : lb;
        List<String> longer = la.size() <= lb.size() ? lb : la;
        Set<Integer> used = new Set<Integer>();
        Decimal sum = 0, minTok = 1;
        for (String t : shorter) {
            Decimal best = 0; Integer bestIdx = -1;
            for (Integer i = 0; i < longer.size(); i++) {
                if (used.contains(i)) continue;
                Decimal s = tokenSimilarity(t, longer[i]);
                if (s > best) { best = s; bestIdx = i; }
            }
            if (bestIdx >= 0) used.add(bestIdx);
            sum += best;
            if (best < minTok) minTok = best;
        }
        Decimal avg = sum / shorter.size();
        Decimal coverage = Decimal.valueOf(shorter.size()) / longer.size();
        Decimal sim = avg * (0.8 + 0.2 * coverage);
        // One clearly different name (Malhotra / Mehra) should not be rescued by the other one matching.
        if (minTok < 0.85) sim = sim * 0.7;
        // A whole-string comparison catches run-together and split names.
        Decimal whole = DuplicateText.levenshteinRatio(String.join(sa, ''), String.join(sb, ''));
        return Math.max(sim, whole * (minTok >= 0.85 ? 1 : 0.85));
    }

    private static Decimal tokenSimilarity(String x, String y) {
        if (x == y) return 1;
        Decimal jw = DuplicateText.jaroWinkler(x, y);
        String px = DuplicateText.phonetic(x), py = DuplicateText.phonetic(y);
        if (px.length() >= 2 && px == py) jw = Math.max(jw, 0.94);
        return jw;
    }

    private static Decimal namePoints(Decimal sim) {
        if (sim >= 0.985) return 45;
        if (sim >= 0.9) return 30 + (sim - 0.9) / 0.085 * 15;
        if (sim >= 0.8) return 13 + (sim - 0.8) / 0.1 * 17;
        if (sim >= 0.6) return (sim - 0.6) / 0.2 * 13;
        return 0;
    }

    private static Boolean scoreHcpSignals(Sciagen_Account__c a, Sciagen_Account__c b, Context ctx, Acc acc, Decimal namePts) {
        Boolean strong = false;

        // Licence number: the closest thing to an ID. Equal is strong; different is strong evidence against.
        String la = DuplicateText.licenseKey(a.License_Number__c), lb = DuplicateText.licenseKey(b.License_Number__c);
        if (la != null && lb != null) {
            if (la == lb) { acc.add(40, 'Same licence number ' + a.License_Number__c); strong = true; }
            else if (String.isBlank(a.Licensing_Body__c) || String.isBlank(b.Licensing_Body__c) || a.Licensing_Body__c == b.Licensing_Body__c) {
                acc.add(-35, 'Different licence numbers (' + a.License_Number__c + ' / ' + b.License_Number__c + ')');
            }
        }

        // Email.
        String ea = DuplicateText.emailKey(a.Email__c), eb = DuplicateText.emailKey(b.Email__c);
        if (ea != null && eb != null && ea == eb) {
            Integer f = ctx.emailFreq.get(ea) == null ? 2 : ctx.emailFreq.get(ea);
            if (DuplicateText.isGenericMailbox(ea) || f > 3) {
                acc.add(6, 'Same shared mailbox ' + ea);
            } else {
                acc.add(30, 'Same email ' + ea);
                strong = true;
            }
        }

        // Phone.
        String pa = DuplicateText.phoneKey(a.Phone__c), pb = DuplicateText.phoneKey(b.Phone__c);
        if (pa != null && pb != null && pa == pb) {
            Integer f = ctx.phoneFreq.get(pa) == null ? 2 : ctx.phoneFreq.get(pa);
            if (f > 3) {
                acc.add(5, 'Same phone ' + pa + ' but shared by ' + f + ' records');
            } else {
                acc.add(25, 'Same phone ' + pa);
                strong = true;
            }
        }

        // Account code and other external identifiers.
        if (String.isNotBlank(a.Account_Code__c) && String.isNotBlank(b.Account_Code__c) && a.Account_Code__c.equalsIgnoreCase(b.Account_Code__c)) {
            acc.add(20, 'Same account code ' + a.Account_Code__c);
            strong = true;
        }
        Set<String> shared = sharedExternalIds(a.External_Ids__c, b.External_Ids__c);
        if (!shared.isEmpty()) {
            acc.add(35, 'Shared external ID ' + new List<String>(shared)[0]);
            strong = true;
        }

        // Specialty.
        String sa = specialty(a), sb = specialty(b);
        if (String.isNotBlank(sa) && String.isNotBlank(sb)) {
            if (sa.equalsIgnoreCase(sb)) acc.add(8, 'Same specialty ' + sa);
            else if (!isBroadSpecialty(sa) && !isBroadSpecialty(sb)) acc.add(-8, 'Different specialty (' + sa + ' / ' + sb + ')');
        }

        // Location.
        String za = DuplicateText.postalKey(a.Billing_Postal_Code__c), zb = DuplicateText.postalKey(b.Billing_Postal_Code__c);
        String ca = DuplicateText.normText(a.Billing_City__c), cb = DuplicateText.normText(b.Billing_City__c);
        if (za != null && zb != null && za == zb) {
            acc.add(7, 'Same postal code ' + za);
        } else if (ca != '' && cb != '' && ca == cb) {
            acc.add(4, 'Same city ' + a.Billing_City__c);
        } else if (ca != '' && cb != '' && ca != cb && !ca.contains(cb) && !cb.contains(ca)) {
            acc.add(-6, 'Different city (' + a.Billing_City__c + ' / ' + b.Billing_City__c + ')');
        }

        // Shared HCO affiliation is a strong soft signal for people.
        Set<Id> ha = ctx.hcoByHcp.get(a.Id), hb = ctx.hcoByHcp.get(b.Id);
        if (ha != null && hb != null && !ha.isEmpty() && !hb.isEmpty()) {
            Set<Id> common = ha.clone();
            common.retainAll(hb);
            if (!common.isEmpty()) acc.add(12, 'Affiliated to the same organisation');
        }

        // Qualifications.
        Set<String> da = degrees(a), db = degrees(b);
        if (!da.isEmpty() && !db.isEmpty()) {
            Set<String> commonDeg = da.clone();
            commonDeg.retainAll(db);
            if (!commonDeg.isEmpty()) acc.add(3, 'Shared qualification');
        }
        if (a.Graduation_Year__c != null && b.Graduation_Year__c != null) {
            Decimal diff = Math.abs(a.Graduation_Year__c - b.Graduation_Year__c);
            if (diff == 0) acc.add(3, 'Same graduation year');
            else if (diff > 2) acc.add(-4, 'Graduation years differ (' + a.Graduation_Year__c + ' / ' + b.Graduation_Year__c + ')');
        }
        return strong;
    }

    // ---------------------------------------------------------------- HCO

    private static Decimal scoreHcoName(Sciagen_Account__c a, Sciagen_Account__c b, Acc acc) {
        List<String> ta = DuplicateText.orgTokens(a.Name), tb = DuplicateText.orgTokens(b.Name);
        Decimal sim = orgNameSimilarity(ta, tb);
        Decimal pts = namePoints(sim);
        if (pts > 0) {
            acc.add(pts, 'Name ' + (sim >= 0.985 ? 'matches' : 'is similar') + ' ("' + a.Name + '" / "' + b.Name + '")');
        } else {
            acc.add(-5, 'Names differ ("' + a.Name + '" / "' + b.Name + '")');
        }
        return pts;
    }

    public static Decimal orgNameSimilarity(List<String> ta, List<String> tb) {
        if (ta.isEmpty() || tb.isEmpty()) return 0;
        Set<String> sa = new Set<String>(ta), sb = new Set<String>(tb);
        // Fuzzy token match so "Sunshine" and "Sunshin" count as the same word.
        Integer matched = 0;
        Set<String> usedB = new Set<String>();
        for (String x : sa) {
            String hit = null;
            for (String y : sb) {
                if (usedB.contains(y)) continue;
                if (x == y || tokenSimilarity(x, y) >= 0.92) { hit = y; break; }
            }
            if (hit != null) { matched++; usedB.add(hit); }
        }
        Decimal union = sa.size() + sb.size() - matched;
        Decimal jaccard = union == 0 ? 0 : matched / union;
        Decimal contain = Decimal.valueOf(matched) / Math.min(sa.size(), sb.size());
        // Containment alone would call "Max" and "Nanavati Max" the same; blend in Jaccard.
        return 0.6 * jaccard + 0.4 * contain;
    }

    private static Boolean scoreHcoSignals(Sciagen_Account__c a, Sciagen_Account__c b, Context ctx, Acc acc, Decimal namePts) {
        Boolean strong = false;

        // A hospital and its own department / branch are related, not duplicates.
        if (a.Parent_Account__c == b.Id || b.Parent_Account__c == a.Id) {
            acc.add(-30, 'One is the parent of the other (branch or department, not a duplicate)');
        } else if (a.Parent_Account__c != null && a.Parent_Account__c == b.Parent_Account__c) {
            acc.add(-8, 'Same parent organisation (sibling units)');
        }

        String pa = DuplicateText.phoneKey(a.Phone__c), pb = DuplicateText.phoneKey(b.Phone__c);
        if (pa != null && pb != null && pa == pb) {
            Integer f = ctx.phoneFreq.get(pa) == null ? 2 : ctx.phoneFreq.get(pa);
            if (f > 3) { acc.add(5, 'Same phone ' + pa + ' but shared by ' + f + ' records'); }
            else { acc.add(25, 'Same phone ' + pa); strong = true; }
        }

        String ea = DuplicateText.emailKey(a.Email__c), eb = DuplicateText.emailKey(b.Email__c);
        if (ea != null && eb != null && ea == eb) {
            acc.add(DuplicateText.isGenericMailbox(ea) ? 18 : 25, 'Same email ' + ea);
            strong = true;
        } else if (ea != null && eb != null) {
            String da = DuplicateText.emailDomain(ea), db = DuplicateText.emailDomain(eb);
            if (da == db && da != null && !da.contains('gmail.') && !da.contains('yahoo.') && !da.contains('hotmail.') && !da.contains('outlook.')
                && !da.contains('example.') && !da.contains('rediff')) {
                acc.add(10, 'Same email domain ' + da);
            }
        }

        String wa = DuplicateText.websiteHost(a.Website__c), wb = DuplicateText.websiteHost(b.Website__c);
        if (wa != null && wb != null && wa == wb) { acc.add(20, 'Same website ' + wa); strong = true; }

        if (String.isNotBlank(a.Plus_Code__c) && String.isNotBlank(b.Plus_Code__c) && a.Plus_Code__c.equalsIgnoreCase(b.Plus_Code__c)) {
            acc.add(25, 'Same Plus Code ' + a.Plus_Code__c);
            strong = true;
        }
        if (String.isNotBlank(a.Account_Code__c) && String.isNotBlank(b.Account_Code__c) && a.Account_Code__c.equalsIgnoreCase(b.Account_Code__c)) {
            acc.add(25, 'Same account code ' + a.Account_Code__c);
            strong = true;
        }
        Set<String> shared = sharedExternalIds(a.External_Ids__c, b.External_Ids__c);
        if (!shared.isEmpty()) { acc.add(30, 'Shared external ID ' + new List<String>(shared)[0]); strong = true; }

        // Geo distance: the best evidence two HCO rows are the same building.
        Boolean hasGeoA = a.Geolocation__Latitude__s != null && a.Geolocation__Longitude__s != null && !(a.Geolocation__Latitude__s == 0 && a.Geolocation__Longitude__s == 0);
        Boolean hasGeoB = b.Geolocation__Latitude__s != null && b.Geolocation__Longitude__s != null && !(b.Geolocation__Latitude__s == 0 && b.Geolocation__Longitude__s == 0);
        if (hasGeoA && hasGeoB) {
            Decimal d = DuplicateText.distanceMetres(a.Geolocation__Latitude__s, a.Geolocation__Longitude__s, b.Geolocation__Latitude__s, b.Geolocation__Longitude__s);
            String dl = d < 1000 ? d.setScale(0) + ' m' : (d / 1000).setScale(1) + ' km';
            if (d <= 50) acc.add(35, 'Same location (' + dl + ' apart)');
            else if (d <= 150) acc.add(26, 'Almost the same location (' + dl + ' apart)');
            else if (d <= 500) acc.add(12, 'Nearby (' + dl + ' apart)');
            else if (d <= 2000) acc.add(3, 'Same neighbourhood (' + dl + ' apart)');
            else if (d > 5000) acc.add(-15, 'Far apart (' + dl + ')');
        }

        String za = DuplicateText.postalKey(a.Billing_Postal_Code__c), zb = DuplicateText.postalKey(b.Billing_Postal_Code__c);
        String ca = DuplicateText.normText(a.Billing_City__c), cb = DuplicateText.normText(b.Billing_City__c);
        if (za != null && zb != null && za == zb) acc.add(8, 'Same postal code ' + za);
        else if (ca != '' && cb != '' && ca == cb) acc.add(4, 'Same city ' + a.Billing_City__c);
        else if (ca != '' && cb != '' && !ca.contains(cb) && !cb.contains(ca)) acc.add(-6, 'Different city (' + a.Billing_City__c + ' / ' + b.Billing_City__c + ')');

        Set<String> stA = DuplicateText.streetTokens(a.Billing_Street__c), stB = DuplicateText.streetTokens(b.Billing_Street__c);
        if (stA.size() >= 2 && stB.size() >= 2) {
            Set<String> common = stA.clone();
            common.retainAll(stB);
            Decimal contain = Decimal.valueOf(common.size()) / Math.min(stA.size(), stB.size());
            if (contain >= 0.7) acc.add(12, 'Street address matches');
        }

        if (String.isNotBlank(a.HCO_Type__c) && a.HCO_Type__c == b.HCO_Type__c) acc.add(3, 'Same organisation type ' + a.HCO_Type__c);
        String sa = specialty(a), sb = specialty(b);
        if (String.isNotBlank(sa) && sa.equalsIgnoreCase(sb)) acc.add(3, 'Same specialty ' + sa);
        return strong;
    }

    // ---------------------------------------------------------------- shared helpers

    public static String specialty(Sciagen_Account__c a) {
        return String.isNotBlank(a.Specialty__c) ? a.Specialty__c : a.Speciality__c;
    }

    private static Boolean isBroadSpecialty(String s) {
        String l = s.toLowerCase();
        return l == 'other' || l == 'general physician' || l == 'internal medicine';
    }

    private static Set<String> degrees(Sciagen_Account__c a) {
        Set<String> out = new Set<String>();
        for (String d : new List<String>{ a.Degree_1__c, a.Degree_2__c, a.Degree_3__c, a.Degree_4__c, a.Degree_5__c }) {
            if (String.isNotBlank(d)) out.add(d.toLowerCase().replaceAll('[^a-z0-9]', ''));
        }
        return out;
    }

    /** Values (not keys) from External_Ids__c, whether it holds JSON, "KEY:value" lines or bare ids. */
    public static Set<String> externalIdValues(String raw) {
        Set<String> out = new Set<String>();
        if (String.isBlank(raw)) return out;
        String body = raw.trim();
        try {
            Object parsed = JSON.deserializeUntyped(body);
            if (parsed instanceof Map<String, Object>) {
                for (String k : ((Map<String, Object>) parsed).keySet()) {
                    if (k == 'MERGED_FROM') continue;
                    Object v = ((Map<String, Object>) parsed).get(k);
                    addExternalValue(out, v == null ? null : String.valueOf(v));
                }
                return out;
            }
        } catch (Exception e) { /* not JSON; fall through */ }
        for (String line : body.split('[\\n,;]')) {
            String v = line;
            Integer i = line.indexOf(':');
            if (i < 0) i = line.indexOf('=');
            if (i >= 0) {
                String key = line.substring(0, i).trim().toUpperCase();
                if (key == 'MERGED_FROM') continue;
                v = line.substring(i + 1);
            }
            addExternalValue(out, v);
        }
        return out;
    }

    private static void addExternalValue(Set<String> out, String v) {
        if (String.isBlank(v)) return;
        String k = v.toUpperCase().replaceAll('[^A-Z0-9]', '');
        if (k.length() >= 4) out.add(k);
    }

    public static Set<String> sharedExternalIds(String rawA, String rawB) {
        Set<String> a = externalIdValues(rawA);
        if (a.isEmpty()) return a;
        Set<String> b = externalIdValues(rawB);
        a.retainAll(b);
        return a;
    }
}