import { LightningElement } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getMyCallReports from '@salesforce/apex/SciagenCVRController.getMyCallReports';
import { pillStyle, callStatusColor } from 'c/sciagenColors';

const DAY_MS = 24 * 60 * 60 * 1000;

function toDateOnly(d) {
    return new Date(d.getFullYear(), d.getMonth(), d.getDate());
}
// See mySchedule.js's localDayKey for why this can't be `.toISOString().slice(0,10)`.
function isoDate(d) {
    const year = d.getFullYear();
    const month = String(d.getMonth() + 1).padStart(2, '0');
    const day = String(d.getDate()).padStart(2, '0');
    return `${year}-${month}-${day}`;
}

/// "Call Reports" — top-level browser for the rep's own Call_Visit_Report__c
/// records, modeled on mySchedule.js's container/list pattern (owns the fetch +
/// filter state; callVisitReportDetail is the presentational per-record editor).
export default class CallVisitReportBrowser extends NavigationMixin(LightningElement) {
    selectedDate = toDateOnly(new Date());
    reports = [];
    isLoading = false;

    searchTerm = '';
    status = '';

    showDetail = false;
    editingId = null;
    formDefaultHcpId = null;
    formDefaultHcoId = null;

    connectedCallback() {
        this.loadReports();
    }

    get rangeStart() {
        return this.selectedDate;
    }

    get rangeEnd() {
        const end = new Date(this.selectedDate);
        end.setDate(end.getDate() + 13);
        return end;
    }

    get rangeLabel() {
        const fmt = (d) => d.toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric' });
        return `${fmt(this.rangeStart)} – ${fmt(this.rangeEnd)}`;
    }

    async loadReports() {
        this.isLoading = true;
        try {
            this.reports = await getMyCallReports({
                startDate: isoDate(this.rangeStart), endDate: isoDate(this.rangeEnd), status: this.status || null,
            });
        } catch (e) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Couldn’t load call reports', message: e.body?.message || 'Try again.', variant: 'error',
            }));
            this.reports = [];
        } finally {
            this.isLoading = false;
        }
    }

    handlePrev() {
        this.selectedDate = new Date(this.selectedDate.getTime() - 14 * DAY_MS);
        this.loadReports();
    }

    handleNext() {
        this.selectedDate = new Date(this.selectedDate.getTime() + 14 * DAY_MS);
        this.loadReports();
    }

    handleToday() {
        this.selectedDate = toDateOnly(new Date());
        this.loadReports();
    }

    get statusOptions() {
        return [
            { label: 'All Statuses', value: '' },
            { label: 'Draft', value: 'Draft' },
            { label: 'Saved', value: 'Saved' },
            { label: 'Submitted', value: 'Submitted' },
        ];
    }

    handleStatusChange(event) {
        this.status = event.detail.value;
        this.loadReports();
    }

    handleSearchChange(event) {
        this.searchTerm = event.target.value;
    }

    get filteredReports() {
        const rows = (this.reports || []).map((r) => ({
            ...r,
            displayName: r.hcpName || r.hcoName || 'Untitled visit',
            statusStyle: pillStyle(callStatusColor(r.recordStatus)),
        }));
        if (!this.searchTerm) { return rows; }
        const term = this.searchTerm.toLowerCase();
        return rows.filter((r) => `${r.hcpName || ''} ${r.hcoName || ''}`.toLowerCase().includes(term));
    }

    get hasResults() {
        return this.filteredReports.length > 0;
    }

    handleNewReport() {
        this.editingId = null;
        this.formDefaultHcpId = null;
        this.formDefaultHcoId = null;
        this.showDetail = true;
    }

    handleRowClick(event) {
        this.editingId = event.currentTarget.dataset.id;
        this.formDefaultHcpId = null;
        this.formDefaultHcoId = null;
        this.showDetail = true;
    }

    handleRecordCreated() {
        this.loadReports();
    }

    handleCloseDetail() {
        this.showDetail = false;
        this.editingId = null;
        this.loadReports();
    }

    navigateToAccount(event) {
        event.stopPropagation();
        const id = event.currentTarget.dataset.accountId;
        if (!id) { return; }
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: id, objectApiName: 'Sciagen_Account__c', actionName: 'view' },
        });
    }
}