/**
 * Reports workspace engine -- reproduces the iPad Reports module server-side.
 * One flat HcpRow per in-scope HCP; every report is a different grouping of those rows.
 * Read-only: no DML. `with sharing` + USER_MODE on every query.
 * TODO (CLM): Presentation_Session__c is not synced from the iPad yet, so clmSessions /
 * clmMinutes / slides stay 0. Switch on in loadClm() once sessions sync.
 */
public with sharing class ReportsService {

    // ---------- public shapes ----------
    public class HcpRow {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String specialty;
        @AuraEnabled public String degree;
        @AuraEnabled public String tier;
        @AuraEnabled public String territory;
        @AuraEnabled public String city;
        @AuraEnabled public String hospital;
        @AuraEnabled public String product;
        @AuraEnabled public List<String> products = new List<String>();
        @AuraEnabled public String consent;
        @AuraEnabled public Integer planned = 0;
        @AuraEnabled public Integer completed = 0;
        @AuraEnabled public Integer draft = 0;
        @AuraEnabled public Integer missed = 0;
        @AuraEnabled public Integer clmSessions = 0;
        @AuraEnabled public Decimal clmMinutes = 0;
        @AuraEnabled public Integer slides = 0;
        @AuraEnabled public Integer emailsSent = 0;
        @AuraEnabled public Integer emailsDelivered = 0;
        @AuraEnabled public Integer emailsFailed = 0;
        @AuraEnabled public Integer emailsQueued = 0;
        @AuraEnabled public Integer samples = 0;
        @AuraEnabled public Date lastCall;
    }
    public class Kpi {
        @AuraEnabled public String label;
        @AuraEnabled public String value;
        @AuraEnabled public String delta;      // e.g. '+5 pts'
        @AuraEnabled public String deltaDir;   // up | down | flat | null
        @AuraEnabled public String tone;
        @AuraEnabled public Boolean positiveIsGood = true;
        public Kpi(String l, String v) { label = l; value = v; }
    }
    public class Series {
        @AuraEnabled public String name;
        @AuraEnabled public List<Decimal> values = new List<Decimal>();
        @AuraEnabled public String color;
        @AuraEnabled public List<String> colors;
        public Series(String n, String c) { name = n; color = c; }
    }
    public class Chart {
        @AuraEnabled public String title;
        @AuraEnabled public String type;       // bar | hbar | gbar | line
        @AuraEnabled public List<String> labels = new List<String>();
        @AuraEnabled public List<Series> series = new List<Series>();
        @AuraEnabled public Decimal maxValue;
        @AuraEnabled public Decimal refLine;
        @AuraEnabled public Boolean percent = false;
        public Chart(String t, String ty) { title = t; type = ty; }
    }
    public class Col {
        @AuraEnabled public String key;
        @AuraEnabled public String label;
        @AuraEnabled public Boolean numeric = false;
        public Col(String k, String l, Boolean n) { key = k; label = l; numeric = n; }
    }
    public class Tbl {
        @AuraEnabled public String title;
        @AuraEnabled public String icon = 'utility:table';
        @AuraEnabled public List<Col> columns = new List<Col>();
        @AuraEnabled public List<Map<String, String>> rows = new List<Map<String, String>>();
        @AuraEnabled public String rowAction;     // 'doctor' | 'group' | null
        @AuraEnabled public String groupDim;      // dimension used by the group drill
        public Tbl(String t) { title = t; }
        public Tbl col(String k, String l, Boolean n) { columns.add(new Col(k, l, n)); return this; }
    }
    public class ReportResult {
        @AuraEnabled public String key;
        @AuraEnabled public String title;
        @AuraEnabled public String periodLabel;
        @AuraEnabled public Integer doctorCount = 0;
        @AuraEnabled public String headline;
        @AuraEnabled public String note;
        @AuraEnabled public List<Kpi> kpis = new List<Kpi>();
        @AuraEnabled public List<Chart> charts = new List<Chart>();
        @AuraEnabled public List<Tbl> tables = new List<Tbl>();
        @AuraEnabled public List<String> monthOptions;
        @AuraEnabled public List<String> brandOptions;
        @AuraEnabled public Boolean noData = false;
    }
    public class Filters {
        public String search;
        public Set<String> segments = new Set<String>();
        public Set<String> coverage = new Set<String>();
        public Set<String> consents = new Set<String>();
        public Set<String> specialties = new Set<String>();
        public Set<String> territories = new Set<String>();
        public Set<String> cities = new Set<String>();
        public Set<String> products = new Set<String>();
    }
    public class EmailRec {
        public Id hcpId; public Datetime sentAt; public String template; public String status;
    }
    public class MissedPlan {
        public Id hcpId; public Date planDate; public String hco; public String note;
    }
    public class Ctx {
        public List<HcpRow> rows = new List<HcpRow>();
        public List<EmailRec> emails = new List<EmailRec>();
        public List<MissedPlan> missedPlans = new List<MissedPlan>();
        public Map<Id, Set<Id>> cvrHcps = new Map<Id, Set<Id>>();
        public Map<Id, String> cvrStatus = new Map<Id, String>();
        public Map<Id, Date> cvrDate = new Map<Id, Date>();
        public Map<Id, Set<String>> cvrProducts = new Map<Id, Set<String>>();
        public Map<Id, List<Map<String, String>>> planDetail = new Map<Id, List<Map<String, String>>>();
        public Set<String> productCatalogue = new Set<String>();
    }

    private static final Set<String> NAMES = new Set<String>{'V3', 'V2', 'V1', 'Unclassified'};
    @TestVisible private static Boolean managerOverride;

    // ---------- scope ----------
    @TestVisible private static Boolean adminOverride;
    /** Territory chosen in the picker for this request (set by each entry point). */
    @TestVisible private static Id reqTerritory;

    public static Boolean isAdmin() {
        if (adminOverride != null) return adminOverride;
        return FeatureManagement.checkPermission('Sciagen_Reports_Business_Admin');
    }
    /** Managers and Business Admins get the territory / KAM pickers. */
    public static Boolean isManager() {
        if (isAdmin()) return true;
        if (managerOverride != null) return managerOverride;
        return FeatureManagement.checkPermission('Sciagen_Reports_Manager');
    }
    private static Id idOrNull(Object o) { return (o == null || String.isBlank(String.valueOf(o))) ? null : (Id) String.valueOf(o); }
    private static void setScope(Id territoryId) { reqTerritory = territoryId; }

    /** Reads the assignment tables regardless of sharing -- only used to decide WHO may see WHICH territory. */
    private without sharing class ScopeReader {
        Set<Id> userTerritories(Id uid) {
            Set<Id> s = new Set<Id>();
            for (User_Territory__c ut : [SELECT Territory__c FROM User_Territory__c WHERE User__c = :uid]) if (ut.Territory__c != null) s.add(ut.Territory__c);
            return s;
        }
        Set<Id> expand(Set<Id> roots) {
            Set<Id> all = new Set<Id>(roots), frontier = new Set<Id>(roots);
            for (Integer i = 0; i < 5 && !frontier.isEmpty(); i++) {
                Set<Id> next = new Set<Id>();
                for (Territory__c t : [SELECT Id FROM Territory__c WHERE Parent_Territory__c IN :frontier]) if (all.add(t.Id)) next.add(t.Id);
                frontier = next;
            }
            return all;
        }
        List<Territory__c> territories(Set<Id> ids) { return [SELECT Id, Name, Parent_Territory__c FROM Territory__c WHERE Id IN :ids ORDER BY Name]; }
        List<User_Territory__c> assignments(Set<Id> terrIds) {
            return [SELECT User__c, User__r.Name, Territory__c FROM User_Territory__c WHERE Territory__c IN :terrIds AND User__r.IsActive = true];
        }
    }

    /** The territories whose doctors the running user may see at all; null = every territory. */
    private static Set<Id> allowedTerritories() {
        ScopeReader r = new ScopeReader();
        if (isAdmin()) return null;
        return r.expand(r.userTerritories(UserInfo.getUserId()));
    }

    /**
     * Territories to scope the HCP list to; null = no restriction.
     * KAM (no manager permission): own territories only, whatever the request says.
     * Manager: own territories + their children; may narrow to one territory and then to one KAM in it.
     * Business Admin: every territory.
     */
    @TestVisible
    private static Set<Id> scopeTerritories(Id repUserId) {
        ScopeReader r = new ScopeReader();
        Id me = UserInfo.getUserId();
        if (!isManager()) return r.expand(r.userTerritories(me));
        Set<Id> allowed = allowedTerritories();
        Set<Id> result = allowed;
        if (reqTerritory != null) {
            if (allowed != null && !allowed.contains(reqTerritory)) throw new AuraHandledException('That territory is outside your scope.');
            result = r.expand(new Set<Id>{ reqTerritory });
        }
        if (repUserId != null) {
            Set<Id> rep = r.expand(r.userTerritories(repUserId));
            if (result != null) rep.retainAll(result);
            result = rep;
        }
        return result;
    }

    // ---------- date helpers ----------
    public static Date toDate(Datetime dt) {
        return dt == null ? null : Date.valueOf(dt.format('yyyy-MM-dd'));
    }
    private static Datetime dayStart(Date d) { return Datetime.newInstance(d.year(), d.month(), d.day()); }

    public static Integer pct(Integer n, Integer d) {
        if (d == null || d == 0) return 0;
        return Math.min(100, (Integer) Math.round(100.0 * n / d));
    }
    public static Integer achievement(Integer a, Integer p) {
        if (p == null || p == 0) return 0;
        return (Integer) Math.round(100.0 * a / p);
    }

    // ---------- core: buildRows ----------
    public static List<HcpRow> buildRows(Date startDate, Date endDate, Id repUserId) {
        return buildCtx(startDate, endDate, repUserId).rows;
    }

    public static Ctx buildCtx(Date startDate, Date endDate, Id repUserId) {
        Ctx c = new Ctx();
        Set<Id> terrs = scopeTerritories(repUserId);
        Datetime startDT = dayStart(startDate);
        Datetime endDT = dayStart(endDate.addDays(1));
        Date today = Date.today();

        // 1. in-scope HCPs
        List<Sciagen_Account__c> hcps;
        if (terrs == null) {
            hcps = [SELECT Id, Name, Specialty__c, Degree_1__c, Billing_City__c FROM Sciagen_Account__c
                    WHERE Type__c = 'HCP' AND Is_Merged__c = false WITH USER_MODE LIMIT 20000];
        } else {
            hcps = [SELECT Id, Name, Specialty__c, Degree_1__c, Billing_City__c FROM Sciagen_Account__c
                    WHERE Type__c = 'HCP' AND Is_Merged__c = false
                    AND Id IN (SELECT Account__c FROM Account_Territory__c WHERE Territory__c IN :terrs)
                    WITH USER_MODE LIMIT 20000];
        }
        Map<Id, HcpRow> byId = new Map<Id, HcpRow>();
        for (Sciagen_Account__c a : hcps) {
            HcpRow r = new HcpRow();
            r.id = a.Id; r.name = a.Name; r.specialty = a.Specialty__c; r.degree = a.Degree_1__c;
            r.city = a.Billing_City__c; r.tier = 'Unclassified'; r.consent = 'Pending';
            byId.put(a.Id, r);
            c.rows.add(r);
        }
        Set<Id> hcpIds = byId.keySet();
        if (hcpIds.isEmpty()) return c;

        // 2. territory (earliest Account_Territory__c)
        Set<Id> terrSeen = new Set<Id>();
        for (Account_Territory__c at : [SELECT Account__c, Territory__r.Name FROM Account_Territory__c
                WHERE Account__c IN :hcpIds WITH USER_MODE ORDER BY CreatedDate ASC, Id ASC]) {
            if (terrSeen.add(at.Account__c)) byId.get(at.Account__c).territory = at.Territory__r.Name;
        }
        // 3. hospital (primary affiliation, else first)
        Set<Id> primarySeen = new Set<Id>(); Set<Id> anySeen = new Set<Id>();
        for (Affiliation__c af : [SELECT HCP__c, HCO__r.Name, HCO__r.Billing_City__c, Is_Primary__c FROM Affiliation__c
                WHERE HCP__c IN :hcpIds WITH USER_MODE ORDER BY Is_Primary__c DESC, CreatedDate ASC]) {
            HcpRow r = byId.get(af.HCP__c);
            if (r == null || primarySeen.contains(af.HCP__c)) continue;
            if (af.Is_Primary__c) primarySeen.add(af.HCP__c);
            else if (!anySeen.add(af.HCP__c)) continue;
            r.hospital = af.HCO__r.Name;
            if (String.isBlank(r.city)) r.city = af.HCO__r.Billing_City__c;
        }
        // 4. segment = the doctor's classification (V3 highest ... V1), no classification = Unclassified
        for (Segmentation__c s : [SELECT HCP__c, Classification__c FROM Segmentation__c WHERE HCP__c IN :hcpIds WITH USER_MODE ORDER BY CreatedDate ASC]) {
            HcpRow r = byId.get(s.HCP__c);
            if (r != null) r.tier = (s.Classification__c == 'V3' || s.Classification__c == 'V2' || s.Classification__c == 'V1') ? s.Classification__c : 'Unclassified';
        }
        // 5. consent (today, most recent by Captured_At__c)
        Set<Id> consentSeen = new Set<Id>();
        for (Consent__c k : [SELECT HCP__c, Signed__c, Captured_At__c FROM Consent__c WHERE HCP__c IN :hcpIds WITH USER_MODE
                ORDER BY Captured_At__c DESC NULLS LAST]) {
            if (!consentSeen.add(k.HCP__c)) continue;
            byId.get(k.HCP__c).consent = consentState(k.Signed__c, k.Captured_At__c, today);
        }
        // 6. plans in the period (HCP only; plans have no attendee object)
        List<Planned_Call__c> plans = [SELECT Id, HCP__c, Call_DateTime__c, Status__c, HCO__r.Name, Resulting_CVR__c
                FROM Planned_Call__c WHERE HCP__c IN :hcpIds AND Call_DateTime__c >= :startDT AND Call_DateTime__c < :endDT
                AND Is_Event__c = false AND Origin__c <> 'Call log' AND Status__c <> 'Cancelled' WITH USER_MODE];
        Set<Id> planIds = new Set<Id>();
        for (Planned_Call__c p : plans) planIds.add(p.Id);
        Set<Id> plansWithReport = new Set<Id>();
        for (Planned_Call__c p : plans) if (p.Resulting_CVR__c != null) plansWithReport.add(p.Id);
        for (Call_Visit_Report__c l : [SELECT Source_Planned_Call__c FROM Call_Visit_Report__c
                WHERE Source_Planned_Call__c IN :planIds WITH USER_MODE]) plansWithReport.add(l.Source_Planned_Call__c);
        for (Planned_Call__c p : plans) {
            HcpRow r = byId.get(p.HCP__c);
            Date pd = toDate(p.Call_DateTime__c);
            r.planned++;
            Boolean missed = p.Status__c == 'Planned' && pd < today && !plansWithReport.contains(p.Id);
            if (missed) {
                r.missed++;
                MissedPlan m = new MissedPlan();
                m.hcpId = p.HCP__c; m.planDate = pd; m.hco = p.HCO__r.Name; m.note = null;
                c.missedPlans.add(m);
            }
            List<Map<String, String>> pl = c.planDetail.get(p.HCP__c);
            if (pl == null) { pl = new List<Map<String, String>>(); c.planDetail.put(p.HCP__c, pl); }
            pl.add(new Map<String, String>{'date' => pd.format(), 'status' => p.Status__c, 'missed' => missed ? 'Missed' : '', 'sort' => String.valueOf(pd)});
        }
        // 7. call reports (primary or attendee), de-duplicated by (HCP, report)
        Set<Id> attCvrs = new Set<Id>();
        Map<Id, Set<Id>> attByCvr = new Map<Id, Set<Id>>();
        for (CVR_Attendee__c a : [SELECT CVR__c, HCP__c FROM CVR_Attendee__c WHERE HCP__c IN :hcpIds
                AND CVR__r.Visit_Date__c >= :startDate AND CVR__r.Visit_Date__c <= :endDate AND CVR__r.Parent_Call__c = null WITH USER_MODE]) {
            attCvrs.add(a.CVR__c);
            Set<Id> s = attByCvr.get(a.CVR__c); if (s == null) { s = new Set<Id>(); attByCvr.put(a.CVR__c, s); }
            s.add(a.HCP__c);
        }
        for (Call_Visit_Report__c v : [SELECT Id, HCP__c, Visit_Date__c, Record_Status__c FROM Call_Visit_Report__c
                WHERE Visit_Date__c >= :startDate AND Visit_Date__c <= :endDate
                AND Parent_Call__c = null AND (HCP__c IN :hcpIds OR Id IN :attCvrs) WITH USER_MODE]) {
            Set<Id> involved = new Set<Id>();
            if (v.HCP__c != null && byId.containsKey(v.HCP__c)) involved.add(v.HCP__c);
            if (attByCvr.containsKey(v.Id)) involved.addAll(attByCvr.get(v.Id));
            if (involved.isEmpty()) continue;
            c.cvrHcps.put(v.Id, involved);
            c.cvrStatus.put(v.Id, v.Record_Status__c);
            c.cvrDate.put(v.Id, v.Visit_Date__c);
            Boolean sub = v.Record_Status__c == 'Submitted';
            for (Id h : involved) {
                HcpRow r = byId.get(h);
                if (sub) {
                    r.completed++;
                    if (r.lastCall == null || v.Visit_Date__c > r.lastCall) r.lastCall = v.Visit_Date__c;
                } else r.draft++;
            }
        }
        // 8. products detailed per call
        Set<Id> cvrIds = c.cvrHcps.keySet();
        for (CVR_Detail_Priority__c d : [SELECT CVR__c, Product_Name__c, Product__r.Name FROM CVR_Detail_Priority__c
                WHERE CVR__c IN :cvrIds WITH USER_MODE]) {
            String n = String.isNotBlank(d.Product__r.Name) ? d.Product__r.Name : d.Product_Name__c;
            addProduct(c, d.CVR__c, n);
        }
        Set<Id> withDetail = c.cvrProducts.keySet().clone();
        for (Key_Message__c k : [SELECT CVR__c, Product__c FROM Key_Message__c WHERE CVR__c IN :cvrIds WITH USER_MODE]) {
            if (!withDetail.contains(k.CVR__c)) addProduct(c, k.CVR__c, k.Product__c);
        }
        Map<Id, Map<String, Integer>> prodCalls = new Map<Id, Map<String, Integer>>();
        for (Id cv : c.cvrProducts.keySet()) {
            for (Id h : c.cvrHcps.get(cv)) {
                Map<String, Integer> m = prodCalls.get(h); if (m == null) { m = new Map<String, Integer>(); prodCalls.put(h, m); }
                for (String p : c.cvrProducts.get(cv)) m.put(p, (m.containsKey(p) ? m.get(p) : 0) + 1);
            }
        }
        for (Id h : prodCalls.keySet()) {
            HcpRow r = byId.get(h);
            String best; Integer bn = -1;
            List<String> names = new List<String>(prodCalls.get(h).keySet()); names.sort();
            for (String n : names) { Integer k = prodCalls.get(h).get(n); if (k > bn) { bn = k; best = n; } }
            r.product = best; r.products = names;
        }
        // 9. emails
        // Sent_At__c is stamped by the server when delivery happens; a still-Queued email has none yet,
        // so it falls back to CreatedDate (README assumption).
        for (Sent_Email__c e : [SELECT HCP__c, Sent_At__c, CreatedDate, Status__c, Template__r.Template_Name__c, Template__r.Name FROM Sent_Email__c
                WHERE HCP__c IN :hcpIds AND Folder__c = 'Sent'
                AND ((Sent_At__c >= :startDT AND Sent_At__c < :endDT) OR (Sent_At__c = null AND CreatedDate >= :startDT AND CreatedDate < :endDT)) WITH USER_MODE]) {
            HcpRow r = byId.get(e.HCP__c);
            String st = String.isBlank(e.Status__c) ? 'Sent' : e.Status__c;
            r.emailsSent++;
            if (st == 'Sent') r.emailsDelivered++; else if (st == 'Failed') r.emailsFailed++; else if (st == 'Queued') r.emailsQueued++;
            EmailRec er = new EmailRec();
            er.hcpId = e.HCP__c; er.sentAt = e.Sent_At__c != null ? e.Sent_At__c : e.CreatedDate; er.status = st;
            er.template = String.isNotBlank(e.Template__r.Template_Name__c) ? e.Template__r.Template_Name__c : e.Template__r.Name;
            if (String.isBlank(er.template)) er.template = '(No template)';
            c.emails.add(er);
        }
        // 10. samples (Submitted reports only)
        Set<Id> subCvrs = new Set<Id>();
        for (Id cv : cvrIds) if (c.cvrStatus.get(cv) == 'Submitted') subCvrs.add(cv);
        for (Sample_Drop__c s : [SELECT CVR__c, Qty__c FROM Sample_Drop__c WHERE CVR__c IN :subCvrs WITH USER_MODE]) {
            Integer q = s.Qty__c == null ? 0 : (Integer) s.Qty__c;
            for (Id h : c.cvrHcps.get(s.CVR__c)) byId.get(h).samples += q;
        }
        // 11. CLM (not synced yet) -- see class TODO
        return c;
    }

    private static void addProduct(Ctx c, Id cvr, String name) {
        if (String.isBlank(name)) return;
        Set<String> s = c.cvrProducts.get(cvr); if (s == null) { s = new Set<String>(); c.cvrProducts.put(cvr, s); }
        s.add(name);
    }

    public static String consentState(Boolean signed, Datetime capturedAt, Date today) {
        if (capturedAt != null && toDate(capturedAt).addYears(3) < today) return 'Expired';
        if (signed == true && capturedAt != null) return 'Captured';
        return 'Pending';
    }

    // ---------- filters ----------
    public static Filters parseFilters(Map<String, Object> p) {
        Filters f = new Filters();
        if (p == null) return f;
        f.search = (String) p.get('search');
        f.segments = toSet(p.get('segments')); f.coverage = toSet(p.get('coverage')); f.consents = toSet(p.get('consents'));
        f.specialties = toSet(p.get('specialties')); f.territories = toSet(p.get('territories'));
        f.cities = toSet(p.get('cities')); f.products = toSet(p.get('products'));
        return f;
    }
    private static Set<String> toSet(Object o) {
        Set<String> s = new Set<String>();
        if (o instanceof List<Object>) for (Object x : (List<Object>) o) if (x != null) s.add(String.valueOf(x));
        return s;
    }
    private static Boolean has(String hay, String needle) { return hay != null && hay.toLowerCase().contains(needle); }

    public static List<HcpRow> applyFilters(List<HcpRow> rows, Filters f) {
        List<HcpRow> out = new List<HcpRow>();
        String q = String.isBlank(f.search) ? null : f.search.trim().toLowerCase();
        for (HcpRow r : rows) {
            if (q != null && !(has(r.name, q) || has(r.hospital, q) || has(r.specialty, q) || has(r.city, q) || has(r.territory, q))) continue;
            if (!f.segments.isEmpty() && !f.segments.contains(r.tier)) continue;
            if (!f.coverage.isEmpty() && !f.coverage.contains(r.completed > 0 ? 'Covered' : 'Not covered')) continue;
            if (!f.consents.isEmpty() && !f.consents.contains(r.consent)) continue;
            if (!f.specialties.isEmpty() && !f.specialties.contains(nz(r.specialty, ''))) continue;
            if (!f.territories.isEmpty() && !f.territories.contains(nz(r.territory, ''))) continue;
            if (!f.cities.isEmpty() && !f.cities.contains(nz(r.city, ''))) continue;
            if (!f.products.isEmpty()) {
                Boolean hit = false;
                for (String pr : r.products) if (f.products.contains(pr)) { hit = true; break; }
                if (!hit) continue;
            }
            out.add(r);
        }
        return out;
    }
    private static String nz(String s, String d) { return String.isBlank(s) ? d : s; }

    // ---------- period ----------
    public static String periodLabel(Date s, Date e, String label) {
        String r = (s == e) ? fmtDate(s) : fmtDay(s) + ' – ' + fmtDate(e);
        return String.isBlank(label) ? r : label + ' (' + r + ')';
    }
    private static final List<String> MON = new List<String>{'Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'};
    public static String fmtDay(Date d) { return d.day() + ' ' + MON[d.month() - 1]; }
    public static String fmtDate(Date d) { return d.day() + ' ' + MON[d.month() - 1] + ' ' + d.year(); }

    // ---------- shared builders ----------
    private static Integer sumP(List<HcpRow> rs) { Integer n = 0; for (HcpRow r : rs) n += r.planned; return n; }
    private static Integer sumC(List<HcpRow> rs) { Integer n = 0; for (HcpRow r : rs) n += r.completed; return n; }
    private static Integer sumM(List<HcpRow> rs) { Integer n = 0; for (HcpRow r : rs) n += r.missed; return n; }
    private static Integer sumD(List<HcpRow> rs) { Integer n = 0; for (HcpRow r : rs) n += r.draft; return n; }
    private static Integer covered(List<HcpRow> rs) { Integer n = 0; for (HcpRow r : rs) if (r.completed > 0) n++; return n; }
    private static Integer covPct(List<HcpRow> rs) { return pct(covered(rs), rs.size()); }

    private static String ach(Integer a, Integer p) { return p == 0 ? '—' : achievement(a, p) + '%'; }
    private static String dm(Date d) { return d == null ? '—' : fmtDay(d); }

    private static Kpi kpi(String label, Object value, Integer now, Integer prev, Boolean isPct, Boolean positiveIsGood) {
        Kpi k = new Kpi(label, String.valueOf(value));
        k.positiveIsGood = positiveIsGood;
        if (prev != null) {
            Integer d = now - prev;
            k.deltaDir = d > 0 ? 'up' : (d < 0 ? 'down' : 'flat');
            k.delta = (d > 0 ? '+' : '') + d + (isPct ? ' pts' : '');
        }
        return k;
    }

    private static Map<String, String> docRow(HcpRow r) {
        return new Map<String, String>{'_id' => r.id, 'name' => r.name, 'tier' => r.tier, 'specialty' => nz(r.specialty, '—'),
            'planned' => String.valueOf(r.planned), 'done' => String.valueOf(r.completed), 'missed' => String.valueOf(r.missed),
            'ach' => ach(r.completed, r.planned), 'last' => dm(r.lastCall), 'hospital' => nz(r.hospital, '—')};
    }
    private static Tbl docTable(String title, List<HcpRow> rs) {
        Tbl t = new Tbl(title);
        t.rowAction = 'doctor'; t.icon = 'utility:user';
        t.col('name', 'Doctor', false).col('tier', 'Segment', false).col('specialty', 'Specialty', false)
         .col('planned', 'Planned', true).col('done', 'Done', true).col('missed', 'Missed', true)
         .col('ach', 'Ach. %', true).col('last', 'Last call', true);
        for (HcpRow r : rs) t.rows.add(docRow(r));
        return t;
    }
    private static List<HcpRow> byName(List<HcpRow> rs) {
        List<String> keys = new List<String>(); Map<String, HcpRow> m = new Map<String, HcpRow>();
        for (HcpRow r : rs) { String k = (r.name == null ? '' : r.name.toLowerCase()) + '|' + r.id; keys.add(k); m.put(k, r); }
        keys.sort();
        List<HcpRow> out = new List<HcpRow>(); for (String k : keys) out.add(m.get(k)); return out;
    }
    private static final List<String> TIERS = new List<String>{'V3', 'V2', 'V1', 'Unclassified'};
    private static final Map<String, String> TIER_COLOR = new Map<String, String>{'V3' => '#059669', 'V2' => '#4F46E5', 'V1' => '#F59E0B', 'Unclassified' => '#64748B'};

    // group key per dimension
    public static String groupKey(HcpRow r, String dim) {
        if (dim == 'Specialty') return nz(r.specialty, '(No specialty)');
        if (dim == 'Territory') return nz(r.territory, '(No territory)');
        if (dim == 'City') return nz(r.city, '(No city)');
        if (dim == 'Product') return nz(r.product, '(Not detailed)');
        return r.tier;
    }
    private static Map<String, List<HcpRow>> groupRows(List<HcpRow> rs, String dim) {
        Map<String, List<HcpRow>> g = new Map<String, List<HcpRow>>();
        for (HcpRow r : rs) { String k = groupKey(r, dim); if (!g.containsKey(k)) g.put(k, new List<HcpRow>()); g.get(k).add(r); }
        return g;
    }
    /** keys sorted by doctors desc then label asc */
    private static List<String> sortedKeys(Map<String, List<HcpRow>> g) {
        List<String> padded = new List<String>(); Map<String, String> back = new Map<String, String>();
        for (String k : g.keySet()) {
            String p = String.valueOf(1000000 - g.get(k).size()).leftPad(8, '0') + '|' + k.toLowerCase() + '|' + k;
            padded.add(p); back.put(p, k);
        }
        padded.sort();
        List<String> out = new List<String>(); for (String p : padded) out.add(back.get(p)); return out;
    }

    private static List<Date> lastSixMonths() {
        List<Date> m = new List<Date>(); Date first = Date.today().toStartOfMonth();
        for (Integer i = 5; i >= 0; i--) m.add(first.addMonths(-i));
        return m;
    }
    private static String monLabel(Date d) { return MON[d.month() - 1] + ' ' + String.valueOf(d.year()).right(2); }

    /** Coverage % for each of the last 6 months over the given HCPs (ignores the period picker). */
    private static List<Integer> monthlyCoverage(List<HcpRow> rs) {
        List<Date> months = lastSixMonths();
        Set<Id> ids = new Set<Id>(); for (HcpRow r : rs) ids.add(r.id);
        Date fromD = months[0], toD = months[5].addMonths(1).addDays(-1);
        List<Set<Id>> cov = new List<Set<Id>>(); for (Integer i = 0; i < 6; i++) cov.add(new Set<Id>());
        Map<Id, Set<Id>> att = new Map<Id, Set<Id>>();
        Set<Id> attCvrs = new Set<Id>();
        for (CVR_Attendee__c a : [SELECT CVR__c, HCP__c FROM CVR_Attendee__c WHERE HCP__c IN :ids AND CVR__r.Record_Status__c = 'Submitted'
                AND CVR__r.Visit_Date__c >= :fromD AND CVR__r.Visit_Date__c <= :toD AND CVR__r.Parent_Call__c = null WITH USER_MODE]) {
            attCvrs.add(a.CVR__c);
            Set<Id> s = att.get(a.CVR__c); if (s == null) { s = new Set<Id>(); att.put(a.CVR__c, s); } s.add(a.HCP__c);
        }
        for (Call_Visit_Report__c v : [SELECT Id, HCP__c, Visit_Date__c FROM Call_Visit_Report__c WHERE Record_Status__c = 'Submitted'
                AND Visit_Date__c >= :fromD AND Visit_Date__c <= :toD AND Parent_Call__c = null AND (HCP__c IN :ids OR Id IN :attCvrs) WITH USER_MODE]) {
            Integer idx = (v.Visit_Date__c.year() - fromD.year()) * 12 + v.Visit_Date__c.month() - fromD.month();
            if (idx < 0 || idx > 5) continue;
            if (ids.contains(v.HCP__c)) cov[idx].add(v.HCP__c);
            if (att.containsKey(v.Id)) cov[idx].addAll(att.get(v.Id));
        }
        List<Integer> out = new List<Integer>();
        for (Integer i = 0; i < 6; i++) out.add(rs.isEmpty() ? 0 : (Integer) Math.round(100.0 * cov[i].size() / rs.size()));
        return out;
    }

    // ---------- reports ----------
    public static ReportResult getReport(String key, Map<String, Object> params) {
        Date s = Date.valueOf((String) params.get('startDate'));
        Date e = Date.valueOf((String) params.get('endDate'));
        Id rep = idOrNull(params.get('repUserId'));
        setScope(idOrNull(params.get('territoryId')));
        Filters f = parseFilters(params);
        Integer days = s.daysBetween(e) + 1;
        Date ps = s.addDays(-days), pe = s.addDays(-1);

        Ctx cur = buildCtx(s, e, rep);
        List<HcpRow> rs = applyFilters(cur.rows, f);
        List<HcpRow> prs = applyFilters(buildRows(ps, pe, rep), f);

        ReportResult res = new ReportResult();
        res.key = key; res.doctorCount = rs.size();
        res.periodLabel = periodLabel(s, e, (String) params.get('periodName'));

        if (key == 'performance') perf(res, rs, prs);
        else if (key == 'coverage') coverage(res, rs, prs, nz((String) params.get('groupBy'), 'Segment'));
        else if (key == 'frequency') freq(res, rs);
        else if (key == 'missed') missed(res, cur, rs, prs);
        else if (key == 'segment') segment(res, rs);
        else if (key == 'specialty') specialty(res, rs);
        else if (key == 'consent') consent(res, rs);
        else if (key == 'product') product(res, cur, rs);
        else if (key == 'email') email(res, cur, rs, f);
        else if (key == 'omni') omni(res, rs);
        else throw new AuraHandledException('Unknown report: ' + key);
        return res;
    }

    private static void perf(ReportResult res, List<HcpRow> rs, List<HcpRow> prs) {
        res.title = 'Performance Overview';
        Integer cp = covPct(rs), pp = covPct(prs);
        Map<String, List<HcpRow>> g = groupRows(rs, 'Segment');
        String best, worst; Integer bv = -1, wv = 101;
        for (String t : TIERS) {
            if (!g.containsKey(t) || t == 'Unclassified') continue;   // best/worst compares V1-V3 only
            Integer v = covPct(g.get(t));
            if (v > bv) { bv = v; best = t; }
            if (v < wv) { wv = v; worst = t; }
        }
        Integer d = cp - pp;
        res.headline = 'Coverage is ' + cp + '% — ' + (d == 0 ? 'unchanged' : (d > 0 ? 'up ' : 'down ') + Math.abs(d) + ' points') + ' vs the previous period.'
            + (best != null ? ' Best segment: ' + best + ' (' + bv + '%); weakest: ' + worst + ' (' + wv + '%).' : '');
        res.kpis.add(kpi('Doctors', rs.size(), rs.size(), null, false, true));
        res.kpis.add(kpi('Covered', covered(rs), covered(rs), null, false, true));
        res.kpis.add(kpi('Coverage %', cp + '%', cp, pp, true, true));
        res.kpis.add(kpi('Planned calls', sumP(rs), sumP(rs), null, false, true));
        res.kpis.add(kpi('Completed calls', sumC(rs), sumC(rs), sumC(prs), false, true));
        res.kpis.add(kpi('Call achievement %', sumP(rs) == 0 ? '0%' : achievement(sumC(rs), sumP(rs)) + '%', 0, null, false, true));
        Kpi mk = kpi('Missed (prev. ' + sumM(prs) + ')', sumM(rs), 0, null, false, false); res.kpis.add(mk);
        res.kpis.add(kpi('Drafts to submit', sumD(rs), 0, null, false, false));
        Chart c1 = new Chart('Planned vs completed by segment', 'gbar');
        Series sp = new Series('Planned', '#9AA5B1'), sc = new Series('Completed', '#1B5E8C');
        for (String t : TIERS) {
            c1.labels.add(t);
            List<HcpRow> x = g.containsKey(t) ? g.get(t) : new List<HcpRow>();
            sp.values.add(sumP(x)); sc.values.add(sumC(x));
        }
        c1.series.add(sp); c1.series.add(sc); res.charts.add(c1);
        Chart c2 = new Chart('Coverage % — last 6 months', 'line'); c2.maxValue = 100; c2.percent = true;
        Series sl = new Series('Coverage %', '#1B5E8C');
        List<Integer> mc = monthlyCoverage(rs); List<Date> ms = lastSixMonths();
        for (Integer i = 0; i < 6; i++) { c2.labels.add(monLabel(ms[i])); sl.values.add(mc[i]); }
        c2.series.add(sl); res.charts.add(c2);
        res.tables.add(docTable('Doctors · ' + rs.size(), byName(rs)));
    }

    private static void coverage(ReportResult res, List<HcpRow> rs, List<HcpRow> prs, String dim) {
        res.title = 'Call Coverage';
        res.kpis.add(kpi('Coverage %', covPct(rs) + '%', covPct(rs), covPct(prs), true, true));
        res.kpis.add(kpi('Doctors covered', covered(rs) + ' / ' + rs.size(), 0, null, false, true));
        res.kpis.add(kpi('Call achievement %', sumP(rs) == 0 ? '0%' : achievement(sumC(rs), sumP(rs)) + '%', 0, null, false, true));
        res.kpis.add(kpi('Not covered', rs.size() - covered(rs), 0, null, false, false));
        Map<String, List<HcpRow>> g = groupRows(rs, dim);
        Chart ch = new Chart('Coverage % by ' + dim.toLowerCase(), 'hbar'); ch.maxValue = 100; ch.percent = true;
        Series sr = new Series('Coverage %', '#1B5E8C');
        Tbl t = new Tbl('Coverage by ' + dim.toLowerCase()); t.rowAction = 'group'; t.groupDim = dim; t.icon = 'utility:groups';
        t.col('group', dim, false).col('doctors', 'Doctors', true).col('covered', 'Covered', true).col('cov', 'Coverage %', true)
         .col('planned', 'Planned', true).col('completed', 'Completed', true).col('ach', 'Ach. %', true).col('missed', 'Missed', true);
        for (String k : sortedKeys(g)) {
            List<HcpRow> x = g.get(k);
            ch.labels.add(k); sr.values.add(covPct(x));
            t.rows.add(new Map<String, String>{'_group' => k, 'group' => k, 'doctors' => String.valueOf(x.size()), 'covered' => String.valueOf(covered(x)),
                'cov' => covPct(x) + '%', 'planned' => String.valueOf(sumP(x)), 'completed' => String.valueOf(sumC(x)), 'ach' => ach(sumC(x), sumP(x)), 'missed' => String.valueOf(sumM(x))});
        }
        ch.series.add(sr); res.charts.add(ch); res.tables.add(t);
        List<HcpRow> nc = new List<HcpRow>(); for (HcpRow r : byName(rs)) if (r.completed == 0) nc.add(r);
        res.tables.add(docTable('Not covered · ' + nc.size(), nc));
    }

    private static void freq(ReportResult res, List<HcpRow> rs) {
        res.title = 'Call Frequency';
        Integer n = Math.max(1, rs.size());
        Integer below = 0; for (HcpRow r : rs) if (r.planned > 0 && r.completed < r.planned) below++;
        res.kpis.add(new Kpi('Planned per doctor', String.valueOf((Decimal.valueOf(sumP(rs)) / n).setScale(1))));
        res.kpis.add(new Kpi('Calls per doctor', String.valueOf((Decimal.valueOf(sumC(rs)) / n).setScale(1))));
        res.kpis.add(new Kpi('Frequency achievement %', achievement(sumC(rs), sumP(rs)) + '%'));
        res.kpis.add(new Kpi('Doctors below plan', String.valueOf(below)));
        Map<String, List<HcpRow>> g = groupRows(rs, 'Segment');
        Chart ch = new Chart('Frequency achievement % by segment', 'bar'); ch.refLine = 100; ch.percent = true;
        Series sr = new Series('Achievement %', '#2E9E6B'); sr.colors = new List<String>();
        Tbl t = new Tbl('Frequency by segment'); t.rowAction = 'group'; t.groupDim = 'Segment'; t.icon = 'utility:groups';
        t.col('group', 'Segment', false).col('doctors', 'Doctors', true).col('planned', 'Planned', true).col('completed', 'Completed', true)
         .col('pd', 'Plan / doctor', true).col('cd', 'Calls / doctor', true).col('ach', 'Ach. %', true).col('below', 'Below plan', true);
        for (String k : TIERS) {
            List<HcpRow> x = g.containsKey(k) ? g.get(k) : new List<HcpRow>();
            Integer a = achievement(sumC(x), sumP(x)); Integer dn = Math.max(1, x.size());
            Integer bp = 0; for (HcpRow r : x) if (r.planned > 0 && r.completed < r.planned) bp++;
            ch.labels.add(k); sr.values.add(a); sr.colors.add(a >= 80 ? '#2E9E6B' : '#E0A100');
            t.rows.add(new Map<String, String>{'_group' => k, 'group' => k, 'doctors' => String.valueOf(x.size()), 'planned' => String.valueOf(sumP(x)),
                'completed' => String.valueOf(sumC(x)), 'pd' => String.valueOf((Decimal.valueOf(sumP(x)) / dn).setScale(1)),
                'cd' => String.valueOf((Decimal.valueOf(sumC(x)) / dn).setScale(1)), 'ach' => ach(sumC(x), sumP(x)), 'below' => String.valueOf(bp)});
        }
        ch.series.add(sr); res.charts.add(ch); res.tables.add(t);
        List<HcpRow> bl = new List<HcpRow>(); for (HcpRow r : byName(rs)) if (r.planned > 0 && r.completed < r.planned) bl.add(r);
        // sort by gap desc (stable on name order)
        List<String> keys = new List<String>(); Map<String, HcpRow> m = new Map<String, HcpRow>();
        for (HcpRow r : bl) { String k = String.valueOf(100000 - (r.planned - r.completed)).leftPad(8, '0') + '|' + (r.name == null ? '' : r.name.toLowerCase()) + '|' + r.id; keys.add(k); m.put(k, r); }
        keys.sort();
        Tbl bt = docTable('Below plan · ' + bl.size(), new List<HcpRow>());
        bt.col('gap', 'Gap', true);
        for (String k : keys) { HcpRow r = m.get(k); Map<String, String> row = docRow(r); row.put('gap', String.valueOf(r.planned - r.completed)); bt.rows.add(row); }
        res.tables.add(bt);
    }

    private static void missed(ReportResult res, Ctx cur, List<HcpRow> rs, List<HcpRow> prs) {
        res.title = 'Missed Calls';
        res.note = 'Missed = planned, its day has passed, no call report. A saved or draft report counts as done — submit it to count it as completed.';
        Map<Id, HcpRow> byMap = new Map<Id, HcpRow>(); for (HcpRow r : rs) byMap.put(r.id, r);
        List<MissedPlan> ms = new List<MissedPlan>();
        for (MissedPlan m : cur.missedPlans) if (byMap.containsKey(m.hcpId)) ms.add(m);
        // newest plan date first
        List<String> keys = new List<String>(); Map<String, MissedPlan> km = new Map<String, MissedPlan>(); Integer i = 0;
        for (MissedPlan m : ms) { String k = String.valueOf(99999999 - Integer.valueOf(String.valueOf(m.planDate).replace('-', ''))).leftPad(8, '0') + '|' + String.valueOf(i++).leftPad(6, '0'); keys.add(k); km.put(k, m); }
        keys.sort();
        Set<Id> aff = new Set<Id>(); Integer gold = 0; Integer oldest = 0;
        Tbl t = new Tbl('Missed calls'); t.rowAction = 'doctor'; t.icon = 'utility:warning';
        t.col('name', 'Doctor', false).col('hospital', 'Hospital', false).col('tier', 'Segment', false).col('specialty', 'Specialty', false)
         .col('planFor', 'Planned for', true).col('ago', 'Days ago', true).col('note', 'Note', false);
        Map<String, Integer> byTier = new Map<String, Integer>{'V3' => 0, 'V2' => 0, 'V1' => 0, 'Unclassified' => 0};
        for (String k : keys) {
            MissedPlan m = km.get(k); HcpRow r = byMap.get(m.hcpId);
            Integer ago = m.planDate.daysBetween(Date.today());
            aff.add(r.id); if (r.tier == 'V3') gold++; oldest = Math.max(oldest, ago);
            byTier.put(r.tier, byTier.get(r.tier) + 1);
            t.rows.add(new Map<String, String>{'_id' => r.id, 'name' => r.name, 'hospital' => nz(nz(r.hospital, m.hco), '—'), 'tier' => r.tier,
                'specialty' => nz(r.specialty, '—'), 'planFor' => fmtDay(m.planDate), 'ago' => String.valueOf(ago), 'note' => nz(m.note, '—')});
        }
        res.kpis.add(new Kpi('Missed calls', String.valueOf(ms.size())));
        res.kpis.add(new Kpi('Doctors affected', String.valueOf(aff.size())));
        res.kpis.add(new Kpi('V3 missed', String.valueOf(gold)));
        res.kpis.add(new Kpi('Oldest (days)', String.valueOf(oldest)));
        Chart ch = new Chart('Missed calls by segment', 'bar'); Series sr = new Series('Missed', '#D64545');
        for (String tr : TIERS) { ch.labels.add(tr); sr.values.add(byTier.get(tr)); }
        ch.series.add(sr); res.charts.add(ch); res.tables.add(t);
    }

    private static void segment(ReportResult res, List<HcpRow> rs) {
        res.title = 'Segment Analysis';
        res.note = 'Segment = the doctor\'s classification: V3 (visited most), V2, V1. Doctors with no classification are shown as Unclassified.';
        Map<String, List<HcpRow>> g = groupRows(rs, 'Segment');
        Chart ch = new Chart('Coverage and call achievement by segment', 'gbar'); ch.percent = true;
        Series sc = new Series('Coverage %', '#1B5E8C'), sa = new Series('Achievement %', '#2E9E6B');
        Tbl t = new Tbl('Segments'); t.rowAction = 'group'; t.groupDim = 'Segment'; t.icon = 'utility:groups';
        t.col('group', 'Segment', false).col('doctors', 'Doctors', true).col('covered', 'Covered', true).col('cov', 'Coverage %', true)
         .col('planned', 'Planned', true).col('completed', 'Completed', true).col('ach', 'Ach. %', true).col('cd', 'Calls / doctor', true).col('missed', 'Missed', true);
        for (String k : TIERS) {
            List<HcpRow> x = g.containsKey(k) ? g.get(k) : new List<HcpRow>();
            ch.labels.add(k); sc.values.add(covPct(x)); sa.values.add(Math.min(150, achievement(sumC(x), sumP(x))));
            t.rows.add(new Map<String, String>{'_group' => k, 'group' => k, 'doctors' => String.valueOf(x.size()), 'covered' => String.valueOf(covered(x)),
                'cov' => covPct(x) + '%', 'planned' => String.valueOf(sumP(x)), 'completed' => String.valueOf(sumC(x)), 'ach' => ach(sumC(x), sumP(x)),
                'cd' => String.valueOf((Decimal.valueOf(sumC(x)) / Math.max(1, x.size())).setScale(1)), 'missed' => String.valueOf(sumM(x))});
        }
        ch.series.add(sc); ch.series.add(sa); res.charts.add(ch); res.tables.add(t);
    }

    private static void specialty(ReportResult res, List<HcpRow> rs) {
        res.title = 'Specialty Coverage';
        Map<String, List<HcpRow>> g = groupRows(rs, 'Specialty');
        Chart ch = new Chart('Coverage % by specialty', 'hbar'); ch.maxValue = 100; ch.percent = true; Series sr = new Series('Coverage %', '#1B5E8C');
        Tbl t = new Tbl('Specialties'); t.rowAction = 'group'; t.groupDim = 'Specialty'; t.icon = 'utility:groups';
        t.col('group', 'Specialty', false).col('doctors', 'Doctors', true).col('covered', 'Covered', true).col('cov', 'Coverage %', true)
         .col('calls', 'Calls', true).col('cd', 'Calls / doctor', true).col('missed', 'Missed', true);
        for (String k : sortedKeys(g)) {
            List<HcpRow> x = g.get(k); ch.labels.add(k); sr.values.add(covPct(x));
            t.rows.add(new Map<String, String>{'_group' => k, 'group' => k, 'doctors' => String.valueOf(x.size()), 'covered' => String.valueOf(covered(x)), 'cov' => covPct(x) + '%',
                'calls' => String.valueOf(sumC(x)), 'cd' => String.valueOf((Decimal.valueOf(sumC(x)) / Math.max(1, x.size())).setScale(1)), 'missed' => String.valueOf(sumM(x))});
        }
        ch.series.add(sr); res.charts.add(ch); res.tables.add(t);
        Integer reached = 0; for (String k : g.keySet()) if (covered(g.get(k)) > 0) reached++;
        res.headline = reached + ' specialties reached';
    }

    private static void consent(ReportResult res, List<HcpRow> rs) {
        res.title = 'Consent Status';
        res.note = 'Consent is today\'s status (not limited to the period). The trend counts consents captured each month.';
        Integer cap = 0, pen = 0, exp = 0;
        for (HcpRow r : rs) { if (r.consent == 'Captured') cap++; else if (r.consent == 'Expired') exp++; else pen++; }
        res.kpis.add(new Kpi('Captured %', pct(cap, rs.size()) + '%'));
        res.kpis.add(new Kpi('Doctors with consent', String.valueOf(cap)));
        res.kpis.add(new Kpi('Pending', String.valueOf(pen)));
        res.kpis.add(new Kpi('Expired', String.valueOf(exp)));
        List<Date> ms = lastSixMonths(); Set<Id> ids = new Set<Id>(); for (HcpRow r : rs) ids.add(r.id);
        List<Decimal> cnt = new List<Decimal>{0, 0, 0, 0, 0, 0};
        Datetime fromDT = dayStart(ms[0]), toDT = dayStart(ms[5].addMonths(1));
        for (Consent__c k : [SELECT Captured_At__c FROM Consent__c WHERE HCP__c IN :ids AND Captured_At__c >= :fromDT AND Captured_At__c < :toDT WITH USER_MODE]) {
            Date d = toDate(k.Captured_At__c); Integer idx = (d.year() - ms[0].year()) * 12 + d.month() - ms[0].month();
            if (idx >= 0 && idx <= 5) cnt[idx]++;
        }
        Chart ch = new Chart('Consents captured — last 6 months', 'bar'); Series sr = new Series('Consents', '#1B5E8C');
        for (Integer i = 0; i < 6; i++) { ch.labels.add(monLabel(ms[i])); sr.values.add(cnt[i]); }
        ch.series.add(sr); res.charts.add(ch);
        Map<String, List<HcpRow>> g = groupRows(rs, 'Territory');
        List<String> keys = new List<String>(g.keySet()); keys.sort();
        Tbl t = new Tbl('Consent by territory'); t.rowAction = 'group'; t.groupDim = 'Territory'; t.icon = 'utility:groups';
        t.col('group', 'Territory', false).col('doctors', 'Doctors', true).col('captured', 'Captured', true).col('pending', 'Pending', true)
         .col('expired', 'Expired', true).col('pct', 'Captured %', true);
        for (String k : keys) {
            Integer a = 0, b = 0, d = 0; for (HcpRow r : g.get(k)) { if (r.consent == 'Captured') a++; else if (r.consent == 'Expired') d++; else b++; }
            t.rows.add(new Map<String, String>{'_group' => k, 'group' => k, 'doctors' => String.valueOf(g.get(k).size()), 'captured' => String.valueOf(a),
                'pending' => String.valueOf(b), 'expired' => String.valueOf(d), 'pct' => pct(a, g.get(k).size()) + '%'});
        }
        res.tables.add(t);
        List<HcpRow> pe = new List<HcpRow>();
        for (HcpRow r : byName(rs)) if (r.consent == 'Pending') pe.add(r);
        for (HcpRow r : byName(rs)) if (r.consent == 'Expired') pe.add(r);
        Tbl pt = docTable('Consent pending or expired · ' + pe.size(), new List<HcpRow>()); pt.col('consent', 'Consent', false);
        for (HcpRow r : pe) { Map<String, String> row = docRow(r); row.put('consent', r.consent); pt.rows.add(row); }
        res.tables.add(pt);
    }

    private static void product(ReportResult res, Ctx cur, List<HcpRow> rs) {
        res.title = 'Product Detailing';
        res.note = 'A product counts on a call when it is in the call\'s Detailing Priority (or, for older calls, its key messages).';
        Set<Id> inSet = new Set<Id>(); for (HcpRow r : rs) inSet.add(r.id);
        Map<String, Integer> calls = new Map<String, Integer>(), subs = new Map<String, Integer>();
        Integer withProduct = 0;
        for (Id cv : cur.cvrProducts.keySet()) {
            Boolean mine = false; for (Id h : cur.cvrHcps.get(cv)) if (inSet.contains(h)) { mine = true; break; }
            if (!mine) continue;
            withProduct++;
            for (String p : cur.cvrProducts.get(cv)) {
                calls.put(p, (calls.containsKey(p) ? calls.get(p) : 0) + 1);
                if (cur.cvrStatus.get(cv) == 'Submitted') subs.put(p, (subs.containsKey(p) ? subs.get(p) : 0) + 1);
            }
        }
        Map<String, Integer> docs = new Map<String, Integer>(); Integer detailed = 0;
        for (HcpRow r : rs) { if (!r.products.isEmpty()) detailed++; for (String p : r.products) docs.put(p, (docs.containsKey(p) ? docs.get(p) : 0) + 1); }
        List<String> keys = new List<String>(); Map<String, String> back = new Map<String, String>();
        for (String p : calls.keySet()) { String k = String.valueOf(1000000 - calls.get(p)).leftPad(8, '0') + '|' + p.toLowerCase(); keys.add(k); back.put(k, p); }
        keys.sort();
        res.kpis.add(new Kpi('Products detailed', String.valueOf(calls.size())));
        res.kpis.add(new Kpi('Calls with a product', String.valueOf(withProduct)));
        res.kpis.add(new Kpi('Doctors detailed', String.valueOf(detailed)));
        res.kpis.add(new Kpi('Most detailed', keys.isEmpty() ? '—' : back.get(keys[0])));
        Chart ch = new Chart('Calls by product', 'bar'); Series sr = new Series('Calls', '#1B5E8C');
        Tbl t = new Tbl('Products'); t.rowAction = 'group'; t.groupDim = 'ProductAny'; t.icon = 'utility:products';
        // TODO (CLM): add 'CLM minutes' column once Presentation_Session__c syncs.
        t.col('group', 'Product', false).col('calls', 'Calls', true).col('sub', 'Submitted', true).col('docs', 'Doctors', true).col('share', 'Share of doctors', true);
        for (String k : keys) {
            String p = back.get(k); ch.labels.add(p); sr.values.add(calls.get(p));
            Integer d = docs.containsKey(p) ? docs.get(p) : 0;
            t.rows.add(new Map<String, String>{'_group' => p, 'group' => p, 'calls' => String.valueOf(calls.get(p)), 'sub' => String.valueOf(subs.containsKey(p) ? subs.get(p) : 0),
                'docs' => String.valueOf(d), 'share' => pct(d, rs.size()) + '%'});
        }
        ch.series.add(sr); res.charts.add(ch); res.tables.add(t);
    }

    private static void email(ReportResult res, Ctx cur, List<HcpRow> rs, Filters f) {
        res.title = 'Approved Email';
        res.note = 'Delivery status comes from Salesforce. Opens and clicks aren\'t tracked for approved email.';
        Set<Id> inSet = new Set<Id>(); for (HcpRow r : rs) inSet.add(r.id);
        Integer sent = 0, del = 0, fail = 0, que = 0; Set<Id> emailed = new Set<Id>();
        Map<String, Integer[]> tpl = new Map<String, Integer[]>(); Map<String, Set<Id>> tpd = new Map<String, Set<Id>>();
        for (EmailRec e : cur.emails) {
            if (!inSet.contains(e.hcpId)) continue;
            sent++; emailed.add(e.hcpId);
            if (e.status == 'Sent') del++; else if (e.status == 'Failed') fail++; else if (e.status == 'Queued') que++;
            if (!tpl.containsKey(e.template)) { tpl.put(e.template, new Integer[]{0, 0, 0}); tpd.put(e.template, new Set<Id>()); }
            Integer[] a = tpl.get(e.template); a[0]++; if (e.status == 'Sent') a[1]++; if (e.status == 'Failed') a[2]++;
            tpd.get(e.template).add(e.hcpId);
        }
        res.kpis.add(new Kpi('Sent', String.valueOf(sent)));
        res.kpis.add(new Kpi('Delivered', String.valueOf(del)));
        res.kpis.add(new Kpi('Delivery rate', pct(del, sent) + '%'));
        res.kpis.add(new Kpi('Failed', String.valueOf(fail)));
        res.kpis.add(new Kpi('Queued', String.valueOf(que)));
        res.kpis.add(new Kpi('Doctors emailed', String.valueOf(emailed.size())));
        // last 6 months (ignores period picker, honours filters)
        List<Date> ms = lastSixMonths(); Datetime fromDT = dayStart(ms[0]), toDT = dayStart(ms[5].addMonths(1));
        List<Decimal> cnt = new List<Decimal>{0, 0, 0, 0, 0, 0};
        for (Sent_Email__c e : [SELECT Sent_At__c, CreatedDate FROM Sent_Email__c WHERE HCP__c IN :inSet AND Folder__c = 'Sent'
                AND ((Sent_At__c >= :fromDT AND Sent_At__c < :toDT) OR (Sent_At__c = null AND CreatedDate >= :fromDT AND CreatedDate < :toDT)) WITH USER_MODE]) {
            Date d = toDate(e.Sent_At__c != null ? e.Sent_At__c : e.CreatedDate); Integer idx = (d.year() - ms[0].year()) * 12 + d.month() - ms[0].month();
            if (idx >= 0 && idx <= 5) cnt[idx]++;
        }
        Chart ch = new Chart('Emails sent — last 6 months', 'bar'); Series sr = new Series('Sent', '#1B5E8C');
        for (Integer i = 0; i < 6; i++) { ch.labels.add(monLabel(ms[i])); sr.values.add(cnt[i]); }
        ch.series.add(sr); res.charts.add(ch);
        List<String> keys = new List<String>(); Map<String, String> back = new Map<String, String>();
        for (String k : tpl.keySet()) { String kk = String.valueOf(1000000 - tpl.get(k)[0]).leftPad(8, '0') + '|' + k.toLowerCase(); keys.add(kk); back.put(kk, k); }
        keys.sort();
        Tbl t = new Tbl('By template'); t.icon = 'utility:email';
        t.col('group', 'Template', false).col('sent', 'Sent', true).col('del', 'Delivered', true).col('fail', 'Failed', true).col('docs', 'Doctors', true);
        for (String kk : keys) { String k = back.get(kk); Integer[] a = tpl.get(k);
            t.rows.add(new Map<String, String>{'group' => k, 'sent' => String.valueOf(a[0]), 'del' => String.valueOf(a[1]), 'fail' => String.valueOf(a[2]), 'docs' => String.valueOf(tpd.get(k).size())}); }
        res.tables.add(t);
        List<HcpRow> em = new List<HcpRow>(); for (HcpRow r : byName(rs)) if (r.emailsSent > 0) em.add(r);
        List<String> ek = new List<String>(); Map<String, HcpRow> emap = new Map<String, HcpRow>();
        for (HcpRow r : em) { String k = String.valueOf(100000 - r.emailsSent).leftPad(8, '0') + '|' + (r.name == null ? '' : r.name.toLowerCase()) + '|' + r.id; ek.add(k); emap.put(k, r); }
        ek.sort();
        Tbl dt = docTable('Doctors emailed · ' + em.size(), new List<HcpRow>()); dt.col('emails', 'Emails', true).col('failed', 'Failed', true);
        for (String k : ek) { HcpRow r = emap.get(k); Map<String, String> row = docRow(r); row.put('emails', String.valueOf(r.emailsSent)); row.put('failed', String.valueOf(r.emailsFailed)); dt.rows.add(row); }
        res.tables.add(dt);
    }

    private static Integer channels(HcpRow r) {
        return (r.completed > 0 ? 1 : 0) + (r.clmSessions > 0 ? 1 : 0) + (r.emailsSent > 0 ? 1 : 0) + (r.samples > 0 ? 1 : 0);
    }
    private static void omni(ReportResult res, List<HcpRow> rs) {
        res.title = 'Omnichannel Engagement';
        Integer eng = 0, two = 0, calls = 0, clm = 0, em = 0, sm = 0; List<Decimal> dist = new List<Decimal>{0, 0, 0, 0, 0};
        for (HcpRow r : rs) { Integer c = channels(r); dist[c]++; if (c >= 1) eng++; if (c >= 2) two++; calls += r.completed; clm += r.clmSessions; em += r.emailsSent; sm += r.samples; }
        res.kpis.add(new Kpi('Doctors engaged %', pct(eng, rs.size()) + '%'));
        res.kpis.add(new Kpi('2+ channels', String.valueOf(two)));
        res.kpis.add(new Kpi('Calls', String.valueOf(calls)));
        res.kpis.add(new Kpi('CLM', String.valueOf(clm)));
        res.kpis.add(new Kpi('Emails', String.valueOf(em)));
        res.kpis.add(new Kpi('Sample packs', String.valueOf(sm)));
        Chart c1 = new Chart('Touchpoints by channel', 'bar'); Series s1 = new Series('Touchpoints', '#1B5E8C');
        c1.labels.addAll(new List<String>{'Calls', 'CLM', 'Email', 'Sample packs'}); s1.values.addAll(new List<Decimal>{calls, clm, em, sm});
        c1.series.add(s1); res.charts.add(c1);
        Chart c2 = new Chart('Doctors by number of channels', 'bar'); Series s2 = new Series('Doctors', '#2E9E6B');
        c2.labels.addAll(new List<String>{'0 channels', '1 channel', '2 channels', '3 channels', '4 channels'}); s2.values.addAll(dist);
        c2.series.add(s2); res.charts.add(c2);
        List<String> keys = new List<String>(); Map<String, HcpRow> m = new Map<String, HcpRow>();
        for (HcpRow r : rs) { String k = String.valueOf(10 - channels(r)) + '|' + (r.name == null ? '' : r.name.toLowerCase()) + '|' + r.id; keys.add(k); m.put(k, r); }
        keys.sort();
        Tbl t = docTable('Engagement by doctor', new List<HcpRow>()); t.col('clm', 'CLM', true).col('emails', 'Emails', true).col('samples', 'Samples', true).col('channels', 'Channels', true);
        for (String k : keys) { HcpRow r = m.get(k); Map<String, String> row = docRow(r);
            row.put('clm', String.valueOf(r.clmSessions)); row.put('emails', String.valueOf(r.emailsSent)); row.put('samples', String.valueOf(r.samples)); row.put('channels', String.valueOf(channels(r))); t.rows.add(row); }
        res.tables.add(t);
    }


    // ---------- library card headline numbers (current period, no filters) ----------
    public static Map<String, String> getLibrary(Date s, Date e, Id rep, Id terr) {
        setScope(terr);
        Ctx c = buildCtx(s, e, rep);
        List<HcpRow> rs = c.rows;
        Map<String, String> m = new Map<String, String>();
        Integer cp = covPct(rs);
        m.put('performance', cp + '%'); m.put('coverage', cp + '%');
        m.put('frequency', sumP(rs) == 0 ? '0%' : achievement(sumC(rs), sumP(rs)) + '%');
        m.put('missed', String.valueOf(sumM(rs)));
        List<HcpRow> gold = new List<HcpRow>(); for (HcpRow r : rs) if (r.tier == 'V3') gold.add(r);
        m.put('segment', covPct(gold) + '%');
        Set<String> sp = new Set<String>(); for (HcpRow r : rs) if (r.completed > 0 && String.isNotBlank(r.specialty)) sp.add(r.specialty);
        m.put('specialty', String.valueOf(sp.size()));
        Integer cap = 0; for (HcpRow r : rs) if (r.consent == 'Captured') cap++;
        m.put('consent', pct(cap, rs.size()) + '%');
        Set<String> pr = new Set<String>(); for (HcpRow r : rs) pr.addAll(r.products);
        m.put('product', String.valueOf(pr.size()));
        m.put('email', String.valueOf(c.emails.size()));
        Integer eng = 0; for (HcpRow r : rs) if (channels(r) >= 1) eng++;
        m.put('omni', pct(eng, rs.size()) + '%');
        return m;
    }

    // ---------- drill ----------
    /** Level 2: doctors in a group. dim 'ProductAny' matches any detailed product. */
    public static List<HcpRow> groupDoctors(Map<String, Object> params, String dim, String value) {
        Date s = Date.valueOf((String) params.get('startDate')); Date e = Date.valueOf((String) params.get('endDate'));
        Id rep = idOrNull(params.get('repUserId'));
        setScope(idOrNull(params.get('territoryId')));
        List<HcpRow> rs = applyFilters(buildRows(s, e, rep), parseFilters(params));
        List<HcpRow> out = new List<HcpRow>();
        for (HcpRow r : rs) {
            Boolean match = dim == 'ProductAny' ? r.products.contains(value) : groupKey(r, dim) == value;
            if (match) out.add(r);
        }
        return byName(out);
    }

    public class HcpDetail {
        @AuraEnabled public HcpRow row;
        @AuraEnabled public List<Map<String, String>> calls = new List<Map<String, String>>();
        @AuraEnabled public List<Map<String, String>> plans = new List<Map<String, String>>();
        @AuraEnabled public List<Map<String, String>> emails = new List<Map<String, String>>();
    }
    public static HcpDetail getHcpDetail(Id hcpId, Date startDate, Date endDate, Id rep, Id terr) {
        setScope(terr);
        Ctx c = buildCtx(startDate, endDate, rep);
        HcpDetail d = new HcpDetail();
        for (HcpRow r : c.rows) if (r.id == hcpId) d.row = r;
        if (d.row == null) {
            // manager viewing a doctor outside their default scope still resolved by buildCtx(null); otherwise not visible
            throw new AuraHandledException('Doctor not found in your scope.');
        }
        for (Id cv : c.cvrHcps.keySet()) {
            if (!c.cvrHcps.get(cv).contains(hcpId)) continue;
            Set<String> pr = c.cvrProducts.get(cv);
            List<String> pn = pr == null ? new List<String>() : new List<String>(pr); pn.sort();
            d.calls.add(new Map<String, String>{'date' => c.cvrDate.get(cv).format(), 'status' => c.cvrStatus.get(cv), 'products' => pn.isEmpty() ? '—' : String.join(pn, ', '), 'sort' => String.valueOf(c.cvrDate.get(cv))});
        }
        if (c.planDetail.containsKey(hcpId)) d.plans = c.planDetail.get(hcpId);
        for (EmailRec e : c.emails) if (e.hcpId == hcpId) d.emails.add(new Map<String, String>{'date' => e.sentAt.format('d MMM yyyy'), 'template' => e.template, 'status' => e.status});
        return d;
    }

    // ---------- Sales ----------
    private static String inr(Decimal v) {
        if (v == null) v = 0;
        Long n = (Long) Math.round(v);
        String s = String.valueOf(Math.abs(n)); String out;
        if (s.length() <= 3) out = s;
        else { String last3 = s.right(3), rest = s.substring(0, s.length() - 3); List<String> parts = new List<String>();
            while (rest.length() > 2) { parts.add(0, rest.right(2)); rest = rest.substring(0, rest.length() - 2); }
            if (rest.length() > 0) parts.add(0, rest); out = String.join(parts, ',') + ',' + last3; }
        return (n < 0 ? '-' : '') + '₹' + out;
    }
    private static String periodLabelYM(String p) {
        if (String.isBlank(p) || p.length() < 7) return p;
        return MON[Integer.valueOf(p.substring(5, 7)) - 1] + ' \'' + p.substring(2, 4);
    }
    private class SkuAgg { String name; String brand; Decimal price = 0; Decimal pu = 0; Decimal su = 0; Decimal tu = 0; }

    public static ReportResult getSales(Map<String, Object> params) {
        String view = nz((String) params.get('view'), 'primary');
        String grpBy = nz((String) params.get('by'), 'sku');
        String month = (String) params.get('month');
        String brand = (String) params.get('brand');
        ReportResult res = new ReportResult(); res.key = 'sales'; res.title = 'Sales';
        List<Sales_Transaction__c> all = [SELECT Period__c, Primary_Units__c, Secondary_Units__c, Product__c, Product__r.Name, Product__r.Brand_Name__c,
                Product__r.Unit_Value_Per_Strip__c, Stockist__c, Stockist__r.Name FROM Sales_Transaction__c WITH USER_MODE LIMIT 50000];
        Set<String> pset = new Set<String>(); for (Sales_Transaction__c t : all) if (t.Period__c != null) pset.add(t.Period__c);
        List<String> periods = new List<String>(pset); periods.sort();
        while (periods.size() > 24) periods.remove(0);
        res.monthOptions = periods;
        Set<String> brands = new Set<String>(); for (Sales_Transaction__c t : all) if (t.Product__r.Brand_Name__c != null) brands.add(t.Product__r.Brand_Name__c);
        res.brandOptions = new List<String>(brands); res.brandOptions.sort();
        if (all.isEmpty()) { res.noData = true; res.note = 'No Sales data loaded yet'; return res; }
        List<Sales_Target__c> targets = [SELECT Period__c, Product__c, Product__r.Name, Product__r.Unit_Value_Per_Strip__c, Target_Units__c FROM Sales_Target__c
                WHERE Territory__c = null WITH USER_MODE LIMIT 50000];
        Boolean oneMonth = String.isNotBlank(month);

        // per SKU / stockist / period aggregates
        Map<Id, SkuAgg> sku = new Map<Id, SkuAgg>(); Map<String, SkuAgg> stk = new Map<String, SkuAgg>();
        Map<String, Decimal[]> trend = new Map<String, Decimal[]>();
        for (Sales_Transaction__c t : all) {
            Decimal price = t.Product__r.Unit_Value_Per_Strip__c == null ? 0 : t.Product__r.Unit_Value_Per_Strip__c;
            Decimal pu = t.Primary_Units__c == null ? 0 : t.Primary_Units__c, su = t.Secondary_Units__c == null ? 0 : t.Secondary_Units__c;
            if (view == 'trend') {
                if (String.isNotBlank(brand) && brand != t.Product__r.Brand_Name__c) continue;
                if (!trend.containsKey(t.Period__c)) trend.put(t.Period__c, new Decimal[]{0, 0});
                trend.get(t.Period__c)[0] += pu * price; trend.get(t.Period__c)[1] += su * price;
                continue;
            }
            if (oneMonth && t.Period__c != month) continue;
            SkuAgg a = sku.get(t.Product__c); if (a == null) { a = new SkuAgg(); a.name = t.Product__r.Name; a.price = price; sku.put(t.Product__c, a); }
            a.pu += pu; a.su += su;
            String sk = t.Stockist__c == null ? '(No stockist)' : t.Stockist__r.Name;
            SkuAgg b = stk.get(sk); if (b == null) { b = new SkuAgg(); b.name = sk; stk.put(sk, b); }
            b.pu += pu * price; b.su += su * price; b.tu += pu; // tu reused: units (primary) -- value accumulates in pu/su
        }
        Decimal totalTarget = 0; Map<Id, Decimal> skuTarget = new Map<Id, Decimal>();
        for (Sales_Target__c t : targets) {
            if (oneMonth && t.Period__c != month) continue;
            Decimal price = t.Product__r.Unit_Value_Per_Strip__c == null ? 0 : t.Product__r.Unit_Value_Per_Strip__c;
            Decimal v = (t.Target_Units__c == null ? 0 : t.Target_Units__c) * price;
            skuTarget.put(t.Product__c, (skuTarget.containsKey(t.Product__c) ? skuTarget.get(t.Product__c) : 0) + v);
            totalTarget += v;
            if (!sku.containsKey(t.Product__c) && view != 'trend') { SkuAgg a = new SkuAgg(); a.name = t.Product__r.Name; a.price = price; sku.put(t.Product__c, a); }
        }

        if (view == 'trend') {
            res.title = 'Trend'; Chart ch = new Chart('Primary vs secondary value', 'line');
            Series sp = new Series('Primary', '#1B5E8C'), ss = new Series('Secondary', '#2E9E6B');
            Tbl t = new Tbl('Monthly Trend (₹)'); t.icon = 'utility:trend'; t.col('group', 'Month', false).col('p', 'Primary', true).col('s', 'Secondary', true).col('fill', 'Channel Fill %', true);
            for (String p : periods) {
                if (!trend.containsKey(p)) continue;
                Decimal[] v = trend.get(p); ch.labels.add(periodLabelYM(p)); sp.values.add(v[0]); ss.values.add(v[1]);
                t.rows.add(new Map<String, String>{'group' => periodLabelYM(p), 'p' => inr(v[0]), 's' => inr(v[1]), 'fill' => (v[0] == 0 ? 0 : (Integer) Math.round(v[1] / v[0] * 100)) + '%'});
            }
            ch.series.add(sp); ch.series.add(ss); res.charts.add(ch); res.tables.add(t);
            res.note = 'Channel Fill % = Secondary ÷ Primary. Sustained fill below 100% means stock is building in the channel.';
            return res;
        }

        Decimal pv = 0, sv = 0, pun = 0, sun = 0;
        for (SkuAgg a : sku.values()) { pv += a.pu * a.price; sv += a.su * a.price; pun += a.pu; sun += a.su; }
        Integer achTot = totalTarget == 0 ? 0 : (Integer) Math.round(pv / totalTarget * 100);

        if (view == 'achievement') {
            res.title = 'Achievement';
            res.kpis.add(new Kpi('Primary (Actual)', inr(pv))); res.kpis.add(new Kpi('Target', inr(totalTarget)));
            Kpi ak = new Kpi('Achievement %', achTot + '%'); ak.tone = achTot >= 80 ? 'good' : 'warn'; res.kpis.add(ak);
            Chart ch = new Chart('% Achievement by SKU (Target vs Primary)', 'hbar'); ch.refLine = 100; ch.percent = true;
            Series sr = new Series('Achievement %', '#2E9E6B'); sr.colors = new List<String>();
            Tbl t = new Tbl('Achievement — SKU-wise'); t.icon = 'utility:target'; t.col('group', 'SKU', false).col('p', 'Primary Value', true).col('t', 'Target Value', true).col('a', 'Ach %', true);
            for (Id id : sortedIds(sku)) { SkuAgg a = sku.get(id); Decimal tv = skuTarget.containsKey(id) ? skuTarget.get(id) : 0; Decimal p = a.pu * a.price;
                Integer ac = tv == 0 ? 0 : (Integer) Math.round(p / tv * 100);
                ch.labels.add(a.name); sr.values.add(ac); sr.colors.add(ac >= 80 ? '#2E9E6B' : '#E0A100');
                t.rows.add(new Map<String, String>{'group' => a.name, 'p' => inr(p), 't' => inr(tv), 'a' => ac + '%'}); }
            ch.series.add(sr); res.charts.add(ch); res.tables.add(t); return res;
        }

        Boolean primary = view != 'secondary';
        res.title = primary ? 'Primary Sales' : 'Secondary Sales';
        res.kpis.add(new Kpi(primary ? 'Primary Value' : 'Secondary Value', inr(primary ? pv : sv)));
        res.kpis.add(new Kpi('Primary Units', String.valueOf((Long) pun))); res.kpis.add(new Kpi('Secondary Units', String.valueOf((Long) sun)));
        res.kpis.add(new Kpi('Achievement %', achTot + '%'));
        Chart ch = new Chart('Value by ' + (grpBy == 'stockist' ? 'stockist' : 'SKU'), 'hbar'); Series sr = new Series('Value', '#1B5E8C');
        Tbl t = new Tbl(grpBy == 'stockist' ? 'By stockist' : 'By SKU'); t.icon = 'utility:moneybag'; t.rowAction = 'salesdrill'; t.groupDim = grpBy;
        t.col('group', grpBy == 'stockist' ? 'Stockist' : 'SKU', false).col('pu', 'Primary units', true).col('su', 'Secondary units', true).col('val', primary ? 'Primary value' : 'Secondary value', true)
         .col('tv', 'Target value', true).col('a', 'Ach %', true);
        if (grpBy == 'stockist') {
            Integer n = Math.max(1, stk.size()); Decimal tper = totalTarget / n;
            Map<String, Decimal> unitsP = new Map<String, Decimal>();
            List<String> names = new List<String>(stk.keySet()); names.sort();
            names.sort(); // sort by value desc below
            List<String> keys = new List<String>(); Map<String, String> back = new Map<String, String>();
            for (String nme : names) { Decimal v = primary ? stk.get(nme).pu : stk.get(nme).su; String k = String.valueOf((Long) (10000000000L - (Long) v)).leftPad(12, '0') + '|' + nme; keys.add(k); back.put(k, nme); }
            keys.sort();
            for (String k : keys) { String nme = back.get(k); SkuAgg b = stk.get(nme); Decimal v = primary ? b.pu : b.su;
                Integer ac = tper == 0 ? 0 : (Integer) Math.round(b.pu / tper * 100);
                ch.labels.add(nme); sr.values.add(v);
                t.rows.add(new Map<String, String>{'_group' => nme, 'group' => nme, 'pu' => '—', 'su' => '—', 'val' => inr(v), 'tv' => inr(tper), 'a' => ac + '%'}); }
        } else {
            for (Id id : sortedIds(sku)) { SkuAgg a = sku.get(id); Decimal v = (primary ? a.pu : a.su) * a.price;
                Decimal tv = skuTarget.containsKey(id) ? skuTarget.get(id) : 0; Integer ac = tv == 0 ? 0 : (Integer) Math.round(a.pu * a.price / tv * 100);
                ch.labels.add(a.name); sr.values.add(v);
                t.rows.add(new Map<String, String>{'_group' => String.valueOf(id), 'group' => a.name, 'pu' => String.valueOf((Long) a.pu), 'su' => String.valueOf((Long) a.su), 'val' => inr(v), 'tv' => inr(tv), 'a' => ac + '%'}); }
        }
        ch.series.add(sr); res.charts.add(ch); res.tables.add(t);
        return res;
    }
    private static List<Id> sortedIds(Map<Id, SkuAgg> m) {
        List<String> keys = new List<String>(); Map<String, Id> back = new Map<String, Id>();
        for (Id id : m.keySet()) { SkuAgg a = m.get(id); Decimal v = a.pu * a.price; String k = String.valueOf((Long) (10000000000L - (Long) v)).leftPad(12, '0') + '|' + a.name + '|' + id; keys.add(k); back.put(k, id); }
        keys.sort(); List<Id> out = new List<Id>(); for (String k : keys) out.add(back.get(k)); return out;
    }

    /** Drill: a SKU -> its months; a stockist -> its SKUs. */
    public static Tbl getSalesDrill(Map<String, Object> params, String key) {
        String grpBy = nz((String) params.get('by'), 'sku');
        Tbl t = new Tbl(grpBy == 'stockist' ? 'SKUs for ' + key : 'Months');
        t.col('group', grpBy == 'stockist' ? 'SKU' : 'Month', false).col('pu', 'Primary units', true).col('su', 'Secondary units', true).col('val', 'Primary value', true);
        Map<String, Decimal[]> agg = new Map<String, Decimal[]>();
        for (Sales_Transaction__c s : [SELECT Period__c, Primary_Units__c, Secondary_Units__c, Product__c, Product__r.Name, Product__r.Unit_Value_Per_Strip__c, Stockist__r.Name
                FROM Sales_Transaction__c WITH USER_MODE LIMIT 50000]) {
            Decimal price = s.Product__r.Unit_Value_Per_Strip__c == null ? 0 : s.Product__r.Unit_Value_Per_Strip__c;
            String g;
            if (grpBy == 'stockist') { if ((s.Stockist__r == null ? '(No stockist)' : s.Stockist__r.Name) != key) continue; g = s.Product__r.Name; }
            else { if (String.valueOf(s.Product__c) != key) continue; g = s.Period__c; }
            if (!agg.containsKey(g)) agg.put(g, new Decimal[]{0, 0, 0});
            Decimal[] a = agg.get(g); a[0] += s.Primary_Units__c == null ? 0 : s.Primary_Units__c; a[1] += s.Secondary_Units__c == null ? 0 : s.Secondary_Units__c; a[2] += (s.Primary_Units__c == null ? 0 : s.Primary_Units__c) * price;
        }
        List<String> ks = new List<String>(agg.keySet()); ks.sort();
        for (String g : ks) { Decimal[] a = agg.get(g);
            t.rows.add(new Map<String, String>{'group' => grpBy == 'stockist' ? g : periodLabelYM(g), 'pu' => String.valueOf((Long) a[0]), 'su' => String.valueOf((Long) a[1]), 'val' => inr(a[2])}); }
        return t;
    }

    // ---------- Samples ----------
    public static ReportResult getSamples(Map<String, Object> params) {
        Date s = Date.valueOf((String) params.get('startDate')); Date e = Date.valueOf((String) params.get('endDate'));
        Id rep = idOrNull(params.get('repUserId'));
        setScope(idOrNull(params.get('territoryId')));
        Ctx c = buildCtx(s, e, rep);
        ReportResult res = new ReportResult(); res.key = 'samples'; res.title = 'Samples';
        res.periodLabel = periodLabel(s, e, (String) params.get('periodName'));
        Set<Id> subs = new Set<Id>(); for (Id cv : c.cvrStatus.keySet()) if (c.cvrStatus.get(cv) == 'Submitted') subs.add(cv);
        Map<String, Integer> byProd = new Map<String, Integer>(); Map<Id, Integer> byDoc = new Map<Id, Integer>(); Integer total = 0;
        for (Sample_Drop__c d : [SELECT CVR__c, Qty__c, Product__r.Name FROM Sample_Drop__c WHERE CVR__c IN :subs WITH USER_MODE]) {
            Integer q = d.Qty__c == null ? 0 : (Integer) d.Qty__c; total += q;
            String pn = nz(d.Product__r.Name, '(No product)'); byProd.put(pn, (byProd.containsKey(pn) ? byProd.get(pn) : 0) + q);
            for (Id h : c.cvrHcps.get(d.CVR__c)) byDoc.put(h, (byDoc.containsKey(h) ? byDoc.get(h) : 0) + q);
        }
        res.kpis.add(new Kpi('Total packs', String.valueOf(total))); res.kpis.add(new Kpi('Products', String.valueOf(byProd.size()))); res.kpis.add(new Kpi('Doctors sampled', String.valueOf(byDoc.size())));
        Tbl tp = new Tbl('Packs by product'); tp.icon = 'utility:products'; tp.col('group', 'Product', false).col('qty', 'Packs', true);
        List<String> ks = new List<String>(); Map<String, String> back = new Map<String, String>();
        for (String p : byProd.keySet()) { String k = String.valueOf(1000000 - byProd.get(p)).leftPad(8, '0') + '|' + p; ks.add(k); back.put(k, p); } ks.sort();
        for (String k : ks) tp.rows.add(new Map<String, String>{'group' => back.get(k), 'qty' => String.valueOf(byProd.get(back.get(k)))});
        Tbl td = new Tbl('Packs by doctor'); td.icon = 'utility:user'; td.col('group', 'Doctor', false).col('qty', 'Packs', true);
        Map<Id, String> names = new Map<Id, String>(); for (HcpRow r : c.rows) names.put(r.id, r.name);
        for (Id h : byDoc.keySet()) td.rows.add(new Map<String, String>{'_id' => h, 'group' => names.get(h), 'qty' => String.valueOf(byDoc.get(h))});
        td.rowAction = 'doctor';
        res.tables.add(tp); res.tables.add(td);
        res.note = 'Yearly sample limits are not available in Salesforce, so no limit warnings are shown.';
        return res;
    }

    // ---------- filter option values ----------
    public class FilterOptions {
        @AuraEnabled public List<String> specialties = new List<String>();
        @AuraEnabled public List<String> territories = new List<String>();
        @AuraEnabled public List<String> cities = new List<String>();
        @AuraEnabled public List<String> products = new List<String>();
        @AuraEnabled public Boolean isManager = false;
    }
    public static FilterOptions getFilterOptions(Date s, Date e, Id rep, Id terr) {
        setScope(terr);
        Ctx c = buildCtx(s, e, rep);
        FilterOptions o = new FilterOptions(); o.isManager = isManager();
        Set<String> sp = new Set<String>(), te = new Set<String>(), ci = new Set<String>(), pr = new Set<String>();
        for (HcpRow r : c.rows) { if (r.specialty != null) sp.add(r.specialty); if (r.territory != null) te.add(r.territory); if (r.city != null) ci.add(r.city); pr.addAll(r.products); }
        for (Product__c p : [SELECT Name FROM Product__c WHERE Is_Detail_Product__c = true AND Active__c = true WITH USER_MODE LIMIT 500]) pr.add(p.Name);
        o.specialties = new List<String>(sp); o.specialties.sort(); o.territories = new List<String>(te); o.territories.sort();
        o.cities = new List<String>(ci); o.cities.sort(); o.products = new List<String>(pr); o.products.sort();
        return o;
    }

    // ---------- territory / KAM pickers ----------
    public class ScopeOption {
        @AuraEnabled public String value;
        @AuraEnabled public String label;
        @AuraEnabled public List<String> ids = new List<String>();   // territory: itself + children; KAM: assigned territories
    }
    public class ScopeOptions {
        @AuraEnabled public Boolean isManager = false;
        @AuraEnabled public Boolean isAdmin = false;
        @AuraEnabled public List<ScopeOption> territories = new List<ScopeOption>();
        @AuraEnabled public List<ScopeOption> kams = new List<ScopeOption>();
    }
    /** What the pickers may offer the running user. KAMs get none. */
    public static ScopeOptions getScopeOptions() {
        ScopeOptions o = new ScopeOptions();
        o.isManager = isManager(); o.isAdmin = isAdmin();
        if (!o.isManager) return o;
        ScopeReader r = new ScopeReader();
        Set<Id> allowed = allowedTerritories();
        List<Territory__c> terrs = allowed == null
            ? [SELECT Id, Name, Parent_Territory__c FROM Territory__c ORDER BY Name LIMIT 2000]
            : r.territories(allowed);
        Map<Id, Territory__c> byId = new Map<Id, Territory__c>(terrs);
        Map<Id, List<Id>> kids = new Map<Id, List<Id>>();
        for (Territory__c t : terrs) if (t.Parent_Territory__c != null && byId.containsKey(t.Parent_Territory__c)) {
            if (!kids.containsKey(t.Parent_Territory__c)) kids.put(t.Parent_Territory__c, new List<Id>());
            kids.get(t.Parent_Territory__c).add(t.Id);
        }
        // parents first, children indented beneath them
        List<Territory__c> roots = new List<Territory__c>();
        for (Territory__c t : terrs) if (t.Parent_Territory__c == null || !byId.containsKey(t.Parent_Territory__c)) roots.add(t);
        for (Territory__c t : roots) addTerritory(o, t.Id, byId, kids, 0);
        Set<Id> terrIds = byId.keySet();
        Set<Id> excluded = new Set<Id>();
        for (PermissionSetAssignment p : [SELECT AssigneeId FROM PermissionSetAssignment WHERE PermissionSet.Name IN ('Sciagen_Reports_Manager', 'Sciagen_Reports_Business_Admin')]) excluded.add(p.AssigneeId);
        Map<Id, ScopeOption> kam = new Map<Id, ScopeOption>();
        for (User_Territory__c ut : r.assignments(terrIds)) {
            if (excluded.contains(ut.User__c) || ut.User__c == UserInfo.getUserId()) continue;
            ScopeOption k = kam.get(ut.User__c);
            if (k == null) { k = new ScopeOption(); k.value = ut.User__c; k.label = ut.User__r.Name; kam.put(ut.User__c, k); }
            k.ids.add(ut.Territory__c);
        }
        o.kams = kam.values();
        o.kams.sort(new ScopeOptionSort());
        return o;
    }
    private class ScopeOptionSort implements System.Comparator<ScopeOption> {
        public Integer compare(ScopeOption a, ScopeOption b) { return a.label.compareTo(b.label); }
    }
    private static void addTerritory(ScopeOptions o, Id id, Map<Id, Territory__c> byId, Map<Id, List<Id>> kids, Integer depth) {
        ScopeOption t = new ScopeOption(); t.value = id;
        t.label = ('— '.repeat(depth)) + byId.get(id).Name;
        List<Id> stack = new List<Id>{ id };
        while (!stack.isEmpty()) { Id x = stack.remove(stack.size() - 1); t.ids.add(x); if (kids.containsKey(x)) stack.addAll(kids.get(x)); }
        o.territories.add(t);
        if (kids.containsKey(id)) for (Id k : kids.get(id)) addTerritory(o, k, byId, kids, depth + 1);
    }
}