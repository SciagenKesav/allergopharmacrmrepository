/**
 * Works out whether giving N more packs of a product to a doctor stays inside
 * every applicable Sample_Limit__c. Usage is counted from completed
 * disbursements; packs already on the same call are added because they are not
 * transactions until the call is submitted.
 *
 * Scopes: HCP_Product, HCP_All, Rep_Product, Rep_All, Territory_Product,
 * Per_Call, Product_Global. Periods: Financial year runs April to March.
 * A product's own Max_Packs_Per_HCP_Per_Year__c is honoured as a regulatory
 * limit as well. Overrides apply to company limits only, never to UCPMP ones.
 */
public without sharing class SampleLimitChecker {

    public static final String UCPMP_REF = 'UCPMP 2024 Clause 5.1(ii)(b)';

    public class LimitCheck {
        public Id limitId;
        public String name;
        public String scope;
        public String period;
        public Decimal limitQuantity;
        public Decimal used;
        public Decimal projected;
        public String status = 'OK';          // OK, WARNING, BLOCKED
        public Boolean hardBlock = true;
        public Boolean regulatory = false;
        public Boolean requiresManager = false;
        public Boolean needsReason = false;
        public Id overrideId;
        public String overrideType;
        public String message;
    }

    public class LimitCheckResult {
        public Boolean allowed = true;
        public String status = 'Eligible';    // Eligible, Warning, Blocked
        public List<LimitCheck> checks = new List<LimitCheck>();
        public List<String> warnings = new List<String>();
        public List<String> blockers = new List<String>();
        public Boolean overrideable = false;
        public Boolean needsReason = false;
        public Boolean requiresManager = false;
        public Id overrideId;
    }

    public class Period {
        public Date startDate;          // inclusive, null = no lower bound
        public Date endDate;            // exclusive, null = no upper bound
    }

    // ------------------------------------------------------------ periods

    public static Date fyStart(Date d) {
        return d.month() >= 4 ? Date.newInstance(d.year(), 4, 1) : Date.newInstance(d.year() - 1, 4, 1);
    }

    /** '2026-27' for any date from 1 Apr 2026 to 31 Mar 2027. */
    public static String financialYear(Date d) {
        Integer y = fyStart(d).year();
        return String.valueOf(y) + '-' + String.valueOf(Math.mod(y + 1, 100)).leftPad(2, '0');
    }

    public static Period periodFor(String period, Date today) {
        Period p = new Period();
        if (period == 'Daily') { p.startDate = today; p.endDate = today.addDays(1); }
        else if (period == 'Weekly') {
            Integer sinceMonday = Math.mod(Date.newInstance(1900, 1, 8).daysBetween(today), 7);
            p.startDate = today.addDays(-sinceMonday);
            p.endDate = p.startDate.addDays(7);
        }
        else if (period == 'Monthly') { p.startDate = today.toStartOfMonth(); p.endDate = p.startDate.addMonths(1); }
        else if (period == 'Quarterly') {
            Date fy = fyStart(today);
            Integer q = Math.mod(today.month() - 4 + 12, 12) / 3;
            p.startDate = fy.addMonths(3 * q);
            p.endDate = p.startDate.addMonths(3);
        }
        else if (period == 'Financial_Year') { p.startDate = fyStart(today); p.endDate = p.startDate.addYears(1); }
        else if (period == 'Rolling_30') { p.startDate = today.addDays(-30); p.endDate = today.addDays(1); }
        else if (period == 'Rolling_90') { p.startDate = today.addDays(-90); p.endDate = today.addDays(1); }
        return p;                       // Lifetime and Per_Call: unbounded
    }

    public static String periodLabel(String period) {
        Map<String, String> m = new Map<String, String>{
            'Per_Call' => 'on this call', 'Daily' => 'today', 'Weekly' => 'this week', 'Monthly' => 'this month',
            'Quarterly' => 'this quarter', 'Financial_Year' => 'this FY', 'Rolling_30' => 'in the last 30 days',
            'Rolling_90' => 'in the last 90 days', 'Lifetime' => 'in total' };
        return m.containsKey(period) ? m.get(period) : period;
    }

    // -------------------------------------------------------------- check

    public static LimitCheckResult checkLimits(Id repUserId, Id hcpAccountId, Id productId, Integer requestedQuantity, Id callId) {
        return checkLimits(repUserId, hcpAccountId, productId, requestedQuantity, callId, 0, 0);
    }

    /** onCallSameProduct / onCallAll: packs already added to this call but not yet saved (this batch). */
    public static LimitCheckResult checkLimits(Id repUserId, Id hcpAccountId, Id productId, Integer requestedQuantity, Id callId,
                                               Decimal onCallSameProduct, Decimal onCallAll) {
        LimitCheckResult res = new LimitCheckResult();
        Decimal requested = requestedQuantity == null ? 0 : requestedQuantity;
        Date today = Date.today();

        Product__c product = [SELECT Id, Name, Max_Packs_Per_HCP_Per_Year__c FROM Product__c WHERE Id = :productId LIMIT 1];
        Set<Id> myTerritories = new Set<Id>();
        for (User_Territory__c ut : [SELECT Territory__c FROM User_Territory__c WHERE User__c = :repUserId AND Territory__c != null]) myTerritories.add(ut.Territory__c);

        List<Sample_Limit__c> limits = new List<Sample_Limit__c>();
        for (Sample_Limit__c l : [
            SELECT Id, Name, Limit_Scope__c, Product__c, Limit_Quantity__c, Limit_Period__c, Warning_Threshold_Pct__c, Hard_Block__c,
                   Override_Requires_Manager__c, Is_Regulatory__c, Regulatory_Reference__c, Territory__c, Applies_To_User__c
            FROM Sample_Limit__c WHERE Is_Active__c = true
        ]) {
            if (l.Product__c != null && l.Product__c != productId) continue;
            if (l.Applies_To_User__c != null && l.Applies_To_User__c != repUserId) continue;
            if (l.Territory__c != null && !myTerritories.contains(l.Territory__c)) continue;
            limits.add(l);
        }
        addProductLimit(limits, product);

        Map<Id, List<Sample_Limit_Override__c>> overrides = new Map<Id, List<Sample_Limit_Override__c>>();
        Set<Id> limitIds = new Set<Id>();
        for (Sample_Limit__c l : limits) if (l.Id != null) limitIds.add(l.Id);
        for (Sample_Limit_Override__c o : [
            SELECT Id, Sample_Limit__c, Override_Type__c, Override_Value__c, Target_Account__c, Target_User__c, Valid_From__c, Valid_To__c
            FROM Sample_Limit_Override__c WHERE Status__c = 'Active' AND Sample_Limit__c IN :limitIds
        ]) {
            if (!overrideApplies(o, hcpAccountId, repUserId, today)) continue;
            if (!overrides.containsKey(o.Sample_Limit__c)) overrides.put(o.Sample_Limit__c, new List<Sample_Limit_Override__c>());
            overrides.get(o.Sample_Limit__c).add(o);
        }

        Map<String, Decimal> callQty = callQuantities(callId);
        for (Sample_Limit__c l : limits) {
            LimitCheck c = evaluate(l, overrides.get(l.Id), repUserId, hcpAccountId, productId, requested, today, callQty, onCallSameProduct, onCallAll, myTerritories);
            res.checks.add(c);
            if (c.status == 'BLOCKED') { res.allowed = false; res.blockers.add(c.message); }
            else if (c.status == 'WARNING') {
                res.warnings.add(c.message);
                if (c.needsReason) { res.needsReason = true; res.overrideable = true; }
                if (c.requiresManager) res.requiresManager = true;
            }
            if (c.overrideId != null && c.status != 'BLOCKED') res.overrideId = c.overrideId;
        }
        res.status = !res.allowed ? 'Blocked' : (res.warnings.isEmpty() ? 'Eligible' : 'Warning');
        if (!res.allowed) { res.overrideable = false; res.needsReason = false; }
        return res;
    }

    private static void addProductLimit(List<Sample_Limit__c> limits, Product__c p) {
        if (p.Max_Packs_Per_HCP_Per_Year__c == null) return;
        for (Sample_Limit__c l : limits) {
            if (l.Limit_Scope__c == 'HCP_Product' && l.Limit_Period__c == 'Financial_Year' && l.Is_Regulatory__c == true
                && l.Limit_Quantity__c <= p.Max_Packs_Per_HCP_Per_Year__c) return;      // already at least as strict
        }
        limits.add(new Sample_Limit__c(Name = 'UCPMP: packs per drug per doctor', Limit_Scope__c = 'HCP_Product', Product__c = p.Id,
            Limit_Quantity__c = p.Max_Packs_Per_HCP_Per_Year__c, Limit_Period__c = 'Financial_Year', Warning_Threshold_Pct__c = 80,
            Hard_Block__c = true, Is_Regulatory__c = true, Regulatory_Reference__c = UCPMP_REF));
    }

    private static Boolean overrideApplies(Sample_Limit_Override__c o, Id hcp, Id rep, Date today) {
        if (o.Valid_From__c != null && o.Valid_From__c > today) return false;
        if (o.Valid_To__c != null && o.Valid_To__c < today) return false;
        if (o.Target_Account__c != null && o.Target_Account__c != hcp) return false;
        if (o.Target_User__c != null && o.Target_User__c != rep) return false;
        return o.Target_Account__c != null || o.Target_User__c != null;
    }

    private static LimitCheck evaluate(Sample_Limit__c l, List<Sample_Limit_Override__c> ovs, Id rep, Id hcp, Id product, Decimal requested, Date today,
                                       Map<String, Decimal> callQty, Decimal onCallSameProduct, Decimal onCallAll, Set<Id> myTerritories) {
        LimitCheck c = new LimitCheck();
        c.limitId = l.Id;
        c.name = l.Name;
        c.scope = l.Limit_Scope__c;
        c.period = l.Limit_Period__c;
        c.hardBlock = l.Hard_Block__c == true;
        c.regulatory = l.Is_Regulatory__c == true;
        c.requiresManager = l.Override_Requires_Manager__c == true;
        Decimal effective = l.Limit_Quantity__c;

        if (ovs != null && !c.regulatory) {
            for (Sample_Limit_Override__c o : ovs) {
                if (o.Override_Type__c == 'Increase' && o.Override_Value__c != null && o.Override_Value__c > effective) {
                    effective = o.Override_Value__c; c.overrideId = o.Id; c.overrideType = 'Increase';
                } else if (o.Override_Type__c == 'Exempt' || o.Override_Type__c == 'One_Time_Waiver') {
                    c.overrideId = o.Id; c.overrideType = o.Override_Type__c; c.limitQuantity = effective; c.used = 0; c.projected = requested;
                    c.message = l.Name + ': exempt by override.';
                    return c;
                }
            }
        }
        c.limitQuantity = effective;

        Decimal used;
        if (l.Limit_Scope__c == 'Per_Call') {
            used = l.Product__c != null ? nz(callQty.get(String.valueOf(l.Product__c))) + onCallSameProduct : nz(callQty.get('ALL')) + onCallAll;
        } else {
            used = usage(l, rep, hcp, product, today, myTerritories);
            if (l.Limit_Scope__c == 'HCP_Product' || l.Limit_Scope__c == 'Rep_Product' || l.Limit_Scope__c == 'Product_Global' || l.Limit_Scope__c == 'Territory_Product') {
                used += onCallSameProduct;
            } else {
                used += onCallAll;
            }
        }
        c.used = used;
        c.projected = used + requested;

        String per = periodLabel(l.Limit_Period__c);
        String ref = String.isBlank(l.Regulatory_Reference__c) ? '' : ' Ref: ' + l.Regulatory_Reference__c;
        String label = c.regulatory ? 'UCPMP limit' : 'Limit';
        if (c.projected > effective) {
            String fact = (used >= effective)
                ? label + ' reached: ' + used.intValue() + '/' + effective.intValue() + ' packs ' + per + '.'
                : label + ' exceeded: ' + used.intValue() + '/' + effective.intValue() + ' packs ' + per + ' and ' + requested.intValue() + ' more were asked for.';
            if (c.hardBlock) {
                c.status = 'BLOCKED';
                c.message = fact + ' Cannot distribute more.' + ref;
            } else {
                c.status = 'WARNING';
                c.needsReason = true;
                c.message = fact + ' Give a reason to continue.' + (c.requiresManager ? ' Manager approval needed; the transaction will be held.' : '');
            }
        } else {
            Decimal threshold = l.Warning_Threshold_Pct__c == null ? 80 : l.Warning_Threshold_Pct__c;
            if (effective > 0 && (c.projected * 100 / effective) >= threshold) {
                c.status = 'WARNING';
                c.message = l.Name + ': ' + c.projected.intValue() + '/' + effective.intValue() + ' packs ' + per + ' (' + (effective - c.projected).intValue() + ' left).';
            } else {
                c.message = l.Name + ': ' + c.projected.intValue() + '/' + effective.intValue() + ' packs ' + per + '.';
            }
        }
        return c;
    }

    private static Decimal nz(Decimal d) { return d == null ? 0 : d; }

    /** Packs of each product already on this call (Sample_Drop__c), plus the total under key ALL. */
    private static Map<String, Decimal> callQuantities(Id callId) {
        Map<String, Decimal> m = new Map<String, Decimal>{ 'ALL' => 0 };
        if (callId == null) return m;
        for (AggregateResult ar : [SELECT Product__c p, SUM(Qty__c) q FROM Sample_Drop__c WHERE CVR__c = :callId GROUP BY Product__c]) {
            Decimal q = (Decimal) ar.get('q');
            m.put(String.valueOf(ar.get('p')), q);
            m.put('ALL', m.get('ALL') + q);
        }
        return m;
    }

    private static Decimal usage(Sample_Limit__c l, Id rep, Id hcp, Id product, Date today, Set<Id> myTerritories) {
        List<String> conds = new List<String>{ 'Transaction_Type__c = \'Disbursement\'', 'Inventory_Applied__c = true' };
        Map<String, Object> binds = new Map<String, Object>();
        Id productFilter = l.Product__c != null ? l.Product__c : null;
        String scope = l.Limit_Scope__c;
        if (scope == 'HCP_Product') { conds.add('HCP_Account__c = :hcp'); conds.add('Product__c = :product'); binds.put('hcp', hcp); binds.put('product', product); }
        else if (scope == 'HCP_All') { conds.add('HCP_Account__c = :hcp'); binds.put('hcp', hcp); }
        else if (scope == 'Rep_Product') { conds.add('Performed_By__c = :rep'); conds.add('Product__c = :product'); binds.put('rep', rep); binds.put('product', product); }
        else if (scope == 'Rep_All') { conds.add('Performed_By__c = :rep'); binds.put('rep', rep); }
        else if (scope == 'Territory_Product') {
            Set<Id> users = new Set<Id>();
            for (User_Territory__c ut : [SELECT User__c FROM User_Territory__c WHERE Territory__c = :l.Territory__c]) users.add(ut.User__c);
            conds.add('Performed_By__c IN :users'); conds.add('Product__c = :product'); binds.put('users', users); binds.put('product', product);
        }
        else if (scope == 'Product_Global') { conds.add('Product__c = :product'); binds.put('product', product); }
        if (productFilter != null && (scope == 'HCP_All' || scope == 'Rep_All')) { conds.add('Product__c = :limitProduct'); binds.put('limitProduct', productFilter); }
        Period p = periodFor(l.Limit_Period__c, today);
        if (p.startDate != null) { conds.add('Performed_At__c >= :fromAt'); binds.put('fromAt', Datetime.newInstance(p.startDate, Time.newInstance(0, 0, 0, 0))); }
        if (p.endDate != null) { conds.add('Performed_At__c < :toAt'); binds.put('toAt', Datetime.newInstance(p.endDate, Time.newInstance(0, 0, 0, 0))); }
        List<AggregateResult> rows = Database.queryWithBinds('SELECT SUM(Quantity__c) s FROM Sample_Transaction__c WHERE ' + String.join(conds, ' AND '), binds, AccessLevel.SYSTEM_MODE);
        return rows.isEmpty() || rows[0].get('s') == null ? 0 : (Decimal) rows[0].get('s');
    }
}