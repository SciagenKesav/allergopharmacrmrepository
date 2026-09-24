/**
 * Text helpers for duplicate detection: name/phone/email/address normalisation,
 * a phonetic key tuned for Indian names, and fuzzy string similarity.
 * Pure functions with no DML or SOQL, so they are cheap to unit test.
 */
public class DuplicateText {

    // Titles, honorifics and degrees that say nothing about who the person is.
    private static final Set<String> NOISE_TOKENS = new Set<String>{
        'dr', 'doctor', 'prof', 'professor', 'mr', 'mrs', 'ms', 'miss', 'shri', 'shree', 'smt', 'sri', 'late',
        'md', 'dm', 'mch', 'mbbs', 'dnb', 'frcs', 'mrcp', 'bds', 'mds', 'phd', 'dch', 'dgo', 'ms', 'mrcog', 'frcp'
    };

    // Words that appear in most organisation names and do not distinguish one from another.
    private static final Set<String> ORG_STOPWORDS = new Set<String>{
        'hospital', 'hospitals', 'clinic', 'clinics', 'centre', 'center', 'centres', 'centers', 'the', 'and', 'of',
        'pvt', 'ltd', 'limited', 'private', 'llp', 'inc', 'multispeciality', 'multispecialty', 'multi', 'super',
        'speciality', 'specialty', 'specialities', 'specialists', 'specialist', 'medical', 'health', 'healthcare',
        'care', 'nursing', 'home', 'institute', 'research', 'diagnostic', 'diagnostics', 'polyclinic', 'general'
    };

    private static final Set<String> GENERIC_MAILBOXES = new Set<String>{
        'info', 'admin', 'contact', 'hello', 'reception', 'office', 'support', 'enquiry', 'enquiries', 'mail',
        'accounts', 'sales', 'care', 'help', 'appointments', 'appointment', 'frontdesk', 'front.desk', 'clinic', 'hospital'
    };

    // ---------------------------------------------------------------- names

    /** Lower-case alphabetic tokens with titles/degrees removed. Initials (1 letter) are kept. */
    public static List<String> nameTokens(String raw) {
        List<String> out = new List<String>();
        if (String.isBlank(raw)) return out;
        String s = raw.toLowerCase().replaceAll('[^a-z0-9 ]', ' ').replaceAll('\\s+', ' ').trim();
        for (String t : s.split(' ')) {
            if (String.isBlank(t) || NOISE_TOKENS.contains(t)) continue;
            out.add(t);
        }
        return out;
    }

    /** Organisation-name tokens: as nameTokens, minus words common to most organisations. */
    public static List<String> orgTokens(String raw) {
        List<String> out = new List<String>();
        for (String t : nameTokens(raw)) {
            if (!ORG_STOPWORDS.contains(t)) out.add(t);
        }
        // "Pharmacy Delhi" style names can be nothing but stopwords; fall back to all tokens.
        return out.isEmpty() ? nameTokens(raw) : out;
    }

    public static List<String> longTokens(List<String> tokens) {
        List<String> out = new List<String>();
        for (String t : tokens) if (t.length() > 1) out.add(t);
        return out;
    }

    /** Order-insensitive normalised name (sorted long tokens). */
    public static String nameKey(List<String> tokens) {
        List<String> longs = longTokens(tokens);
        longs.sort();
        String k = String.join(longs, ' ');
        return k.length() > 120 ? k.substring(0, 120) : k;
    }

    /** Phonetic key of the longest token, which is usually the surname or the distinctive word. */
    public static String soundKey(List<String> tokens) {
        String best = '';
        for (String t : longTokens(tokens)) {
            if (t.length() > best.length() || (t.length() == best.length() && t < best)) best = t;
        }
        String p = phonetic(best);
        return p.length() > 60 ? p.substring(0, 60) : p;
    }

    /**
     * Phonetic normalisation tuned for Indian names: Badhwar / Badwar, Yashwanth / Yeshwanth,
     * Mohd / Mohammed and similar spelling variants collapse to the same key.
     */
    public static String phonetic(String word) {
        if (String.isBlank(word)) return '';
        String w = word.toLowerCase().replaceAll('[^a-z]', '');
        if (w == 'mohd' || w == 'md' || w == 'mohammad' || w == 'muhammad' || w == 'mohamad' || w == 'muhammed' || w == 'mohammed') {
            w = 'mohammed';
        }
        w = w.replace('ph', 'f').replace('kh', 'k').replace('gh', 'g').replace('sh', 's').replace('ch', 'c')
             .replace('th', 't').replace('dh', 'd').replace('bh', 'b').replace('jh', 'j').replace('ck', 'k')
             .replace('ee', 'i').replace('oo', 'u').replace('aa', 'a').replace('w', 'v').replace('z', 'j')
             .replace('q', 'k').replace('x', 'ks');
        if (w.length() > 1) {
            String first = w.substring(0, 1);
            String rest = w.substring(1).replaceAll('[aeiouy]', '');
            w = first + rest;
        }
        // Collapse doubled letters (kk -> k).
        String out = '';
        for (Integer i = 0; i < w.length(); i++) {
            String c = w.substring(i, i + 1);
            if (out.length() == 0 || out.substring(out.length() - 1) != c) out += c;
        }
        return out;
    }

    // ---------------------------------------------------------------- similarity

    public static Decimal jaroWinkler(String a, String b) {
        if (a == null || b == null) return 0;
        if (a == b) return 1;
        Integer la = a.length(), lb = b.length();
        if (la == 0 || lb == 0) return 0;
        Integer window = Math.max(Math.max(la, lb) / 2 - 1, 0);
        List<Boolean> aMatch = new List<Boolean>(), bMatch = new List<Boolean>();
        for (Integer i = 0; i < la; i++) aMatch.add(false);
        for (Integer j = 0; j < lb; j++) bMatch.add(false);
        Integer matches = 0;
        for (Integer i = 0; i < la; i++) {
            Integer lo = Math.max(0, i - window), hi = Math.min(lb - 1, i + window);
            for (Integer j = lo; j <= hi; j++) {
                if (!bMatch[j] && a.charAt(i) == b.charAt(j)) {
                    aMatch[i] = true; bMatch[j] = true; matches++;
                    break;
                }
            }
        }
        if (matches == 0) return 0;
        Integer transpositions = 0, k = 0;
        for (Integer i = 0; i < la; i++) {
            if (!aMatch[i]) continue;
            while (!bMatch[k]) k++;
            if (a.charAt(i) != b.charAt(k)) transpositions++;
            k++;
        }
        Decimal m = matches;
        Decimal jaro = (m / la + m / lb + (m - transpositions / 2.0) / m) / 3;
        Integer prefix = 0;
        for (Integer i = 0; i < Math.min(4, Math.min(la, lb)); i++) {
            if (a.charAt(i) == b.charAt(i)) prefix++; else break;
        }
        return jaro + prefix * 0.1 * (1 - jaro);
    }

    /** 1 - editDistance / maxLength, in the range 0 to 1. */
    public static Decimal levenshteinRatio(String a, String b) {
        if (a == null || b == null) return 0;
        if (a == b) return 1;
        Integer la = a.length(), lb = b.length();
        if (la == 0 || lb == 0) return 0;
        List<Integer> prev = new List<Integer>(), cur = new List<Integer>();
        for (Integer j = 0; j <= lb; j++) prev.add(j);
        for (Integer i = 1; i <= la; i++) {
            cur.clear();
            cur.add(i);
            for (Integer j = 1; j <= lb; j++) {
                Integer cost = a.charAt(i - 1) == b.charAt(j - 1) ? 0 : 1;
                cur.add(Math.min(Math.min(cur[j - 1] + 1, prev[j] + 1), prev[j - 1] + cost));
            }
            List<Integer> tmp = prev; prev = cur; cur = tmp;
        }
        Decimal dist = prev[lb];
        return 1 - dist / Math.max(la, lb);
    }

    // ---------------------------------------------------------------- identifiers

    /** Last 10 digits of a phone number; blank if fewer than 7 digits are present. */
    public static String phoneKey(String raw) {
        if (String.isBlank(raw)) return null;
        String d = raw.replaceAll('[^0-9]', '');
        if (d.length() < 7) return null;
        if (d.length() > 10) d = d.substring(d.length() - 10);
        return d;
    }

    public static String emailKey(String raw) {
        if (String.isBlank(raw) || !raw.contains('@')) return null;
        String e = raw.trim().toLowerCase();
        return e.length() > 120 ? e.substring(0, 120) : e;
    }

    public static Boolean isGenericMailbox(String email) {
        String k = emailKey(email);
        if (k == null) return false;
        return GENERIC_MAILBOXES.contains(k.substring(0, k.indexOf('@')));
    }

    public static String emailDomain(String email) {
        String k = emailKey(email);
        return k == null ? null : k.substring(k.indexOf('@') + 1);
    }

    /** Host of a website without scheme or www; blank for social/generic hosts that prove nothing. */
    public static String websiteHost(String raw) {
        if (String.isBlank(raw)) return null;
        String h = raw.trim().toLowerCase().replaceFirst('^[a-z]+://', '').replaceFirst('^www\\.', '');
        Integer slash = h.indexOf('/');
        if (slash > 0) h = h.substring(0, slash);
        if (h.length() < 4 || h.contains('facebook.') || h.contains('instagram.') || h.contains('linkedin.')
            || h.contains('twitter.') || h.contains('google.') || h.contains('gmail.') || h.contains('yahoo.')) return null;
        return h;
    }

    public static String licenseKey(String raw) {
        if (String.isBlank(raw)) return null;
        String k = raw.toUpperCase().replaceAll('[^A-Z0-9]', '');
        if (k.length() < 3) return null;
        return k.length() > 80 ? k.substring(0, 80) : k;
    }

    public static String normText(String raw) {
        return String.isBlank(raw) ? '' : raw.toLowerCase().replaceAll('[^a-z0-9 ]', ' ').replaceAll('\\s+', ' ').trim();
    }

    public static String postalKey(String raw) {
        if (String.isBlank(raw)) return null;
        String d = raw.replaceAll('[^0-9]', '');
        return d.length() >= 5 ? d : null;
    }

    /** Address street tokens without filler words, for a containment comparison. */
    public static Set<String> streetTokens(String raw) {
        Set<String> out = new Set<String>();
        Set<String> filler = new Set<String>{ 'road', 'rd', 'street', 'st', 'near', 'opp', 'opposite', 'nagar', 'colony', 'the', 'and', 'no', 'floor', 'gf', 'ground', 'block', 'phase' };
        for (String t : normText(raw).split(' ')) {
            if (t.length() > 1 && !filler.contains(t)) out.add(t);
        }
        return out;
    }

    /** Whole-metre distance between two coordinates (haversine). */
    public static Decimal distanceMetres(Decimal lat1, Decimal lon1, Decimal lat2, Decimal lon2) {
        Double r = 6371000;
        Double k = 3.141592653589793 / 180;
        Double p1 = (Double) lat1 * k, p2 = (Double) lat2 * k;
        Double dp = (Double) (lat2 - lat1) * k, dl = (Double) (lon2 - lon1) * k;
        Double a = Math.sin(dp / 2) * Math.sin(dp / 2) + Math.cos(p1) * Math.cos(p2) * Math.sin(dl / 2) * Math.sin(dl / 2);
        return Decimal.valueOf(r * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a)));
    }

    public static String geoCell(Decimal lat, Decimal lon) {
        if (lat == null || lon == null || (lat == 0 && lon == 0)) return null;
        return String.valueOf(Math.floor((Double) lat * 100).intValue()) + ':' + String.valueOf(Math.floor((Double) lon * 100).intValue());
    }

    /** The cell and its 8 neighbours, so two points either side of a cell boundary still meet. */
    public static Set<String> geoCellsAround(Decimal lat, Decimal lon) {
        Set<String> out = new Set<String>();
        if (lat == null || lon == null || (lat == 0 && lon == 0)) return out;
        Integer la = Math.floor((Double) lat * 100).intValue(), lo = Math.floor((Double) lon * 100).intValue();
        for (Integer i = -1; i <= 1; i++) for (Integer j = -1; j <= 1; j++) out.add((la + i) + ':' + (lo + j));
        return out;
    }
}