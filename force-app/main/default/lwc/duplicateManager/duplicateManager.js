import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import LightningConfirm from 'lightning/confirm';
import getSummary from '@salesforce/apex/DuplicateAdminController.getSummary';
import getCandidates from '@salesforce/apex/DuplicateAdminController.getCandidates';
import getComparison from '@salesforce/apex/DuplicateAdminController.getComparison';
import mergeCandidate from '@salesforce/apex/DuplicateAdminController.mergeCandidate';
import markNotDuplicate from '@salesforce/apex/DuplicateAdminController.markNotDuplicate';
import reopenCandidate from '@salesforce/apex/DuplicateAdminController.reopenCandidate';
import getRecentMerges from '@salesforce/apex/DuplicateAdminController.getRecentMerges';
import undoMerge from '@salesforce/apex/DuplicateAdminController.undoMerge';
import runScan from '@salesforce/apex/DuplicateAdminController.runScan';
import scheduleNightly from '@salesforce/apex/DuplicateAdminController.scheduleNightly';
import unscheduleNightly from '@salesforce/apex/DuplicateAdminController.unscheduleNightly';
import saveSettings from '@salesforce/apex/DuplicateAdminController.saveSettings';

const COUNT_LABELS = [
    ['cvr', 'call reports'], ['consent', 'consents'], ['territory', 'territories'],
    ['affiliation', 'affiliations'], ['plan', 'plans'], ['planned', 'planned calls']
];

export default class DuplicateManager extends LightningElement {
    @track summary;
    @track candidates = [];
    @track merges = [];
    @track fType = 'All';
    @track fConfidence = 'All';
    @track fStatus = 'Open';
    @track fSearch = '';
    @track isLoading = false;
    @track error = '';
    @track scanBusy = false;
    @track busy = false;

    @track review = null;
    @track confirming = false;
    @track winnerSide = 'A';
    @track overrides = {};

    @track settingsLoaded = false;
    @track sEnabled = true;
    @track sMin = 55;
    @track sHigh = 85;
    @track sAuto = false;
    @track sAutoScore = 95;
    @track settingsDirty = false;

    typeOptions = [{ label: 'All', value: 'All' }, { label: 'HCP', value: 'HCP' }, { label: 'HCO', value: 'HCO' }];
    confidenceOptions = [{ label: 'All', value: 'All' }, { label: 'High', value: 'High' }, { label: 'Medium', value: 'Medium' }, { label: 'Low', value: 'Low' }];
    statusOptions = [{ label: 'To review', value: 'Open' }, { label: 'Marked not duplicate', value: 'Not Duplicate' }, { label: 'Merged', value: 'Merged' }];

    connectedCallback() {
        this.refreshAll();
    }

    // ------------------------------------------------------------ loading

    async refreshAll() {
        await Promise.all([this.loadSummary(), this.loadCandidates(), this.loadMerges()]);
    }

    async loadSummary() {
        try {
            this.summary = await getSummary();
            if (!this.settingsLoaded || !this.settingsDirty) this.applySettings(this.summary.settings);
        } catch (e) { this.error = this.message(e); }
    }

    async loadCandidates() {
        this.isLoading = true;
        this.error = '';
        try {
            this.candidates = await getCandidates({
                objectType: this.fType, confidence: this.fConfidence, status: this.fStatus, search: this.fSearch, maxRows: 200
            });
        } catch (e) { this.error = this.message(e); } finally { this.isLoading = false; }
    }

    async loadMerges() {
        try {
            const list = await getRecentMerges({ maxRows: 100 });
            this.merges = list.map(m => ({
                ...m,
                statusClass: m.status === 'Merged' ? 'st-merged' : 'st-reverted',
                canUndo: m.status === 'Merged'
            }));
        } catch (e) { this.error = this.message(e); }
    }

    // ------------------------------------------------------------ list view

    get hasUnchecked() { return this.summary && this.summary.unchecked > 0; }
    get queueTabLabel() { return this.summary ? `Review queue (${this.summary.openHcp + this.summary.openHco})` : 'Review queue'; }
    get isOpenView() { return this.fStatus === 'Open'; }
    get hasCandidates() { return this.candidates.length > 0; }
    get showEmpty() { return !this.isLoading && this.candidates.length === 0; }
    get hasMerges() { return this.merges.length > 0; }

    get rows() {
        return this.candidates.map(c => {
            const lines = (c.reasons || '').split('\n').filter(Boolean).map(l => l.replace(/\s*\([+-]?\d+\)\s*$/, ''));
            return {
                ...c,
                scoreText: Math.round(c.score),
                badgeClass: this.badge(c.confidence),
                whyText: lines.slice(0, 3).join(' · '),
                actionLabel: c.status === 'Open' ? 'Review' : 'View'
            };
        });
    }

    badge(confidence) {
        const base = 'score-badge ';
        if (confidence === 'High') return base + 'b-high';
        if (confidence === 'Medium') return base + 'b-med';
        return base + 'b-low';
    }

    handleType(e) { this.fType = e.detail.value; this.loadCandidates(); }
    handleConfidence(e) { this.fConfidence = e.detail.value; this.loadCandidates(); }
    handleStatus(e) { this.fStatus = e.detail.value; this.loadCandidates(); }
    handleSearchInput(e) { this.fSearch = e.target.value; }
    handleSearchKey(e) { if (e.key === 'Enter') this.loadCandidates(); }

    // ------------------------------------------------------------ scanning

    async handleScanChanged() { await this.startScan(false); }
    async handleScanFull() {
        const ok = await LightningConfirm.open({
            message: 'A full rescan compares every HCP and HCO again. It can take several minutes on a large book. Continue?',
            label: 'Full rescan', variant: 'header', theme: 'warning'
        });
        if (ok) await this.startScan(true);
    }

    async startScan(full) {
        this.scanBusy = true;
        this.error = '';
        try {
            await runScan({ fullRescan: full });
            this.toast('Scan started', 'This runs in the background. The list refreshes in a few seconds and again when you reload.', 'success');
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            setTimeout(() => { this.refreshAll(); this.scanBusy = false; }, 10000);
        } catch (e) { this.error = this.message(e); this.scanBusy = false; }
    }

    // ------------------------------------------------------------ review panel

    async openReview(e) {
        const id = e.target.dataset.id;
        this.error = '';
        this.busy = true;
        try {
            const cmp = await getComparison({ candidateId: id });
            const c = cmp.candidate;
            this.overrides = {};
            this.confirming = false;
            this.winnerSide = cmp.suggestedWinnerId === c.aId ? 'A' : 'B';
            this.review = {
                cmp,
                candidate: c,
                isOpen: c.status === 'Open',
                scoreText: Math.round(c.score),
                badgeClass: this.badge(c.confidence),
                reasonList: (c.reasons || '').split('\n').filter(Boolean).map((t, i) => ({ key: 'r' + i, text: t }))
            };
        } catch (err) { this.error = this.message(err); } finally { this.busy = false; }
    }

    closeReview() { this.review = null; this.confirming = false; this.overrides = {}; }

    get winnerName() { return this.review ? (this.winnerSide === 'A' ? this.review.candidate.aName : this.review.candidate.bName) : ''; }
    get loserName() { return this.review ? (this.winnerSide === 'A' ? this.review.candidate.bName : this.review.candidate.aName) : ''; }
    get winnerId() { return this.review ? (this.winnerSide === 'A' ? this.review.candidate.aId : this.review.candidate.bId) : null; }

    get aSuggested() { return this.review && this.review.cmp.suggestedWinnerId === this.review.candidate.aId; }
    get bSuggested() { return this.review && this.review.cmp.suggestedWinnerId === this.review.candidate.bId; }
    get suggestedWhy() {
        if (!this.review) return '';
        const r = (this.review.cmp.winnerReasons || []).slice(0, 3).join('; ');
        return r || 'the more complete record.';
    }
    get aCardClass() { return 'winner-card ' + (this.winnerSide === 'A' ? 'is-winner' : ''); }
    get bCardClass() { return 'winner-card ' + (this.winnerSide === 'B' ? 'is-winner' : ''); }
    get aKeepText() { return this.winnerSide === 'A' ? 'Keep this record' : 'Will be merged into the other'; }
    get bKeepText() { return this.winnerSide === 'B' ? 'Keep this record' : 'Will be merged into the other'; }
    get aCountsText() { return this.countsText(this.review && this.review.cmp.aCounts); }
    get bCountsText() { return this.countsText(this.review && this.review.cmp.bCounts); }

    countsText(counts) {
        if (!counts) return '';
        const parts = COUNT_LABELS.filter(([k]) => counts[k] > 0).map(([k, label]) => `${counts[k]} ${label}`);
        return parts.length ? parts.join(' · ') : 'No related records';
    }

    pickWinner(e) { this.winnerSide = e.currentTarget.dataset.side; }
    pickValue(e) {
        const { key, side } = e.currentTarget.dataset;
        this.overrides = { ...this.overrides, [key]: side };
    }

    // Group rows (name, address) are chosen as one unit; every other field on its own.
    get groups() {
        if (!this.review) return [];
        const byKey = new Map();
        for (const r of this.review.cmp.rows) {
            if (!byKey.has(r.groupKey)) byKey.set(r.groupKey, []);
            byKey.get(r.groupKey).push(r);
        }
        return Array.from(byKey.entries()).map(([key, members]) => ({ key, members }));
    }

    text(key, members, side) {
        const val = api => {
            const m = members.find(x => x.api === api);
            return m ? (side === 'A' ? m.aValue : m.bValue) : null;
        };
        if (key === 'NAME') return val('Name') || [val('Prefix__c'), val('First_Name__c'), val('Last_Name__c')].filter(Boolean).join(' ');
        if (key === 'ADDRESS') {
            const line = ['Billing_Street__c', 'Billing_City__c', 'Billing_State__c', 'Billing_Postal_Code__c', 'Billing_Country__c'].map(val).filter(Boolean).join(', ');
            const lat = val('Geolocation__Latitude__s'), lon = val('Geolocation__Longitude__s');
            const pin = lat && lon ? `(${Number(lat).toFixed(4)}, ${Number(lon).toFixed(4)})` : '';
            return [line, pin].filter(Boolean).join(' ');
        }
        return val(members[0].api) || '';
    }

    get displayRows() {
        return this.groups.map(g => {
            const label = g.key === 'NAME' ? 'Name' : (g.key === 'ADDRESS' ? 'Address and location' : g.members[0].label);
            const aText = this.text(g.key, g.members, 'A');
            const bText = this.text(g.key, g.members, 'B');
            const differs = g.members.some(m => m.differs);
            const auto = g.members.every(m => m.auto);
            const winnerText = this.winnerSide === 'A' ? aText : bText;
            const otherSide = this.winnerSide === 'A' ? 'B' : 'A';
            const pick = this.overrides[g.key] || (winnerText ? this.winnerSide : otherSide);
            return {
                key: g.key, label, differs, auto,
                aText: aText || '—', bText: bText || '—',
                aClass: 'pick ' + (pick === 'A' ? 'pick-on' : 'pick-off'),
                bClass: 'pick ' + (pick === 'B' ? 'pick-on' : 'pick-off')
            };
        });
    }

    get diffRows() { return this.displayRows.filter(r => r.differs); }
    get hasDiffRows() { return this.diffRows.length > 0; }
    get sameCount() { return this.displayRows.filter(r => !r.differs).length; }

    startConfirm() { this.confirming = true; }
    cancelConfirm() { this.confirming = false; }

    async handleMerge() {
        this.busy = true;
        this.error = '';
        try {
            const choices = {};
            for (const r of this.diffRows) {
                const side = this.overrides[r.key];
                if (side && !r.auto) choices[r.key] = side === this.winnerSide ? 'winner' : 'loser';
            }
            const res = await mergeCandidate({ candidateId: this.review.candidate.id, winnerId: this.winnerId, choices });
            this.toast('Merged', res.summary, 'success');
            this.closeReview();
            await this.refreshAll();
        } catch (e) { this.error = this.message(e); this.confirming = false; } finally { this.busy = false; }
    }

    async handleNotDuplicate() {
        this.busy = true;
        try {
            await markNotDuplicate({ candidateId: this.review.candidate.id, note: null });
            this.toast('Marked not a duplicate', 'This pair will not be flagged again.', 'success');
            this.closeReview();
            await this.refreshAll();
        } catch (e) { this.error = this.message(e); } finally { this.busy = false; }
    }

    async handleReopen() {
        this.busy = true;
        try {
            await reopenCandidate({ candidateId: this.review.candidate.id });
            this.closeReview();
            await this.refreshAll();
        } catch (e) { this.error = this.message(e); } finally { this.busy = false; }
    }

    // ------------------------------------------------------------ history

    async handleUndo(e) {
        const id = e.target.dataset.id;
        const m = this.merges.find(x => x.id === id);
        const ok = await LightningConfirm.open({
            message: `Undo ${m.number_x}? "${m.loserName}" comes back and its related records move back from "${m.winnerName}".`,
            label: 'Undo merge', variant: 'header', theme: 'warning'
        });
        if (!ok) return;
        try {
            await undoMerge({ logId: id });
            this.toast('Merge undone', `${m.loserName} is active again.`, 'success');
            await this.refreshAll();
        } catch (err) { this.error = this.message(err); }
    }

    // ------------------------------------------------------------ settings

    applySettings(s) {
        if (!s) return;
        this.sEnabled = s.enabled; this.sMin = s.minScore; this.sHigh = s.highScore; this.sAuto = s.autoMerge; this.sAutoScore = s.autoMergeScore;
        this.settingsLoaded = true;
        this.settingsDirty = false;
    }

    get settingsDisabled() { return !this.sEnabled; }
    get autoScoreDisabled() { return !this.sEnabled || !this.sAuto; }
    get saveDisabled() { return !this.settingsDirty || this.busy; }

    handleSEnabled(e) { this.sEnabled = e.target.checked; this.settingsDirty = true; }
    handleSMin(e) { this.sMin = e.target.value; this.settingsDirty = true; }
    handleSHigh(e) { this.sHigh = e.target.value; this.settingsDirty = true; }
    handleSAuto(e) { this.sAuto = e.target.checked; this.settingsDirty = true; }
    handleSAutoScore(e) { this.sAutoScore = e.target.value; this.settingsDirty = true; }

    async handleSaveSettings() {
        this.busy = true;
        this.error = '';
        try {
            const s = await saveSettings({
                enabled: this.sEnabled, minScore: Number(this.sMin), highScore: Number(this.sHigh),
                autoMerge: this.sAuto, autoMergeScore: Number(this.sAutoScore)
            });
            this.applySettings(s);
            this.toast('Saved', 'Duplicate settings updated.', 'success');
            await this.loadSummary();
        } catch (e) { this.error = this.message(e); } finally { this.busy = false; }
    }

    async handleSchedule() {
        try { await scheduleNightly(); this.toast('Scheduled', 'The duplicate scan will run every night at 2 AM.', 'success'); await this.loadSummary(); }
        catch (e) { this.error = this.message(e); }
    }

    async handleUnschedule() {
        try { await unscheduleNightly(); await this.loadSummary(); } catch (e) { this.error = this.message(e); }
    }

    // ------------------------------------------------------------ helpers

    toast(title, message, variant) { this.dispatchEvent(new ShowToastEvent({ title, message, variant })); }

    message(e) {
        return (e && e.body && e.body.message) || (e && e.message) || 'Something went wrong.';
    }
}