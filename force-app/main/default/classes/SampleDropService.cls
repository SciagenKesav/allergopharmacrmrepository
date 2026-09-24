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
                       CVR__r.Signature_GPS__Latitude__s, CVR__r.Signature_GPS__Longitude__s, CVR__r.Signee_Name__c, CVR__r.Start_Time__c, CVR__r.Unlock_Count__c
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
                    Device_Type__c = 'iPad',
                    // Client_Id__c is a retry-idempotency key: a genuine retried push of THIS
                    // submission attempt must collide (same key) so a duplicate insert is
                    // rejected, but a fresh disbursement created after an unlock (SM-UNL-03,
                    // SampleDropService.reverseDisbursements clears Transaction__c so this
                    // same Sample_Drop__c row is re-processed) is a different event and must
                    // NOT collide with the drop's earlier disbursement — otherwise the
                    // resubmit silently fails as a "duplicate" and never re-posts. Call_Visit_Report__c.
                    // Unlock_Count__c already exists precisely to distinguish these generations.
                    Client_Id__c = 'DROP-' + d.Id + '-U' + (c.Unlock_Count__c == null ? 0 : c.Unlock_Count__c.intValue()));
                txns.add(t);
            }
            List<Database.SaveResult> results = Database.insert(txns, false);
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
        Boolean manager = FeatureManagement.checkPermission('Manage_Sample_Inventory');
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

    /**
     * SM-UNL-01..03 (D3/D14): a call with samples leaving 'Submitted' — via either
     * unlock path (the Support-ticket flow, SupportUnlockService.unlock, or a direct
     * Sample Admin unlock behind Sample_Unlock_Calls) — must reverse every Disbursement
     * it already posted, not edit them in place. Fires from SampleCallTrigger's existing
     * after-update leg, right after beforeCallUpdate's own unlock validation already ran
     * (and would have blocked the save entirely for an unauthorized controlled-substance
     * unlock) — so by the time this runs, the status change is already committed and
     * legitimate. Resubmitting later re-creates fresh Disbursements from whatever the
     * call's sample lines say at that point (createTransactions only ever processes a
     * Sample_Drop__c whose Transaction__c is null), so nothing here has to guess what the
     * rep will change.
     */
    public static void afterCallUnlock(List<Call_Visit_Report__c> news, Map<Id, Call_Visit_Report__c> oldMap) {
        if (oldMap == null) return;
        Set<Id> unlockedIds = new Set<Id>();
        for (Call_Visit_Report__c c : news) {
            Call_Visit_Report__c o = oldMap.get(c.Id);
            if (o != null && o.Record_Status__c == 'Submitted' && c.Record_Status__c != 'Submitted') unlockedIds.add(c.Id);
        }
        if (!unlockedIds.isEmpty()) reverseDisbursements(unlockedIds);
    }

    /** Reverses every posted Disbursement for these calls and frees their drop lines
     *  (clears Sample_Drop__c.Transaction__c) so a later resubmit posts fresh ones. */
    public static void reverseDisbursements(Set<Id> callIds) {
        List<Sample_Drop__c> drops = [SELECT Id, Transaction__c FROM Sample_Drop__c WHERE CVR__c IN :callIds AND Transaction__c != null];
        if (drops.isEmpty()) return;
        Set<Id> txnIds = new Set<Id>();
        for (Sample_Drop__c d : drops) txnIds.add(d.Transaction__c);

        List<Sample_Transaction__c> originals = [
            SELECT Id, Sample_Lot__c, Product__c, Quantity__c, HCP_Account__c, Call_Report__c, Sample_Drop__c,
                   Pack_Size_At_Transaction__c, Unit_Value_At_Transaction__c
            FROM Sample_Transaction__c
            WHERE Id IN :txnIds AND Transaction_Type__c = 'Disbursement' AND Inventory_Applied__c = true
        ];
        if (originals.isEmpty()) return;

        List<Sample_Transaction__c> reversals = new List<Sample_Transaction__c>();
        for (Sample_Transaction__c o : originals) {
            reversals.add(new Sample_Transaction__c(
                Transaction_Type__c = 'Reversal', Status__c = 'Completed', Sample_Lot__c = o.Sample_Lot__c, Product__c = o.Product__c,
                // Same magnitude as what was taken; SampleTransactionService applies it
                // with a positive sign, restoring the lot. Pack size/unit value are
                // copied from the original rather than left to re-default to the
                // product's CURRENT price — an undo must match what was actually
                // added, even if the price master has since changed.
                Quantity__c = o.Quantity__c, Pack_Size_At_Transaction__c = o.Pack_Size_At_Transaction__c,
                Unit_Value_At_Transaction__c = o.Unit_Value_At_Transaction__c, HCP_Account__c = o.HCP_Account__c,
                Call_Report__c = o.Call_Report__c, Sample_Drop__c = o.Sample_Drop__c, Paired_Transaction__c = o.Id,
                Performed_By__c = UserInfo.getUserId(), Performed_At__c = System.now(),
                Notes__c = ('Reversal of ' + o.Id + ' — call ' + o.Call_Report__c + ' was unlocked for correction.').left(255),
                Client_Id__c = 'REV-' + o.Id));
        }
        insert reversals;

        List<Sample_Drop__c> clearLinks = new List<Sample_Drop__c>();
        for (Sample_Drop__c d : drops) {
            clearLinks.add(new Sample_Drop__c(Id = d.Id, Transaction__c = null, Eligibility_Status__c = null, Eligibility_Message__c = null));
        }
        update clearLinks;
    }
}