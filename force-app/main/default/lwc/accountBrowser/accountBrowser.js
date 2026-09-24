import { LightningElement, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import searchAccounts from '@salesforce/apex/SciagenAccountController.searchAccounts';
import getTerritoryOptions from '@salesforce/apex/SciagenAccountController.getTerritoryOptions';
import canSeeAllTerritories from '@salesforce/apex/SciagenAccountController.canSeeAllTerritories';
import getSpecialtyOptions from '@salesforce/apex/SciagenAccountController.getSpecialtyOptions';
import getHCOTypeOptions from '@salesforce/apex/SciagenAccountController.getHCOTypeOptions';
import getHCOSpecialityOptions from '@salesforce/apex/SciagenAccountController.getHCOSpecialityOptions';
import getHCPTypeOptions from '@salesforce/apex/SciagenAccountController.getHCPTypeOptions';
import getSegmentationOptions from '@salesforce/apex/SciagenAccountController.getSegmentationOptions';
import isKeyAccountManager from '@salesforce/apex/SciagenAccountController.isKeyAccountManager';
import getHCOOptionsForAffiliation from '@salesforce/apex/SciagenAccountController.getHCOOptionsForAffiliation';
import submitAccountDcr from '@salesforce/apex/SciagenAccountController.submitAccountDcr';
import getSavedViews from '@salesforce/apex/SciagenAccountController.getSavedViews';
import saveView from '@salesforce/apex/SciagenAccountController.saveView';
import deleteSavedView from '@salesforce/apex/SciagenAccountController.deleteSavedView';
import getCustomLists from '@salesforce/apex/SciagenAccountController.getCustomLists';
import createCustomList from '@salesforce/apex/SciagenAccountController.createCustomList';
import addAccountsToList from '@salesforce/apex/SciagenAccountController.addAccountsToList';
import getCustomListMemberIds from '@salesforce/apex/SciagenScheduleController.getCustomListMemberIds';
import USER_ID from '@salesforce/user/Id';
import { pillStyle, BRAND } from 'c/sciagenColors';

const SEARCH_DEBOUNCE_MS = 300;

const SORT_FIELD_OPTIONS = [
    { label: 'Name', value: 'Name' },
    { label: 'City', value: 'City' },
    { label: 'Territory', value: 'Territory' },
];

const PAGE_SIZE = 50;
const ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'.split('');

// Always shown, same as a standard Salesforce list view's fixed columns.
const BASE_TABLE_COLUMNS = [
    { label: 'Name', fieldName: 'name', type: 'text', sortable: true, wrapText: false },
    { label: 'Type', fieldName: 'type', type: 'text', initialWidth: 90 },
    { label: 'Details', fieldName: 'subtitle', type: 'text', wrapText: false },
    { label: 'City', fieldName: 'city', type: 'text', sortable: true, initialWidth: 140 },
    { label: 'Territory', fieldName: 'territory', type: 'text', sortable: true, initialWidth: 140 },
    { label: 'KOL', fieldName: 'isKOL', type: 'boolean', initialWidth: 70 },
    { label: 'Emerging', fieldName: 'isEmergingExpert', type: 'boolean', initialWidth: 90 },
];

const ACTION_COLUMN = {
    type: 'button-icon',
    typeAttributes: { iconName: 'utility:chevronright', name: 'view', alternativeText: 'Open', variant: 'bare' },
    initialWidth: 44,
};

// Optional columns the rep can add via "Add Column" — the datatable/list-view
// analog of standard Salesforce list views' "Select Fields to Display".
// `key` doubles as the AccountSummary field this reads from
// (SciagenAccountController.searchAccounts) and as the persisted-selection
// id in localStorage.
const EXTRA_COLUMNS = [
    { key: 'specialty', label: 'Specialty', fieldName: 'specialty', type: 'text', initialWidth: 150 },
    { key: 'subType', label: 'Sub Type', fieldName: 'subType', type: 'text', initialWidth: 130 },
    { key: 'phone', label: 'Phone', fieldName: 'phone', type: 'phone', initialWidth: 140 },
    { key: 'email', label: 'Email', fieldName: 'email', type: 'email', initialWidth: 180 },
    { key: 'accountCode', label: 'Account Code', fieldName: 'accountCode', type: 'text', initialWidth: 130 },
    { key: 'website', label: 'Website', fieldName: 'website', type: 'url', initialWidth: 160 },
    { key: 'focusArea', label: 'Focus Area', fieldName: 'focusArea', type: 'text', initialWidth: 150 },
    { key: 'licenseNumber', label: 'License Number', fieldName: 'licenseNumber', type: 'text', initialWidth: 150 },
];

const EXTRA_COLUMNS_BY_KEY = Object.fromEntries(EXTRA_COLUMNS.map((c) => [c.key, c]));

// Per-user, per-browser (localStorage doesn't sync across devices — see the
// "Add Column" doc comment on handleToggleColumn) — scoped by USER_ID so a
// shared/kiosk machine doesn't mix one rep's column choices into another's.
const COLUMN_PREF_KEY = `sciagen-account-browser-columns-${USER_ID}`;

// datatable fieldName -> the app's own sortField vocabulary (matches SORT_FIELD_OPTIONS)
const TABLE_SORT_FIELD_MAP = { name: 'Name', city: 'City', territory: 'Territory' };

const NEW_ACCOUNT_TYPE_OPTIONS = [
    { label: 'HCP — Healthcare Professional', value: 'HCP' },
    { label: 'HCO — Healthcare Organization', value: 'HCO' },
];

const HCP_CREATE_FIELDS = [
    'Name', 'Prefix__c', 'First_Name__c', 'Last_Name__c', 'Primary_Country__c', 'HCP_Type__c', 'Specialty__c',
    'Focus_Area__c', 'License_Number__c', 'Licensing_Body__c', 'Phone__c', 'Email__c', 'Account_Code__c',
    'Website__c', 'Graduation_Year__c', 'Degree_1__c', 'Degree_2__c', 'Degree_3__c', 'Degree_4__c',
];
const HCO_CREATE_FIELDS = [
    'Name', 'HCO_Type__c', 'Speciality__c', 'Website__c', 'Phone__c', 'Email__c', 'Account_Code__c',
];
// Rendered as their own SLDS section below the main grid (see the "Address"
// slds-section in the template) rather than mixed in with everything else —
// same 5 fields for both HCP and HCO, so this is one shared list rather than
// per-type like the arrays above. HCO_CREATE_FIELDS used to carry these
// inline; HCP_CREATE_FIELDS never had them at all.
const ADDRESS_FIELDS = [
    'Billing_Street__c', 'Billing_City__c', 'Billing_State__c', 'Billing_Postal_Code__c', 'Billing_Country__c',
];

// MARK: - Key Account Manager "New Request" (DCR) — mirrors the iPad app's
// NewAccountRequestView field set/defaults exactly (Views/DCRView.swift),
// since a Key Account Manager's request is reviewed against the same
// DataChangeRequestApprovalHandler either way, regardless of which client
// submitted it.
const DCR_PREFIX_OPTIONS = ['Dr.', 'Prof.', 'Mr.', 'Ms.'];

export default class AccountBrowser extends NavigationMixin(LightningElement) {
    // Core search state
    searchTerm = '';
    typeFilter = '';
    territoryFilter = '';
    specialtyFilter = '';
    hcoTypeFilter = '';
    cityFilter = '';
    segmentationFilter = '';
    kolOnly = false;
    emergingOnly = false;
    sortField = 'Name';
    sortAscending = true;

    results = [];
    selectedId;
    isSearching = false;
    error;
    debounceTimer;
    viewMode = 'list'; // 'list' | 'table' | 'map'
    currentPage = 1;
    tableSortedBy = 'name';
    tableSortedDirection = 'asc';
    selectedColumnKeys = [];

    isCreating = false;
    newAccountType = 'HCP';
    sortFieldOptions = SORT_FIELD_OPTIONS;
    newAccountTypeOptions = NEW_ACCOUNT_TYPE_OPTIONS;

    territoryOptions = [{ label: 'All Territories', value: '' }];
    specialtyOptions = [{ label: 'All Specialties', value: '' }];
    hcoTypeOptions = [{ label: 'All HCO Types', value: '' }];
    segmentationOptions = [{ label: 'All Segments', value: '' }];

    // Key Account Manager "New Request" (DCR) state — see the DCR_PREFIX_OPTIONS
    // doc comment above. Kept entirely separate from the isCreating/newAccountType
    // fields above, which stay exactly as-is for every other profile.
    isKAM = false;

    // Territory filter — a System Administrator (canSeeAllTerritories) gets a
    // searchable picker over every territory (see filteredTerritorySearchOptions);
    // everyone else keeps the plain combobox, now populated by Apex with only
    // the territory(ies) they're actually assigned to — see getTerritoryOptions's
    // doc comment. They were never meant to see, let alone filter by, another
    // rep's territory.
    canSeeAllTerritories = false;
    territorySearchTerm = '';
    isTerritorySearchFocused = false;

    isRequestingDcr = false;
    isSubmittingDcr = false;
    dcrType = 'HCO'; // 'HCO' | 'HCP'
    dcrPrefixOptions = DCR_PREFIX_OPTIONS.map((p) => ({ label: p, value: p }));
    hcoSpecialityOptions = [];
    hcpTypeOptionsList = [];
    hcoAffiliationOptions = [];
    dcrHcoName = '';
    dcrHcoType = '';
    dcrHcoSpeciality = '';
    dcrCity = '';
    dcrState = '';
    dcrPincode = '';
    dcrPhone = '';
    dcrPrefix = 'Dr.';
    dcrFirstName = '';
    dcrLastName = '';
    dcrSpecialty = '';
    dcrHcpType = '';
    dcrEmail = '';
    dcrDegree = '';
    dcrHcoSearch = '';
    dcrSelectedHCOId = null;

    // Saved views
    savedViews = [];
    activeViewId;
    isSavingView = false;
    saveViewName = '';

    // Selection + bulk actions
    selectionOn = false;
    selectedIds = new Set();
    isAddingToList = false;
    customLists = [];
    targetListId = '';
    newListName = '';
    customListFilter = '';

    @wire(getTerritoryOptions)
    wiredTerritories({ data }) {
        if (data) {
            // "All Territories" only makes sense as a reset option when there's
            // more than one territory to choose from — a rep (or single-territory
            // KAM) restricted to exactly one doesn't have anything to reset
            // between, so the combobox just shows that one territory instead of
            // a redundant "All Territories" alongside it. A System Administrator
            // never sees this list at all (their searchable picker filters '' out
            // regardless — see territoryNamesOnly), so this only affects the
            // plain combobox everyone else gets.
            // Sorted alphabetically here too (not just relying on getTerritoryOptions'
            // own ORDER BY Name) so the Admin's search list is guaranteed A-Z
            // regardless of how the data arrives.
            const mapped = data.map((t) => ({ label: t, value: t })).sort((a, b) => a.label.localeCompare(b.label));
            this.territoryOptions = mapped.length > 1 ? [{ label: 'All Territories', value: '' }, ...mapped] : mapped;
        }
    }

    @wire(canSeeAllTerritories)
    wiredCanSeeAllTerritories({ data }) {
        // No `else` clearing it — defaults to false (the safe, own-territory-only
        // combobox), never fails open into the admin search view for someone
        // this wasn't meant for.
        if (data === true) {
            this.canSeeAllTerritories = true;
        }
    }

    @wire(getSpecialtyOptions)
    wiredSpecialties({ data }) {
        if (data) {
            this.specialtyOptions = [{ label: 'All Specialties', value: '' }, ...data.map((s) => ({ label: s, value: s }))];
        }
    }

    @wire(getHCOTypeOptions)
    wiredHcoTypes({ data }) {
        if (data) {
            this.hcoTypeOptions = [{ label: 'All HCO Types', value: '' }, ...data.map((t) => ({ label: t, value: t }))];
        }
    }

    @wire(getSegmentationOptions)
    wiredSegmentation({ data }) {
        if (data) {
            this.segmentationOptions = [{ label: 'All Segments', value: '' }, ...data.map((s) => ({ label: s, value: s }))];
        }
    }

    @wire(isKeyAccountManager)
    wiredIsKAM({ data }) {
        // Deliberately no `else` clearing it on error/undefined — defaults to
        // false (the existing "New" direct-create button), never fails open
        // into the DCR-gated flow for someone this wasn't meant for.
        if (data === true) {
            this.isKAM = true;
        }
    }

    @wire(getHCOSpecialityOptions)
    wiredHcoSpecialityOptions({ data }) {
        if (data) {
            this.hcoSpecialityOptions = data.map((s) => ({ label: s, value: s }));
        }
    }

    @wire(getHCPTypeOptions)
    wiredHcpTypeOptions({ data }) {
        if (data) {
            this.hcpTypeOptionsList = data.map((t) => ({ label: t, value: t }));
        }
    }

    @wire(getHCOOptionsForAffiliation)
    wiredHcoAffiliationOptions({ data }) {
        if (data) {
            this.hcoAffiliationOptions = data;
        }
    }

    @wire(getSavedViews)
    wiredSavedViews({ data }) {
        if (data) {
            this.savedViews = data;
        }
    }

    wiredCustomListsResult;

    @wire(getCustomLists)
    wiredCustomLists(result) {
        this.wiredCustomListsResult = result;
        if (result.data) {
            this.customLists = result.data;
        }
    }

    connectedCallback() {
        this.loadColumnPreference();
        this.runSearch();
    }

    // MARK: - Add Column (table & list view field picker)

    // Wrapped in try/catch — a private-browsing tab or a browser with site
    // data blocked can make localStorage throw on either read or write, and
    // "the rep's saved columns didn't load" should never become "the whole
    // Accounts tab is broken".
    loadColumnPreference() {
        try {
            const raw = window.localStorage.getItem(COLUMN_PREF_KEY);
            const keys = raw ? JSON.parse(raw) : [];
            this.selectedColumnKeys = Array.isArray(keys) ? keys.filter((k) => EXTRA_COLUMNS_BY_KEY[k]) : [];
        } catch (e) {
            this.selectedColumnKeys = [];
        }
    }

    persistColumnPreference() {
        try {
            window.localStorage.setItem(COLUMN_PREF_KEY, JSON.stringify(this.selectedColumnKeys));
        } catch (e) {
            // Best-effort only — the picker still works for the rest of this
            // session even if it can't be remembered for next time.
        }
    }

    get addColumnOptions() {
        return EXTRA_COLUMNS.map((c) => ({
            ...c,
            isSelected: this.selectedColumnKeys.includes(c.key),
            rowClass: this.selectedColumnKeys.includes(c.key) ? 'column-option column-option-selected' : 'column-option',
        }));
    }

    get hasSelectedColumns() {
        return this.selectedColumnKeys.length > 0;
    }

    handleToggleColumn(event) {
        const key = event.currentTarget.dataset.key;
        if (!EXTRA_COLUMNS_BY_KEY[key]) return;
        this.selectedColumnKeys = this.selectedColumnKeys.includes(key)
            ? this.selectedColumnKeys.filter((k) => k !== key)
            : [...this.selectedColumnKeys, key];
        this.persistColumnPreference();
    }

    // Table view's actual lightning-datatable columns: the fixed base set,
    // then whatever the rep has added (in the order they added them), then
    // the row-open action — mirrors how a standard Salesforce list view
    // appends chosen fields after its own fixed columns.
    get tableColumns() {
        const extra = this.selectedColumnKeys.map((k) => EXTRA_COLUMNS_BY_KEY[k]).filter(Boolean);
        return [...BASE_TABLE_COLUMNS, ...extra, ACTION_COLUMN];
    }

    // List view's extra fields, pre-formatted as "Label: value" strings per
    // row — same selection as the table view's columns, so a field the rep
    // added is visible however they're currently browsing, not just in one
    // of the two views.
    get selectedExtraFieldDefs() {
        return this.selectedColumnKeys.map((k) => EXTRA_COLUMNS_BY_KEY[k]).filter(Boolean);
    }

    // MARK: - Filters

    handleSearchChange(event) {
        this.searchTerm = event.target.value;
        this.debounceSearch();
    }

    handleTerritoryFilterChange(event) {
        this.territoryFilter = event.detail.value;
        this.runSearch();
    }

    // MARK: - Territory search (System Administrator only — see canSeeAllTerritories)

    get territorySearchPlaceholder() {
        return this.territoryFilter || 'All Territories';
    }

    get isNotAdminTerritoryView() {
        return !this.canSeeAllTerritories;
    }

    get hasTerritoryFilterSelected() {
        return this.territoryFilter !== '';
    }

    /// Excludes the synthetic "All Territories" (value: '') entry from the
    /// searchable list — that's handled by the separate "Clear" affordance
    /// instead, since a free-text search box has no natural row for it.
    get territoryNamesOnly() {
        return this.territoryOptions.filter((t) => t.value !== '');
    }

    /// Shows every territory in alphabetical order (getTerritoryOptions
    /// already returns them sorted, A-Z by Name) — a System Administrator
    /// should be able to see and pick from the full list right away, not
    /// just a 2-row preview. Typing narrows it to actual matches, same as
    /// the DCR HCO picker.
    get filteredTerritorySearchOptions() {
        const q = this.territorySearchTerm.trim().toLowerCase();
        if (!q) {
            return this.territoryNamesOnly;
        }
        return this.territoryNamesOnly.filter((t) => t.label.toLowerCase().includes(q));
    }

    handleTerritorySearchChange(event) {
        this.territorySearchTerm = event.target.value;
    }

    handleTerritorySearchFocus() {
        this.isTerritorySearchFocused = true;
    }

    // Delayed rather than immediate — a click on a dropdown row also blurs
    // the search input, and without this delay the list would unmount
    // before that click has a chance to register.
    handleTerritorySearchBlur() {
        setTimeout(() => { this.isTerritorySearchFocused = false; }, 150);
    }

    handleSelectTerritorySearch(event) {
        this.territoryFilter = event.currentTarget.dataset.value;
        this.territorySearchTerm = '';
        this.isTerritorySearchFocused = false;
        this.runSearch();
    }

    handleClearTerritorySearch() {
        this.territoryFilter = '';
        this.territorySearchTerm = '';
        this.runSearch();
    }

    get customListFilterOptions() {
        return [{ label: 'All Custom Lists', value: '' }, ...this.customLists.map((l) => ({ label: l.listName, value: l.id }))];
    }

    handleCustomListFilterChange(event) {
        this.customListFilter = event.detail.value;
        this.runSearch();
    }

    handleSpecialtyFilterChange(event) {
        this.specialtyFilter = event.detail.value;
        this.runSearch();
    }

    handleHcoTypeFilterChange(event) {
        this.hcoTypeFilter = event.detail.value;
        this.runSearch();
    }

    handleCityFilterChange(event) {
        this.cityFilter = event.target.value;
        this.debounceSearch();
    }

    handleSegmentationFilterChange(event) {
        this.segmentationFilter = event.detail.value;
        this.runSearch();
    }

    handleSortFieldChange(event) {
        this.sortField = event.detail.value;
        this.runSearch();
    }

    handleToggleSortDirection() {
        this.sortAscending = !this.sortAscending;
        this.runSearch();
    }

    // MARK: - HCP/HCO/All type toggle — the sole control for typeFilter now that
    // the redundant "Type" dropdown (All Types/HCP/HCO) has been removed.

    get typeToggleAllVariant() {
        return this.typeFilter === '' ? 'brand' : 'neutral';
    }
    get typeToggleHcpVariant() {
        return this.typeFilter === 'HCP' ? 'brand' : 'neutral';
    }
    get typeToggleHcoVariant() {
        return this.typeFilter === 'HCO' ? 'brand' : 'neutral';
    }

    handleTypeToggleAll() {
        this.typeFilter = '';
        this.runSearch();
    }
    handleTypeToggleHcp() {
        this.typeFilter = 'HCP';
        this.runSearch();
    }
    handleTypeToggleHco() {
        this.typeFilter = 'HCO';
        this.runSearch();
    }

    handleToggleKolOnly() {
        this.kolOnly = !this.kolOnly;
        this.runSearch();
    }

    handleToggleEmergingOnly() {
        this.emergingOnly = !this.emergingOnly;
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
            let results = await searchAccounts({
                searchTerm: this.searchTerm,
                typeFilter: this.typeFilter,
                territoryFilter: this.territoryFilter,
                specialtyFilter: this.specialtyFilter,
                hcoTypeFilter: this.hcoTypeFilter,
                cityFilter: this.cityFilter,
                kolOnly: this.kolOnly,
                emergingOnly: this.emergingOnly,
                segmentationFilter: this.segmentationFilter,
                sortField: this.sortField,
                sortAscending: this.sortAscending,
            });
            // Custom_List_Member__c.HCP__c is a lookup to Sciagen_Account__c
            // generically (the field name is a holdover, not a type
            // restriction) — addAccountsToList lets a rep add HCPs and HCOs
            // alike from this browser's own multi-select, so this filter
            // matches either. (My Schedule's own Custom List filter is
            // narrower by necessity: it matches a Planned Call by its hcpId,
            // so a list containing only HCOs won't surface any calls there —
            // a planned call has no hcpId to match against.)
            if (this.customListFilter) {
                const memberIds = await getCustomListMemberIds({ listId: this.customListFilter });
                results = results.filter((r) => memberIds.includes(r.id));
            }
            this.results = results;
        } catch (e) {
            this.error = reduceError(e);
            this.results = [];
        } finally {
            this.isSearching = false;
            this.currentPage = 1;
        }
    }

    // MARK: - Pagination

    get totalPages() {
        return Math.max(1, Math.ceil((this.results || []).length / PAGE_SIZE));
    }

    get pageLabel() {
        return `Page ${this.currentPage} of ${this.totalPages}`;
    }

    get cannotGoPrevPage() {
        return this.currentPage <= 1;
    }

    get cannotGoNextPage() {
        return this.currentPage >= this.totalPages;
    }

    handlePrevPage() {
        if (!this.cannotGoPrevPage) {
            this.currentPage -= 1;
        }
    }

    handleNextPage() {
        if (!this.cannotGoNextPage) {
            this.currentPage += 1;
        }
    }

    // MARK: - Alphabet jump (only meaningful when sorted by Name)

    get isNameSort() {
        return this.sortField === 'Name';
    }

    get alphabetKeys() {
        const available = new Set(
            (this.results || []).map((r) => (r.name || '').trim().charAt(0).toUpperCase()).filter((c) => ALPHABET.includes(c))
        );
        return ALPHABET.map((letter) => ({
            letter,
            key: letter,
            navClass: available.has(letter) ? 'alpha-key' : 'alpha-key disabled',
            disabled: !available.has(letter),
        }));
    }

    handleAlphaJump(event) {
        const letter = event.currentTarget.dataset.letter;
        const index = (this.results || []).findIndex((r) => (r.name || '').trim().toUpperCase().startsWith(letter));
        if (index === -1) {
            return;
        }
        this.currentPage = Math.floor(index / PAGE_SIZE) + 1;
    }

    // Accounts is the parent (list) page; selecting a row drills down into the
    // full-page Account Details view (the activated Sciagen_Account_Record_Page
    // record page) instead of showing details inline — a back/browser-back
    // return trip is the way back to this list.
    handleSelect(event) {
        const accountId = event.currentTarget.dataset.id;
        this.selectedId = accountId;
        this.navigateToAccount(accountId);
    }

    navigateToAccount(accountId) {
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId: accountId,
                objectApiName: 'Sciagen_Account__c',
                actionName: 'view',
            },
        });
    }

    get hasResults() {
        return this.results && this.results.length > 0;
    }

    get sortIcon() {
        return this.sortAscending ? 'utility:arrowup' : 'utility:arrowdown';
    }

    get kolButtonVariant() {
        return this.kolOnly ? 'brand' : 'neutral';
    }

    get emergingButtonVariant() {
        return this.emergingOnly ? 'brand' : 'neutral';
    }

    get kolCount() {
        return (this.results || []).filter((r) => r.isKOL).length;
    }

    get emergingCount() {
        return (this.results || []).filter((r) => r.isEmergingExpert).length;
    }

    get rows() {
        const start = (this.currentPage - 1) * PAGE_SIZE;
        const extraDefs = this.selectedExtraFieldDefs;
        return (this.results || []).slice(start, start + PAGE_SIZE).map((r) => ({
            ...r,
            rowClass: r.id === this.selectedId ? 'result-row selected' : 'result-row',
            typeStyle: pillStyle(r.type === 'HCP' ? BRAND.primary : BRAND.violet),
            checked: this.selectedIds.has(r.id),
            // SLDS's own standard object icons — the same building glyph
            // Salesforce uses everywhere for Account, and the same person
            // silhouette it uses for Contact — rather than a custom image,
            // so an HCO/HCP row reads instantly the way every other list in
            // the org already does.
            iconName: r.type === 'HCP' ? 'standard:contact' : 'standard:account',
            // "Label: value" for each field the rep added via "Add Column" —
            // same selection the table view uses, so list view shows it too
            // rather than only ever being a table-view-only feature.
            extraFieldLines: extraDefs
                .map((def) => ({ key: def.key, label: def.label, value: r[def.fieldName] }))
                .filter((f) => f.value != null && f.value !== ''),
        }));
    }

    get hasExtraFieldLinesOnRows() {
        return this.selectedExtraFieldDefs.length > 0;
    }

    // MARK: - View modes (List / Table / Map)

    get isListView() {
        return this.viewMode === 'list';
    }

    get isTableView() {
        return this.viewMode === 'table';
    }

    get isMapView() {
        return this.viewMode === 'map';
    }

    get listViewIconVariant() {
        return this.isListView ? 'brand' : 'border-filled';
    }

    get tableViewIconVariant() {
        return this.isTableView ? 'brand' : 'border-filled';
    }

    get mapViewIconVariant() {
        return this.isMapView ? 'brand' : 'border-filled';
    }

    handleShowListView() {
        this.viewMode = 'list';
    }

    handleShowTableView() {
        this.viewMode = 'table';
    }

    handleShowMapView() {
        this.viewMode = 'map';
    }

    /// Same paginated page-window as the List view (`rows`), so Previous/Next
    /// and the alphabet rail behave identically regardless of which view is
    /// active — switching views mid-browse doesn't reset your place.
    get tableRows() {
        return this.rows;
    }

    handleTableRowAction(event) {
        const action = event.detail.action;
        if (action.name === 'view') {
            const accountId = event.detail.row.id;
            this.selectedId = accountId;
            this.navigateToAccount(accountId);
        }
    }

    handleTableSort(event) {
        const { fieldName, sortDirection } = event.detail;
        const mappedField = TABLE_SORT_FIELD_MAP[fieldName];
        if (!mappedField) {
            return;
        }
        this.tableSortedBy = fieldName;
        this.tableSortedDirection = sortDirection;
        this.sortField = mappedField;
        this.sortAscending = sortDirection === 'asc';
        this.runSearch();
    }

    get mapMarkers() {
        return (this.results || [])
            .filter((r) => r.latitude != null && r.longitude != null)
            .map((r) => ({
                location: { Latitude: r.latitude, Longitude: r.longitude },
                title: r.name,
                description: r.subtitle,
                value: r.id,
            }));
    }

    get hasMapMarkers() {
        return this.mapMarkers.length > 0;
    }

    handleMarkerSelect(event) {
        const accountId = event.detail.selectedMarkerValue;
        this.selectedId = accountId;
        this.navigateToAccount(accountId);
    }

    // MARK: - Saved views

    get savedViewOptions() {
        return [{ label: '— Unsaved search —', value: '' }, ...this.savedViews.map((v) => ({ label: v.viewName, value: v.id }))];
    }

    get hasActiveView() {
        return !!this.activeViewId;
    }

    handleApplySavedView(event) {
        const viewId = event.detail.value;
        this.activeViewId = viewId;
        if (!viewId) {
            return;
        }
        const view = this.savedViews.find((v) => v.id === viewId);
        if (!view) {
            return;
        }
        let criteria = {};
        try {
            criteria = view.filterJson ? JSON.parse(view.filterJson) : {};
        } catch (e) {
            criteria = {};
        }
        this.searchTerm = criteria.searchTerm || '';
        this.typeFilter = criteria.typeFilter || '';
        this.territoryFilter = criteria.territoryFilter || '';
        this.specialtyFilter = criteria.specialtyFilter || '';
        this.hcoTypeFilter = criteria.hcoTypeFilter || '';
        this.cityFilter = criteria.cityFilter || '';
        this.kolOnly = !!criteria.kolOnly;
        this.emergingOnly = !!criteria.emergingOnly;
        this.segmentationFilter = criteria.segmentationFilter || '';
        this.sortField = view.sortField || 'Name';
        this.sortAscending = view.sortAscending !== false;
        this.runSearch();
    }

    handleOpenSaveView() {
        const active = this.savedViews.find((v) => v.id === this.activeViewId);
        this.saveViewName = active ? active.viewName : '';
        this.isSavingView = true;
    }

    handleCloseSaveView() {
        this.isSavingView = false;
    }

    handleSaveViewNameChange(event) {
        this.saveViewName = event.target.value;
    }

    async handleConfirmSaveView() {
        if (!this.saveViewName || !this.saveViewName.trim()) {
            return;
        }
        try {
            const criteria = {
                searchTerm: this.searchTerm,
                typeFilter: this.typeFilter,
                territoryFilter: this.territoryFilter,
                specialtyFilter: this.specialtyFilter,
                hcoTypeFilter: this.hcoTypeFilter,
                cityFilter: this.cityFilter,
                kolOnly: this.kolOnly,
                emergingOnly: this.emergingOnly,
                segmentationFilter: this.segmentationFilter,
            };
            const viewId = await saveView({
                viewId: this.activeViewId || null,
                viewName: this.saveViewName.trim(),
                filterJson: JSON.stringify(criteria),
                sortField: this.sortField,
                sortAscending: this.sortAscending,
                layout: this.viewMode === 'map' ? 'Map' : 'List',
            });
            this.activeViewId = viewId;
            this.isSavingView = false;
            this.dispatchEvent(new ShowToastEvent({ title: 'View saved', variant: 'success' }));
            this.savedViews = await getSavedViews();
        } catch (e) {
            this.dispatchEvent(new ShowToastEvent({ title: 'Couldn’t save view', message: reduceError(e), variant: 'error' }));
        }
    }

    async handleDeleteCurrentView() {
        if (!this.activeViewId) {
            return;
        }
        try {
            await deleteSavedView({ viewId: this.activeViewId });
            this.activeViewId = undefined;
            this.dispatchEvent(new ShowToastEvent({ title: 'View deleted', variant: 'success' }));
            this.savedViews = await getSavedViews();
        } catch (e) {
            this.dispatchEvent(new ShowToastEvent({ title: 'Couldn’t delete view', message: reduceError(e), variant: 'error' }));
        }
    }

    // MARK: - Selection + bulk "Add to List"

    get selectionButtonLabel() {
        return this.selectionOn ? 'Cancel Selection' : 'Select';
    }

    get selectedCount() {
        return this.selectedIds.size;
    }

    get hasSelectedRows() {
        return this.selectedIds.size > 0;
    }

    get hasNoSelectedRows() {
        return this.selectedIds.size === 0;
    }

    handleToggleSelectionMode() {
        this.selectionOn = !this.selectionOn;
        if (!this.selectionOn) {
            this.selectedIds = new Set();
        }
    }

    handleRowCheckboxChange(event) {
        event.stopPropagation();
        if (event.type === 'click') {
            return; // avoid double-handling: 'click' bubbles to the row, 'change' does the actual state update
        }
        const id = event.currentTarget.dataset.id;
        const next = new Set(this.selectedIds);
        if (event.target.checked) {
            next.add(id);
        } else {
            next.delete(id);
        }
        this.selectedIds = next;
    }

    handleOpenAddToList() {
        this.targetListId = '';
        this.newListName = '';
        this.isAddingToList = true;
    }

    handleCloseAddToList() {
        this.isAddingToList = false;
    }

    get customListOptions() {
        return [{ label: '— New list —', value: '' }, ...this.customLists.map((l) => ({ label: l.listName, value: l.id }))];
    }

    get isCreatingNewList() {
        return !this.targetListId;
    }

    handleTargetListChange(event) {
        this.targetListId = event.detail.value;
    }

    handleNewListNameChange(event) {
        this.newListName = event.target.value;
    }

    async handleConfirmAddToList() {
        try {
            let listId = this.targetListId;
            if (!listId) {
                if (!this.newListName || !this.newListName.trim()) {
                    return;
                }
                listId = await createCustomList({ listName: this.newListName.trim() });
            }
            await addAccountsToList({ listId, accountIds: Array.from(this.selectedIds) });
            this.isAddingToList = false;
            this.selectionOn = false;
            this.selectedIds = new Set();
            this.dispatchEvent(new ShowToastEvent({ title: 'Added to list', variant: 'success' }));
            // Invalidates the shared Apex cache entry (not just this component's
            // copy) so the just-created list shows up immediately in both this
            // dropdown and My Schedule's Custom List filter, without waiting for
            // a full page reload — see SciagenAccountController.getCustomLists's
            // doc comment for why this couldn't just be `cacheable=false`.
            await refreshApex(this.wiredCustomListsResult);
        } catch (e) {
            this.dispatchEvent(new ShowToastEvent({ title: 'Couldn’t add to list', message: reduceError(e), variant: 'error' }));
        }
    }

    // MARK: - Create

    get isCreatingHCP() {
        return this.newAccountType === 'HCP';
    }

    get createFields() {
        return this.isCreatingHCP ? HCP_CREATE_FIELDS : HCO_CREATE_FIELDS;
    }

    get addressFields() {
        return ADDRESS_FIELDS;
    }

    handleOpenCreate() {
        this.newAccountType = 'HCP';
        this.isCreating = true;
    }

    handleCloseCreate() {
        this.isCreating = false;
    }

    handleNewAccountTypeChange(event) {
        this.newAccountType = event.detail.value;
    }

    handleCreateSuccess(event) {
        this.isCreating = false;
        this.dispatchEvent(new ShowToastEvent({ title: 'Account created', variant: 'success' }));
        this.selectedId = event.detail.id;
        this.runSearch();
    }

    handleCreateError(event) {
        this.dispatchEvent(new ShowToastEvent({
            title: 'Couldn’t create account',
            message: event.detail?.detail || event.detail?.message || 'Check the highlighted fields and try again.',
            variant: 'error',
        }));
    }

    // MARK: - New Request (DCR) — Key Account Manager only

    get isNotKAM() {
        return !this.isKAM;
    }

    get isRequestingHCO() {
        return this.dcrType === 'HCO';
    }

    get dcrModalTitle() {
        return this.isRequestingHCO ? 'Request New HCO' : 'Request New HCP';
    }

    get filteredDcrHcoOptions() {
        const q = (this.dcrHcoSearch || '').trim().toLowerCase();
        const matches = !q
            ? this.hcoAffiliationOptions
            : this.hcoAffiliationOptions.filter((h) => `${h.name} ${h.city || ''}`.toLowerCase().includes(q));
        return matches.slice(0, 40).map((h) => ({ ...h, selected: h.id === this.dcrSelectedHCOId }));
    }

    get selectedDcrHco() {
        return this.hcoAffiliationOptions.find((h) => h.id === this.dcrSelectedHCOId);
    }

    get hasNoHCOsYet() {
        return this.isRequestingHCP && this.hcoAffiliationOptions.length === 0;
    }

    get isRequestingHCP() {
        return this.dcrType === 'HCP';
    }

    get canSubmitDcr() {
        if (this.isRequestingHCO) {
            return this.dcrHcoName.trim() !== '' && this.dcrCity.trim() !== '';
        }
        return this.hcoAffiliationOptions.length > 0 && this.dcrSelectedHCOId != null &&
            this.dcrFirstName.trim() !== '' && this.dcrLastName.trim() !== '';
    }

    get isSubmitDcrDisabled() {
        return this.isSubmittingDcr || !this.canSubmitDcr;
    }

    handleOpenNewRequest(event) {
        this.dcrType = event.currentTarget.dataset.type; // 'HCO' | 'HCP'
        this.resetDcrForm();
        this.isRequestingDcr = true;
    }

    handleCloseDcr() {
        this.isRequestingDcr = false;
    }

    resetDcrForm() {
        this.dcrHcoName = '';
        this.dcrHcoType = '';
        this.dcrHcoSpeciality = '';
        this.dcrCity = '';
        this.dcrState = '';
        this.dcrPincode = '';
        this.dcrPhone = '';
        this.dcrPrefix = 'Dr.';
        this.dcrFirstName = '';
        this.dcrLastName = '';
        this.dcrSpecialty = '';
        this.dcrHcpType = '';
        this.dcrEmail = '';
        this.dcrDegree = '';
        this.dcrHcoSearch = '';
        this.dcrSelectedHCOId = null;
    }

    handleSwitchToNewHCO() {
        // Mirrors DCRView.swift's "HCO not listed? Request a new HCO first" —
        // an HCP request can't go anywhere without an HCO to affiliate with.
        this.dcrType = 'HCO';
    }

    handleDcrFieldChange(event) {
        const field = event.currentTarget.dataset.field;
        this[field] = event.detail.value;
    }

    handleDcrHcoSearchChange(event) {
        this.dcrHcoSearch = event.target.value;
    }

    handleSelectDcrHco(event) {
        this.dcrSelectedHCOId = event.currentTarget.dataset.id;
    }

    handleClearDcrHco() {
        this.dcrSelectedHCOId = null;
    }

    async handleSubmitDcr() {
        if (!this.canSubmitDcr || this.isSubmittingDcr) return;
        this.isSubmittingDcr = true;
        try {
            let type;
            let fields;
            let relatedHCOId = null;
            if (this.isRequestingHCO) {
                type = 'New HCO';
                fields = {
                    name: this.dcrHcoName.trim(),
                    type: this.dcrHcoType,
                    speciality: this.dcrHcoSpeciality,
                    city: this.dcrCity.trim(),
                    state: this.dcrState.trim(),
                    pincode: this.dcrPincode.trim(),
                    phone: this.dcrPhone.trim(),
                };
            } else {
                type = 'New HCP';
                relatedHCOId = this.dcrSelectedHCOId;
                const hcoName = this.selectedDcrHco ? this.selectedDcrHco.name : '';
                fields = {
                    prefix: this.dcrPrefix,
                    firstName: this.dcrFirstName.trim(),
                    lastName: this.dcrLastName.trim(),
                    specialty: this.dcrSpecialty,
                    hcpType: this.dcrHcpType,
                    email: this.dcrEmail.trim(),
                    phone: this.dcrPhone.trim(),
                    affiliationHCO: hcoName,
                };
                if (this.dcrDegree.trim() !== '') {
                    fields.degree1 = this.dcrDegree.trim();
                }
            }

            await submitAccountDcr({ type, fields, relatedHCOId });
            this.isRequestingDcr = false;
            this.dispatchEvent(new ShowToastEvent({
                title: 'Request submitted',
                message: 'Sent to DCR Review for approval.',
                variant: 'success',
            }));
        } catch (e) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Couldn’t submit request',
                message: reduceError(e),
                variant: 'error',
            }));
        } finally {
            this.isSubmittingDcr = false;
        }
    }
}

function reduceError(error) {
    if (error?.body?.message) {
        return error.body.message;
    }
    return 'An unknown error occurred.';
}