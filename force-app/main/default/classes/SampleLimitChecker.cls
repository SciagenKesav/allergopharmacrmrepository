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

    /** One line's worth of input to checkLimitsBulk() — same shape as checkLimits()'s
     *  parameters, plus `key` so the caller can match each result back to its request. */
    public class LimitCheckRequest {
        public String key;
        public Id repUserId;
        public Id hcpAccountId;
        public Id productId;
        public Integer requestedQuantity;
        public Id callId;
        public Decimal onCallSameProduct = 0;
        public Decimal onCallAll = 0;
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

    /**
     * Bulk form of checkLimits() for a whole batch of lines at once (e.g. every
     * Sample_Drop__c on one call). checkLimits() runs, per line: 1 Product__c query, 1
     * territory query, 1 Sample_Limit__c query, 1 override query, 1 call-quantity query,
     * and — the part that actually grows unbounded — one usage() query PER ACTIVE LIMIT.
     * A call with 15 lines and 4 active limits is ~15 x (5 + 4) = 135 queries, already
     * over the 100-query governor limit, and every future phase that adds more limits
     * makes it worse (Phase 0 hotfix, the audit's governor-limit risk).
     *
     * This does the same work with a query count that depends on the number of DISTINCT
     * limits and dimension values in the batch, not the number of lines: one Product__c
     * query, one territory query, one Sample_Limit__c query and one override query for
     * the whole batch, plus exactly one grouped aggregate usage() query PER limit that
     * actually applies to anything in the batch (GROUP BY the scope's dimension — e.g.
     * HCP + Product — covers every line that limit applies to in that single query).
     *
     * requests must each carry a distinct `key`; the result map is keyed the same way.
     */
    public static Map<String, LimitCheckResult> checkLimitsBulk(List<LimitCheckRequest> requests) {
        Map<String, LimitCheckResult> out = new Map<String, LimitCheckResult>();
        if (requests == null || requests.isEmpty()) return out;
        Date today = Date.today();

        Set<Id> productIds = new Set<Id>();
        Set<Id> repIds = new Set<Id>();
        Set<Id> callIds = new Set<Id>();
        for (LimitCheckRequest req : requests) {
            if (req.productId != null) productIds.add(req.productId);
            if (req.repUserId != null) repIds.add(req.repUserId);
            if (req.callId != null) callIds.add(req.callId);
        }

        // Cached once for the whole batch (was: once per line).
        Map<Id, Product__c> products = new Map<Id, Product__c>(
            [SELECT Id, Name, Max_Packs_Per_HCP_Per_Year__c FROM Product__c WHERE Id IN :productIds]);
        Map<Id, Set<Id>> repTerritories = new Map<Id, Set<Id>>();
        for (User_Territory__c ut : [SELECT User__c, Territory__c FROM User_Territory__c WHERE User__c IN :repIds AND Territory__c != null]) {
            if (!repTerritories.containsKey(ut.User__c)) repTerritories.put(ut.User__c, new Set<Id>());
            repTerritories.get(ut.User__c).add(ut.Territory__c);
        }
        List<Sample_Limit__c> activeLimits = [
            SELECT Id, Name, Limit_Scope__c, Product__c, Limit_Quantity__c, Limit_Period__c, Warning_Threshold_Pct__c, Hard_Block__c,
                   Override_Requires_Manager__c, Is_Regulatory__c, Regulatory_Reference__c, Territory__c, Applies_To_User__c
            FROM Sample_Limit__c WHERE Is_Active__c = true
        ];

        // addProductLimit()'s synthetic per-product regulatory limit — built once per
        // distinct product in the batch (was: once per line).
        Map<Id, Sample_Limit__c> syntheticByProduct = new Map<Id, Sample_Limit__c>();
        for (Id pid : productIds) {
            Product__c p = products.get(pid);
            if (p == null) continue;
            List<Sample_Limit__c> scopedToThisProduct = new List<Sample_Limit__c>();
            for (Sample_Limit__c l : activeLimits) if (l.Product__c == null || l.Product__c == pid) scopedToThisProduct.add(l);
            Integer before = scopedToThisProduct.size();
            addProductLimit(scopedToThisProduct, p);
            if (scopedToThisProduct.size() > before) syntheticByProduct.put(pid, scopedToThisProduct[scopedToThisProduct.size() - 1]);
        }

        // Which limits apply to each request — same filter as checkLimits()'s per-line
        // loop, just evaluated once per request against the shared, already-queried lists.
        Map<String, List<Sample_Limit__c>> applicableByKey = new Map<String, List<Sample_Limit__c>>();
        Map<String, Sample_Limit__c> limitByKey = new Map<String, Sample_Limit__c>();
        Map<String, List<LimitCheckRequest>> requestsByLimitKey = new Map<String, List<LimitCheckRequest>>();
        for (LimitCheckRequest req : requests) {
            List<Sample_Limit__c> applicable = new List<Sample_Limit__c>();
            Set<Id> territories = repTerritories.containsKey(req.repUserId) ? repTerritories.get(req.repUserId) : new Set<Id>();
            for (Sample_Limit__c l : activeLimits) {
                if (l.Product__c != null && l.Product__c != req.productId) continue;
                if (l.Applies_To_User__c != null && l.Applies_To_User__c != req.repUserId) continue;
                if (l.Territory__c != null && !territories.contains(l.Territory__c)) continue;
                applicable.add(l);
            }
            Sample_Limit__c synthetic = syntheticByProduct.get(req.productId);
            if (synthetic != null) applicable.add(synthetic);
            applicableByKey.put(req.key, applicable);
            for (Sample_Limit__c l : applicable) {
                String lk = limitKey(l);
                limitByKey.put(lk, l);
                if (!requestsByLimitKey.containsKey(lk)) requestsByLimitKey.put(lk, new List<LimitCheckRequest>());
                requestsByLimitKey.get(lk).add(req);
            }
        }

        // One grouped aggregate query per limit that actually applies to something in
        // this batch (Per_Call doesn't need a query at all — callQuantities() below).
        Map<String, Map<String, Decimal>> usageByLimitKey = new Map<String, Map<String, Decimal>>();
        for (String lk : requestsByLimitKey.keySet()) {
            Sample_Limit__c l = limitByKey.get(lk);
            if (l.Limit_Scope__c == 'Per_Call') continue;
            usageByLimitKey.put(lk, usageBulk(l, requestsByLimitKey.get(lk), today));
        }

        // Per_Call usage — Sample_Drop__c rows already saved on each call in this batch.
        Map<Id, Map<String, Decimal>> callQtyByCall = new Map<Id, Map<String, Decimal>>();
        for (Id callId : callIds) callQtyByCall.put(callId, callQuantities(callId));

        Set<Id> limitIds = new Set<Id>();
        for (String lk : limitByKey.keySet()) { Id lid = limitByKey.get(lk).Id; if (lid != null) limitIds.add(lid); }
        Map<Id, List<Sample_Limit_Override__c>> overridesByLimit = new Map<Id, List<Sample_Limit_Override__c>>();
        for (Sample_Limit_Override__c o : [
            SELECT Id, Sample_Limit__c, Override_Type__c, Override_Value__c, Target_Account__c, Target_User__c, Valid_From__c, Valid_To__c
            FROM Sample_Limit_Override__c WHERE Status__c = 'Active' AND Sample_Limit__c IN :limitIds
        ]) {
            if (!overridesByLimit.containsKey(o.Sample_Limit__c)) overridesByLimit.put(o.Sample_Limit__c, new List<Sample_Limit_Override__c>());
            overridesByLimit.get(o.Sample_Limit__c).add(o);
        }

        for (LimitCheckRequest req : requests) {
            LimitCheckResult res = new LimitCheckResult();
            Decimal requested = req.requestedQuantity == null ? 0 : req.requestedQuantity;
            for (Sample_Limit__c l : applicableByKey.get(req.key)) {
                List<Sample_Limit_Override__c> ovs = l.Id != null ? overridesByLimit.get(l.Id) : null;
                List<Sample_Limit_Override__c> matchingOvs = null;
                if (ovs != null) {
                    matchingOvs = new List<Sample_Limit_Override__c>();
                    for (Sample_Limit_Override__c o : ovs) if (overrideApplies(o, req.hcpAccountId, req.repUserId, today)) matchingOvs.add(o);
                }

                Decimal used;
                if (l.Limit_Scope__c == 'Per_Call') {
                    Map<String, Decimal> callQty = callQtyByCall.containsKey(req.callId) ? callQtyByCall.get(req.callId) : new Map<String, Decimal>();
                    used = l.Product__c != null
                        ? nz(callQty.get(String.valueOf(l.Product__c))) + req.onCallSameProduct
                        : nz(callQty.get('ALL')) + req.onCallAll;
                } else {
                    Map<String, Decimal> byDim = usageByLimitKey.get(limitKey(l));
                    used = byDim != null ? nz(byDim.get(dimensionKey(l.Limit_Scope__c, req))) : 0;
                    if (l.Limit_Scope__c == 'HCP_Product' || l.Limit_Scope__c == 'Rep_Product' || l.Limit_Scope__c == 'Product_Global' || l.Limit_Scope__c == 'Territory_Product') {
                        used += req.onCallSameProduct;
                    } else {
                        used += req.onCallAll;
                    }
                }
                LimitCheck c = evaluateFromUsage(l, matchingOvs, requested, used, today);
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
            out.put(req.key, res);
        }
        return out;
    }

    /** Stable key for a Sample_Limit__c across the batch — real limits by Id, the
     *  synthetic per-product regulatory limit (no Id) by product instead. */
    private static String limitKey(Sample_Limit__c l) {
        return l.Id != null ? String.valueOf(l.Id) : ('PRODUCT:' + l.Product__c);
    }

    /** The dimension a given scope groups usage by, for one request — must match how
     *  usageBulk() below keys its grouped query results. */
    private static String dimensionKey(String scope, LimitCheckRequest req) {
        if (scope == 'HCP_Product') return req.hcpAccountId + '|' + req.productId;
        if (scope == 'HCP_All') return String.valueOf(req.hcpAccountId);
        if (scope == 'Rep_Product') return req.repUserId + '|' + req.productId;
        if (scope == 'Rep_All') return String.valueOf(req.repUserId);
        if (scope == 'Territory_Product' || scope == 'Product_Global') return String.valueOf(req.productId);
        return '';
    }

    /** One grouped aggregate query covering every request this limit applies to, keyed
     *  by dimensionKey() so checkLimitsBulk() can look each request's usage back up. */
    private static Map<String, Decimal> usageBulk(Sample_Limit__c l, List<LimitCheckRequest> reqs, Date today) {
        Map<String, Decimal> out = new Map<String, Decimal>();
        Set<Id> hcps = new Set<Id>();
        Set<Id> reps = new Set<Id>();
        Set<Id> products = new Set<Id>();
        for (LimitCheckRequest req : reqs) {
            if (req.hcpAccountId != null) hcps.add(req.hcpAccountId);
            if (req.repUserId != null) reps.add(req.repUserId);
            if (req.productId != null) products.add(req.productId);
        }

        List<String> conds = new List<String>{ 'Transaction_Type__c = \'Disbursement\'', 'Inventory_Applied__c = true' };
        Map<String, Object> binds = new Map<String, Object>();
        Period p = periodFor(l.Limit_Period__c, today);
        if (p.startDate != null) { conds.add('Performed_At__c >= :fromAt'); binds.put('fromAt', Datetime.newInstance(p.startDate, Time.newInstance(0, 0, 0, 0))); }
        if (p.endDate != null) { conds.add('Performed_At__c < :toAt'); binds.put('toAt', Datetime.newInstance(p.endDate, Time.newInstance(0, 0, 0, 0))); }

        String groupField1 = null;
        String groupField2 = null;
        String scope = l.Limit_Scope__c;
        if (scope == 'HCP_Product') {
            conds.add('HCP_Account__c IN :hcps'); conds.add('Product__c IN :products'); binds.put('hcps', hcps); binds.put('products', products);
            groupField1 = 'HCP_Account__c'; groupField2 = 'Product__c';
        } else if (scope == 'HCP_All') {
            conds.add('HCP_Account__c IN :hcps'); binds.put('hcps', hcps);
            if (l.Product__c != null) { conds.add('Product__c = :limitProduct'); binds.put('limitProduct', l.Product__c); }
            groupField1 = 'HCP_Account__c';
        } else if (scope == 'Rep_Product') {
            conds.add('Performed_By__c IN :reps'); conds.add('Product__c IN :products'); binds.put('reps', reps); binds.put('products', products);
            groupField1 = 'Performed_By__c'; groupField2 = 'Product__c';
        } else if (scope == 'Rep_All') {
            conds.add('Performed_By__c IN :reps'); binds.put('reps', reps);
            if (l.Product__c != null) { conds.add('Product__c = :limitProduct'); binds.put('limitProduct', l.Product__c); }
            groupField1 = 'Performed_By__c';
        } else if (scope == 'Territory_Product') {
            Set<Id> territoryUsers = new Set<Id>();
            for (User_Territory__c ut : [SELECT User__c FROM User_Territory__c WHERE Territory__c = :l.Territory__c]) territoryUsers.add(ut.User__c);
            conds.add('Performed_By__c IN :territoryUsers'); conds.add('Product__c IN :products'); binds.put('territoryUsers', territoryUsers); binds.put('products', products);
            groupField1 = 'Product__c';                    // the territory itself is fixed for this one limit instance
        } else if (scope == 'Product_Global') {
            conds.add('Product__c IN :products'); binds.put('products', products);
            groupField1 = 'Product__c';
        } else {
            return out;                                     // unknown/unsupported scope for bulk usage — treated as 0 used
        }

        String selectFields = groupField2 != null ? (groupField1 + ' g1, ' + groupField2 + ' g2') : (groupField1 + ' g1');
        String groupBy = groupField2 != null ? (groupField1 + ', ' + groupField2) : groupField1;
        String soql = 'SELECT ' + selectFields + ', SUM(Quantity__c) s FROM Sample_Transaction__c WHERE ' + String.join(conds, ' AND ') + ' GROUP BY ' + groupBy;
        for (AggregateResult ar : (List<AggregateResult>) Database.queryWithBinds(soql, binds, AccessLevel.SYSTEM_MODE)) {
            Id g1 = (Id) ar.get('g1');
            Id g2 = groupField2 != null ? (Id) ar.get('g2') : null;
            Decimal s = (Decimal) ar.get('s');
            String key = g2 != null ? (String.valueOf(g1) + '|' + String.valueOf(g2)) : String.valueOf(g1);
            out.put(key, s == null ? 0 : s);
        }
        return out;
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
        return evaluateFromUsage(l, ovs, requested, used, today);
    }

    /** The part of evaluate() that doesn't need a fresh query once `used` (this limit's
     *  current consumption, however it was computed) is already known — shared by the
     *  single-line evaluate() above and checkLimitsBulk()'s batched path below, so the
     *  override/threshold/messaging logic only exists once. */
    private static LimitCheck evaluateFromUsage(Sample_Limit__c l, List<Sample_Limit_Override__c> ovs, Decimal requested, Decimal used, Date today) {
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