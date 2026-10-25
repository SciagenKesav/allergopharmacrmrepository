import { LightningElement, api } from 'lwc';

const SEARCH_DEBOUNCE_MS = 300;

/// Shared search + filter bar for My Schedule's Agenda/Week/Map modes — ports
/// CalendarPlannerView.swift's scheduleFilterBar + matchesFilter dimensions
/// (Kind, Specialty, Territory, Status, Custom List, Saved View) to Salesforce.
/// Stateless: the parent (mySchedule) owns filter values and passes them down
/// via @api, this component only renders controls and emits `filterchange`.
export default class ScheduleFilterBar extends LightningElement {
    @api searchTerm = '';
    @api kind = 'All';
    @api specialty = '';
    @api territory = '';
    @api status = '';
    @api customListId = '';
    @api callCategory = '';
    @api categoryOptions = [];
    @api specialtyOptions = [];
    @api territoryOptions = [];
    @api customListOptions = [];
    @api savedViewOptions = [];

    showFilters = false;
    searchTimeout;

    get kindButtons() {
        return ['All', 'HCP', 'HCO'].map((k) => ({ key: k, label: k, variant: k === this.kind ? 'brand' : 'neutral' }));
    }

    get statusOptions() {
        return ['Planned', 'Draft', 'Completed', 'Cancelled'];
    }

    get categoryComboOptions() {
        return [{ label: 'All Call Types', value: '' }, ...this.categoryOptions.map((c) => ({ label: c, value: c }))];
    }

    get specialtyComboOptions() {
        return [{ label: 'All Specialties', value: '' }, ...this.specialtyOptions.map((s) => ({ label: s, value: s }))];
    }

    get territoryComboOptions() {
        return [{ label: 'All Territories', value: '' }, ...this.territoryOptions.map((t) => ({ label: t, value: t }))];
    }

    get statusComboOptions() {
        return [{ label: 'All Statuses', value: '' }, ...this.statusOptions.map((s) => ({ label: s, value: s }))];
    }

    get customListComboOptions() {
        return [{ label: 'All Accounts', value: '' }, ...this.customListOptions.map((l) => ({ label: l.listName, value: l.id }))];
    }

    get savedViewComboOptions() {
        return [{ label: 'Apply a Saved View…', value: '' }, ...this.savedViewOptions.map((v) => ({ label: v.viewName, value: v.id }))];
    }

    get activeFilterCount() {
        return (this.kind !== 'All' ? 1 : 0)
            + (this.specialty ? 1 : 0) + (this.territory ? 1 : 0) + (this.status ? 1 : 0) + (this.customListId ? 1 : 0) + (this.callCategory ? 1 : 0);
    }

    get filtersButtonLabel() {
        return this.activeFilterCount > 0 ? `Filters (${this.activeFilterCount})` : 'Filters';
    }

    get filtersButtonVariant() {
        return this.activeFilterCount > 0 ? 'brand' : 'neutral';
    }

    get hasActiveFilters() {
        return this.activeFilterCount > 0;
    }

    handleToggleFilters() {
        this.showFilters = !this.showFilters;
    }

    handleSearchInput(event) {
        const value = event.target.value;
        window.clearTimeout(this.searchTimeout);
        this.searchTimeout = window.setTimeout(() => {
            this.dispatchEvent(new CustomEvent('filterchange', { detail: { field: 'searchTerm', value } }));
        }, SEARCH_DEBOUNCE_MS);
    }

    handleKindChange(event) {
        this.dispatchEvent(new CustomEvent('filterchange', { detail: { field: 'kind', value: event.currentTarget.dataset.value } }));
    }

    handleSpecialtyChange(event) {
        this.dispatchEvent(new CustomEvent('filterchange', { detail: { field: 'specialty', value: event.detail.value } }));
    }

    handleTerritoryChange(event) {
        this.dispatchEvent(new CustomEvent('filterchange', { detail: { field: 'territory', value: event.detail.value } }));
    }

    handleStatusChange(event) {
        this.dispatchEvent(new CustomEvent('filterchange', { detail: { field: 'status', value: event.detail.value } }));
    }

    handleCategoryChange(event) {
        this.dispatchEvent(new CustomEvent('filterchange', { detail: { field: 'callCategory', value: event.detail.value } }));
    }

    handleCustomListChange(event) {
        this.dispatchEvent(new CustomEvent('filterchange', { detail: { field: 'customListId', value: event.detail.value } }));
    }

    handleSavedViewChange(event) {
        const viewId = event.detail.value;
        if (!viewId) { return; }
        const view = this.savedViewOptions.find((v) => v.id === viewId);
        if (!view) { return; }
        let criteria = {};
        try {
            criteria = view.filterJson ? JSON.parse(view.filterJson) : {};
        } catch (e) {
            criteria = {};
        }
        // Matches iOS's narrow "apply a saved view" behavior: only the specialty
        // carries over, kind/territory reset — see the plan's Phase 2 notes.
        this.dispatchEvent(new CustomEvent('filterchange', {
            detail: { field: 'savedView', value: { specialty: criteria.specialtyFilter || '' } },
        }));
    }

    handleClear() {
        this.dispatchEvent(new CustomEvent('filterchange', { detail: { field: 'clear' } }));
    }
}