/**
 * The sample ledger. Every movement of free samples is a Sample_Transaction__c.
 *
 * beforeSave decides what a transaction does (validates it, snapshots the
 * product value and the doctor's details, works out the signed effect on the
 * lot and flags it applied). afterSave then moves the stock. Splitting it this
 * way means a transaction can never move stock twice, and a disbursement the
 * rep has already physically handed over is never rejected: any shortfall is
 * recorded so an adjustment can fix the books.
 *
 * Without sharing: a transfer or receipt changes lots owned by another rep.
 */
public without sharing class SampleTransactionService {

    public static final String T_RECEIPT = 'Receipt';
    public static final String T_DISBURSEMENT = 'Disbursement';
    public static final String T_TRANSFER_OUT = 'Transfer_Out';
    public static final String T_TRANSFER_IN = 'Transfer_In';
    public static final String T_RETURN = 'Return';
    public static final String T_ADJUSTMENT = 'Adjustment';
    public static final Decimal LARGE_ADJUSTMENT_SHARE = 0.10;

    private static Boolean followUpRunning = false;

    /**
     * Set by trusted server code that creates transactions itself (SampleDropService after the
     * UCPMP limit engine has passed the drop). Direct API inserts never have it.
     */
    public static Boolean systemOrigin = false;

    public static final String DIRECT_DISBURSEMENT =
        'Samples given to a doctor must be recorded as a sample line on a call report, so the UCPMP limits are checked.';
    public static final String HELD_FOR_APPROVAL = 'Adding stock needs sample manager approval.';

    // Fields the ledger itself owns: never taken from a client.
    private static final List<String> SERVICE_FIELDS = new List<String>{ 'Inventory_Applied__c', 'Inventory_Effect__c', 'Inventory_Shortfall__c' };
    // What a transaction is: a rep can't change these after creating it (a sample manager can).
    private static final List<String> IDENTITY_FIELDS = new List<String>{
        'Transaction_Type__c', 'Quantity__c', 'Product__c', 'Sample_Lot__c', 'HCP_Account__c', 'To_User__c', 'From_User__c',
        'Performed_By__c', 'Approved_By__c', 'Approved_At__c', 'Unit_Value_At_Transaction__c', 'Pack_Size_At_Transaction__c'
    };

    // ------------------------------------------------------------------ before

    public static void beforeSave(List<Sample_Transaction__c> rows, Map<Id, Sample_Transaction__c> oldMap) {
        Set<Id> lotIds = new Set<Id>();
        Set<Id> productIds = new Set<Id>();
        Set<Id> hcpIds = new Set<Id>();
        Set<Id> warehouseIds = new Set<Id>();
        for (Sample_Transaction__c r : rows) {
            if (r.Sample_Lot__c != null) lotIds.add(r.Sample_Lot__c);
            if (r.Product__c != null) productIds.add(r.Product__c);
            if (r.HCP_Account__c != null) hcpIds.add(r.HCP_Account__c);
            if (r.To_Warehouse__c != null) warehouseIds.add(r.To_Warehouse__c);
        }
        Map<Id, Sample_Lot__c> lots = new Map<Id, Sample_Lot__c>([
            SELECT Id, Product__c, Status__c, Available_Quantity__c, Initial_Quantity__c, Lot_Number__c, Expiry_Date__c,
                   Cold_Chain_Tag_Number__c, Cold_Chain_Status__c, Owner_User__c
            FROM Sample_Lot__c WHERE Id IN :lotIds
        ]);
        for (Sample_Lot__c l : lots.values()) productIds.add(l.Product__c);
        Map<Id, Product__c> products = new Map<Id, Product__c>([
            SELECT Id, Name, Is_Sample_Product__c, Is_Restricted__c, Requires_Lot_Number__c, Requires_Cold_Chain__c,
                   Is_Controlled_Substance__c, Sample_Unit_Value_INR__c, Pack_Size__c
            FROM Product__c WHERE Id IN :productIds
        ]);
        Map<Id, Sciagen_Account__c> hcps = new Map<Id, Sciagen_Account__c>([
            SELECT Id, Speciality__c, Billing_Street__c, Billing_City__c, Billing_State__c, Billing_Postal_Code__c
            FROM Sciagen_Account__c WHERE Id IN :hcpIds
        ]);
        Map<Id, Sample_Warehouse__c> warehouses = new Map<Id, Sample_Warehouse__c>([
            SELECT Id, Has_Cold_Storage__c, Is_Active__c FROM Sample_Warehouse__c WHERE Id IN :warehouseIds
        ]);
        Boolean isManager = SampleAccess.isManager();
        Map<Id, Decimal> running = new Map<Id, Decimal>();
        for (Sample_Lot__c l : lots.values()) running.put(l.Id, l.Available_Quantity__c == null ? 0 : l.Available_Quantity__c);

        Set<Id> repIds = new Set<Id>();
        if (oldMap == null) {
            for (Sample_Transaction__c r : rows) repIds.add(r.Performed_By__c != null ? r.Performed_By__c : UserInfo.getUserId());
        }
        Map<Id, String> territories = SampleTerritoryService.namesFor(repIds);
        Boolean trusted = systemOrigin || followUpRunning;
        // Admins (Modify All Data) are treated like sample managers; checked only when it matters.
        Boolean privileged = trusted || isManager || SciagenAccess.hasModifyAllData();
        for (Sample_Transaction__c r : rows) {
            Sample_Transaction__c old = oldMap == null ? null : oldMap.get(r.Id);
            Sample_Lot__c lot = r.Sample_Lot__c == null ? null : lots.get(r.Sample_Lot__c);
            if (!trusted) {
                protectServiceFields(r, old);
                if (old != null && SciagenAccess.mergeInProgress) continue;   // merge re-points HCP_Account__c only
                if (!clientChangeAllowed(r, old, lot, isManager, privileged)) continue;
            }
            if (old == null && r.Rep_Territory__c == null) r.Rep_Territory__c = territories.get(r.Performed_By__c != null ? r.Performed_By__c : UserInfo.getUserId());
            if (r.Product__c == null && lot != null) r.Product__c = lot.Product__c;
            Product__c product = r.Product__c == null ? null : products.get(r.Product__c);
            if (old == null) defaults(r, lot, product, hcps.get(r.HCP_Account__c));
            else if (!lockedEditsAllowed(r, old, isManager)) continue;
            validateAndDecide(r, old, lot, product, warehouses.get(r.To_Warehouse__c), running, isManager);
        }
    }

    /** Inventory_* are the ledger's own bookkeeping: a client can never set them (it could otherwise move stock at will). */
    private static void protectServiceFields(Sample_Transaction__c r, Sample_Transaction__c old) {
        for (String f : SERVICE_FIELDS) r.put(f, old == null ? (f == 'Inventory_Applied__c' ? (Object) false : null) : old.get(f));
    }

    /**
     * Rules for transactions written directly by a client (iPad, web, API) rather than by trusted
     * server code (QA-31 / S-06). Returns false after adding an error.
     */
    private static Boolean clientChangeAllowed(Sample_Transaction__c r, Sample_Transaction__c old, Sample_Lot__c lot,
                                               Boolean isManager, Boolean privileged) {
        String type = r.Transaction_Type__c;
        Id me = UserInfo.getUserId();
        if (old == null) {
            // (a) Hand-outs only through Sample_Drop__c, where SampleEligibilityService / SampleLimitChecker run.
            if (type == T_DISBURSEMENT && !SciagenAccess.hasModifyAllData()) { r.addError(DIRECT_DISBURSEMENT); return false; }
            if (privileged) return true;
            if (type == T_RECEIPT) { r.addError('Only a sample manager can record a receipt of stock.'); return false; }
            if (type == T_TRANSFER_IN) { r.addError('A transfer in is created by the sender\'s transfer out.'); return false; }
            if (r.Performed_By__c != null && r.Performed_By__c != me) { r.addError('You can only record your own sample transactions.'); return false; }
            if ((type == T_TRANSFER_OUT || type == T_RETURN || type == T_ADJUSTMENT) && lot != null && lot.Owner_User__c != me) {
                r.addError('You can only move stock from your own lot.'); return false;
            }
            // (c) Stock added by a rep (e.g. a recount that found more) waits for a sample manager.
            if (type == T_ADJUSTMENT && r.Quantity__c != null && r.Quantity__c > 0 && r.Status__c != 'Cancelled') {
                r.Status__c = 'Pending';
                r.Requires_Approval__c = true;
                r.Eligibility_Message__c = HELD_FOR_APPROVAL;
            }
            return true;
        }
        if (privileged) return true;
        // (b) The approval hold is not the rep's to lift.
        if (old.Requires_Approval__c == true && r.Requires_Approval__c != true) {
            r.addError('Only a sample manager can clear the approval hold on this transaction.'); return false;
        }
        for (String f : IDENTITY_FIELDS) {
            if (r.get(f) != old.get(f)) { r.addError('Only a sample manager can change ' + f + ' on a sample transaction.'); return false; }
        }
        if ((type == T_RECEIPT || type == T_TRANSFER_IN) && r.Status__c != old.Status__c) {
            if (r.To_User__c != null && r.To_User__c != me) { r.addError('Only the person receiving the stock can confirm it.'); return false; }
            if (r.Confirmed_Quantity__c != null && r.Quantity__c != null && r.Confirmed_Quantity__c > r.Quantity__c) {
                r.addError('You can confirm at most the ' + r.Quantity__c.intValue() + ' packs sent. Ask a sample manager to record extra stock.'); return false;
            }
        } else if (r.Confirmed_Quantity__c != old.Confirmed_Quantity__c) {
            r.addError('Only a sample manager can change the confirmed quantity.'); return false;
        }
        return true;
    }

    private static void defaults(Sample_Transaction__c r, Sample_Lot__c lot, Product__c product, Sciagen_Account__c hcp) {
        if (r.Performed_By__c == null) r.Performed_By__c = UserInfo.getUserId();
        if (r.Performed_At__c == null) r.Performed_At__c = System.now();
        if (product != null) {
            if (r.Unit_Value_At_Transaction__c == null) r.Unit_Value_At_Transaction__c = product.Sample_Unit_Value_INR__c;
            if (r.Pack_Size_At_Transaction__c == null) r.Pack_Size_At_Transaction__c = product.Pack_Size__c == null ? 1 : product.Pack_Size__c;
        }
        if (hcp != null) {
            if (r.HCP_Specialty__c == null) r.HCP_Specialty__c = hcp.Speciality__c == null ? null : hcp.Speciality__c.left(100);
            if (r.HCP_Address__c == null) {
                List<String> parts = new List<String>();
                for (String p : new List<String>{ hcp.Billing_Street__c, hcp.Billing_City__c, hcp.Billing_State__c, hcp.Billing_Postal_Code__c }) {
                    if (!String.isBlank(p)) parts.add(p);
                }
                if (!parts.isEmpty()) r.HCP_Address__c = String.join(parts, ', ').left(255);
            }
        }
        if (r.Transaction_Type__c == T_TRANSFER_OUT || r.Transaction_Type__c == T_RETURN) {
            if (r.From_User__c == null) r.From_User__c = UserInfo.getUserId();
            if (lot != null && r.Cold_Chain_Tag_Number__c == null) r.Cold_Chain_Tag_Number__c = lot.Cold_Chain_Tag_Number__c;
            if (lot != null && r.Cold_Chain_Status__c == null) r.Cold_Chain_Status__c = lot.Cold_Chain_Status__c;
        }
        if ((r.Transaction_Type__c == T_RECEIPT || r.Transaction_Type__c == T_TRANSFER_IN) && r.To_User__c != null) {
            r.OwnerId = r.To_User__c;
        }
        if (r.Transaction_Type__c == T_DISBURSEMENT && product != null && product.Is_Controlled_Substance__c == true) {
            r.After_Hours__c = isAfterHours(r.Performed_At__c);
        }
    }

    /** Once stock has moved, only a sample manager may change what the transaction is. */
    private static Boolean lockedEditsAllowed(Sample_Transaction__c r, Sample_Transaction__c old, Boolean isManager) {
        if (old.Inventory_Applied__c != true || isManager) return true;
        Boolean changed = r.Transaction_Type__c != old.Transaction_Type__c || r.Product__c != old.Product__c
            || r.Sample_Lot__c != old.Sample_Lot__c || r.Quantity__c != old.Quantity__c || r.Status__c != old.Status__c
            || r.To_User__c != old.To_User__c || r.From_User__c != old.From_User__c;
        if (changed) r.addError('This transaction has already moved stock and can only be changed by a sample manager.');
        return !changed;
    }

    private static void validateAndDecide(Sample_Transaction__c r, Sample_Transaction__c old, Sample_Lot__c lot, Product__c product,
                                          Sample_Warehouse__c toWarehouse, Map<Id, Decimal> running, Boolean isManager) {
        String type = r.Transaction_Type__c;
        Boolean becameActive = old == null || old.Status__c != r.Status__c;
        Boolean wasApplied = old != null && old.Inventory_Applied__c == true;
        Decimal qty = r.Quantity__c == null ? 0 : r.Quantity__c;
        Boolean cold = product != null && product.Requires_Cold_Chain__c == true;

        // Stock has already moved for this transaction: a follow-up edit (linking the paired transaction,
        // recording the destination lot) must not re-run the checks against a lot it has since emptied.
        Boolean reversal = wasApplied && type == T_DISBURSEMENT && (r.Status__c == 'Cancelled' || r.Status__c == 'Rejected') && becameActive;
        if (wasApplied && !reversal) return;

        if (old != null && old.Requires_Approval__c == true && old.Status__c == 'Pending'
            && (r.Status__c == 'Completed' || r.Status__c == 'Confirmed')) {
            if (!isManager) { r.addError('This transaction is held for manager approval.'); return; }
            r.Approved_By__c = UserInfo.getUserId();
            r.Approved_At__c = System.now();
        }
        if (product != null && r.Sample_Lot__c != null && lot != null && lot.Product__c != r.Product__c) {
            r.addError('That lot belongs to a different product.');
            return;
        }
        if (type == T_DISBURSEMENT) {
            if (r.HCP_Account__c == null) { r.addError('A disbursement needs the doctor it was given to.'); return; }
            if (product != null && product.Is_Sample_Product__c != true) { r.addError('This product is not set up as a sample product.'); return; }
            if (product != null && product.Is_Restricted__c == true) { r.addError('This product is restricted and can not be sampled (UCPMP 2024 clause 5.1(ii)).'); return; }
            if (product != null && product.Requires_Lot_Number__c == true && lot == null) { r.addError('A lot is required for this product.'); return; }
            if (lot != null && lot.Status__c != 'Active' && lot.Status__c != 'Depleted' && !wasApplied) {
                r.addError('Lot ' + lot.Lot_Number__c + ' is ' + lot.Status__c + ' and can not be given out.'); return;
            }
            if (lot != null && lot.Expiry_Date__c < Date.today() && !wasApplied) { r.addError('Lot ' + lot.Lot_Number__c + ' has expired.'); return; }
            if (cold && !coldChainComplete(r)) { r.addError('Cold chain product: enter the tag number and status.'); return; }
            if (cold && r.Cold_Chain_Status__c == 'Breach') {
                r.addError('Cold chain breach detected. Cannot distribute. Return to warehouse for quality assessment.'); return;
            }
            if (product != null && product.Is_Controlled_Substance__c == true && r.Status__c == 'Completed' && r.Signature_Captured__c != true) {
                r.addError('A controlled substance needs the doctor\'s signature.'); return;
            }
        } else if (type == T_TRANSFER_OUT) {
            if (lot == null) { r.addError('Choose the lot to transfer from.'); return; }
            if (r.To_User__c == null) { r.addError('Choose who the samples are going to.'); return; }
            if (lot.Status__c != 'Active') { r.addError('Only an active lot can be transferred.'); return; }
            if (cold && !coldChainComplete(r)) { r.addError('Cold chain product: enter the tag number and status.'); return; }
            if (cold && r.Cold_Chain_Status__c == 'Breach') {
                r.addError('Cold chain breach detected. Cannot transfer. Return to warehouse for quality assessment.'); return;
            }
        } else if (type == T_RETURN) {
            if (lot == null) { r.addError('Choose the lot to return from.'); return; }
            if (cold && !coldChainComplete(r)) { r.addError('Cold chain product: enter the tag number and status.'); return; }
            if (cold && (toWarehouse == null || toWarehouse.Has_Cold_Storage__c != true)) {
                r.addError('Cold chain samples can only be returned to a warehouse with cold storage.'); return;
            }
        } else if (type == T_RECEIPT) {
            if (lot == null) { r.addError('A receipt needs the lot being received.'); return; }
            if (r.To_User__c == null && r.To_Warehouse__c == null) { r.addError('Say who or where the samples are received by.'); return; }
        } else if (type == T_ADJUSTMENT) {
            if (lot == null) { r.addError('Choose the lot to adjust.'); return; }
        }

        // What will this transaction do to the lot, and has that happened yet?
        Boolean applies = false;
        Decimal effect = 0;
        Decimal shortfall = 0;
        String status = r.Status__c;
        Decimal available = lot == null ? 0 : running.get(lot.Id);

        if (type == T_DISBURSEMENT && status == 'Completed' && !wasApplied) {
            applies = true;
            Decimal take = Math.min(qty, available);
            effect = -take;
            shortfall = qty - take;
        } else if (type == T_RECEIPT && (status == 'Confirmed' || status == 'Completed') && !wasApplied) {
            if (cold && !coldChainComplete(r)) { r.addError('Cold chain product: enter the tag number and status when confirming the receipt.'); return; }
            applies = true;
            effect = r.Confirmed_Quantity__c != null ? r.Confirmed_Quantity__c : qty;
        } else if (type == T_TRANSFER_OUT && status == 'Completed' && !wasApplied) {
            if (qty > available) { r.addError('Only ' + available.intValue() + ' packs are available in lot ' + lot.Lot_Number__c + '.'); return; }
            applies = true;
            effect = -qty;
        } else if (type == T_TRANSFER_IN && (status == 'Confirmed' || status == 'Completed') && !wasApplied) {
            if (cold && !coldChainComplete(r)) { r.addError('Cold chain product: enter the tag number and status when confirming the transfer.'); return; }
            applies = true;
            effect = r.Confirmed_Quantity__c != null ? r.Confirmed_Quantity__c : qty;
        } else if (type == T_TRANSFER_IN && (status == 'Rejected' || status == 'Cancelled') && !wasApplied && old != null) {
            applies = true;                   // the stock goes back to the sender's lot
            effect = qty;
        } else if (type == T_RETURN && status == 'Completed' && !wasApplied) {
            if (qty > available) { r.addError('Only ' + available.intValue() + ' packs are available in lot ' + lot.Lot_Number__c + '.'); return; }
            applies = true;
            effect = -qty;
        } else if (type == T_ADJUSTMENT && status == 'Completed' && !wasApplied) {
            if (available + qty < 0) { r.addError('That adjustment would leave lot ' + lot.Lot_Number__c + ' below zero.'); return; }
            applies = true;
            effect = qty;
        } else if (type == T_DISBURSEMENT && wasApplied && (status == 'Cancelled' || status == 'Rejected') && becameActive) {
            applies = true;                   // reversal by a sample manager
            effect = -(old.Inventory_Effect__c == null ? 0 : old.Inventory_Effect__c);
            r.Inventory_Applied__c = false;
            r.Inventory_Effect__c = effect;
            if (lot != null) running.put(lot.Id, available + effect);
            return;
        }
        if (applies) {
            r.Inventory_Applied__c = true;
            r.Inventory_Effect__c = effect;
            r.Inventory_Shortfall__c = shortfall;
            if (lot != null && type != T_TRANSFER_IN) running.put(lot.Id, available + effect);
        }
    }

    private static Boolean coldChainComplete(Sample_Transaction__c r) {
        return !String.isBlank(r.Cold_Chain_Tag_Number__c) && !String.isBlank(r.Cold_Chain_Status__c);
    }

    private static Boolean isAfterHours(Datetime at) {
        if (at == null) return false;
        return !SciagenAppConfig.isWithinCallHours(at) || SciagenAppConfig.isNonWorkingDay(at);
    }

    // ------------------------------------------------------------------- after

    public static void afterSave(List<Sample_Transaction__c> rows, Map<Id, Sample_Transaction__c> oldMap) {
        if (followUpRunning) return;
        List<Sample_Transaction__c> moved = new List<Sample_Transaction__c>();
        List<Sample_Transaction__c> reversed = new List<Sample_Transaction__c>();
        for (Sample_Transaction__c r : rows) {
            Sample_Transaction__c old = oldMap == null ? null : oldMap.get(r.Id);
            Boolean wasApplied = old != null && old.Inventory_Applied__c == true;
            if (r.Inventory_Applied__c == true && !wasApplied) moved.add(r);
            else if (r.Inventory_Applied__c != true && wasApplied) reversed.add(r);
        }
        if (moved.isEmpty() && reversed.isEmpty()) {
            notifyBreaches(rows, oldMap);
            return;
        }

        Set<Id> lotIds = new Set<Id>();
        for (Sample_Transaction__c r : moved) if (r.Sample_Lot__c != null) lotIds.add(r.Sample_Lot__c);
        for (Sample_Transaction__c r : reversed) if (r.Sample_Lot__c != null) lotIds.add(r.Sample_Lot__c);
        Map<Id, Sample_Lot__c> lots = new Map<Id, Sample_Lot__c>([
            SELECT Id, Product__c, Lot_Number__c, Batch_Lot_Id__c, Manufactured_Date__c, Expiry_Date__c, Available_Quantity__c,
                   Initial_Quantity__c, Storage_Conditions__c, Cold_Chain_Tag_Number__c, Cold_Chain_Status__c, Owner_User__c, OwnerId, Status__c
            FROM Sample_Lot__c WHERE Id IN :lotIds FOR UPDATE
        ]);

        Map<Id, Decimal> delta = new Map<Id, Decimal>();
        List<Sample_Transaction__c> disbursements = new List<Sample_Transaction__c>();
        List<Sample_Transaction__c> transferOuts = new List<Sample_Transaction__c>();
        List<Sample_Transaction__c> transferIns = new List<Sample_Transaction__c>();
        List<Sample_Transaction__c> returns = new List<Sample_Transaction__c>();
        List<Sample_Transaction__c> adjustments = new List<Sample_Transaction__c>();

        for (Sample_Transaction__c r : moved) {
            String type = r.Transaction_Type__c;
            Decimal effect = r.Inventory_Effect__c == null ? 0 : r.Inventory_Effect__c;
            if (type == T_TRANSFER_IN && (r.Status__c == 'Confirmed' || r.Status__c == 'Completed')) {
                transferIns.add(r);                     // goes into the recipient's lot, handled below
                continue;
            }
            if (r.Sample_Lot__c == null) continue;
            if (type == T_TRANSFER_IN) {                // rejected: back to the sender's lot
                addDelta(delta, r.Sample_Lot__c, effect);
                continue;
            }
            addDelta(delta, r.Sample_Lot__c, effect);
            if (type == T_DISBURSEMENT) disbursements.add(r);
            else if (type == T_TRANSFER_OUT) transferOuts.add(r);
            else if (type == T_RETURN) returns.add(r);
            else if (type == T_ADJUSTMENT) adjustments.add(r);
        }
        for (Sample_Transaction__c r : reversed) {
            if (r.Sample_Lot__c != null) addDelta(delta, r.Sample_Lot__c, r.Inventory_Effect__c == null ? 0 : r.Inventory_Effect__c);
        }

        Map<Id, Sample_Lot__c> lotUpdates = new Map<Id, Sample_Lot__c>();
        for (Id lotId : delta.keySet()) {
            Sample_Lot__c l = lots.get(lotId);
            Decimal now = (l.Available_Quantity__c == null ? 0 : l.Available_Quantity__c) + delta.get(lotId);
            lotUpdates.put(lotId, new Sample_Lot__c(Id = lotId, Available_Quantity__c = Math.max(0, now)));
        }

        followUpRunning = true;
        try {
            List<Sample_Transaction__c> linkUpdates = new List<Sample_Transaction__c>();
            landTransfersIn(transferIns, lots, lotUpdates, linkUpdates);
            if (!lotUpdates.isEmpty()) update lotUpdates.values();
            createTransfersIn(transferOuts, lots, linkUpdates);
            if (!linkUpdates.isEmpty()) update linkUpdates;
            SampleExpenditureService.applyDisbursements(disbursements, 1);
            SampleExpenditureService.applyDisbursements(reversed, -1);
            SampleAllocationService.applyDisbursements(disbursements, 1);
            SampleAllocationService.applyDisbursements(reversed, -1);
            notifyReturns(returns, lots);
            notifyLargeAdjustments(adjustments, lots);
            notifyShortfalls(disbursements);
            notifyBreaches(rows, oldMap);
        } finally {
            followUpRunning = false;
        }
    }

    private static void addDelta(Map<Id, Decimal> delta, Id lotId, Decimal amount) {
        delta.put(lotId, (delta.containsKey(lotId) ? delta.get(lotId) : 0) + amount);
    }

    /** A sender's Transfer_Out creates the recipient's pending Transfer_In. */
    private static void createTransfersIn(List<Sample_Transaction__c> outs, Map<Id, Sample_Lot__c> lots, List<Sample_Transaction__c> linkUpdates) {
        List<Sample_Transaction__c> ins = new List<Sample_Transaction__c>();
        for (Sample_Transaction__c o : outs) {
            ins.add(new Sample_Transaction__c(
                Transaction_Type__c = T_TRANSFER_IN, Status__c = 'Pending', Product__c = o.Product__c, Sample_Lot__c = o.Sample_Lot__c,
                Quantity__c = o.Quantity__c, From_User__c = o.From_User__c, To_User__c = o.To_User__c, Paired_Transaction__c = o.Id,
                Cold_Chain_Tag_Number__c = o.Cold_Chain_Tag_Number__c, Cold_Chain_Status__c = o.Cold_Chain_Status__c,
                Custom_Text__c = o.Custom_Text__c, Performed_By__c = o.To_User__c, Shipment_Reference__c = o.Shipment_Reference__c));
        }
        if (ins.isEmpty()) return;
        insert ins;
        for (Integer i = 0; i < outs.size(); i++) {
            linkUpdates.add(new Sample_Transaction__c(Id = outs[i].Id, Paired_Transaction__c = ins[i].Id));
        }
    }

    /** A confirmed Transfer_In lands in the recipient's own lot (created if they have none for this lot number). */
    private static void landTransfersIn(List<Sample_Transaction__c> ins, Map<Id, Sample_Lot__c> lots, Map<Id, Sample_Lot__c> lotUpdates,
                                        List<Sample_Transaction__c> linkUpdates) {
        if (ins.isEmpty()) return;
        Set<String> keys = new Set<String>();
        Map<Id, Sample_Lot__c> sourceOf = new Map<Id, Sample_Lot__c>();
        for (Sample_Transaction__c t : ins) {
            Sample_Lot__c src = lots.get(t.Sample_Lot__c);
            if (src == null) continue;
            sourceOf.put(t.Id, src);
            keys.add(SampleLotService.keyFor(new Sample_Lot__c(Product__c = src.Product__c, Owner_User__c = t.To_User__c, Lot_Number__c = src.Lot_Number__c)));
        }
        Map<String, Sample_Lot__c> existing = new Map<String, Sample_Lot__c>();
        for (Sample_Lot__c l : [SELECT Id, Lot_Key__c, Available_Quantity__c, Batch_Lot_Id__c FROM Sample_Lot__c WHERE Lot_Key__c IN :keys FOR UPDATE]) {
            existing.put(l.Lot_Key__c, l);
        }
        List<Sample_Lot__c> toInsert = new List<Sample_Lot__c>();
        List<Sample_Transaction__c> waiting = new List<Sample_Transaction__c>();
        for (Sample_Transaction__c t : ins) {
            Sample_Lot__c src = sourceOf.get(t.Id);
            if (src == null) continue;
            Decimal qty = t.Inventory_Effect__c == null ? 0 : t.Inventory_Effect__c;
            String key = SampleLotService.keyFor(new Sample_Lot__c(Product__c = src.Product__c, Owner_User__c = t.To_User__c, Lot_Number__c = src.Lot_Number__c));
            Sample_Lot__c mine = existing.get(key);
            if (mine != null) {
                Sample_Lot__c upd = lotUpdates.containsKey(mine.Id) ? lotUpdates.get(mine.Id) : new Sample_Lot__c(Id = mine.Id, Available_Quantity__c = mine.Available_Quantity__c == null ? 0 : mine.Available_Quantity__c);
                upd.Available_Quantity__c = (upd.Available_Quantity__c == null ? 0 : upd.Available_Quantity__c) + qty;
                if (!String.isBlank(src.Batch_Lot_Id__c)) upd.Batch_Lot_Id__c = src.Batch_Lot_Id__c;
                lotUpdates.put(mine.Id, upd);
                mine.Available_Quantity__c = upd.Available_Quantity__c;
                linkUpdates.add(new Sample_Transaction__c(Id = t.Id, Destination_Lot__c = mine.Id));
            } else {
                Sample_Lot__c fresh = new Sample_Lot__c(Product__c = src.Product__c, Lot_Number__c = src.Lot_Number__c, Batch_Lot_Id__c = src.Batch_Lot_Id__c,
                    Manufactured_Date__c = src.Manufactured_Date__c, Expiry_Date__c = src.Expiry_Date__c, Initial_Quantity__c = qty,
                    Available_Quantity__c = qty, Status__c = 'Active', Owner_User__c = t.To_User__c, Source_Lot__c = src.Id,
                    Storage_Conditions__c = src.Storage_Conditions__c, Cold_Chain_Tag_Number__c = t.Cold_Chain_Tag_Number__c,
                    Cold_Chain_Status__c = t.Cold_Chain_Status__c);
                toInsert.add(fresh);
                waiting.add(t);
            }
        }
        if (!toInsert.isEmpty()) {
            insert toInsert;
            for (Integer i = 0; i < waiting.size(); i++) linkUpdates.add(new Sample_Transaction__c(Id = waiting[i].Id, Destination_Lot__c = toInsert[i].Id));
        }
    }

    // ----------------------------------------------------------------- alerts

    private static void notifyReturns(List<Sample_Transaction__c> returns, Map<Id, Sample_Lot__c> lots) {
        if (returns.isEmpty()) return;
        Set<Id> admins = SampleNotifier.sampleAdmins();
        for (Sample_Transaction__c r : returns) {
            Sample_Lot__c l = lots.get(r.Sample_Lot__c);
            SampleNotifier.notify(admins, 'Sample return submitted',
                Math.abs(r.Quantity__c.intValue()) + ' packs of lot ' + (l == null ? '' : l.Lot_Number__c) + ' returned to ' + (r.Return_To__c == null ? 'the warehouse' : r.Return_To__c)
                + ' (' + r.Return_Reason__c + ').', r.Id);
        }
    }

    private static void notifyLargeAdjustments(List<Sample_Transaction__c> adjustments, Map<Id, Sample_Lot__c> lots) {
        for (Sample_Transaction__c a : adjustments) {
            Sample_Lot__c l = lots.get(a.Sample_Lot__c);
            if (l == null || l.Initial_Quantity__c == null || l.Initial_Quantity__c == 0) continue;
            if (Math.abs(a.Quantity__c) > l.Initial_Quantity__c * LARGE_ADJUSTMENT_SHARE) {
                Set<Id> managers = SampleNotifier.managersOf(new Set<Id>{ a.Performed_By__c != null ? a.Performed_By__c : UserInfo.getUserId() });
                SampleNotifier.notify(managers, 'Large sample adjustment for review',
                    'Adjustment of ' + a.Quantity__c.intValue() + ' packs (' + a.Adjustment_Reason__c + ') on lot ' + l.Lot_Number__c + ' is more than 10% of the lot.', a.Id);
            }
        }
    }

    private static void notifyShortfalls(List<Sample_Transaction__c> disbursements) {
        for (Sample_Transaction__c d : disbursements) {
            if (d.Inventory_Shortfall__c != null && d.Inventory_Shortfall__c > 0) {
                Set<Id> who = SampleNotifier.managersOf(new Set<Id>{ d.Performed_By__c });
                who.add(d.Performed_By__c);
                SampleNotifier.notify(who, 'Sample stock does not match',
                    d.Inventory_Shortfall__c.intValue() + ' packs were given but not on the books. Record an adjustment for the lot.', d.Id);
            }
        }
    }

    private static void notifyBreaches(List<Sample_Transaction__c> rows, Map<Id, Sample_Transaction__c> oldMap) {
        for (Sample_Transaction__c r : rows) {
            Sample_Transaction__c old = oldMap == null ? null : oldMap.get(r.Id);
            if (r.Cold_Chain_Status__c == 'Breach' && (old == null || old.Cold_Chain_Status__c != 'Breach')) {
                Set<Id> who = SampleNotifier.managersOf(new Set<Id>{ r.Performed_By__c != null ? r.Performed_By__c : UserInfo.getUserId() });
                who.addAll(SampleNotifier.sampleAdmins());
                SampleNotifier.notify(who, 'Cold chain breach reported', 'A cold chain breach was recorded on transaction ' + r.Id + '. Do not distribute this stock.', r.Id);
            }
        }
    }
}