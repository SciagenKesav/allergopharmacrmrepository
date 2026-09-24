import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import LightningConfirm from 'lightning/confirm';
import getFilterOptions from '@salesforce/apex/SampleAdminController.getFilterOptions';
import getLots from '@salesforce/apex/SampleAdminController.getLots';
import bulkSetStatus from '@salesforce/apex/SampleAdminController.bulkSetStatus';
import bulkTransfer from '@salesforce/apex/SampleAdminController.bulkTransfer';
import createShipments from '@salesforce/apex/SampleAdminController.createShipments';
import getPendingReceipts from '@salesforce/apex/SampleAdminController.getPendingReceipts';
import getTransactions from '@salesforce/apex/SampleAdminController.getTransactions';
import getDiscrepancies from '@salesforce/apex/SampleAdminController.getDiscrepancies';
import getApprovals from '@salesforce/apex/SampleAdminController.getApprovals';
import decideTransaction from '@salesforce/apex/SampleAdminController.decideTransaction';
import decideOverride from '@salesforce/apex/SampleAdminController.decideOverride';

const ALL = { label: 'All', value: '' };

export default class SampleAdmin extends LightningElement {
    @track options = { products: [], reps: [], territories: [], warehouses: [], canManage: false };
    @track loading = false;
    @track error = '';

    // inventory
    @track fProduct = ''; @track fRep = ''; @track fTerritory = ''; @track fStatus = ''; @track fExpiring = '';
    @track lots = []; @track selectedLotIds = []; @track transferTo = ''; @track transferResults = null;
    // shipments
    @track sRep = ''; @track sProduct = ''; @track sLot = ''; @track sBatch = ''; @track sExpiry = ''; @track sQty = ''; @track sWarehouse = ''; @track sRef = '';
    @track csvRows = []; @track csvResults = null; @track pending = [];
    // log
    @track tType = ''; @track tStatus = ''; @track tRep = ''; @track tProduct = ''; @track tHcp = ''; @track tFrom = ''; @track tTo = ''; @track log = [];
    // discrepancies + approvals
    @track disc = []; @track flaggedOnly = false; @track held = []; @track overrides = [];

    connectedCallback() { this.loadOptions(); this.loadInventory(); }

    async loadOptions() {
        try { this.options = await getFilterOptions(); } catch (e) { this.fail(e); }
    }

    // ---------------------------------------------------------------- options
    get productOptions() { return [ALL, ...this.options.products]; }
    get productOptionsNoAll() { return this.options.products; }
    get repOptions() { return [ALL, ...this.options.reps]; }
    get repOptionsNoAll() { return this.options.reps; }
    get territoryOptions() { return [ALL, ...this.options.territories]; }
    get warehouseOptions() { return [{ label: 'None', value: '' }, ...this.options.warehouses]; }
    get statusOptions() { return [ALL, ...['Active', 'Depleted', 'Expired', 'Recalled', 'Quarantined'].map(v => ({ label: v, value: v }))]; }
    get expiringOptions() { return [ALL, { label: '30 days', value: '30' }, { label: '60 days', value: '60' }, { label: '90 days', value: '90' }]; }
    get typeOptions() { return [ALL, ...['Receipt', 'Disbursement', 'Transfer_Out', 'Transfer_In', 'Return', 'Adjustment'].map(v => ({ label: v.replace('_', ' '), value: v }))]; }
    get txnStatusOptions() { return [ALL, ...['Pending', 'Confirmed', 'Completed', 'Cancelled', 'Rejected'].map(v => ({ label: v, value: v }))]; }
    get cannotManage() { return !this.options.canManage; }

    // -------------------------------------------------------------- inventory
    handleFProduct(e) { this.fProduct = e.detail.value; this.loadInventory(); }
    handleFRep(e) { this.fRep = e.detail.value; this.loadInventory(); }
    handleFTerritory(e) { this.fTerritory = e.detail.value; this.loadInventory(); }
    handleFStatus(e) { this.fStatus = e.detail.value; this.loadInventory(); }
    handleFExpiring(e) { this.fExpiring = e.detail.value; this.loadInventory(); }

    lotColumns = [
        { label: 'Lot', fieldName: 'url', type: 'url', typeAttributes: { label: { fieldName: 'name' }, target: '_blank' }, initialWidth: 110 },
        { label: 'Lot number', fieldName: 'lotNumber' },
        { label: 'Product', fieldName: 'productName' },
        { label: 'Held by', fieldName: 'repName' },
        { label: 'Warehouse', fieldName: 'warehouseName' },
        { label: 'Available', fieldName: 'available', type: 'number', initialWidth: 100, cellAttributes: { alignment: 'right' } },
        { label: 'Initial', fieldName: 'initial', type: 'number', initialWidth: 90, cellAttributes: { alignment: 'right' } },
        { label: 'Expiry', fieldName: 'expiry', type: 'date-local', initialWidth: 110 },
        { label: 'Days left', fieldName: 'daysToExpiry', type: 'number', initialWidth: 90, cellAttributes: { alignment: 'right' } },
        { label: 'Status', fieldName: 'status', initialWidth: 110 },
        { label: 'Cold chain', fieldName: 'coldChain', initialWidth: 110 }
    ];

    async loadInventory() {
        this.loading = true;
        this.error = '';
        try {
            this.lots = await getLots({
                productId: this.fProduct || null, repId: this.fRep || null, territoryId: this.fTerritory || null,
                status: this.fStatus || null, expiringInDays: this.fExpiring ? Number(this.fExpiring) : null
            });
            this.selectedLotIds = [];
        } catch (e) { this.fail(e); } finally { this.loading = false; }
    }

    get lotCountText() {
        const units = this.lots.reduce((n, l) => n + l.available, 0);
        return `${this.lots.length} lots, ${units} packs on hand` + (this.selectedLotIds.length ? `, ${this.selectedLotIds.length} selected` : '');
    }
    get bulkDisabled() { return this.cannotManage || this.selectedLotIds.length === 0; }
    get transferDisabled() { return this.bulkDisabled || !this.transferTo; }
    handleLotSelection(e) { this.selectedLotIds = e.detail.selectedRows.map(r => r.id); }
    handleTransferTo(e) { this.transferTo = e.detail.value; }

    async setStatus(status, verb) {
        const ok = await LightningConfirm.open({ message: `${verb} ${this.selectedLotIds.length} lot(s)? Reps see the change on their next sync.`, label: `${verb} lots`, theme: status === 'Recalled' ? 'warning' : 'default' });
        if (!ok) return;
        try {
            const n = await bulkSetStatus({ lotIds: this.selectedLotIds, status });
            this.toast('Done', `${n} lot(s) set to ${status}.`, 'success');
            await this.loadInventory();
        } catch (e) { this.fail(e); }
    }
    recallSelected() { this.setStatus('Recalled', 'Recall'); }
    quarantineSelected() { this.setStatus('Quarantined', 'Quarantine'); }
    reactivateSelected() { this.setStatus('Active', 'Reactivate'); }

    async transferSelected() {
        const ok = await LightningConfirm.open({ message: `Move the whole balance of ${this.selectedLotIds.length} lot(s) to the chosen rep? They confirm the receipt on their iPad.`, label: 'Transfer lots' });
        if (!ok) return;
        try {
            const res = await bulkTransfer({ lotIds: this.selectedLotIds, toUserId: this.transferTo });
            this.transferResults = res.map((r, i) => ({ key: `t${i}`, message: r.message, className: r.ok ? 'r-ok' : 'r-bad' }));
            await this.loadInventory();
        } catch (e) { this.fail(e); }
    }

    // ---------------------------------------------------------------- receipts
    handleSRep(e) { this.sRep = e.detail.value; }
    handleSProduct(e) { this.sProduct = e.detail.value; }
    handleSLot(e) { this.sLot = e.target.value; }
    handleSBatch(e) { this.sBatch = e.target.value; }
    handleSExpiry(e) { this.sExpiry = e.target.value; }
    handleSQty(e) { this.sQty = e.target.value; }
    handleSWarehouse(e) { this.sWarehouse = e.detail.value; }
    handleSRef(e) { this.sRef = e.target.value; }
    get shipmentDisabled() { return this.cannotManage || !this.sRep || !this.sProduct || !this.sLot || !this.sExpiry || !(Number(this.sQty) > 0); }

    async createOneShipment() {
        try {
            const res = await createShipments({ rows: [{
                repId: this.sRep, productId: this.sProduct, lotNumber: this.sLot, batchLotId: this.sBatch, expiry: this.sExpiry,
                quantity: Number(this.sQty), warehouseId: this.sWarehouse || null, shipmentRef: this.sRef
            }] });
            if (res[0].ok) {
                this.toast('Shipment created', res[0].message, 'success');
                this.sLot = ''; this.sBatch = ''; this.sQty = ''; this.sRef = '';
                await this.loadReceipts();
            } else {
                this.error = res[0].message;
            }
        } catch (e) { this.fail(e); }
    }

    handleCsvFile(e) {
        const file = e.target.files && e.target.files[0];
        if (!file) return;
        const reader = new FileReader();
        reader.onload = () => { this.csvRows = this.parseCsv(String(reader.result)); this.csvResults = null; };
        reader.readAsText(file);
    }

    parseCsv(text) {
        const rows = [];
        let row = [], cell = '', quoted = false;
        for (let i = 0; i < text.length; i++) {
            const c = text[i];
            if (quoted) {
                if (c === '"' && text[i + 1] === '"') { cell += '"'; i++; }
                else if (c === '"') quoted = false;
                else cell += c;
            } else if (c === '"') quoted = true;
            else if (c === ',') { row.push(cell); cell = ''; }
            else if (c === '\n' || c === '\r') {
                if (c === '\r' && text[i + 1] === '\n') i++;
                row.push(cell); cell = '';
                if (row.some(v => v.trim() !== '')) rows.push(row);
                row = [];
            } else cell += c;
        }
        row.push(cell);
        if (row.some(v => v.trim() !== '')) rows.push(row);
        if (rows.length < 2) return [];
        const head = rows[0].map(h => h.trim().toLowerCase());
        const col = name => head.indexOf(name);
        return rows.slice(1).map(r => ({
            repUsername: r[col('rep_username')], skuCode: r[col('sku_code')], lotNumber: r[col('lot_number')], expiry: r[col('expiry')],
            quantity: Number(r[col('quantity')]), warehouseName: r[col('warehouse')], shipmentRef: r[col('shipment_ref')], batchLotId: r[col('batch_lot_id')]
        }));
    }

    get csvDisabled() { return this.cannotManage || this.csvRows.length === 0; }
    async createCsvShipments() {
        try {
            const res = await createShipments({ rows: this.csvRows });
            this.csvResults = res.map(r => ({ key: `c${r.row}`, row: r.row, message: r.message, className: r.ok ? 'r-ok' : 'r-bad' }));
            const ok = res.filter(r => r.ok).length;
            this.toast('Shipments processed', `${ok} of ${res.length} rows created.`, ok === res.length ? 'success' : 'warning');
            await this.loadReceipts();
        } catch (e) { this.fail(e); }
    }

    pendingColumns = [
        { label: 'Transaction', fieldName: 'url', type: 'url', typeAttributes: { label: { fieldName: 'name' }, target: '_blank' }, initialWidth: 130 },
        { label: 'Type', fieldName: 'type', initialWidth: 110 },
        { label: 'Rep', fieldName: 'toName' },
        { label: 'Product', fieldName: 'productName' },
        { label: 'Lot', fieldName: 'lotNumber' },
        { label: 'Packs', fieldName: 'quantity', type: 'number', initialWidth: 90 },
        { label: 'Shipment', fieldName: 'shipmentRef' },
        { label: 'Waiting (days)', fieldName: 'ageDays', type: 'number', initialWidth: 120 }
    ];
    get hasPending() { return this.pending.length > 0; }
    async loadReceipts() {
        try { this.pending = await getPendingReceipts(); } catch (e) { this.fail(e); }
    }

    // ------------------------------------------------------------------- log
    handleTType(e) { this.tType = e.detail.value; }
    handleTStatus(e) { this.tStatus = e.detail.value; }
    handleTRep(e) { this.tRep = e.detail.value; }
    handleTProduct(e) { this.tProduct = e.detail.value; }
    handleTHcp(e) { this.tHcp = e.target.value; }
    handleTFrom(e) { this.tFrom = e.target.value; }
    handleTTo(e) { this.tTo = e.target.value; }

    logColumns = [
        { label: 'Transaction', fieldName: 'url', type: 'url', typeAttributes: { label: { fieldName: 'name' }, target: '_blank' }, initialWidth: 130 },
        { label: 'Type', fieldName: 'type', initialWidth: 110 },
        { label: 'Status', fieldName: 'status', initialWidth: 100 },
        { label: 'When', fieldName: 'performedAt', initialWidth: 150 },
        { label: 'By', fieldName: 'repName' },
        { label: 'Doctor', fieldName: 'hcpName' },
        { label: 'Reg #', fieldName: 'registration', initialWidth: 120 },
        { label: 'Product', fieldName: 'productName' },
        { label: 'Lot', fieldName: 'lotNumber', initialWidth: 100 },
        { label: 'Packs', fieldName: 'quantity', type: 'number', initialWidth: 80 },
        { label: 'Value (Rs.)', fieldName: 'valueInr', type: 'number', typeAttributes: { maximumFractionDigits: 0 }, initialWidth: 110 },
        { label: 'Signed', fieldName: 'signature', type: 'boolean', initialWidth: 80 }
    ];
    get logCountText() { return `${this.log.length} transactions` + (this.log.length >= 1000 ? ' (first 1,000: narrow the filters)' : ''); }
    get noLog() { return this.log.length === 0; }
    async loadLog() {
        this.loading = true;
        this.error = '';
        try {
            this.log = await getTransactions({
                type: this.tType || null, status: this.tStatus || null, repId: this.tRep || null, productId: this.tProduct || null,
                hcpTerm: this.tHcp || null, fromDate: this.tFrom || null, toDate: this.tTo || null
            });
        } catch (e) { this.fail(e); } finally { this.loading = false; }
    }
    exportLog() {
        const head = ['Transaction', 'Type', 'Status', 'When', 'By', 'Doctor', 'Registration', 'Product', 'Lot', 'Packs', 'Value INR', 'Signed', 'To', 'Reason', 'Shipment', 'Cold chain'];
        const cell = v => { const s = v == null ? '' : String(v); return /[",\r\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s; };
        const lines = this.log.map(r => [r.name, r.type, r.status, r.performedAt, r.repName, r.hcpName, r.registration, r.productName, r.lotNumber, r.quantity, r.valueInr, r.signature ? 'Yes' : 'No', r.toName, r.reason, r.shipmentRef, r.coldChain].map(cell).join(','));
        const csv = [head.join(','), ...lines].join('\r\n');
        const a = document.createElement('a');
        a.href = 'data:text/csv;charset=utf-8,' + encodeURIComponent('﻿' + csv);
        a.download = 'sample-transactions.csv';
        document.body.appendChild(a); a.click(); document.body.removeChild(a);
    }

    // ---------------------------------------------------------- discrepancies
    discColumns = [
        { label: 'Transaction', fieldName: 'url', type: 'url', typeAttributes: { label: { fieldName: 'name' }, target: '_blank' }, initialWidth: 130 },
        { label: 'What', fieldName: 'kind' },
        { label: 'Rep', fieldName: 'repName' },
        { label: 'Product', fieldName: 'productName' },
        { label: 'Lot', fieldName: 'lotNumber', initialWidth: 100 },
        { label: 'Packs', fieldName: 'quantity', type: 'number', initialWidth: 80 },
        { label: '% of lot', fieldName: 'percentOfLot', type: 'number', typeAttributes: { maximumFractionDigits: 1 }, initialWidth: 90 },
        { label: 'Flag', fieldName: 'flagText', initialWidth: 90 },
        { label: 'When', fieldName: 'occurredAt', initialWidth: 150 },
        { label: 'Reason', fieldName: 'reason', wrapText: true }
    ];
    get discRows() {
        return this.disc.filter(d => !this.flaggedOnly || d.flagged).map(d => ({ ...d, flagText: d.flagged ? 'Review' : '' }));
    }
    get discCountText() { return `${this.discRows.length} shown, ${this.disc.filter(d => d.flagged).length} flagged`; }
    handleFlagged(e) { this.flaggedOnly = e.target.checked; }
    async loadDiscrepancies() {
        try { this.disc = await getDiscrepancies(); } catch (e) { this.fail(e); }
    }

    // -------------------------------------------------------------- approvals
    get hasHeld() { return this.held.length > 0; }
    get hasOverrides() { return this.overrides.length > 0; }
    async loadApprovals() {
        try { const a = await getApprovals(); this.held = a.heldTransactions; this.overrides = a.overrides; } catch (e) { this.fail(e); }
    }
    async decideTxn(id, approve) {
        try { await decideTransaction({ transactionId: id, approve }); this.toast(approve ? 'Approved' : 'Rejected', approve ? 'The samples were recorded and stock updated.' : 'The hand-out was rejected. Stock is unchanged.', 'success'); await this.loadApprovals(); } catch (e) { this.fail(e); }
    }
    approveTxn(e) { this.decideTxn(e.target.dataset.id, true); }
    rejectTxn(e) { this.decideTxn(e.target.dataset.id, false); }
    async decideOvr(id, approve) {
        try { await decideOverride({ overrideId: id, approve }); this.toast(approve ? 'Override approved' : 'Override declined', '', 'success'); await this.loadApprovals(); } catch (e) { this.fail(e); }
    }
    approveOverride(e) { this.decideOvr(e.target.dataset.id, true); }
    declineOverride(e) { this.decideOvr(e.target.dataset.id, false); }

    toast(title, message, variant) { this.dispatchEvent(new ShowToastEvent({ title, message, variant })); }
    fail(e) { this.error = (e && e.body && e.body.message) || (e && e.message) || 'Something went wrong.'; }
}