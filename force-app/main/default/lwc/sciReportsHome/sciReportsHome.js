import { LightningElement, wire } from 'lwc';
import USER_ID from '@salesforce/user/Id';
import { getRecord } from 'lightning/uiRecordApi';
import NAME_FIELD from '@salesforce/schema/User.Name';
import getLibrary from '@salesforce/apex/ReportsController.getLibrary';
import getScopeOptions from '@salesforce/apex/ReportsController.getScopeOptions';
import getFilterOptions from '@salesforce/apex/ReportsController.getFilterOptions';
import { PERIOD_OPTIONS, computePeriod } from 'c/sciReportsUtil';

const CATALOGUE = [
    { group: 'Calls & Coverage', key: 'performance', name: 'Performance Overview', icon: 'utility:chart', color: '#4F46E5', summary: 'Coverage, calls and achievement at a glance', label: 'coverage' },
    { group: 'Calls & Coverage', key: 'coverage', name: 'Call Coverage', icon: 'utility:groups', color: '#059669', summary: 'Who you reached, grouped any way you like', label: 'coverage' },
    { group: 'Calls & Coverage', key: 'frequency', name: 'Call Frequency', icon: 'utility:repeat', color: '#7C3AED', summary: 'Calls per doctor against plan', label: 'achievement' },
    { group: 'Calls & Coverage', key: 'missed', name: 'Missed Calls', icon: 'utility:warning', color: '#DC2626', summary: 'Planned calls whose day has passed', label: 'missed' },
    { group: 'Customers', key: 'segment', name: 'Segment Analysis', icon: 'utility:rating', color: '#059669', summary: 'V3, V2 and V1 classification performance', label: 'V3 covered' },
    { group: 'Customers', key: 'specialty', name: 'Specialty Coverage', icon: 'utility:user', color: '#0891B2', summary: 'Coverage by specialty', label: 'specialties reached' },
    { group: 'Customers', key: 'consent', name: 'Consent Status', icon: 'utility:check', color: '#059669', summary: 'Captured, pending and expired consent', label: 'captured' },
    { group: 'Products & Engagement', key: 'product', name: 'Product Detailing', icon: 'utility:products', color: '#4F46E5', summary: 'Which products you detailed', label: 'products' },
    { group: 'Products & Engagement', key: 'email', name: 'Approved Email', icon: 'utility:email', color: '#0891B2', summary: 'Approved emails sent and delivered', label: 'sent' },
    { group: 'Products & Engagement', key: 'omni', name: 'Omnichannel Engagement', icon: 'utility:layers', color: '#7C3AED', summary: 'Calls, CLM, email and samples per doctor', label: 'engaged' },
    { group: 'Sales', key: 'sales', name: 'Sales', icon: 'utility:moneybag', color: '#D97706', summary: 'Primary, secondary, trend and achievement', label: '' },
    { group: 'Sales', key: 'samples', name: 'Samples', icon: 'utility:package', color: '#BE185D', summary: 'Packs given on submitted calls', label: '' }
];
const EMPTY = { search: '', segments: [], coverage: [], consents: [], specialties: [], territories: [], cities: [], products: [] };
const DIM_KEYS = ['segments', 'coverage', 'consents', 'specialties', 'territories', 'cities', 'products'];

export default class SciReportsHome extends LightningElement {
    screen = 'library';
    periodName = 'month';
    customFrom;
    customTo;
    filters = { ...EMPTY };
    repUserId = '';
    territoryId = '';
    scope = { isManager: false, isAdmin: false, territories: [], kams: [] };
    groupBy = 'Segment';
    refreshToken = 0;
    options = {};
    showFilters = false;
    drill;
    drillParams = '{}';
    doctorCount = 0;
    userName = '';
    library = {};
    period = computePeriod('month');

    periodOptions = PERIOD_OPTIONS;
    groupOptions = ['Segment', 'Specialty', 'Territory', 'City', 'Product'].map(v => ({ label: `By ${v}`, value: v }));

    @wire(getRecord, { recordId: USER_ID, fields: [NAME_FIELD] })
    wiredUser({ data }) { if (data) this.userName = data.fields.Name.value; }

    connectedCallback() { this.loadScope(); this.loadLibrary(); this.loadOptions(); }

    async loadScope() {
        try { this.scope = await getScopeOptions(); } catch (e) { /* keep KAM-only view */ }
    }

    async loadLibrary() {
        try { this.library = await getLibrary({ startDate: this.period.start, endDate: this.period.end, repUserId: this.repUserId, territoryId: this.territoryId, nonce: String(this.refreshToken) }); }
        catch (e) { this.library = {}; }
    }
    async loadOptions() {
        try { this.options = await getFilterOptions({ startDate: this.period.start, endDate: this.period.end, repUserId: this.repUserId, territoryId: this.territoryId }); }
        catch (e) { this.options = {}; }
    }

    get isManager() { return !!this.scope?.isManager; }
    get territoryChoices() {
        return [{ label: this.scope.isAdmin ? 'All territories' : 'All my territories', value: '' }, ...this.scope.territories.map(t => ({ label: t.label, value: t.value }))];
    }
    get repChoices() {
        const sel = this.scope.territories.find(t => t.value === this.territoryId);
        const list = this.scope.kams.filter(k => !sel || k.ids.some(id => sel.ids.includes(id)));
        return [{ label: this.territoryId ? 'All KAMs in territory' : 'All KAMs', value: '' }, ...list.map(k => ({ label: k.label, value: k.value }))];
    }
    get isCustom() { return this.periodName === 'custom'; }
    get inReport() { return this.screen !== 'library'; }
    get isSales() { return this.screen === 'sales'; }
    get isCoverage() { return this.screen === 'coverage'; }
    get showControls() { return this.screen !== 'sales' && this.screen !== 'samples'; }
    get current() { return CATALOGUE.find(c => c.key === this.screen) || {}; }
    get viewingLabel() {
        const k = this.scope.kams.find(x => x.value === this.repUserId);
        const t = this.scope.territories.find(x => x.value === this.territoryId);
        if (k) return ` · viewing ${k.label}`;
        if (t) return ` · ${t.label.replace(/^(— )+/, '')} team`;
        return '';
    }
    get headerTitle() { return this.inReport ? this.current.name : 'Reports'; }
    get headerSub() {
        if (!this.inReport) return `${this.userName} · Standard reports${this.viewingLabel}`;
        if (this.isSales) return 'All data loaded · ignores period, search and filters';
        const n = this.showControls ? ` · ${this.doctorCount} doctors` : '';
        return `${this.period.label}${n}${this.viewingLabel}`;
    }
    get groups() {
        const out = [];
        CATALOGUE.forEach(c => {
            let g = out.find(x => x.name === c.group.toUpperCase());
            if (!g) { g = { name: c.group.toUpperCase(), cards: [] }; out.push(g); }
            const hl = this.library[c.key];
            g.cards.push({ ...c, tileStyle: `background:${c.color};`, headline: hl === undefined ? '' : hl, label: hl === undefined ? '' : c.label });
        });
        return out;
    }
    get activeCount() { return DIM_KEYS.reduce((n, k) => n + (this.filters[k]?.length || 0), 0); }
    get filterLabel() { return this.activeCount ? `Filters · ${this.activeCount}` : 'Filters'; }
    get chips() { const out = []; DIM_KEYS.forEach(d => (this.filters[d] || []).forEach(v => out.push({ key: `${d}:${v}`, dim: d, value: v }))); return out; }
    get hasChips() { return this.chips.length > 0; }

    handlePeriod(e) {
        this.periodName = e.detail.value;
        if (this.periodName === 'custom' && !this.customFrom) { this.customFrom = this.period.start; this.customTo = this.period.end; }
        this.recompute();
    }
    handleFrom(e) { this.customFrom = e.target.value; if (this.customTo && this.customTo < this.customFrom) this.customTo = this.customFrom; this.recompute(); }
    handleTo(e) { this.customTo = e.target.value; if (this.customFrom && this.customTo < this.customFrom) this.customTo = this.customFrom; this.recompute(); }
    recompute() { this.period = computePeriod(this.periodName, this.customFrom, this.customTo); this.loadLibrary(); this.loadOptions(); }
    handleTerritory(e) {
        this.territoryId = e.detail.value;
        // drop the KAM if they are not in the newly picked territory
        if (this.repUserId && !this.repChoices.some(c => c.value === this.repUserId)) this.repUserId = '';
        this.loadLibrary(); this.loadOptions();
    }
    handleRep(e) { this.repUserId = e.detail.value; this.loadLibrary(); this.loadOptions(); }
    handleRefresh() { this.refreshToken += 1; this.loadLibrary(); this.loadOptions(); }
    openReport(e) { this.screen = e.currentTarget.dataset.key; this.doctorCount = 0; }
    goLibrary() { this.screen = 'library'; this.loadLibrary(); }
    handleSearch(e) { this.filters = { ...this.filters, search: e.target.value }; }
    handleGroupBy(e) { this.groupBy = e.detail.value; }
    handleLoaded(e) { this.doctorCount = e.detail.doctorCount; }
    openFilters() { this.showFilters = true; }
    closeFilters() { this.showFilters = false; }
    applyFilters(e) { this.filters = { ...e.detail, search: this.filters.search }; this.showFilters = false; }
    removeChip(e) {
        const { dim, value } = e.currentTarget.dataset;
        this.filters = { ...this.filters, [dim]: this.filters[dim].filter(v => v !== value) };
    }
    clearAll() { this.filters = { ...EMPTY }; }
    handleDrill(e) {
        const { row, action, dim } = e.detail;
        this.drillParams = JSON.stringify({ startDate: this.period.start, endDate: this.period.end, repUserId: this.repUserId, territoryId: this.territoryId, ...this.filters });
        if (action === 'doctor') this.drill = { mode: 'doctor', title: row.name, hcpId: row._id };
        else if (action === 'group') this.drill = { mode: 'group', title: `${dim === 'ProductAny' ? 'Product' : dim}: ${row.group}`, dim, value: row._group };
    }
    closeDrill() { this.drill = null; }
}
