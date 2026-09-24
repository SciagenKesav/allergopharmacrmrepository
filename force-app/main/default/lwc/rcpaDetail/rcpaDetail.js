import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { updateRecord, deleteRecord } from 'lightning/uiRecordApi';
import getAuditDetail from '@salesforce/apex/RCPAController.getAuditDetail';
import { pillStyle, TREND_COLOR, callStatusColor } from 'c/sciagenColors';

const EDIT_FIELDS = [
    'Status__c', 'POB_Units__c', 'Chemist_Signer_Name__c', 'Chemist_OTP_Verified__c',
    'Competitor_Activity__c', 'Stock_Issues__c', 'General_Remarks__c',
];

const TREND_OPTIONS = ['New Rx', 'Growing', 'Stable', 'Declining', 'Switched to competitor'].map((t) => ({
    label: t,
    value: t,
}));

export default class RcpaDetail extends LightningElement {
    _recordId;
    record;
    isLoading = false;
    isEditing = false;
    isSavingLines = false;
    error;
    editFields = EDIT_FIELDS;
    trendOptions = TREND_OPTIONS;
    prescriberFilter = { criteria: [{ fieldPath: 'Type__c', operator: 'eq', value: 'HCP' }] };

    // Edit-mode-only working copy of record.lines — a deep clone (plain
    // objects/arrays, not the same references) so Cancel can discard changes
    // without mutating the loaded, still-displayed `record`. Populated on
    // handleEdit, discarded on handleCancelEdit/after a successful save.
    editLines = [];
    removedLineIds = [];
    removedCompetitorIds = [];

    @api
    get recordId() {
        return this._recordId;
    }
    set recordId(value) {
        this._recordId = value;
        this.isEditing = false;
        this.loadDetail();
    }

    async loadDetail() {
        if (!this._recordId) {
            this.record = undefined;
            return;
        }
        this.isLoading = true;
        this.error = undefined;
        try {
            this.record = await getAuditDetail({ auditId: this._recordId });
            // Lets rcpaBrowser default the Doctor Matrix tab to whichever
            // prescriber this audit actually covers, instead of always
            // opening on the first doctor in the org-wide list — a rep who
            // just opened "Max Super Speciality Hospital" here shouldn't
            // land on an unrelated doctor when they switch tabs.
            const firstPrescriberId = this.record?.lines?.find((l) => l.prescriberId)?.prescriberId;
            this.dispatchEvent(new CustomEvent('detailloaded', { detail: { prescriberId: firstPrescriberId } }));
        } catch (e) {
            this.error = reduceError(e);
        } finally {
            this.isLoading = false;
        }
    }

    get statusPillStyle() {
        return pillStyle(callStatusColor(this.record?.status));
    }

    get isDraft() {
        return this.record?.status === 'Draft';
    }

    // "chemistArea · chemistPhone" — mirrors RCPADetailView.header's subtitle
    // line exactly (RCPAViews.swift:256). Both are optional/independent.
    get chemistMeta() {
        return [this.record?.chemistArea, this.record?.chemistPhone].filter((v) => !!v).join(' · ');
    }

    get hasChemistMeta() {
        return !!this.chemistMeta;
    }

    // Hero share stats — own vs. competitor units summed across every line,
    // same aggregate RCPADetailView.header computes from audit.lines.
    get ownUnits() {
        return (this.record?.lines || []).reduce((sum, l) => sum + (l.ownUnitsPerWeek || 0), 0);
    }

    get competitorUnits() {
        return (this.record?.lines || []).reduce(
            (sum, l) => sum + (l.competitors || []).reduce((s, c) => s + (c.unitsPerWeek || 0), 0), 0);
    }

    get totalUnits() {
        return this.ownUnits + this.competitorUnits;
    }

    get ownSharePct() {
        return this.totalUnits === 0 ? 0 : Math.round((this.ownUnits / this.totalUnits) * 100);
    }

    get shareBarStyle() {
        return `width:${this.ownSharePct}%`;
    }

    get hasLines() {
        return this.record?.lines?.length > 0;
    }

    get hasObservations() {
        const r = this.record;
        return !!r && (r.pobUnits > 0 || !!r.competitorActivity || !!r.stockIssues || !!r.generalRemarks);
    }

    get hasPobUnits() {
        return this.record?.pobUnits > 0;
    }

    // Each molecule card's own share%, stock ratio, and brand rows (own
    // brand first, then competitors sorted by units descending) — mirrors
    // RCPADetailView.moleculeCard/brandRow (RCPAViews.swift:292-341).
    get lineRows() {
        return (this.record?.lines || []).map((line) => {
            const competitors = line.competitors || [];
            const competitorTotal = competitors.reduce((s, c) => s + (c.unitsPerWeek || 0), 0);
            const ownUnits = line.ownUnitsPerWeek || 0;
            const total = ownUnits + competitorTotal;
            const sharePct = total === 0 ? 0 : Math.round((ownUnits / total) * 100);
            const brandRows = [
                { key: 'own', name: line.ownBrand, units: ownUnits, isOwn: true,
                  dotClass: 'brand-dot brand-dot-own',
                  pct: total === 0 ? 0 : Math.round((ownUnits / total) * 100) },
                ...[...competitors].sort((a, b) => (b.unitsPerWeek || 0) - (a.unitsPerWeek || 0)).map((c) => ({
                    key: c.id,
                    name: c.company ? `${c.brand} (${c.company})` : c.brand,
                    units: c.unitsPerWeek || 0,
                    isOwn: false,
                    dotClass: 'brand-dot brand-dot-comp',
                    pct: total === 0 ? 0 : Math.round(((c.unitsPerWeek || 0) / total) * 100),
                })),
            ];
            return {
                ...line,
                trendStyle: pillStyle(TREND_COLOR[line.trend]),
                hasCompetitors: competitors.length > 0,
                sharePct,
                shareBarStyle: `width:${sharePct}%`,
                stockRatio: `${ownUnits}:${competitorTotal}`,
                brandRows,
                hasPrescriber: !!line.prescriberName,
                hasRemarks: !!line.remarks,
            };
        });
    }

    handleEdit() {
        this.isEditing = true;
        // Deep clone (not just [...record.lines]) — a shallow copy still
        // shares the same line/competitor objects, so editing a quantity
        // here would mutate `record` too and show as already-changed behind
        // the edit form even before Save. This is what used to be missing
        // entirely: the record-edit-form only ever touched RCPA_Audit__c's
        // own scalar fields (EDIT_FIELDS below), so every RCPA_Line__c value
        // — molecule, own units, trend, competitors — simply vanished the
        // moment a rep tapped Edit, both on screen and from what got saved.
        this.editLines = (this.record?.lines || []).map((line) => ({
            ...line,
            competitors: (line.competitors || []).map((c) => ({ ...c })),
        }));
        this.removedLineIds = [];
        this.removedCompetitorIds = [];
    }

    handleCancelEdit() {
        this.isEditing = false;
        this.editLines = [];
        this.removedLineIds = [];
        this.removedCompetitorIds = [];
    }

    findEditLine(lineId) {
        return this.editLines.find((l) => l.id === lineId);
    }

    // Wired to both `oninput` and `onchange` in the template, same reasoning
    // as rcpaAuditForm.js's handleOwnQtyChange/handleCompetitorQtyChange —
    // onchange alone only commits on blur, which a Save tapped right after
    // typing can beat.
    handleLineOwnQtyChange(event) {
        const line = this.findEditLine(event.currentTarget.dataset.lineId);
        if (!line) return;
        line.ownUnitsPerWeek = Math.max(0, Number(event.target.value) || 0);
        this.editLines = [...this.editLines];
    }

    handleLineTrendChange(event) {
        const line = this.findEditLine(event.currentTarget.dataset.lineId);
        if (!line) return;
        line.trend = event.detail.value;
        this.editLines = [...this.editLines];
    }

    handleLineRemarksChange(event) {
        const line = this.findEditLine(event.currentTarget.dataset.lineId);
        if (line) line.remarks = event.target.value;
    }

    handleLinePrescriberChange(event) {
        const line = this.findEditLine(event.currentTarget.dataset.lineId);
        if (line) line.prescriberId = event.detail.recordId;
    }

    handleCompetitorQtyChange(event) {
        const line = this.findEditLine(event.currentTarget.dataset.lineId);
        if (!line) return;
        const comp = line.competitors.find((c) => c.id === event.currentTarget.dataset.compId);
        if (!comp) return;
        comp.unitsPerWeek = Math.max(0, Number(event.target.value) || 0);
        this.editLines = [...this.editLines];
    }

    // Removing a line/competitor here means it already exists in Salesforce
    // (this is edit mode, not the create form — every row has a real id), so
    // it has to actually be deleted on Save, not just spliced out of a local
    // array the rep is about to walk away from.
    handleRemoveLine(event) {
        const lineId = event.currentTarget.dataset.lineId;
        this.removedLineIds = [...this.removedLineIds, lineId];
        this.editLines = this.editLines.filter((l) => l.id !== lineId);
    }

    handleRemoveCompetitor(event) {
        const lineId = event.currentTarget.dataset.lineId;
        const compId = event.currentTarget.dataset.compId;
        this.removedCompetitorIds = [...this.removedCompetitorIds, compId];
        const line = this.findEditLine(lineId);
        if (line) {
            line.competitors = line.competitors.filter((c) => c.id !== compId);
            this.editLines = [...this.editLines];
        }
    }

    get hasEditLines() {
        return this.editLines.length > 0;
    }

    // Fires after the record-edit-form above (RCPA_Audit__c's own scalar
    // fields) already saved successfully — this is what actually persists
    // the molecule lines, which that form never touched.
    async handleSaveSuccess() {
        this.isSavingLines = true;
        try {
            for (const id of this.removedCompetitorIds) {
                await deleteRecord(id);
            }
            for (const id of this.removedLineIds) {
                await deleteRecord(id);
            }
            for (const line of this.editLines) {
                await updateRecord({
                    fields: {
                        Id: line.id,
                        Own_Units_Per_Week__c: line.ownUnitsPerWeek || 0,
                        Trend__c: line.trend,
                        Remarks__c: line.remarks || null,
                        Prescriber__c: line.prescriberId || null,
                    },
                });
                for (const comp of line.competitors) {
                    await updateRecord({
                        fields: { Id: comp.id, Units_Per_Week__c: comp.unitsPerWeek || 0 },
                    });
                }
            }
            this.isEditing = false;
            this.dispatchEvent(new ShowToastEvent({ title: 'Saved', message: 'RCPA audit updated.', variant: 'success' }));
        } catch (e) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Audit saved, but a molecule line failed to update',
                message: e.body?.message || 'Reopen Edit and try again — some line changes may not have been saved.',
                variant: 'error',
            }));
            this.isEditing = false;
        } finally {
            this.isSavingLines = false;
            this.loadDetail();
        }
    }

    handleSaveError(event) {
        this.dispatchEvent(new ShowToastEvent({
            title: 'Couldn’t save RCPA audit',
            message: event.detail?.detail || event.detail?.message || 'Check the highlighted fields and try again.',
            variant: 'error',
        }));
    }
}

function reduceError(error) {
    if (error?.body?.message) {
        return error.body.message;
    }
    return 'An unknown error occurred.';
}