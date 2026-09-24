import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getFinancialYears from '@salesforce/apex/UCPMPComplianceController.getFinancialYears';
import getSummary from '@salesforce/apex/UCPMPComplianceController.getSummary';
import getHcpReport from '@salesforce/apex/UCPMPComplianceController.getHcpReport';
import getRestricted from '@salesforce/apex/UCPMPComplianceController.getRestricted';
import getConfig from '@salesforce/apex/UCPMPComplianceController.getConfig';
import saveConfig from '@salesforce/apex/UCPMPComplianceController.saveConfig';
import generateDisclosure from '@salesforce/apex/UCPMPComplianceController.generateDisclosure';

const TYPE_LABELS = {
    Restricted_Product: 'Restricted product', Limit: 'Limit reached', Licence: 'Licence problem', Lot_Or_Stock: 'Lot or stock',
    Cold_Chain: 'Cold chain', Signature: 'Signature missing', Other: 'Other'
};
const fmtInr = n => (n == null ? '-' : 'Rs. ' + Number(n).toLocaleString('en-IN', { maximumFractionDigits: 0 }));
const fmtCrore = n => (n == null ? '-' : 'Rs. ' + (Number(n) / 10000000).toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 4 }) + ' Cr');

export default class UcpmpComplianceDashboard extends LightningElement {
    @track fy = '';
    @track fyOptions = [];
    @track summary;
    @track reportRows = [];
    @track restricted;
    @track cfg = {};
    @track showSettings = false;
    @track loading = false;
    @track generating = false;
    @track error = '';

    connectedCallback() { this.init(); }

    async init() {
        try {
            const years = await getFinancialYears();
            this.fyOptions = years.map(y => ({ label: y, value: y }));
            this.fy = years[0];
            this.cfg = await getConfig();
            await this.refresh();
        } catch (e) { this.error = this.message(e); }
    }

    async refresh() {
        this.loading = true;
        this.error = '';
        try {
            const [s, r, x] = await Promise.all([getSummary({ fy: this.fy }), getHcpReport({ fy: this.fy }), getRestricted()]);
            this.summary = s;
            this.reportRows = r;
            this.restricted = x;
        } catch (e) { this.error = this.message(e); } finally { this.loading = false; }
    }

    handleFy(e) { this.fy = e.detail.value; this.refresh(); }
    toggleSettings() { this.showSettings = !this.showSettings; }
    get cannotEdit() { return !this.cfg.canEdit; }
    handleCfg(e) { this.cfg = { ...this.cfg, [e.target.dataset.field]: e.target.value }; }

    async saveCfg() {
        try {
            const c = this.cfg;
            this.cfg = await saveConfig({
                financialYear: c.financialYear, domesticSalesCrore: c.domesticSalesCrore === '' || c.domesticSalesCrore == null ? null : Number(c.domesticSalesCrore),
                companyName: c.companyName, cin: c.cin, address: c.address, email: c.email, pan: c.pan,
                designation: c.designation, dinOrPan: c.dinOrPan, mobile: c.mobile, signEmail: c.signEmail
            });
            this.toast('Saved', 'UCPMP settings updated.', 'success');
            await this.refresh();
        } catch (e) { this.error = this.message(e); }
    }

    async generate() {
        this.generating = true;
        this.error = '';
        try {
            const f = await generateDisclosure({ fy: this.fy });
            this.toast('Form ready', `${f.title} was saved to Files and is opening.`, 'success');
            window.open(f.downloadPath, '_blank');
        } catch (e) { this.error = this.message(e); } finally { this.generating = false; }
    }

    // ---- view helpers
    get summaryTitle() { return `Annual expenditure summary, FY ${this.fy}`; }
    get salesText() { return this.summary && this.summary.salesConfigured ? fmtCrore(this.summary.domesticSalesInr) : 'Not set'; }
    get capText() { return this.summary && this.summary.salesConfigured ? fmtCrore(this.summary.capInr) : '-'; }
    get spentText() { return this.summary ? fmtInr(this.summary.spentInr) : '-'; }
    get percentText() {
        const s = this.summary;
        if (!s || !s.salesConfigured) return '';
        return `${s.percentOfSales}% of sales (limit 2.0%), ${s.percentOfCap}% of the cap`;
    }
    get gaugeLabel() { return this.percentText || 'No sales figure entered'; }
    get gaugeStyle() {
        const p = this.summary && this.summary.salesConfigured ? Math.min(100, this.summary.percentOfCap) : 0;
        return `width: ${p}%`;
    }
    get gaugeFillClass() {
        const st = this.summary && this.summary.status;
        return 'gauge-fill ' + (st === 'Exceeding' ? 'g-bad' : st === 'Approaching' ? 'g-warn' : st === 'Within' ? 'g-ok' : 'g-none');
    }
    get statusClass() {
        const st = this.summary && this.summary.status;
        return st === 'Exceeding' ? 'st-exceeding' : st === 'Approaching' ? 'st-approaching' : st === 'Within' ? 'st-within' : 'st-none';
    }
    get hasRows() { return this.reportRows.length > 0; }
    get rows() {
        return this.reportRows.slice(0, 20).map((r, i) => {
            const pct = r.percentOfLimit;
            return {
                key: `${r.hcpId}-${r.productName}-${i}`, hcpName: r.hcpName, registration: r.registration || '-', productName: r.productName,
                packs: r.packs, valueText: Number(r.valueInr).toLocaleString('en-IN', { maximumFractionDigits: 0 }),
                limitText: r.limitPacks == null ? `${r.packs}` : `${r.packs}/${r.limitPacks}`,
                barClass: 'mini-fill ' + (pct != null && pct >= 100 ? 'g-bad' : pct != null && pct >= 80 ? 'g-warn' : 'g-ok'),
                barStyle: `width: ${Math.min(100, pct == null ? 0 : pct)}%`
            };
        });
    }
    get restrictedList() { return this.restricted && this.restricted.restrictedProducts.length ? this.restricted.restrictedProducts.join(', ') : 'none set up'; }
    get typeCounts() {
        const m = (this.restricted && this.restricted.byType) || {};
        return Object.keys(m).filter(k => k !== 'Restricted_Product').map(k => ({ type: k, label: TYPE_LABELS[k] || k, count: m[k] }));
    }
    get hasAttempts() { return this.restricted && this.restricted.attempts.length > 0; }

    toast(title, message, variant) { this.dispatchEvent(new ShowToastEvent({ title, message, variant })); }
    message(e) { return (e && e.body && e.body.message) || (e && e.message) || 'Something went wrong.'; }
}