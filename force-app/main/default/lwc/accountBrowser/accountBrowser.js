import { LightningElement, wire } from 'lwc';
import USER_ID from '@salesforce/user/Id';
import { refreshApex } from '@salesforce/apex';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import searchAccounts from '@salesforce/apex/SciagenAccountController.searchAccounts';
import getTerritoryOptions from '@salesforce/apex/SciagenAccountController.getTerritoryOptions';
import getMyTerritoryNames from '@salesforce/apex/SciagenAccountController.getMyTerritoryNames';
import getSpecialtyOptions from '@salesforce/apex/SciagenAccountController.getSpecialtyOptions';
import getHCOTypeOptions from '@salesforce/apex/SciagenAccountController.getHCOTypeOptions';
import getSegmentationOptions from '@salesforce/apex/SciagenAccountController.getSegmentationOptions';
import getSavedViews from '@salesforce/apex/SciagenAccountController.getSavedViews';
import saveView from '@salesforce/apex/SciagenAccountController.saveView';
import deleteSavedView from '@salesforce/apex/SciagenAccountController.deleteSavedView';
import getCustomLists from '@salesforce/apex/SciagenAccountController.getCustomLists';
import createCustomList from '@salesforce/apex/SciagenAccountController.createCustomList';
import addAccountsToList from '@salesforce/apex/SciagenAccountController.addAccountsToList';
import getCustomListMemberIds from '@salesforce/apex/SciagenScheduleController.getCustomListMemberIds';
import isKeyAccountManager from '@salesforce/apex/SciagenAccountController.isKeyAccountManager';
import getHCPTypeOptions from '@salesforce/apex/SciagenAccountController.getHCPTypeOptions';
import getHCOSpecialtyOptions from '@salesforce/apex/SciagenAccountController.getHCOSpecialtyOptions';
import submitNewAccountRequest from '@salesforce/apex/SciagenAccountController.submitNewAccountRequest';
import { pillStyle, BRAND } from 'c/sciagenColors';

const SEARCH_DEBOUNCE_MS = 300;

const SORT_FIELD_OPTIONS = [
    { label: 'Name', value: 'Name' },
    { label: 'City', value: 'City' },
    { label: 'Territory', value: 'Territory' },
];

const PAGE_SIZE_OPTIONS = [20, 30, 40];
const DEFAULT_PAGE_SIZE = 20;
const ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'.split('');
// AccountSummary only carries the full Name (no separate first/last name), and
// most HCP names are stored as "Dr. <name>" -- indexing on the raw first
// character collapsed nearly every HCP under "D", which is why the A-Z rail
// looked broken (everything but a few HCOs was disabled). Strip the common
// title prefixes before computing the sort/jump letter.
const NAME_TITLE_PREFIX = /^(dr|mr|mrs|ms|prof)\.?\s+/i;
function sortableNameKey(name) {
    return (name || '').trim().replace(NAME_TITLE_PREFIX, '');
}

// Every field the Accounts page can show, in list and table view alike. `isDefault` = shown out of
// the box; the rest are switched on/off from the "Add Column" menu (a tick = currently displayed).
// `key` is also the property read from the row (SciagenAccountController.AccountSummary) and the id
// stored in the rep's saved column choice. Name can never be removed.
const COLUMN_CATALOG = [
    { key: 'name', label: 'Name', type: 'text', sortable: true, wrapText: false, initialWidth: 220, locked: true, isDefault: true },
    { key: 'type', label: 'Type', type: 'text', initialWidth: 90, isDefault: true },
    { key: 'subtitle', label: 'Details', type: 'text', wrapText: false, initialWidth: 240, isDefault: true },
    { key: 'city', label: 'City', type: 'text', sortable: true, initialWidth: 140, isDefault: true },
    { key: 'territory', label: 'Territory', type: 'text', sortable: true, initialWidth: 140, isDefault: true },
    { key: 'isKOL', label: 'KOL', type: 'boolean', initialWidth: 70, isDefault: true },
    { key: 'isEmergingExpert', label: 'Emerging', type: 'boolean', initialWidth: 90, isDefault: true },
    { key: 'specialty', label: 'Specialty', type: 'text', initialWidth: 150 },
    { key: 'subType', label: 'Sub Type', type: 'text', initialWidth: 130 },
    { key: 'phone', label: 'Phone', type: 'phone', initialWidth: 140 },
    { key: 'email', label: 'Email', type: 'email', initialWidth: 190 },
    { key: 'accountCode', label: 'Account Code', type: 'text', initialWidth: 130 },
    { key: 'website', label: 'Website', type: 'url', initialWidth: 170 },
    { key: 'focusArea', label: 'Focus Area', type: 'text', initialWidth: 150 },
    { key: 'licenseNumber', label: 'License Number', type: 'text', initialWidth: 150 },
    { key: 'licensingBody', label: 'Licensing Body', type: 'text', initialWidth: 170 },
    { key: 'licenseStatus', label: 'License Status', type: 'text', initialWidth: 140 },
    { key: 'licenseExpiry', label: 'License Expiry', type: 'date-local', initialWidth: 140 },
    { key: 'councilRegNumber', label: 'Council Reg. Number', type: 'text', initialWidth: 170 },
    { key: 'reachFlag', label: 'Reach', type: 'text', initialWidth: 110 },
    { key: 'lastVisit', label: 'Last Visit', type: 'date-local', initialWidth: 130 },
    { key: 'experienceYears', label: 'Experience (Yrs)', type: 'text', initialWidth: 140 },
    { key: 'graduationYear', label: 'Graduation Year', type: 'text', initialWidth: 140 },
    { key: 'street', label: 'Street', type: 'text', initialWidth: 180 },
    { key: 'state', label: 'State', type: 'text', initialWidth: 120 },
    { key: 'postalCode', label: 'Postal Code', type: 'text', initialWidth: 120 },
    { key: 'country', label: 'Country', type: 'text', initialWidth: 120 },
];
const COLUMN_BY_KEY = Object.fromEntries(COLUMN_CATALOG.map((c) => [c.key, c]));
const DEFAULT_COLUMN_KEYS = COLUMN_CATALOG.filter((c) => c.isDefault).map((c) => c.key);

const ACTION_COLUMN = {
    type: 'button-icon',
    typeAttributes: { iconName: 'utility:chevronright', name: 'view', alternativeText: 'Open', variant: 'bare' },
    initialWidth: 44,
};

// Per rep, per browser (localStorage does not sync across devices). Scoped by user id so a shared
// machine doesn't mix one rep's column choices into another's.
const COLUMN_PREF_KEY = `sciagen-account-browser-visible-columns-${USER_ID}`;

// Fields already drawn by the list card itself; every other ticked field is listed as "Label: value".
const LIST_CARD_BUILT_IN = new Set(['name', 'type', 'subtitle', 'city', 'territory', 'isKOL', 'isEmergingExpert']);


// datatable fieldName -> the app's own sortField vocabulary (matches SORT_FIELD_OPTIONS)
const TABLE_SORT_FIELD_MAP = { name: 'Name', city: 'City', territory: 'Territory' };

const NEW_ACCOUNT_TYPE_OPTIONS = [
    { label: 'HCP — Healthcare Professional', value: 'HCP' },
    { label: 'HCO — Healthcare Organization', value: 'HCO' },
];

const HCP_CREATE_FIELDS = [
    'Name', 'Prefix__c', 'First_Name__c', 'Last_Name__c', 'Primary_Country__c', 'HCP_Type__c', 'Specialty__c',
    'Focus_Area__c', 'License_Number__c', 'Licensing_Body__c', 'Phone__c', 'Email__c', 'Account_Code__c',
];
const HCO_CREATE_FIELDS = [
    'Name', 'HCO_Type__c', 'Speciality__c', 'Billing_Street__c', 'Billing_City__c', 'Billing_State__c',
    'Billing_Country__c', 'Billing_Postal_Code__c', 'Website__c', 'Phone__c', 'Email__c', 'Account_Code__c',
];

// The "New Request" (DCR) form a KAM sees instead of the direct-create modal above —
// deliberately a narrower field set than HCP_CREATE_FIELDS/HCO_CREATE_FIELDS: these are
// exactly the keys DataChangeRequestApprovalHandler.buildHCP/buildHCO read out of
// Fields_Payload__c to build the Account once a steward approves the request. A field
// with no key here (Focus_Area__c, License_Number__c, Website__c, ...) simply isn't part
// of the DCR payload — a steward fills it in on the Account after approval.
const HCP_REQUEST_FIELDS = [
    { key: 'prefix', label: 'Prefix', type: 'text' },
    { key: 'firstName', label: 'First Name', type: 'text', required: true },
    { key: 'lastName', label: 'Last Name', type: 'text', required: true },
    { key: 'hcpType', label: 'HCP Type', type: 'picklist', optionsProp: 'hcpTypeOptions' },
    { key: 'specialty', label: 'Specialty', type: 'picklist', optionsProp: 'requestSpecialtyOptions' },
    { key: 'degree1', label: 'Degree', type: 'text' },
    { key: 'phone', label: 'Phone', type: 'text' },
    { key: 'email', label: 'Email', type: 'email' },
];
const HCO_REQUEST_FIELDS = [
    { key: 'name', label: 'Name', type: 'text', required: true },
    { key: 'type', label: 'HCO Type', type: 'picklist', optionsProp: 'requestHcoTypeOptions' },
    { key: 'speciality', label: 'Speciality', type: 'picklist', optionsProp: 'hcoSpecialtyOptions' },
    { key: 'street', label: 'Street / Address', type: 'text' },
    { key: 'city', label: 'City', type: 'text' },
    { key: 'state', label: 'State', type: 'text' },
    { key: 'pincode', label: 'Pincode', type: 'text' },
    { key: 'country', label: 'Country', type: 'text' },
    { key: 'phone', label: 'Phone', type: 'text' },
];

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
    pageSize = DEFAULT_PAGE_SIZE;
    visibleColumnKeys = [...DEFAULT_COLUMN_KEYS];
    isColumnMenuOpen = false;
    tableSortedBy = 'name';
    tableSortedDirection = 'asc';

    isCreating = false;
    newAccountType = 'HCP';
    sortFieldOptions = SORT_FIELD_OPTIONS;
    newAccountTypeOptions = NEW_ACCOUNT_TYPE_OPTIONS;

    // "New Request" (DCR) modal — shown instead of the direct-create modal for a KAM.
    isKAM = false;
    isRequesting = false;
    isSubmittingRequest = false;
    requestType = 'HCP';
    requestFields = {};
    relatedHCOId;
    relatedHCOLabel = '';
    hcpTypeOptions = [];
    requestSpecialtyOptions = [];
    requestHcoTypeOptions = [];
    hcoSpecialtyOptions = [];

    // KAM users don't get an "All Territories" choice -- getTerritoryOptions() already
    // scopes the raw list to just their own (plus descendants for a manager), and offering
    // "All" as a selectable value would just mean "don't narrow further than that baseline",
    // which reads as if there's a broader org-wide view available when there isn't one.
    // Everyone else (admins, managers) keeps the full picker with "All Territories" first.
    rawTerritoryOptions = [];
    myTerritoryNames = [];

    get territoryOptions() {
        const mapped = this.rawTerritoryOptions.map((t) => ({ label: t, value: t }));
        return this.isKAM ? mapped : [{ label: 'All Territories', value: '' }, ...mapped];
    }
    specialtyOptions = [{ label: 'All Specialties', value: '' }];
    hcoTypeOptions = [{ label: 'All HCO Types', value: '' }];
    segmentationOptions = [{ label: 'All Segments', value: '' }];

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
            this.rawTerritoryOptions = data;
            this.maybeAutoSelectTerritory();
        }
    }

    // A KAM with exactly one territory has nothing to pick between -- apply it as the
    // filter automatically instead of making them click a single-item dropdown. A KAM with
    // several sees them all in the dropdown (handled by the territoryOptions getter above)
    // and picks one explicitly; this only auto-applies the single-territory case. Called from
    // both wire handlers below since isKAM and rawTerritoryOptions resolve independently.
    maybeAutoSelectTerritory() {
        if (this.isKAM && this.rawTerritoryOptions.length === 1 && !this.territoryFilter) {
            this.territoryFilter = this.rawTerritoryOptions[0];
            this.runSearch();
        }
    }

    @wire(getMyTerritoryNames)
    wiredMyTerritories({ data }) {
        if (data) {
            this.myTerritoryNames = data;
        }
    }

    // "Chandigarh", "Chandigarh, Delhi North", or a fallback for a user with
    // no Territory__c assignment (e.g. a System Administrator) -- always
    // something rather than a blank header.
    get myTerritoryLabel() {
        return this.myTerritoryNames.length ? this.myTerritoryNames.join(', ') : 'No territory assigned';
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
        if (data !== undefined) {
            this.isKAM = !!data;
            this.maybeAutoSelectTerritory();
        }
    }

    @wire(getHCPTypeOptions)
    wiredHcpTypes({ data }) {
        if (data) {
            this.hcpTypeOptions = data.map((t) => ({ label: t, value: t }));
        }
    }

    @wire(getSpecialtyOptions)
    wiredRequestSpecialties({ data }) {
        if (data) {
            this.requestSpecialtyOptions = data.map((s) => ({ label: s, value: s }));
        }
    }

    @wire(getHCOTypeOptions)
    wiredRequestHcoTypes({ data }) {
        if (data) {
            this.requestHcoTypeOptions = data.map((t) => ({ label: t, value: t }));
        }
    }

    @wire(getHCOSpecialtyOptions)
    wiredHcoSpecialties({ data }) {
        if (data) {
            this.hcoSpecialtyOptions = data.map((s) => ({ label: s, value: s }));
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

    // MARK: - Filters

    handleSearchChange(event) {
        this.searchTerm = event.target.value;
        this.debounceSearch();
    }

    handleTerritoryFilterChange(event) {
        this.territoryFilter = event.detail.value;
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
        return Math.max(1, Math.ceil((this.results || []).length / this.pageSize));
    }

    get pageSizeOptions() {
        return PAGE_SIZE_OPTIONS.map((n) => ({ label: String(n), value: String(n) }));
    }

    get pageSizeValue() {
        return String(this.pageSize);
    }

    /// Changing the page size keeps the first record that was on screen in view
    /// (rather than dumping the rep back on page 1 or past the end).
    handlePageSizeChange(event) {
        const next = Number(event.detail.value);
        if (!PAGE_SIZE_OPTIONS.includes(next) || next === this.pageSize) {
            return;
        }
        const firstIndex = (this.currentPage - 1) * this.pageSize;
        this.pageSize = next;
        this.currentPage = Math.floor(firstIndex / next) + 1;
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
            (this.results || []).map((r) => sortableNameKey(r.name).charAt(0).toUpperCase()).filter((c) => ALPHABET.includes(c))
        );
        return ALPHABET.map((letter) => ({
            letter,
            key: letter,
            navClass: available.has(letter) ? 'alpha-key' : 'alpha-key disabled',
            disabled: !available.has(letter),
        }));
    }

    // Jumping to a letter with 200+ possible rows across pages needs two
    // things, not just the page number: if the target page isn't the current
    // one, wait for that page to actually render (renderedCallback) before
    // scrolling, otherwise the row doesn't exist in the DOM yet.
    pendingScrollToId;

    handleAlphaJump(event) {
        const letter = event.currentTarget.dataset.letter;
        const index = (this.results || []).findIndex((r) => sortableNameKey(r.name).toUpperCase().startsWith(letter));
        if (index === -1) {
            return;
        }
        const targetId = this.results[index].id;
        const targetPage = Math.floor(index / this.pageSize) + 1;
        if (this.currentPage === targetPage) {
            this.scrollToRow(targetId);
        } else {
            this.pendingScrollToId = targetId;
            this.currentPage = targetPage;
        }
    }

    renderedCallback() {
        if (this.pendingScrollToId) {
            const id = this.pendingScrollToId;
            this.pendingScrollToId = null;
            this.scrollToRow(id);
        }
    }

    scrollToRow(id) {
        const row = this.template.querySelector(`li[data-id="${id}"]`);
        if (!row) {
            return;
        }
        row.scrollIntoView({ behavior: 'smooth', block: 'center' });
        row.classList.add('alpha-jump-highlight');
        window.setTimeout(() => row.classList.remove('alpha-jump-highlight'), 1600);
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

    // MARK: - Add Column (which fields the list and table view display)

    // Wrapped in try/catch: private browsing or blocked site data can make localStorage throw, and
    // "the saved columns didn't load" must never turn into "the Accounts tab is broken".
    loadColumnPreference() {
        try {
            const raw = window.localStorage.getItem(COLUMN_PREF_KEY);
            const keys = raw ? JSON.parse(raw) : null;
            const valid = Array.isArray(keys) ? keys.filter((k) => COLUMN_BY_KEY[k]) : [];
            if (valid.length > 0) {
                // Name is always shown, and always first.
                this.visibleColumnKeys = ['name', ...valid.filter((k) => k !== 'name')];
            }
        } catch (e) {
            this.visibleColumnKeys = [...DEFAULT_COLUMN_KEYS];
        }
    }

    persistColumnPreference() {
        try {
            window.localStorage.setItem(COLUMN_PREF_KEY, JSON.stringify(this.visibleColumnKeys));
        } catch (e) {
            // Best effort: the choice still applies for this session.
        }
    }

    get columnOptions() {
        const visible = new Set(this.visibleColumnKeys);
        return COLUMN_CATALOG.map((c) => ({
            key: c.key,
            label: c.label,
            isSelected: visible.has(c.key),
            isLocked: !!c.locked,
            rowClass: `column-option${visible.has(c.key) ? ' column-option-selected' : ''}${c.locked ? ' column-option-locked' : ''}`,
        }));
    }

    get visibleColumnCount() {
        return this.visibleColumnKeys.length;
    }

    handleToggleColumnMenu() {
        this.isColumnMenuOpen = !this.isColumnMenuOpen;
    }

    handleCloseColumnMenu() {
        this.isColumnMenuOpen = false;
    }

    handleToggleColumn(event) {
        const key = event.currentTarget.dataset.key;
        const column = COLUMN_BY_KEY[key];
        if (!column || column.locked) {
            return;
        }
        this.visibleColumnKeys = this.visibleColumnKeys.includes(key)
            ? this.visibleColumnKeys.filter((k) => k !== key)
            : [...this.visibleColumnKeys, key];
        this.persistColumnPreference();
    }

    handleResetColumns() {
        this.visibleColumnKeys = [...DEFAULT_COLUMN_KEYS];
        this.persistColumnPreference();
    }

    // Table view: exactly the ticked fields, then the row-open action. Sorting stays available only
    // on the columns the server can sort by (name / city / territory).
    get tableColumns() {
        const columns = this.visibleColumnKeys.map((k) => COLUMN_BY_KEY[k]).filter(Boolean).map((c) => {
            const col = { label: c.label, fieldName: c.key, type: c.type };
            if (c.sortable) col.sortable = true;
            if (c.initialWidth) col.initialWidth = c.initialWidth;
            if (c.wrapText === false) col.wrapText = false;
            return col;
        });
        return [...columns, ACTION_COLUMN];
    }

    // Minimum table width = the sum of its column widths, so a wide selection scrolls sideways inside
    // the results pane instead of squeezing every column (Name, Details) down to a few characters.
    get tableInnerStyle() {
        const total = this.tableColumns.reduce((sum, c) => sum + (c.initialWidth || 160), 0);
        return `min-width: ${total}px;`;
    }

    // "Label: value" lines for the list card: every ticked field the card doesn't already draw itself.
    listExtraFields(row) {
        const out = [];
        for (const key of this.visibleColumnKeys) {
            if (LIST_CARD_BUILT_IN.has(key)) continue;
            const c = COLUMN_BY_KEY[key];
            const v = row[key];
            if (!c || v === null || v === undefined || v === '') continue;
            const value = c.type === 'date-local' ? new Date(`${v}T00:00:00`).toLocaleDateString() : String(v);
            out.push({ key, label: c.label, value });
        }
        return out;
    }

    get rows() {
        const start = (this.currentPage - 1) * this.pageSize;
        const shown = new Set(this.visibleColumnKeys);
        return (this.results || []).slice(start, start + this.pageSize).map((r) => ({
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
            // List card: each built-in element follows its tick, and ticked extras are listed under it.
            showType: shown.has('type'),
            showSubtitle: shown.has('subtitle'),
            showCity: shown.has('city') && !!r.city,
            showTerritory: shown.has('territory') && !!r.territory,
            showKol: shown.has('isKOL') && !!r.isKOL,
            showEmerging: shown.has('isEmergingExpert') && !!r.isEmergingExpert,
            extraFields: this.listExtraFields(r),
        }));
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

    // Map markers. An account with real coordinates gets its own exact pin. Accounts with no
    // coordinates (nothing geocodes them unless a Google key is set in Geocoding_Config__mdt) are
    // grouped by city/state/country into ONE marker per place, and lightning-map geocodes that address
    // itself. Clicking a place marker lists that city's accounts (see handleMarkerSelect).
    get mapMarkers() {
        const exact = [];
        const places = new Map();
        for (const r of this.results || []) {
            if (r.latitude != null && r.longitude != null) {
                exact.push({
                    location: { Latitude: r.latitude, Longitude: r.longitude },
                    title: r.name,
                    description: r.subtitle,
                    value: r.id,
                });
            } else if (r.city || r.state) {
                const key = [r.city || '', r.state || '', r.country || ''].join('|');
                if (!places.has(key)) {
                    places.set(key, { city: r.city || '', state: r.state || '', country: r.country || '', names: [] });
                }
                places.get(key).names.push(r.name);
            }
        }
        const grouped = [...places.values()]
            .sort((a, b) => b.names.length - a.names.length)
            .map((p) => {
                const label = [p.city, p.state].filter(Boolean).join(', ');
                const shown = p.names.slice(0, 5).join(', ');
                const more = p.names.length > 5 ? ` +${p.names.length - 5} more` : '';
                const location = {};
                if (p.city) location.City = p.city;
                if (p.state) location.State = p.state;
                if (p.country) location.Country = p.country;
                return {
                    location,
                    title: `${label} — ${p.names.length} account${p.names.length === 1 ? '' : 's'}`,
                    description: `${shown}${more}`,
                    value: `place:${encodeURIComponent(p.city || p.state)}`,
                };
            });
        // lightning-map geocodes addresses one by one, so keep the total reasonable.
        return [...exact, ...grouped].slice(0, 100);
    }

    get hasMapMarkers() {
        return this.mapMarkers.length > 0;
    }

    handleMarkerSelect(event) {
        const value = event.detail.selectedMarkerValue;
        if (typeof value === 'string' && value.startsWith('place:')) {
            // A city marker: narrow the list to that city and show it.
            this.cityFilter = decodeURIComponent(value.slice('place:'.length));
            this.viewMode = 'list';
            this.runSearch();
            return;
        }
        this.selectedId = value;
        this.navigateToAccount(value);
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

    // KAM profiles have full CRUD on Sciagen_Account__c, but a brand-new HCP/HCO from
    // the web still goes through the same DCR governance gate the iPad app enforces —
    // see SciagenAccountController.isKeyAccountManager's doc comment.
    get newButtonLabel() {
        return this.isKAM ? 'New Request' : 'New';
    }

    handleOpenCreate() {
        if (this.isKAM) {
            this.requestType = 'HCP';
            this.requestFields = {};
            this.relatedHCOId = undefined;
            this.relatedHCOLabel = '';
            this.isRequesting = true;
            return;
        }
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

    // MARK: - New Request (KAM's DCR-gated create)

    get isRequestingHCP() {
        return this.requestType === 'HCP';
    }

    get requestFieldDefs() {
        return this.isRequestingHCP ? HCP_REQUEST_FIELDS : HCO_REQUEST_FIELDS;
    }

    // Each field def carries its own options array's *property name* (not the array
    // itself) so this can stay a plain getter over requestFieldDefs — the template
    // resolves {def.value}/{def.options} per row without a second, hand-kept list.
    get requestFieldRows() {
        return this.requestFieldDefs.map((def) => ({
            ...def,
            value: this.requestFields[def.key] || '',
            options: def.optionsProp ? this[def.optionsProp] : undefined,
            isPicklist: def.type === 'picklist',
            isText: def.type !== 'picklist',
        }));
    }

    get hcoFilter() {
        return { criteria: [{ fieldPath: 'Type__c', operator: 'eq', value: 'HCO' }] };
    }

    get submitRequestDisabled() {
        return this.isSubmittingRequest || (this.isRequestingHCP && !this.relatedHCOId);
    }

    handleRequestTypeChange(event) {
        this.requestType = event.detail.value;
        this.requestFields = {};
    }

    handleRequestFieldChange(event) {
        const key = event.currentTarget.dataset.field;
        const value = event.detail.value;
        this.requestFields = { ...this.requestFields, [key]: value };
    }

    handleRelatedHCOChange(event) {
        this.relatedHCOId = event.detail.recordId || undefined;
    }

    handleCloseRequest() {
        this.isRequesting = false;
    }

    async handleSubmitRequest() {
        if (this.isRequestingHCP && !this.relatedHCOId) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Affiliated HCO required',
                message: 'Select the HCO this HCP is affiliated with.',
                variant: 'error',
            }));
            return;
        }
        this.isSubmittingRequest = true;
        try {
            await submitNewAccountRequest({
                acctType: this.requestType,
                fields: this.requestFields,
                relatedHCOId: this.isRequestingHCP ? this.relatedHCOId : null,
            });
            this.isRequesting = false;
            this.dispatchEvent(new ShowToastEvent({
                title: 'Request submitted',
                message: 'Sent for review in DCR Review — the account is created once a steward approves it.',
                variant: 'success',
            }));
        } catch (e) {
            this.dispatchEvent(new ShowToastEvent({ title: 'Couldn’t submit request', message: reduceError(e), variant: 'error' }));
        } finally {
            this.isSubmittingRequest = false;
        }
    }
}

function reduceError(error) {
    if (error?.body?.message) {
        return error.body.message;
    }
    return 'An unknown error occurred.';
}