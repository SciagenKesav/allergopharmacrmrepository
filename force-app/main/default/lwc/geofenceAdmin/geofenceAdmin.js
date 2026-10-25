import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import LightningConfirm from 'lightning/confirm';
import getSettings from '@salesforce/apex/GeofenceAdminController.getSettings';
import saveSettings from '@salesforce/apex/GeofenceAdminController.saveSettings';
import searchHcos from '@salesforce/apex/GeofenceAdminController.searchHcos';
import saveHcoRadius from '@salesforce/apex/GeofenceAdminController.saveHcoRadius';
import getRules from '@salesforce/apex/GeofenceAdminController.getRules';
import saveRule from '@salesforce/apex/GeofenceAdminController.saveRule';
import deleteRule from '@salesforce/apex/GeofenceAdminController.deleteRule';
import getTerritories from '@salesforce/apex/GeofenceAdminController.getTerritories';
import previewForUser from '@salesforce/apex/GeofenceAdminController.previewForUser';

const MIN_RADIUS = 25;
const MAX_RADIUS = 5000;

export default class GeofenceAdmin extends LightningElement {
    @track enabled = true;
    @track enforce = true;
    @track defaultRadiusM = 200;
    @track dirty = false;
    @track saving = false;
    @track error = '';
    @track searchTerm = '';
    @track hcos = [];
    @track hcoTerritory = '';
    @track customOnly = false;
    @track missingOnly = false;
    @track rules = [];
    @track territories = [];
    @track scopeFilter = 'all';
    @track territoryFilter = '';
    @track statusFilter = 'all';
    @track ruleTerm = '';
    @track showEditor = false;
    @track editor = {};
    @track editorError = '';
    @track previewUserId = '';
    @track effective = null;
    _saved = {};

    activeUserFilter = { criteria: [{ fieldPath: 'IsActive', operator: 'eq', value: true }] };
    scopeChoices = [{ label: 'Territory', value: 'Territory' }, { label: 'User', value: 'User' }];
    scopeFilterOptions = [
        { label: 'All', value: 'all' }, { label: 'Territory rules', value: 'Territory' }, { label: 'User rules', value: 'User' }
    ];
    statusFilterOptions = [
        { label: 'All', value: 'all' }, { label: 'Active', value: 'active' }, { label: 'Inactive', value: 'inactive' }
    ];

    connectedCallback() {
        this.loadSettings();
        this.loadTerritories();
        this.loadRules();
        this.runSearch();
    }

    get territoryFilterOptions() {
        return [{ label: 'All territories', value: '' }, ...this.territories.map(t => ({ label: t.name, value: t.id }))];
    }
    get territoryChoices() {
        return this.territories.map(t => ({ label: t.name, value: t.id }));
    }

    get enforceDisabled() { return !this.enabled; }
    get radiusDisabled() { return !this.enabled; }
    get radiusValid() {
        const r = Number(this.defaultRadiusM);
        return Number.isFinite(r) && r >= MIN_RADIUS && r <= MAX_RADIUS;
    }
    get saveDisabled() { return this.saving || !this.dirty || !this.radiusValid; }
    get hasHcos() { return this.hcos.length > 0; }
    get noHcos() { return this.hcos.length === 0; }

    async loadSettings() {
        try {
            const s = await getSettings();
            this.applySaved(s);
        } catch (e) {
            this.error = this.message(e);
        }
    }

    applySaved(s) {
        this.enabled = s.enabled;
        this.enforce = s.enforce;
        this.defaultRadiusM = s.defaultRadiusM;
        this._saved = { enabled: s.enabled, enforce: s.enforce, radius: s.defaultRadiusM };
        this.dirty = false;
    }

    markDirty() {
        this.dirty = this.enabled !== this._saved.enabled
            || this.enforce !== this._saved.enforce
            || Number(this.defaultRadiusM) !== Number(this._saved.radius);
    }

    handleEnabled(e) { this.enabled = e.target.checked; this.markDirty(); }
    handleEnforce(e) { this.enforce = e.target.checked; this.markDirty(); }
    handleRadius(e) { this.defaultRadiusM = e.target.value; this.markDirty(); }

    async handleSave() {
        this.saving = true;
        this.error = '';
        try {
            const s = await saveSettings({
                enabled: this.enabled,
                enforce: this.enforce,
                defaultRadiusM: Number(this.defaultRadiusM)
            });
            this.applySaved(s);
            this.toast('Saved', 'Geofence settings updated. iPads pick this up on their next sync.', 'success');
        } catch (e) {
            this.error = this.message(e);
        } finally {
            this.saving = false;
        }
    }

    handleHcoTerritory(e) { this.hcoTerritory = e.detail.value; this.runSearch(); }
    handleCustomOnly(e) { this.customOnly = e.target.checked; this.runSearch(); }
    handleMissingOnly(e) { this.missingOnly = e.target.checked; this.runSearch(); }

    handleSearchInput(e) { this.searchTerm = e.target.value; }
    handleSearchKey(e) { if (e.key === 'Enter') this.runSearch(); }

    async runSearch() {
        this.error = '';
        try {
            const rows = await searchHcos({
                term: this.searchTerm,
                territoryId: this.hcoTerritory || null,
                customOnly: this.customOnly,
                missingLocationOnly: this.missingOnly
            });
            this.hcos = rows.map(h => this.decorate(h, h.radiusOverrideM));
        } catch (e) {
            this.error = this.message(e);
        }
    }

    decorate(h, savedRadius) {
        const text = h.radiusText !== undefined ? h.radiusText : (savedRadius == null ? '' : String(savedRadius));
        const saved = savedRadius == null ? '' : String(savedRadius);
        return { ...h, savedRadius, radiusText: text, saveDisabled: text === saved };
    }

    handleHcoRadius(e) {
        const id = e.target.dataset.id;
        const value = e.target.value;
        this.hcos = this.hcos.map(h => {
            if (h.id !== id) return h;
            const saved = h.savedRadius == null ? '' : String(h.savedRadius);
            return { ...h, radiusText: value, saveDisabled: value === saved };
        });
    }

    async saveHco(e) {
        const id = e.target.dataset.id;
        const row = this.hcos.find(h => h.id === id);
        if (!row) return;
        const text = String(row.radiusText || '').trim();
        const radius = text === '' ? null : Number(text);
        if (radius !== null && (!Number.isFinite(radius) || radius < MIN_RADIUS || radius > MAX_RADIUS)) {
            this.error = `Radius must be between ${MIN_RADIUS} and ${MAX_RADIUS} metres.`;
            return;
        }
        this.error = '';
        try {
            await saveHcoRadius({ hcoId: id, radiusM: radius });
            this.hcos = this.hcos.map(h => (h.id === id ? this.decorate({ ...h, radiusText: undefined }, radius) : h));
            this.toast('Saved', `${row.name}: ${radius === null ? 'uses the default radius' : radius + ' m'}.`, 'success');
        } catch (err) {
            this.error = this.message(err);
        }
    }


    async loadTerritories() {
        try {
            this.territories = await getTerritories();
        } catch (e) {
            this.error = this.message(e);
        }
    }

    async loadRules() {
        try {
            this.rules = await getRules();
        } catch (e) {
            this.error = this.message(e);
        }
    }

    handleScopeFilter(e) { this.scopeFilter = e.detail.value; }
    handleTerritoryFilter(e) { this.territoryFilter = e.detail.value; }
    handleStatusFilter(e) { this.statusFilter = e.detail.value; }
    handleRuleTerm(e) { this.ruleTerm = e.target.value; }

    get visibleRules() {
        const term = (this.ruleTerm || '').trim().toLowerCase();
        return this.rules
            .filter(r => this.scopeFilter === 'all' || r.scope === this.scopeFilter)
            .filter(r => !this.territoryFilter
                || (r.scope === 'Territory' ? r.territoryId === this.territoryFilter
                    : (r.memberTerritoryIds || []).includes(this.territoryFilter)))
            .filter(r => this.statusFilter === 'all' || (this.statusFilter === 'active') === r.active)
            .filter(r => !term || [this.targetName(r), r.note, r.memberTerritoryNames]
                .some(v => (v || '').toLowerCase().includes(term)))
            .map(r => this.decorateRule(r));
    }
    get hasVisibleRules() { return this.visibleRules.length > 0; }
    get ruleCountText() { return `Showing ${this.visibleRules.length} of ${this.rules.length} rules`; }
    get emptyRulesText() {
        return this.rules.length === 0
            ? 'No Territory or User rules yet. Every rep gets the organization default. Use New rule to add one.'
            : 'No rules match these filters.';
    }

    targetName(r) { return (r.scope === 'Territory' ? r.territoryName : r.userName) || '(deleted)'; }

    decorateRule(r) {
        return {
            id: r.id,
            appliesTo: this.targetName(r),
            scopeLabel: r.scope === 'Territory' ? 'Territory' : 'User',
            detail: r.scope === 'User' ? r.memberTerritoryNames : '',
            note: r.note,
            onText: r.enabled ? 'On' : 'Off',
            modeText: !r.enabled ? '-' : (r.enforce ? 'Block' : 'Record only'),
            radiusText: !r.enabled ? '-' : (r.radiusM ? `${r.radiusM} m` : `Default (${this.defaultRadiusM} m)`),
            statusText: r.active ? 'Active' : 'Inactive',
            statusClass: r.active ? 'st-active' : 'st-inactive'
        };
    }

    openNewRule() {
        this.editorError = '';
        this.editor = {
            isNew: true, id: null, scope: 'Territory', territoryId: '', userId: '', targetName: '',
            active: true, enabled: this.enabled, enforce: this.enforce, radius: '', note: ''
        };
        this.showEditor = true;
    }

    openEditRule(e) {
        const r = this.rules.find(x => x.id === e.target.dataset.id);
        if (!r) return;
        this.editorError = '';
        this.editor = {
            isNew: false, id: r.id, scope: r.scope, territoryId: r.territoryId, userId: r.userId,
            targetName: this.targetName(r), active: r.active, enabled: r.enabled, enforce: r.enforce,
            radius: r.radiusM == null ? '' : String(r.radiusM), note: r.note || ''
        };
        this.showEditor = true;
    }

    closeEditor() { this.showEditor = false; this.editorError = ''; }

    get editorTitle() { return this.editor.isNew ? 'New geofence rule' : 'Edit geofence rule'; }
    get editorIsTerritory() { return this.editor.scope === 'Territory'; }
    get editorOff() { return !this.editor.enabled; }
    get editorRadiusValid() {
        const t = String(this.editor.radius ?? '').trim();
        if (t === '') return true;
        const n = Number(t);
        return Number.isFinite(n) && n >= MIN_RADIUS && n <= MAX_RADIUS;
    }
    get editorHasTarget() {
        return !this.editor.isNew || (this.editorIsTerritory ? !!this.editor.territoryId : !!this.editor.userId);
    }
    get editorSaveDisabled() { return this.saving || !this.editorRadiusValid || !this.editorHasTarget; }

    handleEditorScope(e) { this.editor = { ...this.editor, scope: e.detail.value, territoryId: '', userId: '' }; }
    handleEditorTerritory(e) { this.editor = { ...this.editor, territoryId: e.detail.value }; }
    handleEditorUser(e) { this.editor = { ...this.editor, userId: e.detail.recordId || '' }; }
    handleEditorActive(e) { this.editor = { ...this.editor, active: e.target.checked }; }
    handleEditorEnabled(e) { this.editor = { ...this.editor, enabled: e.target.checked }; }
    handleEditorEnforce(e) { this.editor = { ...this.editor, enforce: e.target.checked }; }
    handleEditorRadius(e) { this.editor = { ...this.editor, radius: e.target.value }; }
    handleEditorNote(e) { this.editor = { ...this.editor, note: e.target.value }; }

    async saveEditor() {
        const ed = this.editor;
        const text = String(ed.radius ?? '').trim();
        this.saving = true;
        this.editorError = '';
        try {
            await saveRule({
                ruleId: ed.id,
                scope: ed.scope,
                territoryId: ed.scope === 'Territory' ? (ed.territoryId || null) : null,
                userId: ed.scope === 'User' ? (ed.userId || null) : null,
                active: ed.active,
                enabled: ed.enabled,
                enforce: ed.enabled && ed.enforce,
                radiusM: text === '' ? null : Number(text),
                note: ed.note
            });
            this.showEditor = false;
            await this.loadRules();
            this.toast('Saved', 'Rule saved. iPads pick this up on their next sync.', 'success');
        } catch (err) {
            this.editorError = this.message(err);
        } finally {
            this.saving = false;
        }
    }

    async handleDeleteRule(e) {
        const r = this.rules.find(x => x.id === e.target.dataset.id);
        if (!r) return;
        const ok = await LightningConfirm.open({
            message: `Delete the rule for ${this.targetName(r)}? Those reps go back to the next level down. To keep the rule but stop using it, edit it and set it inactive instead.`,
            label: 'Delete rule',
            theme: 'warning'
        });
        if (!ok) return;
        this.error = '';
        try {
            await deleteRule({ ruleId: r.id });
            await this.loadRules();
            this.toast('Deleted', 'Rule deleted.', 'success');
        } catch (err) {
            this.error = this.message(err);
        }
    }

    handlePreviewUser(e) { this.previewUserId = e.detail.recordId || ''; this.effective = null; }
    get previewDisabled() { return !this.previewUserId; }

    async runPreview() {
        this.error = '';
        try {
            this.effective = await previewForUser({ userId: this.previewUserId });
        } catch (err) {
            this.error = this.message(err);
        }
    }

    get effectiveText() {
        const x = this.effective;
        if (!x) return '';
        if (!x.enabled) return 'Geofencing is off. No check, no arrival prompt, nothing blocked.';
        return `Geofencing on, ${x.enforce ? 'blocks check-in' : 'records only'}, ${x.radiusM} m radius.`;
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    message(e) {
        return (e && e.body && e.body.message) || (e && e.message) || 'Something went wrong.';
    }
}