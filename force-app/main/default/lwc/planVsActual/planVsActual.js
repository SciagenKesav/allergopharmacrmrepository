import { LightningElement, track } from 'lwc';
import getOverview from '@salesforce/apex/PlanVsActualController.getOverview';
import getItems from '@salesforce/apex/PlanVsActualController.getItems';
import getTerritories from '@salesforce/apex/PlanVsActualController.getTerritories';

const EMPTY = {
    planned: 0, onPlan: 0, otherDay: 0, missed: 0, excused: 0, cancelled: 0, upcoming: 0,
    unplanned: 0, actual: 0, drafts: 0, typeChanged: 0, achievementPct: null, onDayPct: null,
    unplannedPct: null, truncated: false, reps: [], days: []
};

const DEVIATIONS = ['Other day', 'Missed', 'Cancelled', 'Unplanned'];
const CHIPS = [
    { value: 'deviations', label: 'Deviations' },
    { value: 'Missed', label: 'Missed' },
    { value: 'Other day', label: 'Other day' },
    { value: 'Unplanned', label: 'Unplanned' },
    { value: 'Cancelled', label: 'Cancelled' },
    { value: 'Excused', label: 'Leave' },
    { value: 'Upcoming', label: 'Upcoming' },
    { value: 'On plan', label: 'As planned' },
    { value: 'all', label: 'All' }
];
const BADGE = {
    'On plan': 'o-on', 'Other day': 'o-other', Missed: 'o-missed', Cancelled: 'o-cancelled',
    Unplanned: 'o-unplanned', Excused: 'o-excused', Upcoming: 'o-upcoming'
};
const OUTCOME_TEXT = { 'On plan': 'As planned', Excused: 'On leave' };

export default class PlanVsActual extends LightningElement {
    @track overview = null;
    @track items = [];
    @track territories = [];
    @track allReps = [];
    @track month = '';
    @track territoryId = '';
    @track repId = '';
    @track chip = 'deviations';
    @track loading = false;
    @track error = '';
    @track itemsTotal = 0;
    @track itemsTruncated = false;
    _seq = 0;

    connectedCallback() {
        const now = new Date();
        this.month = this.monthValue(now.getFullYear(), now.getMonth());
        this.loadTerritories();
        this.refresh();
    }

    // ------------------------------------------------------------ options

    monthValue(y, m) { return `${y}-${String(m + 1).padStart(2, '0')}-01`; }

    get monthOptions() {
        const now = new Date();
        const out = [];
        for (let offset = 3; offset >= -11; offset--) {
            const d = new Date(now.getFullYear(), now.getMonth() + offset, 1);
            const label = d.toLocaleDateString('en-IN', { month: 'long', year: 'numeric' });
            out.push({ label: offset > 0 ? `${label} (upcoming)` : label, value: this.monthValue(d.getFullYear(), d.getMonth()) });
        }
        return out;
    }

    get territoryOptions() {
        return [{ label: 'All territories', value: '' }, ...this.territories.map(t => ({ label: t.name, value: t.id }))];
    }

    get repOptions() {
        return [{ label: 'All reps', value: '' }, ...this.allReps.map(r => ({ label: r.name, value: r.userId }))];
    }

    get chips() {
        return CHIPS.map(c => ({ ...c, className: c.value === this.chip ? 'chip chip-on' : 'chip' }));
    }

    // ------------------------------------------------------------ loading

    async loadTerritories() {
        try {
            this.territories = await getTerritories();
        } catch (e) {
            this.error = this.message(e);
        }
    }

    async refresh() {
        const seq = ++this._seq;
        this.loading = true;
        this.error = '';
        try {
            const args = { monthStart: this.month, territoryId: this.territoryId || null, userId: this.repId || null };
            const [ov, list] = await Promise.all([
                getOverview(args),
                getItems({ ...args, outcomes: this.outcomesFor(this.chip) })
            ]);
            if (seq !== this._seq) return;
            this.overview = ov;
            if (!this.repId) this.allReps = [...ov.reps].sort((a, b) => (a.name || '').localeCompare(b.name || ''));
            this.items = list.items;
            this.itemsTotal = list.total;
            this.itemsTruncated = list.truncated;
        } catch (e) {
            if (seq === this._seq) this.error = this.message(e);
        } finally {
            if (seq === this._seq) this.loading = false;
        }
    }

    outcomesFor(chip) {
        if (chip === 'all') return null;
        if (chip === 'deviations') return DEVIATIONS;
        return [chip];
    }

    handleMonth(e) { this.month = e.detail.value; this.repId = ''; this.allReps = []; this.refresh(); }
    handleTerritory(e) { this.territoryId = e.detail.value; this.repId = ''; this.allReps = []; this.refresh(); }
    handleRep(e) { this.repId = e.detail.value; this.refresh(); }
    handleChip(e) { this.chip = e.currentTarget.dataset.value; this.refresh(); }
    viewRep(e) { this.repId = e.target.dataset.id; this.chip = 'deviations'; this.refresh(); }

    // ------------------------------------------------------------ overview

    get ov() { return this.overview || EMPTY; }
    get hasPlans() { return this.ov.planned > 0; }
    get hasReps() { return this.ov.reps.length > 0; }
    get hasDays() { return this.ov.days.some(d => d.planned > 0 || d.actual > 0); }

    get achievementText() { return this.ov.achievementPct == null ? '-' : `${this.ov.achievementPct}%`; }
    get achievedText() {
        const due = this.ov.planned - this.ov.upcoming - this.ov.excused;
        if (due <= 0) return 'No planned call has come due yet.';
        return `${this.ov.onPlan + this.ov.otherDay} of ${due} planned calls done`;
    }
    get onDayText() {
        return this.ov.onDayPct == null ? '' : `${this.ov.onDayPct}% on the day they were planned`;
    }
    get asOfText() {
        const bits = [];
        if (this.ov.upcoming) bits.push(`${this.ov.upcoming} still upcoming`);
        if (this.ov.excused) bits.push(`${this.ov.excused} excused for approved leave`);
        return bits.join(', ');
    }
    get unplannedNote() {
        return this.ov.unplannedPct == null ? '' : `${this.ov.unplannedPct}% of reported calls`;
    }
    get footnote() {
        const bits = [`${this.ov.actual} calls reported this month`];
        if (this.ov.drafts) bits.push(`${this.ov.drafts} more still in draft and not counted`);
        if (this.ov.typeChanged) bits.push(`${this.ov.typeChanged} done with a different call type than planned`);
        return bits.join(' · ');
    }

    get dayBars() {
        const max = Math.max(1, ...this.ov.days.map(d => Math.max(d.planned, d.actual)));
        const h = n => `height: ${n === 0 ? 0 : Math.max(4, Math.round((n / max) * 100))}%`;
        return this.ov.days.map(d => ({
            day: d.day,
            title: `Day ${d.day}: ${d.planned} planned, ${d.actual} reported`,
            planStyle: h(d.planned),
            actStyle: h(d.actual)
        }));
    }

    get repRows() {
        return this.ov.reps.map(r => {
            const pct = r.achievementPct;
            let fill = 'f-none';
            if (pct != null) fill = pct >= 90 ? 'f-good' : pct >= 70 ? 'f-warn' : 'f-bad';
            return {
                ...r,
                territoryText: r.territory || 'No territory',
                missedClass: r.missed > 0 ? 'num-bad' : 'num',
                achievementText: pct == null ? '-' : `${pct}%`,
                barClass: `ach-fill ${fill}`,
                barStyle: `width: ${pct == null ? 0 : Math.min(100, pct)}%`,
                hasDrafts: r.drafts > 0
            };
        });
    }

    // ------------------------------------------------------------ call list

    get hasItems() { return this.items.length > 0; }
    get itemsCountText() {
        if (this.itemsTruncated && this.itemsTotal > this.items.length) return `Showing the first ${this.items.length} of ${this.itemsTotal}`;
        return `${this.itemsTotal} ${this.itemsTotal === 1 ? 'call' : 'calls'}`;
    }
    get emptyItemsText() {
        return this.chip === 'deviations' && this.hasPlans
            ? 'No deviations for this selection. Every due plan was done as planned.'
            : 'No calls to show for this selection.';
    }

    get itemRows() {
        return this.items.map((i, idx) => ({
            key: `${i.planId || ''}-${i.cvrId || ''}-${idx}`,
            repName: i.repName,
            hcpName: i.hcpName || 'HCO visit',
            hcoName: i.hcoName || '',
            plannedText: this.dateText(i.plannedDate) || 'Not planned',
            actualText: this.dateText(i.actualDate) || '-',
            gapText: this.gapText(i),
            outcome: OUTCOME_TEXT[i.outcome] || i.outcome,
            badgeClass: `badge ${BADGE[i.outcome] || 'o-upcoming'}`,
            notes: this.notesText(i)
        }));
    }

    dateText(s) {
        if (!s) return '';
        const [y, m, d] = s.split('-').map(Number);
        return new Date(y, m - 1, d).toLocaleDateString('en-IN', { weekday: 'short', day: '2-digit', month: 'short' });
    }

    gapText(i) {
        if (i.gapDays == null) return '-';
        if (i.gapDays === 0) return 'Same day';
        const n = Math.abs(i.gapDays);
        return `${n} ${n === 1 ? 'day' : 'days'} ${i.gapDays > 0 ? 'late' : 'early'}`;
    }

    notesText(i) {
        const notes = [];
        if (i.typeChanged) notes.push(`Planned as ${i.plannedType}, done as ${i.actualType}`);
        if (i.moved) notes.push('Rep moved this plan to a later date');
        if (i.reportNotFound) notes.push('Marked done but no submitted call report found');
        if (i.outcome === 'Unplanned') notes.push('Call reported with no plan behind it');
        return notes.join('. ');
    }

    // ------------------------------------------------------------ export

    get exportDisabled() { return this.loading || !this.hasReps; }

    async exportCsv() {
        try {
            const list = await getItems({
                monthStart: this.month, territoryId: this.territoryId || null, userId: this.repId || null, outcomes: null
            });
            const head = ['Rep', 'HCP', 'HCO', 'Outcome', 'Planned date', 'Reported date', 'Difference (days)', 'Planned type', 'Reported type', 'Notes'];
            const rows = list.items.map(i => [
                i.repName, i.hcpName, i.hcoName, OUTCOME_TEXT[i.outcome] || i.outcome, i.plannedDate, i.actualDate,
                i.gapDays, i.plannedType, i.actualType, this.notesText(i)
            ]);
            const csv = [head, ...rows].map(r => r.map(v => this.csvCell(v)).join(',')).join('\r\n');
            const a = document.createElement('a');
            a.href = 'data:text/csv;charset=utf-8,' + encodeURIComponent('﻿' + csv);
            a.download = `plan-vs-actual-${this.month.slice(0, 7)}.csv`;
            document.body.appendChild(a);
            a.click();
            document.body.removeChild(a);
        } catch (e) {
            this.error = this.message(e);
        }
    }

    csvCell(v) {
        const s = v == null ? '' : String(v);
        return /[",\r\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
    }

    message(e) {
        return (e && e.body && e.body.message) || (e && e.message) || 'Something went wrong.';
    }
}