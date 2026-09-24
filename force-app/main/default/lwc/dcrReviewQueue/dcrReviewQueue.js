import { LightningElement } from 'lwc';
import getDCRQueue from '@salesforce/apex/DCRReviewController.getDCRQueue';
import { pillStyle, DCR_STATUS_COLOR } from 'c/sciagenColors';

const STATUS_OPTIONS = [
    { label: 'All Statuses', value: '' },
    { label: 'Pending Approval', value: 'Pending Approval' },
    { label: 'Approved', value: 'Approved' },
    { label: 'Rejected', value: 'Rejected' },
];

const TYPE_OPTIONS = [
    { label: 'All Types', value: '' },
    { label: 'New HCP', value: 'New HCP' },
    { label: 'New HCO', value: 'New HCO' },
    { label: 'Edit HCP', value: 'Edit HCP' },
    { label: 'Edit HCO', value: 'Edit HCO' },
];

// Fixed order for the summary pills — matches DCR_STATUS_COLOR's own key
// order in sciagenColors.js.
const STATUSES = ['Pending Approval', 'Approved', 'Rejected'];

export default class DcrReviewQueue extends LightningElement {
    allItems = [];
    statusFilter = '';
    typeFilter = '';
    searchTerm = '';
    selectedId;
    isLoading = false;
    error;

    statusOptions = STATUS_OPTIONS;
    typeOptions = TYPE_OPTIONS;

    connectedCallback() {
        this.loadQueue();
    }

    async loadQueue() {
        this.isLoading = true;
        this.error = undefined;
        try {
            this.allItems = await getDCRQueue();
        } catch (e) {
            this.error = reduceError(e);
            this.allItems = [];
        } finally {
            this.isLoading = false;
        }
    }

    handleSearchChange(event) {
        this.searchTerm = event.target.value;
    }

    handleStatusFilterChange(event) {
        this.statusFilter = event.detail.value;
    }

    handleTypeFilterChange(event) {
        this.typeFilter = event.detail.value;
    }

    handleSelect(event) {
        this.selectedId = event.currentTarget.dataset.id;
    }

    // Fired by c-dcr-review-detail after a successful approve/reject — the
    // row's own status pill needs a fresh queue fetch to reflect it.
    handleDecided() {
        this.loadQueue();
    }

    get summaryPills() {
        const counts = { 'Pending Approval': 0, Approved: 0, Rejected: 0 };
        for (const item of this.allItems) {
            if (counts[item.status] !== undefined) counts[item.status] += 1;
        }
        return STATUSES.map((status) => ({
            status,
            count: counts[status],
            style: pillStyle(DCR_STATUS_COLOR[status]),
        }));
    }

    get filteredItems() {
        const term = this.searchTerm.trim().toLowerCase();
        return this.allItems.filter((item) => {
            if (this.statusFilter && item.status !== this.statusFilter) return false;
            if (this.typeFilter && item.type !== this.typeFilter) return false;
            if (term && !(item.subjectName || '').toLowerCase().includes(term)) return false;
            return true;
        });
    }

    get rows() {
        return this.filteredItems.map((item) => ({
            ...item,
            rowClass: item.id === this.selectedId ? 'result-row selected' : 'result-row',
            statusStyle: pillStyle(DCR_STATUS_COLOR[item.status]),
        }));
    }

    get hasResults() {
        return this.rows.length > 0;
    }

    get hasSelection() {
        return !!this.selectedId;
    }
}

function reduceError(error) {
    if (error?.body?.message) {
        return error.body.message;
    }
    return 'An unknown error occurred.';
}