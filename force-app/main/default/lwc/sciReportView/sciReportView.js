import { LightningElement, api } from 'lwc';
import getReport from '@salesforce/apex/ReportsController.getReport';
import getSamples from '@salesforce/apex/ReportsController.getSamples';

export default class SciReportView extends LightningElement {
    @api reportKey;
    @api period;        // { start, end, label, periodName }
    @api filters;       // { search, segments, ... }
    @api repUserId;
    @api territoryId;
    @api groupBy;
    @api refreshToken;  // changes when the user presses Refresh

    result;
    loading = false;
    error;
    seq = 0;
    connected = false;

    connectedCallback() { this.connected = true; this.load(); }
    renderedCallback() {
        const sig = JSON.stringify([this.reportKey, this.period, this.filters, this.repUserId, this.territoryId, this.groupBy, this.refreshToken]);
        if (sig !== this.lastSig) { this.lastSig = sig; if (this.connected && this.result !== undefined) this.load(); }
    }

    get paramsObject() {
        return { startDate: this.period.start, endDate: this.period.end, periodName: this.period.periodName, repUserId: this.repUserId || '', territoryId: this.territoryId || '', groupBy: this.groupBy || 'Segment', refresh: this.refreshToken || '', ...(this.filters || {}) };
    }
    @api get paramsJson() { return JSON.stringify(this.paramsObject); }

    async load() {
        const mine = ++this.seq;
        this.loading = true; this.error = null;
        try {
            const paramsJson = JSON.stringify(this.paramsObject);
            const r = this.reportKey === 'samples' ? await getSamples({ paramsJson }) : await getReport({ reportKey: this.reportKey, paramsJson });
            if (mine !== this.seq) return;
            this.result = r;
            this.dispatchEvent(new CustomEvent('loaded', { detail: { doctorCount: r.doctorCount, title: r.title } }));
        } catch (e) {
            if (mine !== this.seq) return;
            this.error = e?.body?.message || 'Could not load this report.';
            this.result = null;
        }
        this.loading = false;
    }
    get chartGrid() { return (this.result?.charts?.length || 0) > 1 ? 'charts two' : 'charts'; }
    handleRowClick(e) { this.dispatchEvent(new CustomEvent('drill', { detail: e.detail })); }
}
