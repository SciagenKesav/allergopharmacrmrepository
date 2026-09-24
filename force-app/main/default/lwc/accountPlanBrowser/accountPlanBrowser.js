import { LightningElement, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { refreshApex } from '@salesforce/apex';
import getHomeDashboardData from '@salesforce/apex/AccountPlanHomeDashboardController.getHomeDashboardData';
import searchAccountPlans from '@salesforce/apex/AccountPlanHomeDashboardController.searchAccountPlans';
import { BRAND, pillStyle } from 'c/sciagenColors';

/// "Account Plans" home page — a KPI summary + searchable/filterable table
/// across every plan, plus a Dashboard tab. Reuses the same Apex
/// (AccountPlanHomeDashboardController) kamHomeDashboard already calls: the
/// two surfaces stay in lockstep instead of each maintaining their own query.
///
/// Plans are fetched ONCE, unfiltered (searchAccountPlans('', '', '')) — the
/// KPI tiles always reflect every plan; searchTerm/statusFilter only narrow
/// the table below them, computed client-side (this dataset is KAM-scoped,
/// not bulk, so a round trip per keystroke isn't worth it).
const STATUS_COLOR = { Draft: BRAND.subtle, Active: BRAND.primary, Completed: BRAND.accent, 'On Hold': BRAND.amber };
const STATUS_PILLS = [
    { label: 'All', value: '' },
    { label: 'Active', value: 'Active' },
    { label: 'Draft', value: 'Draft' },
    { label: 'Completed', value: 'Completed' },
    { label: 'On Hold', value: 'On Hold' },
];
const BUCKET_COLOR = { 'In Progress': BRAND.primary, Postponed: BRAND.amber, Achieved: BRAND.accent };

export default class AccountPlanBrowser extends NavigationMixin(LightningElement) {
    mode = 'plans'; // 'plans' | 'dashboard'
    isLoading = true;
    error;
    allPlans = [];

    searchTerm = '';
    statusFilter = '';
    statusPills = STATUS_PILLS;

    showNewPlan = false;

    dashboardData;
    isDashboardLoading = true;
    dashboardError;
    dashboardWireResult;

    connectedCallback() {
        this.loadPlans();
    }

    async loadPlans() {
        this.isLoading = true;
        this.error = undefined;
        try {
            this.allPlans = await searchAccountPlans({ searchTerm: '', statusFilter: '', stageFilter: '' });
        } catch (e) {
            this.error = e.body?.message || 'Failed to load Account Plans.';
            this.allPlans = [];
        } finally {
            this.isLoading = false;
        }
    }

    @wire(getHomeDashboardData)
    wiredDashboard(result) {
        this.dashboardWireResult = result;
        const { data, error } = result;
        this.isDashboardLoading = false;
        if (data) {
            this.dashboardData = data;
            this.dashboardError = undefined;
        } else if (error) {
            this.dashboardError = error.body?.message || 'Failed to load the dashboard.';
        }
    }

    // MARK: - Mode toggle

    get isPlansMode() {
        return this.mode === 'plans';
    }

    get isDashboardMode() {
        return this.mode === 'dashboard';
    }

    get plansTabClass() {
        return this.isPlansMode ? 'mode-button mode-button-active' : 'mode-button';
    }

    get dashboardTabClass() {
        return this.isDashboardMode ? 'mode-button mode-button-active' : 'mode-button';
    }

    handleShowPlans() {
        this.mode = 'plans';
    }

    handleShowDashboard() {
        this.mode = 'dashboard';
    }

    // MARK: - KPI tiles (always over the full, unfiltered set)

    get totalPlans() {
        return this.allPlans.length;
    }

    get activeCount() {
        return this.allPlans.filter((p) => p.status === 'Active').length;
    }

    get draftCount() {
        return this.allPlans.filter((p) => p.status === 'Draft').length;
    }

    get completedCount() {
        return this.allPlans.filter((p) => p.status === 'Completed').length;
    }

    get onHoldCount() {
        return this.allPlans.filter((p) => p.status === 'On Hold').length;
    }

    get avgProgress() {
        if (this.allPlans.length === 0) return 0;
        const sum = this.allPlans.reduce((s, p) => s + (p.progressPercent || 0), 0);
        return Math.round(sum / this.allPlans.length);
    }

    // Open Items / Overdue — summed across every plan's action items (not
    // averaged like progress%, since these are counts of actual items reps
    // still need to act on).
    get openItemsCount() {
        return this.allPlans.reduce((s, p) => s + ((p.totalActionItems || 0) - (p.completedActionItems || 0)), 0);
    }

    get overdueCount() {
        return this.allPlans.reduce((s, p) => s + (p.overdueActionItems || 0), 0);
    }

    // Goal Attainment — completed/total action items across ALL plans
    // (weighted by each plan's actual item count), distinct from Avg.
    // Progress which averages each plan's own % equally regardless of size.
    get goalAttainment() {
        const totalItems = this.allPlans.reduce((s, p) => s + (p.totalActionItems || 0), 0);
        if (totalItems === 0) return 0;
        const totalCompleted = this.allPlans.reduce((s, p) => s + (p.completedActionItems || 0), 0);
        return Math.round((totalCompleted / totalItems) * 100);
    }

    // MARK: - Search + status filter (client-side, over allPlans)

    handleSearchChange(event) {
        this.searchTerm = event.target.value;
    }

    handleStatusFilterClick(event) {
        this.statusFilter = event.currentTarget.dataset.value;
    }

    get statusPillItems() {
        return this.statusPills.map((s) => ({
            ...s,
            buttonClass: s.value === this.statusFilter ? 'status-pill status-pill-active' : 'status-pill',
        }));
    }

    get filteredPlans() {
        const q = this.searchTerm.trim().toLowerCase();
        return this.allPlans.filter((p) => {
            if (this.statusFilter && p.status !== this.statusFilter) return false;
            if (!q) return true;
            const haystack = [p.title, p.hcoName, p.hcpName, p.division, p.ownerName, p.status, p.appliedProducts]
                .filter(Boolean)
                .join(' ')
                .toLowerCase();
            return haystack.includes(q);
        });
    }

    get hasPlans() {
        return this.filteredPlans.length > 0;
    }

    get planRows() {
        return this.filteredPlans.map((p) => {
            const pct = Math.round(p.progressPercent || 0);
            const color = STATUS_COLOR[p.status] || BRAND.primary;
            const open = (p.totalActionItems || 0) - (p.completedActionItems || 0);
            return {
                ...p,
                statusStyle: pillStyle(color),
                ringStyle: `--pct:${pct};--ring-color:#${color};`,
                progressLabel: `${pct}%`,
                actionItemsLabel: `${p.completedActionItems || 0}/${p.totalActionItems || 0}`,
                hasOpenItems: open > 0,
                openLabel: `${open} open`,
                appliedProductsDisplay: p.appliedProducts || '—',
                hcoNameDisplay: p.hcoName || '—',
                hcpNameDisplay: p.hcpName || '—',
                divisionDisplay: p.division || '—',
                startDateDisplay: p.startDate || '—',
                endDateDisplay: p.endDate || '—',
                ownerNameDisplay: p.ownerName || '—',
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

    // Reloads everything the page shows: the plan list/KPIs (imperative) and
    // the Dashboard tab's wired data (refreshApex — a plain re-call of
    // loadPlans() alone would leave the Dashboard tab showing stale numbers
    // if a rep refreshes while on it).
    handleRefresh() {
        this.loadPlans();
        if (this.dashboardWireResult) {
            refreshApex(this.dashboardWireResult);
        }
    }

    // MARK: - New Plan (form lives in c-new-account-plan-modal — shared with
    // kamHomeDashboard so both Account-Plan-list pages offer the same create
    // flow instead of each keeping its own copy)

    handleNewPlan() {
        this.showNewPlan = true;
    }

    handleCloseNewPlan() {
        this.showNewPlan = false;
    }

    // Fires on every successful create, including "Save & New" (keepOpen
    // true) — always worth refreshing the list/KPIs; only navigate away for
    // a real "Submit" (keepOpen false), since the modal stays open otherwise.
    handleNewPlanCreated(event) {
        this.loadPlans();
        if (!event.detail.keepOpen) {
            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: { recordId: event.detail.id, objectApiName: 'Account_Plan__c', actionName: 'view' },
            });
        }
    }

    // MARK: - Dashboard tab (same data/shape as kamHomeDashboard)

    get hasPlanProgress() {
        return this.dashboardData?.planProgress?.length > 0;
    }

    get planProgressRows() {
        return (this.dashboardData?.planProgress || []).map((p) => ({
            key: p.planId,
            label: p.planName,
            sub: `${p.completedActionItems}/${p.totalActionItems}`,
            barStyle: `width: ${p.progressPercent || 0}%;`,
        }));
    }

    get hasStrategyProgress() {
        return this.dashboardData?.strategyProgress?.length > 0;
    }

    get strategyProgressRows() {
        return (this.dashboardData?.strategyProgress || []).map((s, i) => ({
            key: `${s.planName}-${s.strategyName}-${i}`,
            label: `${s.strategyName} (${s.planName})`,
            sub: `${s.completedActivities}/${s.totalActivities}`,
            barStyle: `width: ${s.progressPercent || 0}%;`,
        }));
    }

    get hasTeamObjectiveAchievement() {
        return this.dashboardData?.teamObjectiveAchievement?.length > 0;
    }

    get teamObjectiveRows() {
        const rows = this.dashboardData?.teamObjectiveAchievement || [];
        const maxCount = Math.max(1, ...rows.map((r) => r.count));
        return rows.map((r) => ({
            key: r.bucket,
            label: r.bucket,
            sub: String(r.count),
            barStyle: `width: ${(r.count / maxCount) * 100}%; background: #${BUCKET_COLOR[r.bucket] || BRAND.subtle};`,
        }));
    }

    get hasRecentActivity() {
        return this.dashboardData?.recentActivity?.length > 0;
    }

    get recentActivityRows() {
        const rows = this.dashboardData?.recentActivity || [];
        const maxCount = Math.max(1, ...rows.map((r) => r.count));
        return rows.map((r, i) => ({
            key: `${r.planName}-${r.assignee}-${i}`,
            label: `${r.assignee} — ${r.planName}`,
            sub: String(r.count),
            barStyle: `width: ${(r.count / maxCount) * 100}%;`,
        }));
    }
}