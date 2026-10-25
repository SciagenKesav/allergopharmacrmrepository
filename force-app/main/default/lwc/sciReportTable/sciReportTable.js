import { LightningElement, api } from 'lwc';
import { compareCells, downloadCsv } from 'c/sciReportsUtil';

const PAGE = 50;

export default class SciReportTable extends LightningElement {
    @api title;
    @api icon = 'utility:table';
    @api rowAction; // 'doctor' | 'group' | 'salesdrill' | null
    @api groupDim;
    _columns = [];
    _rows = [];
    sortKey;
    sortAsc = true;
    showAll = false;

    @api get columns() { return this._columns; }
    set columns(v) {
        this._columns = v || [];
        if (!this.sortKey || !this._columns.find(c => c.key === this.sortKey)) {
            this.sortKey = this._columns[0]?.key;
            this.sortAsc = true;
        }
    }
    @api get rows() { return this._rows; }
    set rows(v) { this._rows = v || []; this.showAll = false; }

    get sorted() {
        const key = this.sortKey;
        const dir = this.sortAsc ? 1 : -1;
        return this._rows
            .map((r, i) => ({ r, i }))
            .sort((a, b) => (key ? dir * compareCells(a.r[key], b.r[key]) : 0) || a.i - b.i);
    }
    get isEmpty() { return this._rows.length === 0; }
    get canToggle() { return this._rows.length > PAGE; }
    get toggleLabel() { return this.showAll ? 'Show first 50' : `Show all ${this._rows.length}`; }
    get footer() { return `${this._rows.length} rows${this.rowAction ? ' · tap a row for details' : ''}`; }
    get sortOptions() { return this._columns.map(c => ({ label: c.label, value: c.key })); }
    get headers() {
        return this._columns.map(c => ({
            key: c.key, label: c.label,
            cls: `${c.numeric ? 'num ' : ''}sortable`,
            arrow: c.key === this.sortKey ? (this.sortAsc ? ' ▲' : ' ▼') : ''
        }));
    }
    get visibleRows() {
        const list = this.showAll ? this.sorted : this.sorted.slice(0, PAGE);
        return list.map(({ r, i }) => ({
            id: `${i}`, index: i, cls: this.rowAction ? 'clickable' : '',
            cells: this._columns.map(c => ({ key: c.key, value: r[c.key] ?? '', cls: c.numeric ? 'num' : '' }))
        }));
    }
    handleHeader(e) {
        const key = e.currentTarget.dataset.key;
        if (key === this.sortKey) this.sortAsc = !this.sortAsc;
        else { this.sortKey = key; this.sortAsc = !this._columns.find(c => c.key === key)?.numeric; } // numeric columns start descending
    }
    handleSortPick(e) {
        this.sortKey = e.detail.value;
        this.sortAsc = !this._columns.find(c => c.key === this.sortKey)?.numeric;
    }
    handleToggle() { this.showAll = !this.showAll; }
    handleExport() { downloadCsv(this.title || 'report', this._columns, this.sorted.map(x => x.r)); }
    handleRow(e) {
        if (!this.rowAction) return;
        const row = this._rows[Number(e.currentTarget.dataset.index)];
        this.dispatchEvent(new CustomEvent('rowclick', { detail: { row, action: this.rowAction, dim: this.groupDim } }));
    }
}