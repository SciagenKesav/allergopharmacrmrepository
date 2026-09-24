import { LightningElement, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { refreshApex } from '@salesforce/apex';
import getHomeDashboardData from '@salesforce/apex/AccountPlanHomeDashboardController.getHomeDashboardData';
import searchAccountPlans from '@salesforce/apex/AccountPlanHomeDashboardController.searchAccountPlans';
import { BRAND, pillStyle } from 'c/sciagenColors';

const BUCKET_COLOR = { 'In Progress': BRAND.primary, Postponed: BRAND.amber, Achieved: BRAND.accent };
const STATUS_COLOR = { Draft: BRAND.subtle, Active: BRAND.primary, Completed: BRAND.accent, 'On Hold': BRAND.amber };
const HEALTH_COLOR = { Good: BRAND.accent, 'At Risk': BRAND.amber, Poor: BRAND.red };

const STATUS_OPTIONS = [
    { label: 'All Statuses', value: '' },
    { label: 'Draft', value: 'Draft' },
    { label: 'Active', value: 'Active' },
    { label: 'Completed', value: 'Completed' },
    { label: 'On Hold', value: 'On Hold' },
];
const STAGE_OPTIONS = [
    { label: 'All Stages', value: '' },
    { label: 'Prospect', value: 'Prospect' },
    { label: 'Early', value: 'Early' },
    { label: 'Mid', value: 'Mid' },
    { label: 'Partnership', value: 'Partnership' },
    { label: 'Synergistic', value: 'Synergistic' },
];
const EXPORT_OPTIONS = [
    { label: 'Download as PDF', value: 'pdf' },
    { label: 'Download as CSV', value: 'csv' },
];
const EXPORT_COLUMNS = [
    { key: 'title', label: 'Title' },
    { key: 'accountName', label: 'Account' },
    { key: 'status', label: 'Status' },
    { key: 'stage', label: 'Stage' },
    { key: 'health', label: 'Health' },
    { key: 'ownerName', label: 'Owner' },
];

export default class KamHomeDashboard extends NavigationMixin(LightningElement) {
    mode = 'plan'; // 'plan' | 'dashboard'

    data;
    error;
    isLoading = true;
    wiredDataResult;

    searchTerm = '';
    statusFilter = '';
    stageFilter = '';
    plans = [];
    isLoadingPlans = true;
    statusOptions = STATUS_OPTIONS;
    stageOptions = STAGE_OPTIONS;
    exportOptions = EXPORT_OPTIONS;

    showNewPlan = false;

    connectedCallback() {
        this.loadPlans();
    }

    @wire(getHomeDashboardData)
    wiredData(result) {
        this.wiredDataResult = result;
        const { data, error } = result;
        this.isLoading = false;
        if (data) {
            this.data = data;
            this.error = undefined;
        } else if (error) {
            this.error = error.body?.message || 'Failed to load the KAM dashboard.';
        }
    }

    // MARK: - Plan/Dashboard toggle

    get isPlanMode() {
        return this.mode === 'plan';
    }

    get isDashboardMode() {
        return this.mode === 'dashboard';
    }

    get planTabClass() {
        return this.isPlanMode ? 'mode-button mode-button-active' : 'mode-button';
    }

    get dashboardTabClass() {
        return this.isDashboardMode ? 'mode-button mode-button-active' : 'mode-button';
    }

    // MARK: - KPI tiles — over whatever searchAccountPlans currently returned
    // (this.plans), so the tiles always agree with the table right below
    // them instead of reflecting a separately-fetched, unfiltered set.

    get totalPlans() {
        return this.plans.length;
    }

    get activeCount() {
        return this.plans.filter((p) => p.status === 'Active').length;
    }

    get draftCount() {
        return this.plans.filter((p) => p.status === 'Draft').length;
    }

    get completedCount() {
        return this.plans.filter((p) => p.status === 'Completed').length;
    }

    get onHoldCount() {
        return this.plans.filter((p) => p.status === 'On Hold').length;
    }

    get avgProgress() {
        if (this.plans.length === 0) return 0;
        const sum = this.plans.reduce((s, p) => s + (p.progressPercent || 0), 0);
        return Math.round(sum / this.plans.length);
    }

    // Open Items / Overdue — summed across every plan's action items (not
    // averaged like progress%, since these are counts of actual items reps
    // still need to act on).
    get openItemsCount() {
        return this.plans.reduce((s, p) => s + ((p.totalActionItems || 0) - (p.completedActionItems || 0)), 0);
    }

    get overdueCount() {
        return this.plans.reduce((s, p) => s + (p.overdueActionItems || 0), 0);
    }

    // Goal Attainment — completed/total action items across ALL plans
    // (weighted by each plan's actual item count), distinct from Avg.
    // Progress which averages each plan's own % equally regardless of size.
    get goalAttainment() {
        const totalItems = this.plans.reduce((s, p) => s + (p.totalActionItems || 0), 0);
        if (totalItems === 0) return 0;
        const totalCompleted = this.plans.reduce((s, p) => s + (p.completedActionItems || 0), 0);
        return Math.round((totalCompleted / totalItems) * 100);
    }

    handleShowPlan() {
        this.mode = 'plan';
    }

    handleShowDashboard() {
        this.mode = 'dashboard';
    }

    // Reloads both halves of this page: the plan list (imperative) and the
    // dashboard charts (refreshApex) — same reasoning as accountPlanBrowser's
    // handleRefresh, the other page built on this same Apex.
    handleRefresh() {
        this.loadPlans();
        if (this.wiredDataResult) {
            refreshApex(this.wiredDataResult);
        }
    }

    // MARK: - New Plan (shared modal — see accountPlanBrowser.js's own
    // handleNewPlanCreated for why keepOpen only refreshes instead of
    // navigating away)

    handleNewPlan() {
        this.showNewPlan = true;
    }

    handleCloseNewPlan() {
        this.showNewPlan = false;
    }

    handleNewPlanCreated(event) {
        this.loadPlans();
        if (!event.detail.keepOpen) {
            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: { recordId: event.detail.id, objectApiName: 'Account_Plan__c', actionName: 'view' },
            });
        }
    }

    async loadPlans() {
        this.isLoadingPlans = true;
        try {
            this.plans = await searchAccountPlans({
                searchTerm: this.searchTerm,
                statusFilter: this.statusFilter,
                stageFilter: this.stageFilter,
            });
        } catch (e) {
            this.plans = [];
        } finally {
            this.isLoadingPlans = false;
        }
    }

    handleSearchChange(event) {
        this.searchTerm = event.target.value;
        this.loadPlans();
    }

    handleStatusFilterChange(event) {
        this.statusFilter = event.detail.value;
        this.loadPlans();
    }

    handleStageFilterChange(event) {
        this.stageFilter = event.detail.value;
        this.loadPlans();
    }

    get hasPlans() {
        return this.plans.length > 0;
    }

    get hasNoPlans() {
        return !this.hasPlans;
    }

    // MARK: - Export (currently filtered/visible plans, same rows as the table)

    // The combobox is used as a one-shot action picker, not a persistent
    // filter — reset it back to blank right after firing so it always reads
    // "Export" again rather than sticking on "Download as PDF/CSV".
    handleExportChange(event) {
        const format = event.detail.value;
        const combobox = event.target;
        try {
            if (format === 'csv') {
                this.exportAsCSV();
            } else if (format === 'pdf') {
                this.exportAsPDF();
            }
        } catch (e) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Export failed',
                message: `${e.name || 'Error'}: ${e.message || e}`,
                variant: 'error',
            }));
        }
        combobox.value = '';
    }

    // Uses the hidden <a class="export-download-link"> already sitting in
    // this component's own template rather than a document.createElement +
    // document.body.appendChild/removeChild pair, to keep the whole
    // operation inside the component's own rendered DOM.
    //
    // Confirmed live: "Lightning Web Security error: Unsupported MIME type"
    // fires from Blob + URL.createObjectURL regardless of the Blob's `type`
    // string — a bare 'text/csv' still hits it. LWS's SecureURL wrapper only
    // vets object URLs against its own small internal allow-list, and CSV
    // isn't reliably on it (a long-standing, widely-reported LWS limitation,
    // not something fixable by tweaking the MIME string further). A `data:`
    // URI sidesteps `createObjectURL` entirely — LWS never gets a say on it —
    // so that's what actually gets a CSV download out of this component.
    exportAsCSV() {
        const header = EXPORT_COLUMNS.map((c) => this.csvEscape(c.label)).join(',');
        const rows = this.plans.map((p) => EXPORT_COLUMNS.map((c) => this.csvEscape(p[c.key])).join(','));
        const csv = [header, ...rows].join('\r\n');
        const link = this.template.querySelector('a.export-download-link');
        link.href = `data:text/csv;charset=utf-8,${encodeURIComponent(csv)}`;
        link.download = `Account_Plans_${this.exportTimestamp()}.csv`;
        link.click();
    }

    // No PDF-generation library is available in this org (Export to
    // PowerPoint on the plan's own Export tab is a stub for the same
    // reason), so this generates a real server-rendered PDF via a
    // Visualforce page (AccountPlanExportPdf, renderAs="pdf") that reuses
    // the exact same searchAccountPlans query as this list — same filters,
    // same rows, an actual downloadable .pdf rather than a print dialog.
    exportAsPDF() {
        const params = new URLSearchParams({
            searchTerm: this.searchTerm || '',
            statusFilter: this.statusFilter || '',
            stageFilter: this.stageFilter || '',
        });
        window.open(`/apex/AccountPlanExportPdf?${params.toString()}`, '_blank');
    }

    csvEscape(value) {
        const str = value === null || value === undefined ? '' : String(value);
        return /[",\r\n]/.test(str) ? `"${str.replace(/"/g, '""')}"` : str;
    }

    exportTimestamp() {
        const d = new Date();
        const pad = (n) => String(n).padStart(2, '0');
        return `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}_${pad(d.getHours())}${pad(d.getMinutes())}`;
    }

    get planRows() {
        return this.plans.map((p) => {
            const pct = Math.max(0, Math.min(100, Math.round(p.progressPercent || 0)));
            return {
                ...p,
                statusPillStyle: pillStyle(STATUS_COLOR[p.status]),
                stagePillStyle: pillStyle(BRAND.violet),
                healthPillStyle: pillStyle(HEALTH_COLOR[p.health]),
                // conic-gradient donut ring — --pct drives both the filled arc
                // and (via calc()) how far around it sweeps before falling back
                // to the plain hairline track color for the remainder.
                progressRingStyle: `--pct:${pct};`,
                progressLabel: `${pct}%`,
            };
        });
    }

    handlePlanClick(event) {
        const planId = event.currentTarget.dataset.id;
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: planId, objectApiName: 'Account_Plan__c', actionName: 'view' },
        });
    }

    get hasStrategyProgress() {
        return this.data?.strategyProgress?.length > 0;
    }

    get strategyProgressRows() {
        return (this.data?.strategyProgress || []).map((s, i) => ({
            key: `${s.planName}-${s.strategyName}-${i}`,
            label: `${s.strategyName} (${s.planName})`,
            sub: `${s.completedActivities}/${s.totalActivities}`,
            barStyle: `width: ${s.progressPercent || 0}%;`,
        }));
    }

    get hasPlanProgress() {
        return this.data?.planProgress?.length > 0;
    }

    get planProgressRows() {
        return (this.data?.planProgress || []).map((p) => ({
            key: p.planId,
            label: p.planName,
            sub: `${p.completedActionItems}/${p.totalActionItems}`,
            barStyle: `width: ${p.progressPercent || 0}%;`,
        }));
    }

    get hasRecentActivity() {
        return this.data?.recentActivity?.length > 0;
    }

    get recentActivityRows() {
        const rows = this.data?.recentActivity || [];
        const maxCount = Math.max(1, ...rows.map((r) => r.count));
        return rows.map((r, i) => ({
            key: `${r.planName}-${r.assignee}-${i}`,
            label: `${r.assignee} — ${r.planName}`,
            sub: String(r.count),
            barStyle: `width: ${(r.count / maxCount) * 100}%;`,
        }));
    }

    get hasTeamObjectiveAchievement() {
        return this.data?.teamObjectiveAchievement?.length > 0;
    }

    get teamObjectiveRows() {
        const rows = this.data?.teamObjectiveAchievement || [];
        const maxCount = Math.max(1, ...rows.map((r) => r.count));
        return rows.map((r) => ({
            key: r.bucket,
            label: r.bucket,
            sub: String(r.count),
            barStyle: `width: ${(r.count / maxCount) * 100}%; background: #${BUCKET_COLOR[r.bucket] || BRAND.subtle};`,
        }));
    }
}