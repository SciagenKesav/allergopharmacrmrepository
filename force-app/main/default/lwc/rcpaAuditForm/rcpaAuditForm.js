import { LightningElement, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { createRecord } from 'lightning/uiRecordApi';
import getMoleculeCatalog from '@salesforce/apex/RCPAMatrixController.getMoleculeCatalog';
import getSKUCatalog from '@salesforce/apex/RCPAController.getSKUCatalog';
import getPriorLineForPrescriber from '@salesforce/apex/RCPAController.getPriorLineForPrescriber';

/// Full capture form for a new RCPA_Audit__c — a web port of the iPad app's
/// RCPACaptureView (RCPAViews.swift). Deliberately imperative (createRecord
/// from lightning/uiRecordApi) rather than lightning-record-edit-form: the
/// audit's children (RCPA_Line__c, each with its own RCPA_Competitor__c rows,
/// and POB_Line__c) are a dynamic, user-built list that doesn't exist until
/// Save, which record-edit-form has no good story for. Same approach
/// SciagenCVRController.cls's header comment calls out as the alternative to
/// per-field edit-forms for this kind of nested/dynamic child data.
///
/// Molecule + competitor catalog: molecule/ownBrand come live from
/// RCPAMatrixController.getMoleculeCatalog() (Product__c, admin-editable —
/// same source rcpaUnitValue(forMolecule:) uses on iOS) — no hardcoded
/// fallback data; an org with no Level__c='Molecule' Product__c records
/// simply has nothing to add here until one is created. The named competitor
/// brands per molecule have no live Salesforce catalog counterpart, so
/// COMPETITORS_BY_MOLECULE below is real, hand-maintained competitor
/// intelligence for this org's own molecules — not placeholder data — keyed
/// by the live Product__c.Name of each Level__c='Molecule' record (this
/// org's seeded Molecule-level records have no separate child Brand-level
/// product under them, so `catalogEntry.molecule` is always the brand-style
/// name in practice). A molecule with no entry here just gets the "Others"
/// catch-all instead of named competitors.
const COMPETITORS_BY_MOLECULE = {
    // This org's one live Level__c='Molecule' Product__c record is named
    // "ACAROID-AB" (Brand_Name__c "ACAROID") — the plain "ACAROID"/
    // "ACAROID DF"/"ACAROID DP" records are Level__c='SKU', not the
    // molecule itself. Key has to match that Name exactly (see this
    // constant's own doc comment above).
    'ACAROID-AB': [
        { brand: 'SENSIMUNE 12 SQ SLIT Tables', company: '' },
        { brand: 'ALLCURE HDM SCIT', company: '' },
        { brand: 'ALLCURE HDM SLIT', company: '' },
        { brand: 'ALLVAC HDM SLIT', company: '' },
        { brand: 'ALLVAC HDM SCIT', company: '' },
        { brand: 'CREDISOL HDM SCIT', company: '' },
        { brand: 'CREDISOL HDM SLIT', company: '' },
        { brand: 'EVEXIA HDM SLIT', company: '' },
    ],
};

const TREND_OPTIONS = ['New Rx', 'Growing', 'Stable', 'Declining', 'Switched to competitor'].map((t) => ({
    label: t,
    value: t,
}));

export default class RcpaAuditForm extends LightningElement {
    chemistFilter = { criteria: [{ fieldPath: 'Type__c', operator: 'eq', value: 'HCO' }] };
    prescriberFilter = { criteria: [{ fieldPath: 'Type__c', operator: 'eq', value: 'HCP' }] };
    trendOptions = TREND_OPTIONS;

    // Header
    name = '';
    chemistId;
    territoryId;
    rep = '';
    auditDate = new Date().toISOString().slice(0, 10);

    // Capture grid
    moleculeCatalog = [];
    lines = [];

    // POB
    skuCatalog = [];
    pobLines = [];
    pobSelectedSku;
    pobQty = 1;

    // Chemist confirmation
    chemistSignerName = '';
    chemistOtpVerified = false;
    otpCode = '';
    otpEntry = '';
    signatureDataUrl;

    // Observations
    competitorActivity = '';
    stockIssues = '';
    generalRemarks = '';

    isSaving = false;
    error;

    @wire(getMoleculeCatalog)
    wiredMolecules({ data }) {
        if (data) {
            this.moleculeCatalog = data.map((m) => ({
                molecule: m.molecule,
                ownBrand: m.ownBrand,
                menuLabel: `${m.molecule}  ·  ${m.ownBrand || ''}`,
            }));
        }
    }

    @wire(getSKUCatalog)
    wiredSKUs({ data }) {
        if (data) {
            this.skuCatalog = data;
        }
    }

    get skuOptions() {
        return this.skuCatalog.map((s) => ({ label: s.name, value: s.id }));
    }

    get addableMolecules() {
        const added = new Set(this.lines.map((l) => l.molecule));
        return this.moleculeCatalog.filter((m) => !added.has(m.molecule));
    }

    get hasNoAddableMolecules() {
        return this.addableMolecules.length === 0;
    }

    get addMoleculeLabel() {
        return 'Add molecule to audit';
    }

    get hasNoLines() {
        return this.lines.length === 0;
    }

    get lineRows() {
        return this.lines.map((line) => {
            const own = line.ownUnitsPerWeek || 0;
            const compTotal = line.competitors.reduce((s, c) => s + (c.unitsPerWeek || 0), 0);
            const total = own + compTotal;
            return { ...line, sharePct: total === 0 ? 0 : Math.round((own / total) * 100) };
        });
    }

    get ownUnits() {
        return this.lines.reduce((s, l) => s + (l.ownUnitsPerWeek || 0), 0);
    }

    get competitorUnits() {
        return this.lines.reduce((s, l) => s + l.competitors.reduce((cs, c) => cs + (c.unitsPerWeek || 0), 0), 0);
    }

    get ownSharePct() {
        const total = this.ownUnits + this.competitorUnits;
        return total === 0 ? 0 : Math.round((this.ownUnits / total) * 100);
    }

    get shareBarStyle() {
        return `width:${this.ownSharePct}%`;
    }

    get pobTotal() {
        return this.pobLines.reduce((s, p) => s + (p.qty || 0), 0);
    }

    get pobAddDisabled() {
        return !this.pobSelectedSku;
    }

    get otpButtonLabel() {
        return this.otpCode ? 'Resend OTP' : 'Send OTP to Chemist';
    }

    get chemistSignerNameOrDefault() {
        return this.chemistSignerName || 'chemist';
    }

    get otpVerifyDisabled() {
        return !this.otpEntry || this.otpEntry.length < 6;
    }

    get hasChemist() {
        return !!this.chemistId;
    }

    get saveDraftDisabled() {
        return !this.hasChemist || this.isSaving;
    }

    get submitDisabled() {
        return !this.hasChemist || this.lines.length === 0 || this.isSaving;
    }

    // MARK: Header

    handleNameChange(event) {
        this.name = event.target.value;
    }

    handleChemistChange(event) {
        this.chemistId = event.detail.recordId;
    }

    handleTerritoryChange(event) {
        this.territoryId = event.detail.recordId;
    }

    handleRepChange(event) {
        this.rep = event.target.value;
    }

    handleAuditDateChange(event) {
        this.auditDate = event.target.value;
    }

    // MARK: Capture grid

    handleAddMolecule(event) {
        const molecule = event.detail.value;
        const catalogEntry = this.moleculeCatalog.find((m) => m.molecule === molecule);
        if (!catalogEntry) return;
        // COMPETITORS_BY_MOLECULE is keyed by `molecule` directly (see its own
        // doc comment) — the ownBrand fallback here is extra tolerance in case
        // an org's catalog ever does separate the molecule from its own brand
        // (a child Brand-level product with a different name), which this
        // org's current data doesn't.
        const namedCompetitors = COMPETITORS_BY_MOLECULE[molecule] || COMPETITORS_BY_MOLECULE[catalogEntry.ownBrand] || [];
        this.lines = [
            ...this.lines,
            {
                key: molecule,
                molecule,
                ownBrand: catalogEntry.ownBrand,
                ownUnitsPerWeek: 0,
                trend: 'Stable',
                remarks: '',
                prescriberId: null,
                competitors: [...namedCompetitors, { brand: 'Others', company: '' }].map((c) => ({
                    key: c.brand,
                    brand: c.brand,
                    company: c.company,
                    unitsPerWeek: 0,
                })),
            },
        ];
    }

    handleRemoveLine(event) {
        const key = event.currentTarget.dataset.key;
        this.lines = this.lines.filter((l) => l.key !== key);
    }

    findLine(key) {
        return this.lines.find((l) => l.key === key);
    }

    // Wired to both `oninput` (fires on every keystroke) and `onchange`
    // (fires on blur/commit) in the template — `onchange` alone left a real
    // gap: a rep who types a quantity and taps Save Draft/Submit Audit
    // without first tapping away lets the click reach `save()` before the
    // field's change event (and this handler) has run, so `this.lines` still
    // held the pre-edit value and the just-typed quantity silently never
    // made it into RCPA_Line__c/RCPA_Competitor__c. Both handlers are cheap
    // and idempotent, so firing twice for the same edit is harmless.
    handleOwnQtyChange(event) {
        const line = this.findLine(event.currentTarget.dataset.key);
        if (!line) return;
        line.ownUnitsPerWeek = Math.max(0, Number(event.target.value) || 0);
        this.lines = [...this.lines];
    }

    handleCompetitorQtyChange(event) {
        const line = this.findLine(event.currentTarget.dataset.lineKey);
        if (!line) return;
        const comp = line.competitors.find((c) => c.key === event.currentTarget.dataset.compKey);
        if (!comp) return;
        comp.unitsPerWeek = Math.max(0, Number(event.target.value) || 0);
        this.lines = [...this.lines];
    }

    async handlePrescriberChange(event) {
        const line = this.findLine(event.currentTarget.dataset.key);
        if (!line) return;
        line.prescriberId = event.detail.recordId;
        this.lines = [...this.lines];
        if (line.prescriberId) {
            await this.applyPriorLineIfAny(line);
        }
    }

    // If this HCP already has a recorded line for the same molecule from an
    // earlier audit, pulls its own/competitor units, trend, and remarks into
    // this (still-unsaved) line so the rep edits forward from last time
    // instead of starting blank. Matches competitors by brand name — any
    // named competitor not present on the prior line (or a first-time
    // molecule for this HCP) is simply left as-is.
    async applyPriorLineIfAny(line) {
        let prior;
        try {
            prior = await getPriorLineForPrescriber({ prescriberId: line.prescriberId, molecule: line.molecule });
        } catch (e) {
            return;
        }
        if (!prior) return;

        line.ownUnitsPerWeek = prior.ownUnitsPerWeek || 0;
        line.trend = prior.trend || line.trend;
        line.remarks = prior.remarks || '';
        const priorUnitsByBrand = new Map((prior.competitors || []).map((c) => [c.brand, c.unitsPerWeek || 0]));
        line.competitors = line.competitors.map((c) => ({
            ...c,
            unitsPerWeek: priorUnitsByBrand.has(c.brand) ? priorUnitsByBrand.get(c.brand) : c.unitsPerWeek,
        }));
        this.lines = [...this.lines];

        this.dispatchEvent(new ShowToastEvent({
            title: 'Previous values loaded',
            message: `Filled in ${line.molecule}’s last recorded values for this prescriber — review and update as needed.`,
            variant: 'info',
        }));
    }

    handleTrendChange(event) {
        const line = this.findLine(event.currentTarget.dataset.key);
        if (!line) return;
        line.trend = event.detail.value;
        this.lines = [...this.lines];
    }

    handleLineRemarksChange(event) {
        const line = this.findLine(event.currentTarget.dataset.key);
        if (!line) return;
        line.remarks = event.target.value;
        this.lines = [...this.lines];
    }

    // MARK: POB

    handlePobSkuChange(event) {
        this.pobSelectedSku = event.detail.value;
    }

    handlePobQtyChange(event) {
        this.pobQty = Math.max(1, Number(event.target.value) || 1);
    }

    handleAddPobLine() {
        const sku = this.skuCatalog.find((s) => s.id === this.pobSelectedSku);
        if (!sku) return;
        this.pobLines = [...this.pobLines, { key: `${sku.id}-${this.pobLines.length}`, productId: sku.id, name: sku.name, qty: this.pobQty }];
        this.pobQty = 1;
    }

    handleRemovePOBLine(event) {
        const key = event.currentTarget.dataset.key;
        this.pobLines = this.pobLines.filter((p) => p.key !== key);
    }

    // MARK: Chemist confirmation

    handleSignerNameChange(event) {
        this.chemistSignerName = event.target.value;
    }

    handleSendOtp() {
        this.otpCode = String(Math.floor(100000 + Math.random() * 900000));
        this.otpEntry = '';
    }

    handleOtpEntryChange(event) {
        this.otpEntry = event.target.value;
    }

    handleVerifyOtp() {
        if (this.otpEntry === this.otpCode) {
            this.chemistOtpVerified = true;
        }
    }

    handleSignatureChange(event) {
        this.signatureDataUrl = event.detail.dataUrl;
    }

    // MARK: Observations

    handleCompetitorActivityChange(event) {
        this.competitorActivity = event.target.value;
    }

    handleStockIssuesChange(event) {
        this.stockIssues = event.target.value;
    }

    handleGeneralRemarksChange(event) {
        this.generalRemarks = event.target.value;
    }

    // MARK: Save

    async handleSaveDraft() {
        await this.save('Draft');
    }

    async handleSubmitAudit() {
        await this.save('Submitted');
    }

    async save(status) {
        if (!this.hasChemist || this.isSaving) return;
        this.isSaving = true;
        this.error = undefined;
        try {
            const audit = await createRecord({
                apiName: 'RCPA_Audit__c',
                fields: {
                    Name: this.name || `RCPA Audit ${this.auditDate}`,
                    Chemist__c: this.chemistId,
                    Audit_Date__c: this.auditDate,
                    Territory__c: this.territoryId || null,
                    Rep__c: this.rep || null,
                    Status__c: status,
                    POB_Units__c: this.pobTotal,
                    Chemist_Signer_Name__c: this.chemistSignerName || null,
                    Chemist_OTP_Verified__c: this.chemistOtpVerified,
                    Chemist_Signature__c: this.signatureDataUrl || null,
                    Competitor_Activity__c: this.competitorActivity || null,
                    Stock_Issues__c: this.stockIssues || null,
                    General_Remarks__c: this.generalRemarks || null,
                },
            });

            for (const pob of this.pobLines) {
                await createRecord({
                    apiName: 'POB_Line__c',
                    fields: {
                        Audit__c: audit.id,
                        SKU__c: pob.productId,
                        Qty__c: pob.qty,
                    },
                });
            }

            for (const line of this.lines) {
                const createdLine = await createRecord({
                    apiName: 'RCPA_Line__c',
                    fields: {
                        Audit__c: audit.id,
                        Molecule__c: line.molecule,
                        Own_Brand__c: line.ownBrand,
                        Own_Units_Per_Week__c: line.ownUnitsPerWeek || 0,
                        Trend__c: line.trend,
                        Remarks__c: line.remarks || null,
                        Prescriber__c: line.prescriberId || null,
                    },
                });
                for (const comp of line.competitors) {
                    await createRecord({
                        apiName: 'RCPA_Competitor__c',
                        fields: {
                            Line__c: createdLine.id,
                            Brand__c: comp.brand,
                            Company__c: comp.company || null,
                            Units_Per_Week__c: comp.unitsPerWeek || 0,
                        },
                    });
                }
            }

            this.isSaving = false;
            this.dispatchEvent(new ShowToastEvent({
                title: status === 'Submitted' ? 'Submitted' : 'Saved',
                message: `RCPA audit ${status === 'Submitted' ? 'submitted' : 'saved as draft'}.`,
                variant: 'success',
            }));
            this.dispatchEvent(new CustomEvent('created', { detail: { id: audit.id } }));
        } catch (e) {
            this.isSaving = false;
            this.error = this.friendlyError(e);
        }
    }

    /// A record referenced by this audit (most commonly the Chemist/Pharmacy
    /// itself) can be outside the rep's own assigned territory — accounts are
    /// privately shared per-territory, so Salesforce rejects the create with
    /// a generic "insufficient access" error on that cross-reference rather
    /// than a field-specific one. Surface that plainly instead of the raw
    /// platform wording, which reads as an unexplained failure.
    friendlyError(e) {
        const platformErrors = e.body?.output?.errors || (e.body?.message ? [e.body] : []);
        const accessDenied = platformErrors.some((err) => err.statusCode === 'INSUFFICIENT_ACCESS_ON_CROSS_REFERENCE_ENTITY');
        if (accessDenied) {
            return 'You don’t have access to save this — the selected Chemist/Pharmacy doesn’t belong to your assigned territory. Please choose one from your own territory, or contact your admin if this looks wrong.';
        }
        return e.body?.message || e.body?.pageErrors?.[0]?.message || 'Check the highlighted fields and try again.';
    }

    handleClose() {
        this.dispatchEvent(new CustomEvent('close'));
    }

    stopPropagation(event) {
        event.stopPropagation();
    }
}