import { LightningElement, api } from 'lwc';

const SEG = ['V3', 'V2', 'V1', 'Unclassified'], COV = ['Covered', 'Not covered'], CON = ['Captured', 'Pending', 'Expired'];
const LISTS = [
    { dim: 'specialties', label: 'Specialty', opt: 'specialties', placeholder: 'Search specialty' },
    { dim: 'territories', label: 'Territory', opt: 'territories', placeholder: 'Search territory' },
    { dim: 'cities', label: 'City', opt: 'cities', placeholder: 'Search city' },
    { dim: 'products', label: 'Product detailed', opt: 'products', placeholder: 'Search product' }
];

export default class SciFilterPanel extends LightningElement {
    @api options = {};
    state = { segments: [], coverage: [], consents: [], specialties: [], territories: [], cities: [], products: [] };
    queries = {};

    @api get value() { return this.state; }
    set value(v) { this.state = { segments: [], coverage: [], consents: [], specialties: [], territories: [], cities: [], products: [], ...(v || {}) }; }

    chips(list, dim) { return list.map(v => ({ value: v, cls: `chip ${this.state[dim].includes(v) ? 'on' : ''}` })); }
    get segmentChips() { return this.chips(SEG, 'segments'); }
    get coverageChips() { return this.chips(COV, 'coverage'); }
    get consentChips() { return this.chips(CON, 'consents'); }
    get lists() {
        return LISTS.map(l => {
            const q = (this.queries[l.dim] || '').toLowerCase();
            const all = (this.options?.[l.opt] || []).filter(o => !this.state[l.dim].includes(o) && (!q || o.toLowerCase().includes(q)));
            return { ...l, selected: this.state[l.dim], options: all.slice(0, 60) };
        });
    }
    toggleChip(e) {
        const { dim, value } = e.currentTarget.dataset;
        const cur = this.state[dim];
        this.state = { ...this.state, [dim]: cur.includes(value) ? cur.filter(x => x !== value) : [...cur, value] };
    }
    handleSearch(e) { this.queries = { ...this.queries, [e.target.dataset.dim]: e.target.value }; }
    handleClear() { this.state = { segments: [], coverage: [], consents: [], specialties: [], territories: [], cities: [], products: [] }; }
    handleApply() { this.dispatchEvent(new CustomEvent('apply', { detail: this.state })); }
    disconnectedCallback() { /* nothing to clean */ }
    @api close() { this.dispatchEvent(new CustomEvent('close')); }
}