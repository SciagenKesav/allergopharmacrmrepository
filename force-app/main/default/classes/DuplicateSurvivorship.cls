/**
 * Suggests which of two duplicate records should survive (the winner), from how complete each is,
 * how much real work hangs off it and how old it is. An admin can always override the suggestion.
 */
public without sharing class DuplicateSurvivorship {

    public class Suggestion {
        public Id winnerId;
        public Id loserId;
        public Decimal winnerScore;
        public Decimal loserScore;
        public List<String> reasons = new List<String>();
    }

    /** Child-record counts per account: cvr, consent, territory, affiliation, plan, planned. */
    public static Map<Id, Map<String, Integer>> loadActivity(Set<Id> ids) {
        Map<Id, Map<String, Integer>> out = new Map<Id, Map<String, Integer>>();
        for (Id i : ids) out.put(i, new Map<String, Integer>());
        if (ids.isEmpty()) return out;
        for (AggregateResult r : [SELECT HCP__c a, COUNT(Id) c FROM Call_Visit_Report__c WHERE HCP__c IN :ids GROUP BY HCP__c]) put(out, (Id) r.get('a'), 'cvr', (Integer) r.get('c'));
        for (AggregateResult r : [SELECT HCO__c a, COUNT(Id) c FROM Call_Visit_Report__c WHERE HCO__c IN :ids GROUP BY HCO__c]) put(out, (Id) r.get('a'), 'cvr', (Integer) r.get('c'));
        for (AggregateResult r : [SELECT HCP__c a, COUNT(Id) c FROM Consent__c WHERE HCP__c IN :ids GROUP BY HCP__c]) put(out, (Id) r.get('a'), 'consent', (Integer) r.get('c'));
        for (AggregateResult r : [SELECT Account__c a, COUNT(Id) c FROM Account_Territory__c WHERE Account__c IN :ids GROUP BY Account__c]) put(out, (Id) r.get('a'), 'territory', (Integer) r.get('c'));
        for (AggregateResult r : [SELECT HCP__c a, COUNT(Id) c FROM Affiliation__c WHERE HCP__c IN :ids GROUP BY HCP__c]) put(out, (Id) r.get('a'), 'affiliation', (Integer) r.get('c'));
        for (AggregateResult r : [SELECT HCO__c a, COUNT(Id) c FROM Affiliation__c WHERE HCO__c IN :ids GROUP BY HCO__c]) put(out, (Id) r.get('a'), 'affiliation', (Integer) r.get('c'));
        for (AggregateResult r : [SELECT HCP__c a, COUNT(Id) c FROM Account_Plan__c WHERE HCP__c IN :ids GROUP BY HCP__c]) put(out, (Id) r.get('a'), 'plan', (Integer) r.get('c'));
        for (AggregateResult r : [SELECT HCP__c a, COUNT(Id) c FROM Planned_Call__c WHERE HCP__c IN :ids GROUP BY HCP__c]) put(out, (Id) r.get('a'), 'planned', (Integer) r.get('c'));
        return out;
    }

    private static void put(Map<Id, Map<String, Integer>> m, Id id, String k, Integer c) {
        if (id == null || !m.containsKey(id)) return;
        Integer cur = m.get(id).get(k) == null ? 0 : m.get(id).get(k);
        m.get(id).put(k, cur + c);
    }

    public static Suggestion suggest(Sciagen_Account__c a, Sciagen_Account__c b, Map<Id, Map<String, Integer>> activity) {
        List<String> ra = new List<String>(), rb = new List<String>();
        Decimal sa = score(a, activity == null ? null : activity.get(a.Id), ra);
        Decimal sb = score(b, activity == null ? null : activity.get(b.Id), rb);
        // The older record is the original: it carries the ids reps and integrations already know.
        if (a.CreatedDate != null && b.CreatedDate != null) {
            if (a.CreatedDate < b.CreatedDate.addDays(-1)) { sa += 5; ra.add('Older record (+5)'); }
            else if (b.CreatedDate < a.CreatedDate.addDays(-1)) { sb += 5; rb.add('Older record (+5)'); }
        }
        Boolean aWins = sa > sb || (sa == sb && a.CreatedDate <= b.CreatedDate);
        Suggestion s = new Suggestion();
        s.winnerId = aWins ? a.Id : b.Id;
        s.loserId = aWins ? b.Id : a.Id;
        s.winnerScore = aWins ? sa : sb;
        s.loserScore = aWins ? sb : sa;
        s.reasons = aWins ? ra : rb;
        return s;
    }

    private static Decimal score(Sciagen_Account__c a, Map<String, Integer> act, List<String> why) {
        Decimal pts = 0;
        Integer filled = 0;
        List<Object> values = a.Type__c == 'HCO'
            ? new List<Object>{ a.Billing_Street__c, a.Billing_City__c, a.Billing_Postal_Code__c, a.Billing_State__c, a.Phone__c, a.Email__c, a.Website__c, a.Account_Code__c, a.Plus_Code__c, a.HCO_Type__c, DuplicateMatchService.specialty(a), a.Geolocation__Latitude__s }
            : new List<Object>{ a.Prefix__c, a.First_Name__c, a.Last_Name__c, a.Billing_Street__c, a.Billing_City__c, a.Billing_Postal_Code__c, a.Phone__c, a.Email__c, a.License_Number__c, a.Licensing_Body__c, a.Account_Code__c, a.HCP_Type__c, DuplicateMatchService.specialty(a), a.Degree_1__c, a.Graduation_Year__c };
        for (Object v : values) if (v != null && String.valueOf(v).trim() != '') filled++;
        pts += filled * 2;
        why.add(filled + ' of ' + values.size() + ' key fields filled (+' + (filled * 2) + ')');
        if (String.isNotBlank(a.License_Number__c)) { pts += 6; why.add('Has a licence number (+6)'); }
        if (String.isNotBlank(a.Email__c)) pts += 4;
        if (String.isNotBlank(a.Phone__c)) pts += 4;
        if (act != null) {
            Integer cvr = act.get('cvr') == null ? 0 : act.get('cvr');
            Integer consent = act.get('consent') == null ? 0 : act.get('consent');
            Integer terr = act.get('territory') == null ? 0 : act.get('territory');
            Integer aff = act.get('affiliation') == null ? 0 : act.get('affiliation');
            Integer plan = act.get('plan') == null ? 0 : act.get('plan');
            if (cvr > 0) { pts += Math.min(cvr, 20); why.add(cvr + ' call report(s) (+' + Math.min(cvr, 20) + ')'); }
            if (consent > 0) { pts += Math.min(consent, 3) * 4; why.add(consent + ' consent record(s) (+' + (Math.min(consent, 3) * 4) + ')'); }
            if (terr > 0) { pts += Math.min(terr, 3) * 3; why.add(terr + ' territory assignment(s) (+' + (Math.min(terr, 3) * 3) + ')'); }
            if (aff > 0) { pts += Math.min(aff, 3) * 2; }
            if (plan > 0) { pts += Math.min(plan, 3) * 2; why.add(plan + ' account plan(s)'); }
        }
        if (a.Last_Visit__c != null) { pts += 3; why.add('Has a last-visit date (+3)'); }
        return pts;
    }
}