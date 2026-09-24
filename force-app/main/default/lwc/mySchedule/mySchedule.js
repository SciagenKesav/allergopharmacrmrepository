import { LightningElement } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { deleteRecord, updateRecord } from 'lightning/uiRecordApi';
import getMyPlannedCalls from '@salesforce/apex/SciagenScheduleController.getMyPlannedCalls';
import getCustomListMemberIds from '@salesforce/apex/SciagenScheduleController.getCustomListMemberIds';
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
function startOfMonth(d) {
    return toDateOnly(new Date(d.getFullYear(), d.getMonth(), 1));
}
// The full Monday-first grid a month view actually renders — from the Monday
// of the week containing the 1st through the Sunday of the week containing
// the last day, so scheduleMonthGrid can lay out complete calendar rows
// (including the leading/trailing days that spill into neighboring months).
function startOfMonthGrid(d) {
    return startOfWeek(startOfMonth(d));
}
function endOfMonthGrid(d) {
    const lastOfMonth = toDateOnly(new Date(d.getFullYear(), d.getMonth() + 1, 0));
    const dow = lastOfMonth.getDay(); // 0 = Sun
    const diffToSunday = dow === 0 ? 0 : 7 - dow;
    const end = new Date(lastOfMonth);
    end.setDate(lastOfMonth.getDate() + diffToSunday);
    return end;
}

/// "My Schedule" — Salesforce LWC port of the iOS CalendarPlannerView. Owns all
/// filter state and the fetched Planned_Call__c list; child components
/// (scheduleFilterBar, scheduleCallForm, and per-mode views) are presentational.
/// See the "My Schedule — Salesforce LWC Port" plan for the full feature mapping.
export default class MySchedule extends NavigationMixin(LightningElement) {
    viewMode = 'agenda'; // 'agenda' | 'week' | 'month' | 'map'
    selectedDate = toDateOnly(new Date());
    calls = [];
    isLoading = false;

    searchTerm = '';
    kind = 'All';
    specialty = '';
    territory = '';
    status = '';
    customListId = '';
    customListMemberIds = [];

    specialtyOptions = [];
    territoryOptions = [];
    customListOptions = [];
    savedViewOptions = [];

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
    }

    // MARK: - Visible range (depends on mode)

    get rangeStart() {
        if (this.viewMode === 'week') { return startOfWeek(this.selectedDate); }
        if (this.viewMode === 'month') { return startOfMonthGrid(this.selectedDate); }
        if (this.viewMode === 'map') { return this.selectedDate; }
        return this.selectedDate; // agenda: anchored on selectedDate, 14-day window
    }

    get rangeEnd() {
        if (this.viewMode === 'week') {
            const end = new Date(this.rangeStart);
            end.setDate(end.getDate() + 6);
            return end;
        }
        if (this.viewMode === 'month') { return endOfMonthGrid(this.selectedDate); }
        if (this.viewMode === 'map') { return this.selectedDate; }
        const end = new Date(this.selectedDate);
        end.setDate(end.getDate() + 13);
        return end;
    }

    get rangeLabel() {
        if (this.viewMode === 'month') {
            return this.selectedDate.toLocaleDateString(undefined, { month: 'long', year: 'numeric' });
        }
        const fmt = (d) => d.toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric' });
        return `${fmt(this.rangeStart)} – ${fmt(this.rangeEnd)}`;
    }

    async loadCalls() {
        this.isLoading = true;
        try {
            this.calls = await getMyPlannedCalls({ startDate: isoDate(this.rangeStart), endDate: isoDate(this.rangeEnd) });
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

    handlePrev() {
        if (this.viewMode === 'month') {
            this.selectedDate = toDateOnly(new Date(this.selectedDate.getFullYear(), this.selectedDate.getMonth() - 1, 1));
        } else {
            const days = this.viewMode === 'week' ? 7 : (this.viewMode === 'map' ? 1 : 14);
            this.selectedDate = new Date(this.selectedDate.getTime() - days * DAY_MS);
        }
        this.loadCalls();
    }

    handleNext() {
        if (this.viewMode === 'month') {
            this.selectedDate = toDateOnly(new Date(this.selectedDate.getFullYear(), this.selectedDate.getMonth() + 1, 1));
        } else {
            const days = this.viewMode === 'week' ? 7 : (this.viewMode === 'map' ? 1 : 14);
            this.selectedDate = new Date(this.selectedDate.getTime() + days * DAY_MS);
        }
        this.loadCalls();
    }

    handleToday() {
        this.selectedDate = toDateOnly(new Date());
        this.loadCalls();
    }

    // MARK: - Filters (ports CalendarPlannerView.swift's matchesFilter)

    async handleFilterChange(event) {
        const { field, value } = event.detail;
        if (field === 'clear') {
            this.kind = 'All'; this.specialty = ''; this.territory = ''; this.status = ''; this.customListId = '';
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
        if (this.customListId && (!c.hcpId || !this.customListMemberIds.includes(c.hcpId))) { return false; }
        if (this.searchTerm) {
            const hay = `${c.hcpName || ''} ${c.hcoName || ''} ${c.specialty || ''} ${c.callType || ''} ${c.ownerName || ''}`.toLowerCase();
            if (!hay.includes(this.searchTerm.toLowerCase())) { return false; }
        }
        return true;
    }

    get filteredCalls() {
        return (this.calls || []).filter((c) => this.matchesFilter(c));
    }

    // MARK: - Agenda mode

    get agendaGroups() {
        const byDay = new Map();
        for (const c of this.filteredCalls) {
            const day = localDayKey(new Date(c.callDateTime));
            if (!byDay.has(day)) { byDay.set(day, []); }
            byDay.get(day).push(c);
        }
        const days = [...byDay.keys()].sort();
        return days.map((day) => {
            const dateObj = new Date(`${day}T00:00:00`);
            const items = byDay.get(day).slice().sort((a, b) => a.callDateTime.localeCompare(b.callDateTime));
            return {
                key: day,
                dateLabel: dateObj.toLocaleDateString(undefined, { weekday: 'long', month: 'short', day: 'numeric' }),
                items: items.map((c) => this.decorateCall(c)),
            };
        });
    }

    get hasAgendaResults() {
        return this.agendaGroups.length > 0;
    }

    decorateCall(c) {
        const time = new Date(c.callDateTime).toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' });
        return {
            ...c,
            timeLabel: time,
            displayName: c.isEvent ? (c.eventTitle || 'Event') : (c.hcpName || c.hcoName || 'Untitled visit'),
            // Now that My Schedule shows every rep's calls for a shared
            // territory (see SciagenScheduleController.getMyPlannedCalls()'s
            // doc comment), a teammate's call needs an explicit "· Rep Name"
            // tag so it doesn't read as the viewer's own.
            subtitle: [
                c.isEvent ? [c.venue, c.productName].filter(Boolean).join(' · ') : (c.callType || ''),
                c.isMine ? null : c.ownerName,
            ].filter(Boolean).join(' · '),
            // visitState(), not raw c.status — see its own doc comment.
            // `status` itself is left untouched since the Status filter
            // (handleFilterChange below) compares against its raw value.
            statusStyle: pillStyle(visitState(c).color),
            visitLabel: visitState(c).label,
            // "Log Visit" only makes sense before a report exists — once
            // Resulting_CVR__c is set (see callVisitReportDetail.js's
            // handleHeaderSave), the same action should reopen that report,
            // not start a second, unlinked one.
            logVisitLabel: c.resultingCVRId ? 'Open Call Report' : 'Log Visit',
        };
    }

    // MARK: - Row actions

    handleNewVisit() {
        this.editingCallId = null;
        this.formDefaultHcpId = null;
        this.formDefaultHcoId = null;
        this.formDefaultDateTime = null;
        this.showForm = true;
    }

    handleEditVisit(event) {
        this.editingCallId = event.currentTarget.dataset.id;
        this.showForm = true;
    }

    /// Same as handleEditVisit, but for the `edit` custom event dispatched by
    /// scheduleWeekGrid (a detail payload, not a data-id on the click target).
    handleGridEditVisit(event) {
        this.editingCallId = event.detail.id;
        this.showForm = true;
    }

    /// Dropping an HCP/HCO onto the week grid opens the scheduling modal
    /// pre-filled with the account and the exact day+hour it was dropped on
    /// (scheduleWeekGrid derives callDateTime from the drop position) —
    /// create mode, same as handleNewVisit, just with those three defaults
    /// populated instead of blank.
    handleScheduleDrop(event) {
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

    /// Clicking the row itself opens its report the same way, once one
    /// exists; otherwise falls back to the account (previous behavior) since
    /// there's nothing call-specific to show yet.
    handleRowClick(event) {
        const { accountId, plannedCallId, hcpid, hcoid, cvrid } = event.currentTarget.dataset;
        if (cvrid) {
            this.openCallReport({ plannedCallId, hcpId: hcpid, hcoId: hcoid, cvrId: cvrid });
        } else {
            this.navigateToAccount(accountId);
        }
    }

    openCallReport({ plannedCallId, hcpId, hcoId, cvrId }) {
        this.callReportRecordId = cvrId || null;
        this.callReportSourcePlannedCallId = cvrId ? null : plannedCallId;
        this.callReportDefaultHcpId = hcpId || null;
        this.callReportDefaultHcoId = hcoId || null;
        this.showCallReport = true;
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