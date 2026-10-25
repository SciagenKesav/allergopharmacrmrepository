import { LightningElement } from 'lwc';
import getSales from '@salesforce/apex/ReportsController.getSales';

const VIEWS = [{ label: 'Primary', value: 'primary' }, { label: 'Secondary', value: 'secondary' }, { label: 'Trend', value: 'trend' }, { label: 'Achievement', value: 'achievement' }];
const BYS = [{ label: 'By SKU', value: 'sku' }, { label: 'By Stockist', value: 'stockist' }];
const MON = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

export default class SciSalesReports extends LightningElement {
    view = 'primary';
    by = 'sku';
    month = '';
    brand = '';
    result;
    loading = false;
    error;
    drill;
    nonce = 0;
    months = [];
    brands = [];

    connectedCallback() { this.load(); }

    get isTrend() { return this.view === 'trend'; }
    get showBy() { return this.view === 'primary' || this.view === 'secondary'; }
    get views() { return VIEWS.map(v => ({ ...v, variant: v.value === this.view ? 'brand' : 'neutral' })); }
    get bys() { return BYS.map(v => ({ ...v, variant: v.value === this.by ? 'brand' : 'neutral' })); }
    get monthChoices() {
        return [{ label: 'Whole window', value: '' }, ...this.months.map(m => ({ label: `${MON[Number(m.slice(5, 7)) - 1]} '${m.slice(2, 4)}`, value: m }))];
    }
    get brandChoices() { return [{ label: 'All brands', value: '' }, ...this.brands.map(b => ({ label: b, value: b }))]; }
    get paramsJson() { return JSON.stringify({ view: this.view, by: this.by, month: this.month, brand: this.brand, n: this.nonce }); }

    async load() {
        this.loading = true; this.error = null;
        try {
            const r = await getSales({ paramsJson: this.paramsJson });
            this.result = r;
            this.months = r.monthOptions || this.months;
            this.brands = r.brandOptions || this.brands;
        } catch (e) { this.error = e?.body?.message || 'Could not load Sales.'; }
        this.loading = false;
    }
    pickView(e) { this.view = e.target.dataset.value; this.load(); }
    pickBy(e) { this.by = e.target.dataset.value; this.load(); }
    pickMonth(e) { this.month = e.detail.value; this.load(); }
    pickBrand(e) { this.brand = e.detail.value; this.load(); }
    refresh() { this.nonce += 1; this.load(); }
    handleRow(e) {
        if (e.detail.action !== 'salesdrill') return;
        const row = e.detail.row;
        this.drill = { mode: 'sales', title: row.group, value: row._group };
    }
    closeDrill() { this.drill = null; }
}