import { LightningElement, api } from 'lwc';
import getGroupDoctors from '@salesforce/apex/ReportsController.getGroupDoctors';
import getHcpDetail from '@salesforce/apex/ReportsController.getHcpDetail';
import getSalesDrill from '@salesforce/apex/ReportsController.getSalesDrill';

export default class SciDrillPanel extends LightningElement {
    // target: { mode: 'group'|'doctor'|'sales', title, dim, value, hcpId }
    @api target;
    @api paramsJson;      // the report's params (period, filters, rep)
    @api startDate;
    @api endDate;
    @api repUserId;
    @api territoryId;
    @api periodLabel;
    loading = false;
    error;
    docsAll = [];
    detail;
    table;
    search = '';
    sortKey = 'name';
    level; // 'group' | 'doctor' | 'sales'
    fromGroup = false;

    sortOptions = [{ label: 'Name', value: 'name' }, { label: 'Most calls', value: 'calls' }, { label: 'Most missed', value: 'missed' }, { label: 'Not covered first', value: 'nc' }];

    connectedCallback() {
        const t = this.target || {};
        this.level = t.mode;
        if (t.mode === 'group') this.loadGroup();
        else if (t.mode === 'doctor') this.loadDoctor(t.hcpId);
        else if (t.mode === 'sales') this.loadSales();
    }
    get heading() { return this.level === 'doctor' && this.detail ? this.detail.row.name : (this.target?.title || ''); }
    get isGroup() { return this.level === 'group'; }
    get isDoctor() { return this.level === 'doctor'; }
    get isTable() { return this.level === 'sales' && this.table; }
    get canGoBack() { return this.fromGroup; }

    async loadGroup() {
        this.loading = true; this.error = null;
        try { this.docsAll = await getGroupDoctors({ paramsJson: this.paramsJson, dim: this.target.dim, value: this.target.value }); }
        catch (e) { this.error = e?.body?.message || 'Could not load doctors.'; }
        this.loading = false;
    }
    async loadDoctor(id) {
        this.loading = true; this.error = null; this.level = 'doctor';
        try { this.detail = await getHcpDetail({ hcpId: id, startDate: this.startDate, endDate: this.endDate, repUserId: this.repUserId || '', territoryId: this.territoryId || '' }); }
        catch (e) { this.error = e?.body?.message || 'Could not load the doctor.'; }
        this.loading = false;
    }
    async loadSales() {
        this.loading = true; this.error = null;
        try { this.table = await getSalesDrill({ paramsJson: this.paramsJson, key: this.target.value }); }
        catch (e) { this.error = e?.body?.message || 'Could not load details.'; }
        this.loading = false;
    }
    get docs() {
        const q = this.search.toLowerCase();
        let list = this.docsAll.filter(d => !q || [d.name, d.hospital, d.specialty].some(x => (x || '').toLowerCase().includes(q)));
        const k = this.sortKey;
        list = [...list].sort((a, b) => {
            if (k === 'calls') return b.completed - a.completed || a.name.localeCompare(b.name);
            if (k === 'missed') return b.missed - a.missed || a.name.localeCompare(b.name);
            if (k === 'nc') return (a.completed > 0) - (b.completed > 0) || a.name.localeCompare(b.name);
            return a.name.localeCompare(b.name);
        });
        return list.map(d => ({ ...d, specialty: d.specialty || '—', hospital: d.hospital || '—', tag: d.completed > 0 ? 'Covered' : 'Not covered', tagClass: d.completed > 0 ? 'tag ok' : 'tag no' }));
    }
    get caption() {
        const cov = this.docsAll.filter(d => d.completed > 0).length;
        return `${this.docsAll.length} doctors · ${cov} covered · ${this.periodLabel || ''}`;
    }
    get calls() { return [...(this.detail?.calls || [])].sort((a, b) => b.sort.localeCompare(a.sort)).map((c, i) => ({ ...c, key: `c${i}` })); }
    get plans() { return [...(this.detail?.plans || [])].sort((a, b) => b.sort.localeCompare(a.sort)).map((c, i) => ({ ...c, key: `p${i}` })); }
    get emails() { return (this.detail?.emails || []).map((c, i) => ({ ...c, key: `m${i}` })); }
    get noCalls() { return this.calls.length === 0; }
    get noPlans() { return this.plans.length === 0; }
    get noEmails() { return this.emails.length === 0; }

    handleSearch(e) { this.search = e.target.value; }
    handleSort(e) { this.sortKey = e.detail.value; }
    openDoctor(e) { this.fromGroup = this.level === 'group' || this.fromGroup; this.loadDoctor(e.currentTarget.dataset.id); }
    backToGroup() { this.level = 'group'; this.detail = null; }
    close() { this.dispatchEvent(new CustomEvent('close')); }
}
