import { LightningElement, wire } from 'lwc';
import searchAudits from '@salesforce/apex/RCPAController.searchAudits';
import getTerritoryOptions from '@salesforce/apex/RCPAController.getTerritoryOptions';
import { pillStyle, callStatusColor } from 'c/sciagenColors';

const SEARCH_DEBOUNCE_MS = 300;

const STATUS_OPTIONS = [
    { label: 'All Statuses', value: '' },
    { label: 'Draft', value: 'Draft' },
    { label: 'Submitted', value: 'Submitted' },
];

// Mirrors RCPAHomeView.RCPAMode (RCPAMatrixViews.swift) — a single screen with
// a segmented mode switch, not three separate tabs/pages.
const MODES = [
    { value: 'audits', label: 'Audits' },
    { value: 'doctorMatrix', label: 'Doctor Matrix' },
    { value: 'masterMatrix', label: 'Master Matrix' },
];

export default class RcpaBrowser extends LightningElement {
    mode = 'audits';
    modes = MODES;

    searchTerm = '';
    statusFilter = '';
    territoryFilter = '';
    results = [];
    selectedId;
    selectedPrescriberId;
    isSearching = false;
    error;
    debounceTimer;
    showCreateForm = false;

    statusOptions = STATUS_OPTIONS;
    territoryOptions = [{ label: 'All Territories', value: '' }];

    @wire(getTerritoryOptions)
    wiredTerritories({ data }) {
        if (data) {
            this.territoryOptions = [{ label: 'All Territories', value: '' }, ...data.map((t) => ({ label: t, value: t }))];
        }
    }

    connectedCallback() {
        this.runSearch();
    }

    get modeButtons() {
        return this.modes.map((m) => ({
            ...m,
            buttonClass: m.value === this.mode ? 'mode-button mode-button-active' : 'mode-button',
        }));
    }

    handleModeChange(event) {
        this.mode = event.currentTarget.dataset.mode;
    }

    get isAuditsMode() {
        return this.mode === 'audits';
    }

    get isDoctorMatrixMode() {
        return this.mode === 'doctorMatrix';
    }

    get isMasterMatrixMode() {
        return this.mode === 'masterMatrix';
    }

    handleSearchChange(event) {
        this.searchTerm = event.target.value;
        this.debounceSearch();
    }

    handleStatusFilterChange(event) {
        this.statusFilter = event.detail.value;
        this.runSearch();
    }

    handleTerritoryFilterChange(event) {
        this.territoryFilter = event.detail.value;
        this.runSearch();
    }

    debounceSearch() {
        window.clearTimeout(this.debounceTimer);
        this.debounceTimer = window.setTimeout(() => this.runSearch(), SEARCH_DEBOUNCE_MS);
    }

    async runSearch() {
        this.isSearching = true;
        this.error = undefined;
        try {
            this.results = await searchAudits({
                searchTerm: this.searchTerm,
                statusFilter: this.statusFilter,
                territoryFilter: this.territoryFilter,
            });
        } catch (e) {
            this.error = reduceError(e);
            this.results = [];
        } finally {
            this.isSearching = false;
        }
    }

    handleSelect(event) {
        this.selectedId = event.currentTarget.dataset.id;
        this.selectedPrescriberId = undefined; // cleared until rcpa-detail loads this audit's own lines
    }

    // rcpa-detail dispatches this once it has loaded the selected audit's
    // full detail (including line items) — lets Doctor Matrix default to a
    // prescriber this audit actually covers instead of an unrelated one.
    handleAuditDetailLoaded(event) {
        this.selectedPrescriberId = event.detail.prescriberId;
    }

    handleNewAudit() {
        this.showCreateForm = true;
    }

    handleCloseCreate() {
        this.showCreateForm = false;
    }

    handleAuditCreated(event) {
        this.showCreateForm = false;
        this.mode = 'audits';
        this.selectedId = event.detail.id;
        this.runSearch();
    }

    get hasResults() {
        return this.results && this.results.length > 0;
    }

    get hasSelection() {
        return !!this.selectedId;
    }

    get rows() {
        return (this.results || []).map((r) => ({
            ...r,
            rowClass: r.id === this.selectedId ? 'result-row selected' : 'result-row',
            statusStyle: pillStyle(callStatusColor(r.status)),
        }));
    }
}

function reduceError(error) {
    if (error?.body?.message) {
        return error.body.message;
    }
    return 'An unknown error occurred.';
}