/**
 * Sample lines on a call report. Before a line is saved it is run through the
 * eligibility rules: the soonest-expiring lot is assigned (first expiry first
 * out), the value is snapshotted, and a line that breaks a hard rule is refused.
 * Once the call is submitted, each line becomes a completed disbursement
 * transaction, which moves the stock (SampleTransactionService).
 */
public without sharing class SampleDropService {

    private static Boolean creating = false;

    public static void beforeInsert(List<Sample_Drop__c> drops) {
        SampleConfig cfg = SampleConfig.load();
        Set<Id> callIds = new Set<Id>();
        Set<Id> productIds = new Set<Id>();
        for (Sample_Drop__c d : drops) { callIds.add(d.CVR__c); productIds.add(d.Product__c); }
        Map<Id, Call_Visit_Report__c> calls = new Map<Id, Call_Visit_Report__c>([
            SELECT Id, OwnerId, HCP__c, Record_Status__c, Signature_Captured__c FROM Call_Visit_Report__c WHERE Id IN :callIds
        ]);
        Map<Id, Product__c> products = new Map<Id, Product__c>([
            SELECT Id, Sample_Unit_Value_INR__c, Pack_Size__c, Requires_Signature__c, Is_Controlled_Substance__c, Requires_Cold_Chain__c
            FROM Product__c WHERE Id IN :productIds
        ]);
        Map<String, Decimal> batchSameProduct = new Map<String, Decimal>();
        Map<Id, Decimal> batchAll = new Map<Id, Decimal>();

        // Load everything the eligibility / limit checks need once for the whole batch (QA-49).
        Set<Id> repIds = new Set<Id>(), hcpIds = new Set<Id>(), lotIds = new Set<Id>();
        for (Call_Visit_Report__c c : calls.values()) { repIds.add(c.OwnerId); if (c.HCP__c != null) hcpIds.add(c.HCP__c); }
        for (Sample_Drop__c d : drops) if (d.Sample_Lot__c != null) lotIds.add(d.Sample_Lot__c);
        productIds.remove(null);
        SampleEligibilityService.prime(repIds, hcpIds, productIds, calls.keySet(), lotIds);
        try {
            checkLines(drops, calls, products, cfg, batchSameProduct, batchAll);
        } finally {
            SampleEligibilityService.clearPrime();
        }
    }

    private static void checkLines(List<Sample_Drop__c> drops, Map<Id, Call_Visit_Report__c> calls, Map<Id, Product__c> products, SampleConfig cfg,
                                   Map<String, Decimal> batchSameProduct, Map<Id, Decimal> batchAll) {
        for (Sample_Drop__c d : drops) {
            Call_Visit_Report__c call = calls.get(d.CVR__c);
            Product__c p = products.get(d.Product__c);
            if (call == null || p == null || call.HCP__c == null) continue;
            if (d.Unit_Value__c == null) d.Unit_Value__c = p.Sample_Unit_Value_INR__c;
            if (d.Pack_Size__c == null) d.Pack_Size__c = p.Pack_Size__c == null ? 1 : p.Pack_Size__c;
            d.Needs_Signature__c = p.Requires_Signature__c == true || p.Is_Controlled_Substance__c == true;

            String key = d.CVR__c + '|' + d.Product__c;
            SampleEligibilityService.Request req = new SampleEligibilityService.Request();
            req.repUserId = call.OwnerId;
            req.hcpAccountId = call.HCP__c;
            req.productId = d.Product__c;
            req.quantity = d.Qty__c == null ? 0 : d.Qty__c.intValue();
            req.callId = call.Id;
            req.lotId = d.Sample_Lot__c;
            req.onCallSameProduct = batchSameProduct.containsKey(key) ? batchSameProduct.get(key) : 0;
            req.onCallAll = batchAll.containsKey(call.Id) ? batchAll.get(call.Id) : 0;
            SampleEligibilityService.Result res = SampleEligibilityService.check(req);

            if (d.Sample_Lot__c == null && res.lotId != null) d.Sample_Lot__c = res.lotId;
            d.Eligibility_Status__c = res.status;
            d.Eligibility_Message__c = res.message;
            d.Limit_Override__c = res.overrideId;
            d.Requires_Approval__c = res.needsReason && res.requiresManager;

            String problem = null;
            if (p.Requires_Cold_Chain__c == true && (String.isBlank(d.Cold_Chain_Tag_Number__c) || String.isBlank(d.Cold_Chain_Status__c))) {
                problem = 'Cold chain product: enter the tag number and status.';
            } else if (p.Requires_Cold_Chain__c == true && d.Cold_Chain_Status__c == 'Breach') {
                problem = 'Cold chain breach detected. Cannot distribute. Return to warehouse for quality assessment.';
            } else if (res.blocked) {
                problem = res.message;
            } else if (res.needsReason && String.isBlank(d.Override_Reason__c)) {
                problem = 'Give a reason for going over the limit. ' + res.message;
            } else if (d.Needs_Signature__c == true && call.Record_Status__c == 'Submitted' && call.Signature_Captured__c != true) {
                problem = 'The doctor\'s signature is required for this sample.';
            }
            if (problem != null) {
                if (cfg.enforceRules) {
                    SampleAttemptLogService.publish(d.Product__c, call.HCP__c, call.OwnerId, call.Id, req.quantity, problem);
                    d.addError(problem.left(255));
                }
                else { d.Eligibility_Status__c = 'Warning'; d.Eligibility_Message__c = ('Not enforced: ' + problem).left(255); }
                continue;
            }
            batchSameProduct.put(key, (batchSameProduct.containsKey(key) ? batchSameProduct.get(key) : 0) + req.quantity);
            batchAll.put(call.Id, (batchAll.containsKey(call.Id) ? batchAll.get(call.Id) : 0) + req.quantity);
        }
    }

    // Written by this service (eligibility result, ledger link, value snapshot): never by a client.
    private static final List<String> SERVER_OWNED = new List<String>{
        'Transaction__c', 'Eligibility_Status__c', 'Eligibility_Message__c', 'Requires_Approval__c', 'Limit_Override__c',
        'Needs_Signature__c', 'Unit_Value__c', 'Pack_Size__c'
    };
    // What the line is: changing these would skip the eligibility / UCPMP limit check done on insert.
    private static final List<String> DEFINING = new List<String>{ 'CVR__c', 'Product__c', 'Sample_Lot__c', 'Qty__c' };
    private static final List<String> DETAILS = new List<String>{ 'Cold_Chain_Tag_Number__c', 'Cold_Chain_Status__c', 'Custom_Text__c', 'Override_Reason__c' };

    /**
     * Before update. The iPad creates lines with PATCH .../Sample_Drop__c/Client_Id__c/{uuid} (QA-32), so a
     * retry arrives as an update of the same record with the same values: that passes and does nothing
     * (no second eligibility run, no second transaction). A real change is limited: once the line is in the
     * ledger nothing about it changes; before that, only fewer packs or the cold-chain/text details. A
     * different product/lot/call, or more packs, means removing the line and adding it again so the
     * limits are checked. Admins (Modify All Data) are exempt.
     */
    public static void beforeUpdate(List<Sample_Drop__c> news, Map<Id, Sample_Drop__c> oldMap) {
        if (creating) return;   // this service linking the ledger transaction
        CallReportLockService.guardChildren(news, oldMap);
        Boolean admin = null;
        for (Sample_Drop__c d : news) {
            Sample_Drop__c o = oldMap.get(d.Id);
            List<String> changed = new List<String>();
            for (List<String> fieldGroup : new List<List<String>>{ SERVER_OWNED, DEFINING, DETAILS }) {
                for (String f : fieldGroup) if (changedValue(d.get(f), o.get(f))) changed.add(f);
            }
            if (changed.isEmpty()) continue;
            if (admin == null) admin = SciagenAccess.hasModifyAllData();
            if (admin) continue;
            String problem = null;
            if (o.Transaction__c != null) {
                problem = 'This sample line is already in the inventory ledger and can\'t be changed.';
            } else {
                for (String f : changed) {
                    if (SERVER_OWNED.contains(f)) { problem = f + ' is set by the server.'; break; }
                    if (f == 'Qty__c' && d.Qty__c != null && o.Qty__c != null && d.Qty__c < o.Qty__c && d.Qty__c > 0) continue;
                    if (DEFINING.contains(f)) {
                        problem = 'To change the product, lot or add packs, remove this sample line and add it again so the sampling limits are checked.';
                        break;
                    }
                }
            }
            if (problem != null) d.addError(problem);
        }
    }

    /** Before delete: a line on a submitted report, or one already in the inventory ledger, stays. */
    public static void beforeDelete(List<Sample_Drop__c> olds) {
        CallReportLockService.guardChildren(olds, null);
        Boolean admin = null;
        for (Sample_Drop__c d : olds) {
            if (d.Transaction__c == null) continue;
            if (admin == null) admin = SciagenAccess.hasModifyAllData();
            if (!admin) d.addError('This sample line is already in the inventory ledger and can\'t be deleted.');
        }
    }

    private static Boolean changedValue(Object a, Object b) {
        if (a instanceof String || b instanceof String) {
            String sa = (String) a, sb = (String) b;
            if (String.isBlank(sa) && String.isBlank(sb)) return false;
            return sa == null || sb == null || !sa.equals(sb);
        }
        return a != b;
    }

    /** A line added to a call that is already submitted becomes a transaction straight away. */
    public static void afterInsert(List<Sample_Drop__c> drops) {
        Set<Id> callIds = new Set<Id>();
        for (Sample_Drop__c d : drops) callIds.add(d.CVR__c);
        Set<Id> submitted = new Set<Id>();
        for (Call_Visit_Report__c c : [SELECT Id FROM Call_Visit_Report__c WHERE Id IN :callIds AND Record_Status__c = 'Submitted']) submitted.add(c.Id);
        Set<Id> dropIds = new Set<Id>();
        for (Sample_Drop__c d : drops) if (submitted.contains(d.CVR__c)) dropIds.add(d.Id);
        if (!dropIds.isEmpty()) createTransactions(dropIds);
    }

    /** Turns sample lines that have no transaction yet into disbursement transactions. */
    public static void createTransactions(Set<Id> dropIds) {
        if (creating) return;
        creating = true;
        try {
            List<Sample_Drop__c> drops = [
                SELECT Id, CVR__c, Product__c, Qty__c, Sample_Lot__c, Cold_Chain_Tag_Number__c, Cold_Chain_Status__c, Custom_Text__c, Unit_Value__c, Pack_Size__c,
                       Requires_Approval__c, Override_Reason__c, Eligibility_Message__c,
                       CVR__r.HCP__c, CVR__r.OwnerId, CVR__r.Signature_Captured__c, CVR__r.Signature_Image__c, CVR__r.Signature_Captured_At__c,
                       CVR__r.Signature_GPS__Latitude__s, CVR__r.Signature_GPS__Longitude__s, CVR__r.Signee_Name__c, CVR__r.Start_Time__c
                FROM Sample_Drop__c WHERE Id IN :dropIds AND Transaction__c = null
            ];
            if (drops.isEmpty()) return;
            List<Sample_Transaction__c> txns = new List<Sample_Transaction__c>();
            for (Sample_Drop__c d : drops) {
                Call_Visit_Report__c c = d.CVR__r;
                Sample_Transaction__c t = new Sample_Transaction__c(
                    Transaction_Type__c = 'Disbursement', Status__c = d.Requires_Approval__c == true ? 'Pending' : 'Completed',
                    Requires_Approval__c = d.Requires_Approval__c == true, Product__c = d.Product__c, Sample_Lot__c = d.Sample_Lot__c,
                    Quantity__c = d.Qty__c, HCP_Account__c = c.HCP__c, Call_Report__c = d.CVR__c, Sample_Drop__c = d.Id,
                    Signature_Captured__c = c.Signature_Captured__c == true, Signature_Image_Id__c = c.Signature_Image__c,
                    Signature_Captured_At__c = c.Signature_Captured_At__c, Signature_GPS_Lat__c = c.Signature_GPS__Latitude__s,
                    Signature_GPS_Lng__c = c.Signature_GPS__Longitude__s, Signee_Name__c = c.Signee_Name__c, Signature_Type__c = c.Signature_Captured__c == true ? 'In_Person' : null,
                    Signing_Statement__c = c.Signature_Captured__c == true ? SIGNING_STATEMENT : null,
                    Cold_Chain_Tag_Number__c = d.Cold_Chain_Tag_Number__c, Cold_Chain_Status__c = d.Cold_Chain_Status__c, Custom_Text__c = d.Custom_Text__c,
                    Unit_Value_At_Transaction__c = d.Unit_Value__c, Pack_Size_At_Transaction__c = d.Pack_Size__c, Override_Reason__c = d.Override_Reason__c,
                    Eligibility_Message__c = d.Eligibility_Message__c, Performed_By__c = c.OwnerId, Performed_At__c = c.Start_Time__c == null ? System.now() : c.Start_Time__c,
                    Device_Type__c = 'iPad', Client_Id__c = 'DROP-' + d.Id);
                txns.add(t);
            }
            // Trusted origin: these hand-outs have passed the eligibility / UCPMP limit engine in beforeInsert.
            SampleTransactionService.systemOrigin = true;
            List<Database.SaveResult> results;
            try {
                results = Database.insert(txns, false);
            } finally {
                SampleTransactionService.systemOrigin = false;
            }
            List<Sample_Drop__c> link = new List<Sample_Drop__c>();
            for (Integer i = 0; i < results.size(); i++) {
                if (results[i].isSuccess()) link.add(new Sample_Drop__c(Id = drops[i].Id, Transaction__c = txns[i].Id));
                else link.add(new Sample_Drop__c(Id = drops[i].Id, Eligibility_Status__c = 'Blocked', Eligibility_Message__c = ('Not recorded in inventory: ' + results[i].getErrors()[0].getMessage()).left(255)));
            }
            update link;
            expireWaivers(drops, results);
        } finally {
            creating = false;
        }
    }

    private static void expireWaivers(List<Sample_Drop__c> drops, List<Database.SaveResult> results) {
        Set<Id> ids = new Set<Id>();
        for (Integer i = 0; i < drops.size(); i++) {
            // Read back from the org: the override id is on the saved drop.
            if (results[i].isSuccess()) ids.add(drops[i].Id);
        }
        List<Sample_Limit_Override__c> used = new List<Sample_Limit_Override__c>();
        Set<Id> seen = new Set<Id>();
        for (Sample_Drop__c d : [SELECT Limit_Override__c, Limit_Override__r.Override_Type__c, Limit_Override__r.Status__c FROM Sample_Drop__c WHERE Id IN :ids AND Limit_Override__c != null]) {
            if (d.Limit_Override__r.Override_Type__c == 'One_Time_Waiver' && d.Limit_Override__r.Status__c == 'Active' && seen.add(d.Limit_Override__c)) {
                used.add(new Sample_Limit_Override__c(Id = d.Limit_Override__c, Status__c = 'Expired'));
            }
        }
        if (!used.isEmpty()) update used;
    }

    public static final String SIGNING_STATEMENT = 'I acknowledge receipt of the free medical samples listed above. They are marked "free medical sample not for sale". '
        + 'I am qualified to prescribe them and I understand they are to create awareness of treatment options and gain experience with the product.';

    /** Signature rules and controlled-substance locking on the call report itself. */
    public static void beforeCallUpdate(List<Call_Visit_Report__c> news, Map<Id, Call_Visit_Report__c> oldMap) {
        Set<Id> becomingSubmitted = new Set<Id>();
        Set<Id> unlocking = new Set<Id>();
        for (Call_Visit_Report__c c : news) {
            Call_Visit_Report__c o = oldMap.get(c.Id);
            if (c.Record_Status__c == 'Submitted' && o.Record_Status__c != 'Submitted') becomingSubmitted.add(c.Id);
            if (o.Record_Status__c == 'Submitted' && c.Record_Status__c != 'Submitted') unlocking.add(c.Id);
        }
        if (becomingSubmitted.isEmpty() && unlocking.isEmpty()) return;
        Set<Id> needSignature = new Set<Id>();
        for (AggregateResult ar : [SELECT CVR__c c FROM Sample_Drop__c WHERE CVR__c IN :becomingSubmitted AND Needs_Signature__c = true GROUP BY CVR__c]) needSignature.add((Id) ar.get('c'));
        Set<Id> controlled = new Set<Id>();
        for (AggregateResult ar : [SELECT CVR__c c FROM Sample_Drop__c WHERE CVR__c IN :unlocking AND Product__r.Is_Controlled_Substance__c = true GROUP BY CVR__c]) controlled.add((Id) ar.get('c'));
        Boolean manager = SampleAccess.isManager();
        for (Call_Visit_Report__c c : news) {
            if (needSignature.contains(c.Id) && c.Signature_Captured__c != true && SampleConfig.load().enforceRules) {
                c.addError('The doctor\'s signature is required for the samples on this call.');
            }
            if (controlled.contains(c.Id)) {
                if (!manager) c.addError('A submitted call with controlled substance samples can not be unlocked.');
                else c.Signature_Captured__c = false;      // a manager may unlock it, but the doctor must sign again
            }
        }
    }

    public static void afterCallSubmit(List<Call_Visit_Report__c> news, Map<Id, Call_Visit_Report__c> oldMap) {
        Set<Id> submitted = new Set<Id>();
        for (Call_Visit_Report__c c : news) {
            Call_Visit_Report__c o = oldMap == null ? null : oldMap.get(c.Id);
            if (c.Record_Status__c == 'Submitted' && (o == null || o.Record_Status__c != 'Submitted')) submitted.add(c.Id);
        }
        if (submitted.isEmpty()) return;
        Map<Id, Sample_Drop__c> drops = new Map<Id, Sample_Drop__c>([SELECT Id FROM Sample_Drop__c WHERE CVR__c IN :submitted AND Transaction__c = null]);
        if (!drops.isEmpty()) createTransactions(drops.keySet());
    }
}