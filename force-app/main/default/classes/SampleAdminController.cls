/**
 * Backend for the Sample Administration page: every rep's lots, shipments and
 * pending receipts, the full transaction log, discrepancies, and the manager
 * approvals (held disbursements and limit override requests). Reading needs
 * the Sample Admin permission set; changing stock also needs Manage Sample Inventory.
 */
public with sharing class SampleAdminController {

    private static final Integer ROW_LIMIT = 1000;

    public class Option implements Comparable {
        @AuraEnabled public String value;
        @AuraEnabled public String label;
        Option(String v, String l) { value = v; label = l; }
        public Integer compareTo(Object other) { return label.compareTo(((Option) other).label); }
    }

    public class FilterOptions {
        @AuraEnabled public List<Option> products = new List<Option>();
        @AuraEnabled public List<Option> reps = new List<Option>();
        @AuraEnabled public List<Option> territories = new List<Option>();
        @AuraEnabled public List<Option> warehouses = new List<Option>();
        @AuraEnabled public Boolean canManage;
    }

    public class LotRow {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String lotNumber;
        @AuraEnabled public String productName;
        @AuraEnabled public String repName;
        @AuraEnabled public String warehouseName;
        @AuraEnabled public Integer initial;
        @AuraEnabled public Integer available;
        @AuraEnabled public String expiry;
        @AuraEnabled public Integer daysToExpiry;
        @AuraEnabled public String status;
        @AuraEnabled public String coldChain;
        @AuraEnabled public String url;
    }

    public class TxnRow {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String type;
        @AuraEnabled public String status;
        @AuraEnabled public String performedAt;
        @AuraEnabled public String repName;
        @AuraEnabled public String hcpName;
        @AuraEnabled public String registration;
        @AuraEnabled public String productName;
        @AuraEnabled public String lotNumber;
        @AuraEnabled public Integer quantity;
        @AuraEnabled public Decimal valueInr;
        @AuraEnabled public Boolean signature;
        @AuraEnabled public String coldChain;
        @AuraEnabled public String reason;
        @AuraEnabled public String toName;
        @AuraEnabled public String shipmentRef;
        @AuraEnabled public Integer ageDays;
        @AuraEnabled public String note;
        @AuraEnabled public String url;
    }

    public class Discrepancy {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String kind;          // Count difference, Adjustment, Given without stock
        @AuraEnabled public String repName;
        @AuraEnabled public String productName;
        @AuraEnabled public String lotNumber;
        @AuraEnabled public Integer quantity;
        @AuraEnabled public Decimal percentOfLot;
        @AuraEnabled public Boolean flagged;
        @AuraEnabled public String occurredAt;
        @AuraEnabled public String reason;
        @AuraEnabled public String url;
    }

    public class OverrideRow {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String limitName;
        @AuraEnabled public String type;
        @AuraEnabled public Integer value;
        @AuraEnabled public String target;
        @AuraEnabled public String validFrom;
        @AuraEnabled public String validTo;
        @AuraEnabled public String reason;
    }

    public class Approvals {
        @AuraEnabled public List<TxnRow> heldTransactions = new List<TxnRow>();
        @AuraEnabled public List<OverrideRow> overrides = new List<OverrideRow>();
    }

    public class ShipmentInput {
        @AuraEnabled public String repUsername;
        @AuraEnabled public String repId;
        @AuraEnabled public String productId;
        @AuraEnabled public String skuCode;
        @AuraEnabled public String lotNumber;
        @AuraEnabled public String batchLotId;
        @AuraEnabled public String expiry;
        @AuraEnabled public Integer quantity;
        @AuraEnabled public String warehouseId;
        @AuraEnabled public String warehouseName;
        @AuraEnabled public String shipmentRef;
    }

    public class RowResult {
        @AuraEnabled public Integer row;
        @AuraEnabled public Boolean ok;
        @AuraEnabled public String message;
    }

    private static void requireManager() {
        if (!FeatureManagement.checkPermission('Manage_Sample_Inventory')) throw new AuraHandledException('Only a sample manager can change stock.');
    }

    private static String d(Date v) { return v == null ? null : String.valueOf(v); }
    private static String dt(Datetime v) { return v == null ? null : v.format('dd MMM yyyy HH:mm'); }

    // -------------------------------------------------------------- options

    @AuraEnabled(cacheable=false)
    public static FilterOptions getFilterOptions() {
        FilterOptions o = new FilterOptions();
        o.canManage = FeatureManagement.checkPermission('Manage_Sample_Inventory');
        for (Product__c p : [SELECT Id, Name FROM Product__c WHERE Is_Sample_Product__c = true ORDER BY Name]) o.products.add(new Option(p.Id, p.Name));
        Set<Id> seen = new Set<Id>();
        for (Sample_Lot__c l : [SELECT Owner_User__c, Owner_User__r.Name FROM Sample_Lot__c WHERE Owner_User__c != null LIMIT 2000]) {
            if (seen.add(l.Owner_User__c)) o.reps.add(new Option(l.Owner_User__c, l.Owner_User__r.Name));
        }
        for (User_Territory__c ut : [SELECT User__c, User__r.Name FROM User_Territory__c WHERE User__c != null LIMIT 2000]) {
            if (seen.add(ut.User__c)) o.reps.add(new Option(ut.User__c, ut.User__r.Name));
        }
        o.reps.sort();
        for (Territory__c t : [SELECT Id, Name FROM Territory__c ORDER BY Name LIMIT 1000]) o.territories.add(new Option(t.Id, t.Name));
        for (Sample_Warehouse__c w : [SELECT Id, Name FROM Sample_Warehouse__c WHERE Is_Active__c = true ORDER BY Name]) o.warehouses.add(new Option(w.Id, w.Name));
        return o;
    }

    // ----------------------------------------------------------- inventory

    @AuraEnabled(cacheable=false)
    public static List<LotRow> getLots(String productId, String repId, String territoryId, String status, Integer expiringInDays) {
        List<String> conds = new List<String>();
        Map<String, Object> binds = new Map<String, Object>();
        if (!String.isBlank(productId)) { conds.add('Product__c = :productId'); binds.put('productId', productId); }
        if (!String.isBlank(repId)) { conds.add('Owner_User__c = :repId'); binds.put('repId', repId); }
        if (!String.isBlank(territoryId)) {
            Set<Id> users = new Set<Id>();
            for (User_Territory__c ut : [SELECT User__c FROM User_Territory__c WHERE Territory__c = :territoryId]) users.add(ut.User__c);
            conds.add('Owner_User__c IN :users'); binds.put('users', users);
        }
        if (!String.isBlank(status)) { conds.add('Status__c = :status'); binds.put('status', status); }
        if (expiringInDays != null) { conds.add('Expiry_Date__c <= :until'); binds.put('until', Date.today().addDays(expiringInDays)); }
        String soql = 'SELECT Id, Name, Lot_Number__c, Product__r.Name, Owner_User__r.Name, Warehouse__r.Name, Initial_Quantity__c, Available_Quantity__c, Expiry_Date__c, Days_To_Expiry__c, '
            + 'Status__c, Cold_Chain_Required__c, Cold_Chain_Status__c FROM Sample_Lot__c'
            + (conds.isEmpty() ? '' : ' WHERE ' + String.join(conds, ' AND ')) + ' ORDER BY Owner_User__r.Name NULLS FIRST, Expiry_Date__c LIMIT ' + ROW_LIMIT;
        List<LotRow> out = new List<LotRow>();
        for (Sample_Lot__c l : (List<Sample_Lot__c>) Database.queryWithBinds(soql, binds, AccessLevel.USER_MODE)) {
            LotRow r = new LotRow();
            r.id = l.Id; r.name = l.Name; r.lotNumber = l.Lot_Number__c; r.productName = l.Product__r.Name;
            r.repName = l.Owner_User__r.Name; r.warehouseName = l.Warehouse__r.Name;
            r.initial = l.Initial_Quantity__c == null ? 0 : l.Initial_Quantity__c.intValue();
            r.available = l.Available_Quantity__c == null ? 0 : l.Available_Quantity__c.intValue();
            r.expiry = d(l.Expiry_Date__c);
            r.daysToExpiry = l.Days_To_Expiry__c == null ? null : l.Days_To_Expiry__c.intValue();
            r.status = l.Status__c;
            r.coldChain = l.Cold_Chain_Required__c == true ? (String.isBlank(l.Cold_Chain_Status__c) ? 'Tag needed' : l.Cold_Chain_Status__c) : '';
            r.url = '/' + l.Id;
            out.add(r);
        }
        return out;
    }

    /** Recall, quarantine or reactivate lots in one go. */
    @AuraEnabled
    public static Integer bulkSetStatus(List<Id> lotIds, String status) {
        requireManager();
        if (status != 'Recalled' && status != 'Quarantined' && status != 'Active') throw new AuraHandledException('Choose Recalled, Quarantined or Active.');
        if (lotIds == null || lotIds.isEmpty()) throw new AuraHandledException('Select at least one lot.');
        List<Sample_Lot__c> updates = new List<Sample_Lot__c>();
        for (Sample_Lot__c l : [SELECT Id, Available_Quantity__c, Expiry_Date__c FROM Sample_Lot__c WHERE Id IN :lotIds]) {
            if (status == 'Active' && l.Expiry_Date__c < Date.today()) continue;
            updates.add(new Sample_Lot__c(Id = l.Id, Status__c = status));
        }
        update updates;
        return updates.size();
    }

    /** Moves each selected lot's whole balance to another rep. The rep confirms the receipt. */
    @AuraEnabled
    public static List<RowResult> bulkTransfer(List<Id> lotIds, Id toUserId) {
        requireManager();
        if (toUserId == null) throw new AuraHandledException('Choose who the stock is going to.');
        List<Sample_Lot__c> lots = [SELECT Id, Product__c, Owner_User__c, Available_Quantity__c, Status__c, Lot_Number__c FROM Sample_Lot__c WHERE Id IN :lotIds];
        List<Sample_Transaction__c> txns = new List<Sample_Transaction__c>();
        List<RowResult> results = new List<RowResult>();
        List<Sample_Lot__c> used = new List<Sample_Lot__c>();
        for (Sample_Lot__c l : lots) {
            RowResult r = new RowResult();
            r.row = used.size();
            if (l.Status__c != 'Active' || l.Available_Quantity__c == null || l.Available_Quantity__c <= 0) {
                r.ok = false; r.message = 'Lot ' + l.Lot_Number__c + ' is not active or is empty.'; results.add(r); continue;
            }
            txns.add(new Sample_Transaction__c(Transaction_Type__c = 'Transfer_Out', Status__c = 'Completed', Product__c = l.Product__c, Sample_Lot__c = l.Id,
                Quantity__c = l.Available_Quantity__c, To_User__c = toUserId, From_User__c = l.Owner_User__c, Performed_By__c = UserInfo.getUserId(),
                Notes__c = 'Moved by a sample manager.'));
            used.add(l);
        }
        List<Database.SaveResult> saves = Database.insert(txns, false);
        for (Integer i = 0; i < saves.size(); i++) {
            RowResult r = new RowResult();
            r.row = i;
            r.ok = saves[i].isSuccess();
            r.message = r.ok ? 'Lot ' + used[i].Lot_Number__c + ' transferred. The rep must confirm it.' : 'Lot ' + used[i].Lot_Number__c + ': ' + saves[i].getErrors()[0].getMessage();
            results.add(r);
        }
        return results;
    }

    // -------------------------------------------------- receipts & shipments

    /** Creates a lot for each rep with nothing on hand yet, and a pending receipt the rep confirms. */
    @AuraEnabled
    public static List<RowResult> createShipments(List<ShipmentInput> rows) {
        requireManager();
        Set<String> usernames = new Set<String>();
        Set<String> skus = new Set<String>();
        Set<String> warehouseNames = new Set<String>();
        for (ShipmentInput s : rows) {
            if (!String.isBlank(s.repUsername)) usernames.add(s.repUsername.trim());
            if (!String.isBlank(s.skuCode)) skus.add(s.skuCode.trim());
            if (!String.isBlank(s.warehouseName)) warehouseNames.add(s.warehouseName.trim());
        }
        Map<String, Id> userByName = new Map<String, Id>();
        for (User u : [SELECT Id, Username FROM User WHERE Username IN :usernames AND IsActive = true]) userByName.put(u.Username.toLowerCase(), u.Id);
        Map<String, Id> productBySku = new Map<String, Id>();
        for (Product__c p : [SELECT Id, SKU_Code__c FROM Product__c WHERE SKU_Code__c IN :skus AND Is_Sample_Product__c = true]) productBySku.put(p.SKU_Code__c.toLowerCase(), p.Id);
        Map<String, Id> warehouseByName = new Map<String, Id>();
        for (Sample_Warehouse__c w : [SELECT Id, Name FROM Sample_Warehouse__c WHERE Name IN :warehouseNames]) warehouseByName.put(w.Name.toLowerCase(), w.Id);

        List<RowResult> results = new List<RowResult>();
        List<Sample_Lot__c> lots = new List<Sample_Lot__c>();
        List<Integer> lotRow = new List<Integer>();
        List<ShipmentInput> lotInput = new List<ShipmentInput>();
        for (Integer i = 0; i < rows.size(); i++) {
            ShipmentInput s = rows[i];
            RowResult r = new RowResult();
            r.row = i + 1;
            r.ok = false;
            Id rep = !String.isBlank(s.repId) ? (Id) s.repId : (String.isBlank(s.repUsername) ? null : userByName.get(s.repUsername.trim().toLowerCase()));
            Id product = !String.isBlank(s.productId) ? (Id) s.productId : (String.isBlank(s.skuCode) ? null : productBySku.get(s.skuCode.trim().toLowerCase()));
            Id warehouse = !String.isBlank(s.warehouseId) ? (Id) s.warehouseId : (String.isBlank(s.warehouseName) ? null : warehouseByName.get(s.warehouseName.trim().toLowerCase()));
            Date expiry;
            try { expiry = String.isBlank(s.expiry) ? null : Date.valueOf(s.expiry.trim()); } catch (Exception e) { expiry = null; }
            if (rep == null) r.message = 'Rep not found (use the rep\'s username).';
            else if (product == null) r.message = 'Sample product not found (use its SKU code).';
            else if (String.isBlank(s.lotNumber)) r.message = 'Lot number is missing.';
            else if (expiry == null || expiry <= Date.today()) r.message = 'Expiry must be a future date, written yyyy-mm-dd.';
            else if (s.quantity == null || s.quantity <= 0) r.message = 'Quantity must be above zero.';
            if (r.message != null) { results.add(r); continue; }
            lots.add(new Sample_Lot__c(Product__c = product, Lot_Number__c = s.lotNumber.trim(), Batch_Lot_Id__c = s.batchLotId, Expiry_Date__c = expiry,
                Initial_Quantity__c = s.quantity, Available_Quantity__c = 0, Owner_User__c = rep, Warehouse__c = warehouse, Status__c = 'Depleted'));
            lotRow.add(i);
            lotInput.add(s);
            results.add(r);
        }
        List<Database.SaveResult> lotSaves = Database.insert(lots, false);
        List<Sample_Transaction__c> receipts = new List<Sample_Transaction__c>();
        List<Integer> receiptRow = new List<Integer>();
        for (Integer i = 0; i < lotSaves.size(); i++) {
            RowResult r = results[lotRow[i]];
            if (!lotSaves[i].isSuccess()) { r.message = lotSaves[i].getErrors()[0].getMessage(); continue; }
            Sample_Lot__c l = lots[i];
            ShipmentInput s = lotInput[i];
            receipts.add(new Sample_Transaction__c(Transaction_Type__c = 'Receipt', Status__c = 'Pending', Product__c = l.Product__c, Sample_Lot__c = l.Id, Quantity__c = s.quantity,
                To_User__c = l.Owner_User__c, From_Warehouse__c = l.Warehouse__c, Shipment_Reference__c = s.shipmentRef, Performed_By__c = UserInfo.getUserId()));
            receiptRow.add(lotRow[i]);
        }
        List<Database.SaveResult> receiptSaves = Database.insert(receipts, false);
        for (Integer i = 0; i < receiptSaves.size(); i++) {
            RowResult r = results[receiptRow[i]];
            r.ok = receiptSaves[i].isSuccess();
            r.message = r.ok ? 'Shipment created. Waiting for the rep to confirm.' : receiptSaves[i].getErrors()[0].getMessage();
        }
        return results;
    }

    @AuraEnabled(cacheable=false)
    public static List<TxnRow> getPendingReceipts() {
        return txnRows([
            SELECT Id, Name, Transaction_Type__c, Status__c, Performed_At__c, CreatedDate, Product__r.Name, Sample_Lot__r.Lot_Number__c, Quantity__c, To_User__r.Name,
                   Shipment_Reference__c, HCP_Name__c, HCP_Registration_Number__c, Total_Value__c, Signature_Captured__c, Cold_Chain_Status__c, Adjustment_Reason__c,
                   Return_Reason__c, Notes__c, Performed_By__r.Name
            FROM Sample_Transaction__c WHERE Transaction_Type__c IN ('Receipt', 'Transfer_In') AND Status__c = 'Pending' ORDER BY CreatedDate LIMIT :ROW_LIMIT
        ]);
    }

    // ----------------------------------------------------------- transactions

    @AuraEnabled(cacheable=false)
    public static List<TxnRow> getTransactions(String type, String status, String repId, String productId, String hcpTerm, String fromDate, String toDate) {
        List<String> conds = new List<String>();
        Map<String, Object> binds = new Map<String, Object>();
        if (!String.isBlank(type)) { conds.add('Transaction_Type__c = :type'); binds.put('type', type); }
        if (!String.isBlank(status)) { conds.add('Status__c = :status'); binds.put('status', status); }
        if (!String.isBlank(repId)) { conds.add('(Performed_By__c = :repId OR To_User__c = :repId OR From_User__c = :repId)'); binds.put('repId', repId); }
        if (!String.isBlank(productId)) { conds.add('Product__c = :productId'); binds.put('productId', productId); }
        if (!String.isBlank(hcpTerm)) { conds.add('HCP_Account__r.Name LIKE :hcpLike'); binds.put('hcpLike', '%' + String.escapeSingleQuotes(hcpTerm.trim()) + '%'); }
        if (!String.isBlank(fromDate)) { conds.add('Performed_At__c >= :fromAt'); binds.put('fromAt', Datetime.newInstance(Date.valueOf(fromDate), Time.newInstance(0, 0, 0, 0))); }
        if (!String.isBlank(toDate)) { conds.add('Performed_At__c < :toAt'); binds.put('toAt', Datetime.newInstance(Date.valueOf(toDate).addDays(1), Time.newInstance(0, 0, 0, 0))); }
        String soql = 'SELECT Id, Name, Transaction_Type__c, Status__c, Performed_At__c, CreatedDate, Product__r.Name, Sample_Lot__r.Lot_Number__c, Quantity__c, To_User__r.Name, '
            + 'Shipment_Reference__c, HCP_Name__c, HCP_Registration_Number__c, Total_Value__c, Signature_Captured__c, Cold_Chain_Status__c, Adjustment_Reason__c, Return_Reason__c, Notes__c, '
            + 'Performed_By__r.Name FROM Sample_Transaction__c' + (conds.isEmpty() ? '' : ' WHERE ' + String.join(conds, ' AND ')) + ' ORDER BY Performed_At__c DESC NULLS LAST LIMIT ' + ROW_LIMIT;
        return txnRows((List<Sample_Transaction__c>) Database.queryWithBinds(soql, binds, AccessLevel.USER_MODE));
    }

    private static List<TxnRow> txnRows(List<Sample_Transaction__c> rows) {
        List<TxnRow> out = new List<TxnRow>();
        for (Sample_Transaction__c t : rows) {
            TxnRow r = new TxnRow();
            r.id = t.Id; r.name = t.Name; r.type = t.Transaction_Type__c; r.status = t.Status__c;
            r.performedAt = dt(t.Performed_At__c != null ? t.Performed_At__c : t.CreatedDate);
            r.repName = t.Performed_By__r.Name;
            r.hcpName = t.HCP_Name__c; r.registration = t.HCP_Registration_Number__c;
            r.productName = t.Product__r.Name; r.lotNumber = t.Sample_Lot__r.Lot_Number__c;
            r.quantity = t.Quantity__c == null ? null : t.Quantity__c.intValue();
            r.valueInr = t.Total_Value__c; r.signature = t.Signature_Captured__c;
            r.coldChain = t.Cold_Chain_Status__c;
            r.reason = String.isBlank(t.Adjustment_Reason__c) ? t.Return_Reason__c : t.Adjustment_Reason__c;
            r.toName = t.To_User__r.Name; r.shipmentRef = t.Shipment_Reference__c;
            r.ageDays = t.CreatedDate == null ? null : t.CreatedDate.date().daysBetween(Date.today());
            r.note = t.Notes__c; r.url = '/' + t.Id;
            out.add(r);
        }
        return out;
    }

    // --------------------------------------------------------- discrepancies

    @AuraEnabled(cacheable=false)
    public static List<Discrepancy> getDiscrepancies() {
        List<Discrepancy> out = new List<Discrepancy>();
        for (Sample_Transaction__c t : [
            SELECT Id, Name, Transaction_Type__c, Quantity__c, Inventory_Shortfall__c, Notes__c, Adjustment_Reason__c, Performed_At__c, CreatedDate,
                   Product__r.Name, Sample_Lot__r.Lot_Number__c, Sample_Lot__r.Initial_Quantity__c, Performed_By__r.Name
            FROM Sample_Transaction__c
            WHERE (Transaction_Type__c = 'Adjustment' AND Status__c = 'Completed') OR Inventory_Shortfall__c > 0
            ORDER BY CreatedDate DESC LIMIT :ROW_LIMIT
        ]) {
            Discrepancy x = new Discrepancy();
            x.id = t.Id; x.name = t.Name; x.repName = t.Performed_By__r.Name; x.productName = t.Product__r.Name; x.lotNumber = t.Sample_Lot__r.Lot_Number__c;
            x.occurredAt = dt(t.Performed_At__c != null ? t.Performed_At__c : t.CreatedDate); x.url = '/' + t.Id;
            Decimal qty;
            if (t.Transaction_Type__c == 'Adjustment') {
                qty = t.Quantity__c;
                x.kind = (t.Notes__c != null && t.Notes__c.startsWith('Inventory count')) ? 'Count difference' : 'Adjustment';
                x.reason = t.Adjustment_Reason__c + (String.isBlank(t.Notes__c) ? '' : '. ' + t.Notes__c);
            } else {
                qty = -t.Inventory_Shortfall__c;
                x.kind = 'Given without stock on the books';
                x.reason = 'The lot did not have enough on the books when the call was submitted.';
            }
            x.quantity = qty.intValue();
            Decimal initial = t.Sample_Lot__r.Initial_Quantity__c;
            x.percentOfLot = (initial == null || initial == 0) ? null : (Math.abs(qty) * 100 / initial).setScale(1);
            x.flagged = x.kind == 'Given without stock on the books' || (x.percentOfLot != null && x.percentOfLot > 10);
            out.add(x);
        }
        return out;
    }

    // -------------------------------------------------------------- approvals

    @AuraEnabled(cacheable=false)
    public static Approvals getApprovals() {
        Approvals a = new Approvals();
        a.heldTransactions = txnRows([
            SELECT Id, Name, Transaction_Type__c, Status__c, Performed_At__c, CreatedDate, Product__r.Name, Sample_Lot__r.Lot_Number__c, Quantity__c, To_User__r.Name,
                   Shipment_Reference__c, HCP_Name__c, HCP_Registration_Number__c, Total_Value__c, Signature_Captured__c, Cold_Chain_Status__c, Adjustment_Reason__c,
                   Return_Reason__c, Notes__c, Override_Reason__c, Performed_By__r.Name
            FROM Sample_Transaction__c WHERE Requires_Approval__c = true AND Status__c = 'Pending' ORDER BY CreatedDate LIMIT :ROW_LIMIT
        ]);
        for (Sample_Transaction__c t : [SELECT Id, Override_Reason__c FROM Sample_Transaction__c WHERE Requires_Approval__c = true AND Status__c = 'Pending' LIMIT :ROW_LIMIT]) {
            for (TxnRow r : a.heldTransactions) if (r.id == t.Id) r.note = t.Override_Reason__c;
        }
        for (Sample_Limit_Override__c o : [
            SELECT Id, Name, Sample_Limit__r.Name, Override_Type__c, Override_Value__c, Target_Account__r.Name, Target_User__r.Name, Valid_From__c, Valid_To__c, Reason__c
            FROM Sample_Limit_Override__c WHERE Status__c = 'Pending' ORDER BY CreatedDate LIMIT 200
        ]) {
            OverrideRow r = new OverrideRow();
            r.id = o.Id; r.name = o.Name; r.limitName = o.Sample_Limit__r.Name; r.type = o.Override_Type__c;
            r.value = o.Override_Value__c == null ? null : o.Override_Value__c.intValue();
            r.target = o.Target_Account__c != null ? o.Target_Account__r.Name : o.Target_User__r.Name;
            r.validFrom = d(o.Valid_From__c); r.validTo = d(o.Valid_To__c); r.reason = o.Reason__c;
            a.overrides.add(r);
        }
        return a;
    }

    @AuraEnabled
    public static void decideTransaction(Id transactionId, Boolean approve) {
        requireManager();
        Sample_Transaction__c t = [SELECT Id, Status__c, Requires_Approval__c FROM Sample_Transaction__c WHERE Id = :transactionId LIMIT 1];
        if (t.Status__c != 'Pending' || t.Requires_Approval__c != true) throw new AuraHandledException('That transaction is no longer waiting for approval.');
        t.Status__c = approve == true ? 'Completed' : 'Rejected';
        update t;
    }

    @AuraEnabled
    public static void decideOverride(Id overrideId, Boolean approve) {
        requireManager();
        Sample_Limit_Override__c o = [SELECT Id, Status__c FROM Sample_Limit_Override__c WHERE Id = :overrideId LIMIT 1];
        if (o.Status__c != 'Pending') throw new AuraHandledException('That request has already been decided.');
        o.Status__c = approve == true ? 'Active' : 'Revoked';
        update o;
    }
}