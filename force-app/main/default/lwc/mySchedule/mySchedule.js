import { LightningElement, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import LightningConfirm from 'lightning/confirm';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { deleteRecord, updateRecord } from 'lightning/uiRecordApi';
import getPlannedCallsForUser from '@salesforce/apex/SciagenScheduleController.getPlannedCallsForUser';
import getCustomListMemberIds from '@salesforce/apex/SciagenScheduleController.getCustomListMemberIds';
import getTimeOff from '@salesforce/apex/SciagenScheduleController.getTimeOff';
import getSchedulePickerData from '@salesforce/apex/SciagenScheduleController.getSchedulePickerData';
import isKeyAccountManager from '@salesforce/apex/SciagenAccountController.isKeyAccountManager';
import getCustomLists from '@salesforce/apex/SciagenAccountController.getCustomLists';
import getSavedViews from '@salesforce/apex/SciagenAccountController.getSavedViews';
import getTerritoryOptions from '@salesforce/apex/SciagenAccountController.getTerritoryOptions';
import getSpecialtyOptions from '@salesforce/apex/SciagenAccountController.getSpecialtyOptions';
import { pillStyle, visitState } from 'c/sciagenColors';

const DAY_MS = 24 * 60 * 60 * 1000;

function toDateOnly(d) {
    return new Date(d.getFullYear(), d.getMonth(), d.getDate());
}
// LOCAL calendar-day key (Y-M-D) — deliberately NOT `.toISOString().slice(0,10)`,
// which reinterprets a local-midnight Date in UTC and rolls back a day in any
// negative-offset timezone (confirmed live: every day column came out one day
// behind its own header label). Every "which day is this on" comparison in
// this feature (here, scheduleWeekGrid.js, scheduleMap.js) must go through
// this same local-day key, including callDateTime values from Salesforce —
// `new Date(isoString)` parses to the correct instant, then this formats it
// back out in the viewer's local calendar day, matching what's on screen.
function localDayKey(d) {
    const year = d.getFullYear();
    const month = String(d.getMonth() + 1).padStart(2, '0');
    const day = String(d.getDate()).padStart(2, '0');
    return `${year}-${month}-${day}`;
}
function isoDate(d) {
    return localDayKey(toDateOnly(d));
}
function startOfWeek(d) {
    const day = d.getDay(); // 0 = Sun
    const diff = day === 0 ? -6 : 1 - day; // Monday-first week
    const monday = new Date(d);
    monday.setDate(d.getDate() + diff);
    return toDateOnly(monday);
}

/// "My Schedule" — Salesforce LWC port of the iOS CalendarPlannerView. Owns all
/// filter state and the fetched Planned_Call__c list; child components
/// (scheduleFilterBar, scheduleCallForm, and per-mode views) are presentational.
/// See the "My Schedule — Salesforce LWC Port" plan for the full feature mapping.
export default class MySchedule extends NavigationMixin(LightningElement) {
    viewMode = 'agenda'; // 'agenda' | 'week' | 'month' | 'map'
    selectedDate = toDateOnly(new Date());
    calls = [];
    timeOff = [];
    isKam = false;

    // A Key Account Manager can't delete a Completed visit (enforced server-side too
    // by PlannedCallDeleteGuard) — so the Delete menu item is hidden for them there.
    @wire(isKeyAccountManager)
    wiredKam({ data }) {
        if (data !== undefined) this.isKam = data === true;
    }
    isLoading = false;

    searchTerm = '';
    kind = 'All';
    specialty = '';
    territory = '';
    status = '';
    callCategory = '';
    customListId = '';
    customListMemberIds = [];

    specialtyOptions = [];
    territoryOptions = [];
    customListOptions = [];
    savedViewOptions = [];

    // Manager viewing a KAM's schedule (My Schedule stays read-only while this is set —
    // see viewingOtherUser). isManager gates whether the picker shows at all; kamOptions
    // is the manager's own territory-scoped KAM list (empty if they have no subordinates).
    // pickerMode: 'SELF' (a KAM: no picker, just "My Schedule"), 'MANAGER' (their own KAMs),
    // 'ADMIN' (Business Admin / System Admin: Region -> Territory -> KAM).
    pickerMode = 'SELF';
    kamOptions = [];
    pickerTerritories = [];
    selectedRegionId = '';
    selectedTerritoryId = '';
    selectedUserId = '';

    showForm = false;
    editingCallId = null;
    formDefaultHcpId = null;
    formDefaultHcoId = null;
    formDefaultDateTime = null;

    showCallReport = false;
    callReportRecordId = null;
    callReportDefaultHcpId = null;
    callReportDefaultHcoId = null;
    callReportSourcePlannedCallId = null;

    connectedCallback() {
        this.loadFilterOptions();
        this.loadCalls();
    }

    async loadFilterOptions() {
        try {
            const [specialties, territories, lists, views] = await Promise.all([
                getSpecialtyOptions(), getTerritoryOptions(), getCustomLists(), getSavedViews(),
            ]);
            this.specialtyOptions = specialties;
            this.territoryOptions = territories;
            this.customListOptions = lists;
            this.savedViewOptions = views;
        } catch (e) {
            // Filter option lists are a convenience, not core functionality — fail quietly.
        }

        try {
            const data = await getSchedulePickerData();
            this.pickerMode = data.mode || 'SELF';
            this.kamOptions = data.kams || [];
            this.pickerTerritories = data.territories || [];
        } catch (e) {
            // Same reasoning: the picker is a convenience for managers, not core
            // functionality for the (much more common) rep viewing their own schedule.
            this.pickerMode = 'SELF';
            this.kamOptions = [];
            this.pickerTerritories = [];
        }
    }

    get isSelfMode() { return this.pickerMode === 'SELF'; }
    get isAdminMode() { return this.pickerMode === 'ADMIN'; }

    // Manager: a single "My Schedule / <KAM>" picker over their own KAMs.
    get showKamPicker() {
        return this.pickerMode === 'MANAGER' && this.kamOptions.length > 0;
    }

    get kamPickerOptions() {
        return [
            { label: 'My Schedule', value: '' },
            ...this.kamOptions.map((k) => ({ label: `${k.name} — ${k.territoryName}`, value: k.id })),
        ];
    }

    // Business Admin: Region, then Territory, then the users in that territory.
    get regionOptions() {
        const regions = this.pickerTerritories.filter((t) => t.type === 'Region' || (!t.parentId && this.pickerTerritories.some((c) => c.parentId === t.id)));
        return [{ label: 'All regions', value: '' }, ...regions.map((r) => ({ label: r.name, value: r.id }))];
    }

    get regionIds() {
        return new Set(this.regionOptions.map((o) => o.value).filter(Boolean));
    }

    get adminTerritoryOptions() {
        let list = this.pickerTerritories.filter((t) => !this.regionIds.has(t.id));
        if (this.selectedRegionId) list = list.filter((t) => t.parentId === this.selectedRegionId);
        return [{ label: 'All territories', value: '' }, ...list.map((t) => ({ label: t.name, value: t.id }))];
    }

    get adminKamOptions() {
        let allowed = null;
        if (this.selectedTerritoryId) {
            allowed = new Set([this.selectedTerritoryId]);
        } else if (this.selectedRegionId) {
            allowed = new Set(this.pickerTerritories.filter((t) => t.parentId === this.selectedRegionId).map((t) => t.id));
            allowed.add(this.selectedRegionId);
        }
        const kams = this.kamOptions.filter((k) => !allowed || (k.territoryIds || []).some((id) => allowed.has(id)));
        return [
            { label: 'My Schedule', value: '' },
            ...kams.map((k) => ({ label: k.territoryName ? `${k.name} — ${k.territoryName}` : k.name, value: k.id })),
        ];
    }

    handleRegionChange(event) {
        this.selectedRegionId = event.detail.value;
        this.selectedTerritoryId = '';
        this.selectedUserId = '';
        this.loadCalls();
    }

    handleTerritoryChange(event) {
        this.selectedTerritoryId = event.detail.value;
        this.selectedUserId = '';
        this.loadCalls();
    }

    get viewingOtherUser() {
        return !!this.selectedUserId;
    }

    handleKamChange(event) {
        this.selectedUserId = event.detail.value;
        this.loadCalls();
    }

    // MARK: - Visible range (depends on mode)

    // Agenda and Map show a single day (like the app); Week is the Mon-Sun week of
    // selectedDate; Month is the 6-row Monday-first grid covering selectedDate's month.
    get monthFirst() {
        return new Date(this.selectedDate.getFullYear(), this.selectedDate.getMonth(), 1);
    }

    get rangeStart() {
        if (this.viewMode === 'week') { return startOfWeek(this.selectedDate); }
        if (this.viewMode === 'month') { return startOfWeek(this.monthFirst); }
        return this.selectedDate;
    }

    get rangeEnd() {
        if (this.viewMode === 'week') {
            const end = new Date(this.rangeStart);
            end.setDate(end.getDate() + 6);
            return end;
        }
        if (this.viewMode === 'month') {
            const end = new Date(this.rangeStart);
            end.setDate(end.getDate() + 41);
            return end;
        }
        return this.selectedDate;
    }

    get rangeLabel() {
        const d = this.selectedDate;
        if (this.viewMode === 'month') {
            return d.toLocaleDateString(undefined, { month: 'long', year: 'numeric' });
        }
        if (this.viewMode === 'week') {
            const fmt = (x) => x.toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
            return `${fmt(this.rangeStart)} – ${fmt(this.rangeEnd)}, ${this.rangeEnd.getFullYear()}`;
        }
        return d.toLocaleDateString(undefined, { weekday: 'long', month: 'long', day: 'numeric', year: 'numeric' });
    }

    // Planned / Submitted counts for the visible range -- same classification as the
    // app's dayCounts(): a Completed call counts as Submitted; Saved/Draft/Past/Cancelled count as neither.
    get plannedCount() {
        return this.filteredCalls.filter((c) => !c.isEvent && visitState(c).label === 'Planned').length;
    }

    get submittedCount() {
        return this.filteredCalls.filter((c) => {
            if (c.isEvent) { return false; }
            const l = visitState(c).label;
            return l === 'Submitted' || l === 'Completed';
        }).length;
    }

    get plannedChipLabel() { return `${this.plannedCount} Planned`; }
    get submittedChipLabel() { return `${this.submittedCount} Submitted`; }

    get legendItems() {
        return [
            { key: 'sub', label: 'Submitted', style: 'background:#059669;' },
            { key: 'sav', label: 'Saved', style: 'background:#0EA5A5;' },
            { key: 'pla', label: 'Planned (future)', style: 'background:#4F46E5;' },
            { key: 'pas', label: 'Past — not submitted', style: 'background:#DC2626;' },
            { key: 'can', label: 'Cancelled', style: 'background:#94A3B8;' },
            { key: 'evt', label: 'Event / Leave', style: 'background:#6D5BD0;' },
        ];
    }

    async loadCalls() {
        this.isLoading = true;
        try {
            const range = {
                startDate: isoDate(this.rangeStart),
                endDate: isoDate(this.rangeEnd),
                userId: this.selectedUserId || null,
            };
            // Time Off only decorates the Week grid, and is a convenience: never fail the load over it.
            const timeOffPromise = this.viewMode === 'week' ? getTimeOff(range).catch(() => []) : Promise.resolve([]);
            this.calls = await getPlannedCallsForUser(range);
            this.timeOff = await timeOffPromise;
        } catch (e) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Couldn’t load your schedule', message: e.body?.message || 'Try again.', variant: 'error',
            }));
            this.calls = [];
        } finally {
            this.isLoading = false;
        }
    }

    // MARK: - Mode + navigation

    get modeButtons() {
        return [
            { key: 'agenda', label: 'Agenda', variant: this.viewMode === 'agenda' ? 'brand' : 'neutral' },
            { key: 'week', label: 'Week', variant: this.viewMode === 'week' ? 'brand' : 'neutral' },
            { key: 'month', label: 'Month', variant: this.viewMode === 'month' ? 'brand' : 'neutral' },
            { key: 'map', label: 'Map', variant: this.viewMode === 'map' ? 'brand' : 'neutral' },
        ];
    }

    get isAgendaMode() { return this.viewMode === 'agenda'; }
    get isWeekMode() { return this.viewMode === 'week'; }
    get isMonthMode() { return this.viewMode === 'month'; }
    get isMapMode() { return this.viewMode === 'map'; }

    handleModeChange(event) {
        this.viewMode = event.currentTarget.dataset.value;
        this.loadCalls();
    }

    // Agenda and Map step a single day, Week steps a full week, Month steps a calendar month.
    shift(direction) {
        const d = this.selectedDate;
        if (this.viewMode === 'month') {
            this.selectedDate = new Date(d.getFullYear(), d.getMonth() + direction, 1);
        } else {
            const days = this.viewMode === 'week' ? 7 : 1;
            this.selectedDate = new Date(d.getTime() + direction * days * DAY_MS);
        }
        this.loadCalls();
    }

    handlePrev() { this.shift(-1); }

    handleNext() { this.shift(1); }

    handleToday() {
        this.selectedDate = toDateOnly(new Date());
        this.loadCalls();
    }

    // MARK: - Filters (ports CalendarPlannerView.swift's matchesFilter)

    async handleFilterChange(event) {
        const { field, value } = event.detail;
        if (field === 'clear') {
            this.kind = 'All'; this.specialty = ''; this.territory = ''; this.status = ''; this.callCategory = ''; this.customListId = '';
            this.customListMemberIds = [];
            return;
        }
        if (field === 'savedView') {
            this.specialty = value.specialty || '';
            this.territory = ''; this.kind = 'All';
            return;
        }
        if (field === 'searchTerm') { this.searchTerm = value; return; }
        if (field === 'kind') { this.kind = value; return; }
        if (field === 'specialty') { this.specialty = value; return; }
        if (field === 'territory') { this.territory = value; return; }
        if (field === 'status') { this.status = value; return; }
        if (field === 'callCategory') { this.callCategory = value; return; }
        if (field === 'customListId') {
            this.customListId = value;
            this.customListMemberIds = value ? await getCustomListMemberIds({ listId: value }) : [];
        }
    }

    matchesFilter(c) {
        if (this.kind === 'HCP' && !c.hcpId) { return false; }
        if (this.kind === 'HCO' && c.hcpId) { return false; }
        if (this.specialty && c.specialty !== this.specialty) { return false; }
        if (this.territory && c.hcpTerritory !== this.territory && c.hcoTerritory !== this.territory) { return false; }
        if (this.status && c.status !== this.status) { return false; }
        if (this.callCategory && (c.isEvent || c.callCategory !== this.callCategory)) { return false; }
        if (this.customListId && (!c.hcpId || !this.customListMemberIds.includes(c.hcpId))) { return false; }
        if (this.searchTerm) {
            const hay = `${c.hcpName || ''} ${c.hcoName || ''} ${c.specialty || ''} ${c.callType || ''}`.toLowerCase();
            if (!hay.includes(this.searchTerm.toLowerCase())) { return false; }
        }
        return true;
    }

    get categoryOptions() {
        const set = new Set(['Call Only', 'Call with CLM']);
        (this.calls || []).forEach((c) => { if (c.callCategory) { set.add(c.callCategory); } });
        return [...set];
    }

    get filteredCalls() {
        return (this.calls || []).filter((c) => this.matchesFilter(c));
    }

    // MARK: - Agenda mode (one day, like the app)

    get agendaItems() {
        return this.filteredCalls
            .slice()
            .sort((x, y) => x.callDateTime.localeCompare(y.callDateTime))
            .map((c) => this.decorateCall(c));
    }

    get hasAgendaResults() {
        return this.agendaItems.length > 0;
    }

    get agendaEmptyText() {
        return this.hasActiveFilters ? 'No visits match the current filters.' : 'No calls planned. Click Schedule to add one.';
    }

    get hasActiveFilters() {
        return !!(this.searchTerm || this.kind !== 'All' || this.specialty || this.territory || this.status || this.callCategory || this.customListId);
    }

    decorateCall(c) {
        const start = new Date(c.callDateTime);
        const end = new Date(start.getTime() + (c.durationMin || 30) * 60000);
        const t = (d) => d.toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' });
        const state = c.isEvent ? { color: '6D5BD0', label: 'Event' } : visitState(c);
        return {
            ...c,
            timeLabel: t(start),
            timeRange: `${t(start)} – ${t(end)}`,
            displayName: c.isEvent ? (c.eventTitle || 'Event') : (c.hcpName || c.hcoName || 'Untitled visit'),
            subtitle: c.isEvent
                ? [c.venue, c.productName].filter(Boolean).join(' · ')
                : (c.isReportOnly
                    ? [c.callType, 'Walk-in visit'].filter(Boolean).join(' · ')
                    : [c.hcpId ? c.hcoName : null, c.callType].filter(Boolean).join(' · ')),
            stateLabel: state.label,
            cardStyle: `border-left:6px solid #${state.color};background:${c.isEvent ? '#ECE9FB' : '#' + state.color + '14'};`,
            nameClass: c.status === 'Cancelled' ? 'call-name call-name-cancelled' : 'call-name',
            statusStyle: pillStyle(state.color),
            showCategory: !c.isEvent && !!c.callCategory,
            categoryStyle: c.callCategory === 'Call Only'
                ? 'background:#0F766E;color:#ffffff;'
                : 'background:#e3f0fb;color:#0b5cab;border:1px solid #b6d4f0;',
            canDelete: !(this.isKam && c.status === 'Completed'),
            logVisitLabel: c.resultingCVRId ? 'Open Call Report' : 'Log Visit',
        };
    }

    // MARK: - Row actions

    handleNewVisit() {
        if (this.viewingOtherUser) { return; } // read-only while viewing a KAM's schedule
        this.editingCallId = null;
        this.formDefaultHcpId = null;
        this.formDefaultHcoId = null;
        this.formDefaultDateTime = null;
        this.showForm = true;
        this.scrollToTop('.schedule-form-anchor');
    }

    // Keeps a click on the actions menu from also opening the card behind it.
    stopClick(event) {
        event.stopPropagation();
    }

    handleEditVisit(event) {
        this.editingCallId = event.currentTarget.dataset.id;
        this.showForm = true;
    }

    /// Clicking a call in the Week / Month grid (the opencall event) behaves like
    /// tapping it in the app -- see openCall().
    handleGridOpenCall(event) {
        const clicked = (this.calls || []).find((c) => c.id === event.detail.id);
        this.openCall(clicked);
    }

    /// Same rule as the app's openCall(): any call that already has a Call Report (completed,
    /// saved or walk-in) opens that report; an HCP visit or event without one opens a new
    /// report linked to the planned call; an HCO-only visit opens the plan for editing.
    /// Viewing another user's schedule is read-only: their existing reports open, but a
    /// manager can't start a report on a KAM's behalf, so a call with no report yet just says so.
    openCall(c) {
        if (!c) { return; }
        if (this.viewingOtherUser) {
            if (c.resultingCVRId) {
                this.openCallReport({ plannedCallId: null, hcpId: c.hcpId, hcoId: c.hcoId, cvrId: c.resultingCVRId });
            } else {
                this.dispatchEvent(new ShowToastEvent({
                    title: 'No call report yet', message: 'This visit is planned but the KAM has not logged a call report for it.', variant: 'info',
                }));
            }
            return;
        }
        if (c.isReportOnly) {
            this.openCallReport({ plannedCallId: null, hcpId: c.hcpId, hcoId: c.hcoId, cvrId: c.resultingCVRId });
        } else if (c.hcpId || c.isEvent) {
            this.openCallReport({ plannedCallId: c.id, hcpId: c.hcpId, hcoId: c.hcoId, cvrId: c.resultingCVRId });
        } else {
            this.editingCallId = c.id;
            this.showForm = true;
            this.scrollToTop('.schedule-form-anchor');
        }
    }

    /// The form / report open above the grid, which can be scrolled well out of view --
    /// bring them into view so a click never looks like it did nothing.
    scrollToTop(selector) {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        window.setTimeout(() => {
            const el = this.template.querySelector(selector) || this.template.querySelector('.schedule');
            if (el) { el.scrollIntoView({ behavior: 'smooth', block: 'start' }); }
        }, 0);
    }

    /// Tapping an empty hour slot in the Week grid opens the scheduling form at that time.
    handleSlotClick(event) {
        if (this.viewingOtherUser) { return; }
        this.editingCallId = null;
        this.formDefaultHcpId = null;
        this.formDefaultHcoId = null;
        this.formDefaultDateTime = event.detail.callDateTime;
        this.showForm = true;
        this.scrollToTop('.schedule-form-anchor');
    }

    /// The right-click menu on a Week-grid block (same actions as the app's context menu).
    async handleBlockAction(event) {
        const { id, action } = event.detail;
        const call = (this.calls || []).find((c) => c.id === id);
        if (!call) { return; }
        if (action === 'open') {
            this.openCall(call);
        } else if (action === 'edit') {
            this.editingCallId = id;
            this.showForm = true;
            this.scrollToTop('.schedule-form-anchor');
        } else if (action === 'complete') {
            await this.updateStatus(id, 'Completed');
        } else if (action === 'delete') {
            // Same prompt as the app's "Delete this visit?" alert.
            const confirmed = await LightningConfirm.open({
                message: 'This planned visit will be removed from your schedule. This can’t be undone.',
                label: 'Delete this visit?',
                variant: 'header',
                theme: 'error',
            });
            if (confirmed) { await this.handleDeleteVisit({ currentTarget: { dataset: { id } } }); }
        }
    }

    /// "+N more" in the Month grid jumps to that day in the Agenda.
    handleOpenDay(event) {
        const [y, m, d] = event.detail.day.split('-').map(Number);
        this.selectedDate = new Date(y, m - 1, d);
        this.viewMode = 'agenda';
        this.loadCalls();
    }

    /// Dropping an HCP/HCO onto the week grid opens the scheduling modal
    /// pre-filled with the account and the exact day+hour it was dropped on
    /// (scheduleWeekGrid derives callDateTime from the drop position) —
    /// create mode, same as handleNewVisit, just with those three defaults
    /// populated instead of blank.
    handleScheduleDrop(event) {
        if (this.viewingOtherUser) { return; } // read-only while viewing a KAM's schedule
        this.editingCallId = null;
        this.formDefaultHcpId = event.detail.hcpId;
        this.formDefaultHcoId = event.detail.hcoId;
        this.formDefaultDateTime = event.detail.callDateTime;
        this.showForm = true;
    }

    async handleMarkCompleted(event) {
        await this.updateStatus(event.currentTarget.dataset.id, 'Completed');
    }

    async handleMarkCancelled(event) {
        await this.updateStatus(event.currentTarget.dataset.id, 'Cancelled');
    }

    async updateStatus(id, status) {
        try {
            await updateRecord({ fields: { Id: id, Status__c: status } });
            this.dispatchEvent(new ShowToastEvent({ title: 'Updated', message: `Marked ${status}.`, variant: 'success' }));
            this.loadCalls();
        } catch (e) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Couldn’t update visit', message: e.body?.message || 'Try again.', variant: 'error',
            }));
        }
    }

    async handleDeleteVisit(event) {
        const id = event.currentTarget.dataset.id;
        try {
            await deleteRecord(id);
            this.dispatchEvent(new ShowToastEvent({ title: 'Deleted', message: 'Visit removed.', variant: 'success' }));
            this.loadCalls();
        } catch (e) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Couldn’t delete visit', message: e.body?.message || 'Try again.', variant: 'error',
            }));
        }
    }

    handleFormSave() {
        this.showForm = false;
        this.loadCalls();
    }

    handleFormCancel() {
        this.showForm = false;
    }

    /// Opens callVisitReportDetail for the clicked row. If this Planned_Call__c
    /// already has a Resulting_CVR__c (set by callVisitReportDetail.js's
    /// handleHeaderSave the first time this row was logged), reopen that same
    /// report instead of starting a second, unlinked one — sourcePlannedCallId
    /// is only for the not-yet-logged case, so the header's first save can
    /// still make that initial link.
    handleLogVisit(event) {
        const { id, hcpid, hcoid, cvrid } = event.currentTarget.dataset;
        this.openCallReport({ plannedCallId: id, hcpId: hcpid, hcoId: hcoid, cvrId: cvrid });
    }

    /// Clicking an agenda card opens the call the same way the app does.
    handleRowClick(event) {
        const id = event.currentTarget.dataset.id;
        this.openCall((this.calls || []).find((c) => c.id === id));
    }

    openCallReport({ plannedCallId, hcpId, hcoId, cvrId }) {
        this.callReportRecordId = cvrId || null;
        this.callReportSourcePlannedCallId = cvrId ? null : plannedCallId;
        this.callReportDefaultHcpId = hcpId || null;
        this.callReportDefaultHcoId = hcoId || null;
        this.showCallReport = true;
        this.scrollToTop('.call-report-panel');
    }

    handleCallReportClose() {
        this.showCallReport = false;
        this.callReportRecordId = null;
        this.callReportSourcePlannedCallId = null;
        this.loadCalls();
    }

    navigateToAccount(id) {
        if (!id) { return; }
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: id, objectApiName: 'Sciagen_Account__c', actionName: 'view' },
        });
    }
}