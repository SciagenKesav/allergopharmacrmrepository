import { LightningElement, api } from 'lwc';
import searchAccounts from '@salesforce/apex/SciagenAccountController.searchAccounts';
import getTerritoryOptions from '@salesforce/apex/SciagenAccountController.getTerritoryOptions';
import { pillStyle, visitState } from 'c/sciagenColors';

const HOUR_HEIGHT_PX = 48;
const DAY_MS = 24 * 60 * 60 * 1000;
const SEARCH_DEBOUNCE_MS = 300;

// LOCAL calendar-day key — see mySchedule.js's localDayKey for why this must
// never be `.toISOString().slice(0,10)` (that rolls back a day in any
// negative-offset timezone; confirmed live, every day column was one day
// behind its own header until this was fixed).
function localDayKey(d) {
    const year = d.getFullYear();
    const month = String(d.getMonth() + 1).padStart(2, '0');
    const day = String(d.getDate()).padStart(2, '0');
    return `${year}-${month}-${day}`;
}

/// Week / drag-and-drop scheduler grid — ports CalendarPlannerView.swift's
/// schedulerMode (day columns + hour rows + a draggable HCP/HCO side panel).
/// Dropping an account on a day column derives the exact day+hour from the
/// drop position and dispatches `scheduledrop` with that account and
/// datetime — mySchedule.js opens the scheduling modal (scheduleCallForm)
/// pre-filled with them, rather than this component creating the
/// Planned_Call__c directly, so the rep always sees and can adjust the
/// details (duration, call type, etc.) before it's saved.
export default class ScheduleWeekGrid extends LightningElement {
    @api calls = [];
    @api rangeStart; // Date, Monday of the visible week

    hideSunday = false;
    fullDay = false;
    panelCollapsed = false;
    panelKind = 'HCP';
    panelSearch = '';
    panelTerritory = '';
    panelAccounts = [];
    territoryOptions = [];
    dropDayKey = null;
    searchTimeout;

    connectedCallback() {
        this.loadPanelAccounts();
        getTerritoryOptions().then((t) => { this.territoryOptions = t; }).catch(() => {});
    }

    async loadPanelAccounts() {
        try {
            this.panelAccounts = await searchAccounts({
                searchTerm: this.panelSearch, typeFilter: this.panelKind, territoryFilter: this.panelTerritory,
                specialtyFilter: '', hcoTypeFilter: '', cityFilter: '', kolOnly: false, emergingOnly: false,
                sortField: 'Name', sortAscending: true,
            });
        } catch (e) {
            this.panelAccounts = [];
        }
    }

    // MARK: - Panel controls

    get panelKindButtons() {
        return ['HCP', 'HCO'].map((k) => ({ key: k, label: `${k}s`, variant: k === this.panelKind ? 'brand' : 'neutral' }));
    }

    get territoryComboOptions() {
        return [{ label: 'All Territories', value: '' }, ...this.territoryOptions.map((t) => ({ label: t, value: t }))];
    }

    get togglePanelIcon() {
        return this.panelCollapsed ? 'utility:chevronright' : 'utility:chevronleft';
    }

    handleTogglePanel() {
        this.panelCollapsed = !this.panelCollapsed;
    }

    handlePanelKindChange(event) {
        this.panelKind = event.currentTarget.dataset.value;
        this.loadPanelAccounts();
    }

    handlePanelTerritoryChange(event) {
        this.panelTerritory = event.detail.value;
        this.loadPanelAccounts();
    }

    handlePanelSearch(event) {
        const value = event.target.value;
        window.clearTimeout(this.searchTimeout);
        this.searchTimeout = window.setTimeout(() => {
            this.panelSearch = value;
            this.loadPanelAccounts();
        }, SEARCH_DEBOUNCE_MS);
    }

    get hideSundayLabel() {
        return this.hideSunday ? 'Mon–Sat' : 'Mon–Sun';
    }

    get fullDayLabel() {
        return this.fullDay ? '24h' : '8–8';
    }

    handleToggleHideSunday() {
        this.hideSunday = !this.hideSunday;
    }

    handleToggleFullDay() {
        this.fullDay = !this.fullDay;
    }

    get panelRows() {
        return this.panelAccounts.map((a) => ({ ...a, dragToken: `${this.panelKind.toLowerCase()}:${a.id}` }));
    }

    handleDragStart(event) {
        event.dataTransfer.setData('text/plain', event.currentTarget.dataset.token);
        event.dataTransfer.effectAllowed = 'copy';
    }

    // MARK: - Grid geometry

    get hours() {
        const start = this.fullDay ? 0 : 8;
        const end = this.fullDay ? 23 : 20;
        const list = [];
        for (let h = start; h <= end; h++) { list.push(h); }
        return list;
    }

    get hourRows() {
        return this.hours.map((h) => ({
            key: h,
            label: new Date(2000, 0, 1, h).toLocaleTimeString(undefined, { hour: 'numeric' }),
        }));
    }

    get days() {
        const count = this.hideSunday ? 6 : 7;
        const start = this.rangeStart instanceof Date ? this.rangeStart : new Date(this.rangeStart);
        const list = [];
        for (let i = 0; i < count; i++) {
            const d = new Date(start.getTime() + i * DAY_MS);
            list.push(d);
        }
        return list;
    }

    get dayColumns() {
        const firstHour = this.hours[0];
        const totalHours = this.hours.length;
        const todayKey = localDayKey(new Date());
        return this.days.map((d) => {
            const key = localDayKey(d);
            const dayCalls = (this.calls || []).filter((c) => localDayKey(new Date(c.callDateTime)) === key);
            const blocks = this.layoutBlocks(dayCalls, firstHour, totalHours);
            return {
                key,
                label: d.toLocaleDateString(undefined, { weekday: 'short', day: 'numeric' }),
                isToday: key === todayKey,
                isDropTarget: this.dropDayKey === key,
                blocks,
                columnClass: this.dropDayKey === key ? 'day-column drop-target' : 'day-column',
            };
        });
    }

    /// Side-by-side layout for overlapping calls on the same day — a simplified
    /// greedy interval-graph coloring, matching the effect of iOS's overlapLayout.
    layoutBlocks(dayCalls, firstHour, totalHours) {
        const sorted = dayCalls.slice().sort((a, b) => a.callDateTime.localeCompare(b.callDateTime));
        const columns = []; // each: last end-time (ms)
        const placed = sorted.map((c) => {
            const start = new Date(c.callDateTime).getTime();
            const end = start + (c.durationMin || 30) * 60000;
            let col = columns.findIndex((endTime) => endTime <= start);
            if (col === -1) { col = columns.length; columns.push(end); } else { columns[col] = end; }
            return { call: c, start, end, col };
        });
        const totalCols = Math.max(1, columns.length);
        return placed.map(({ call, start, end, col }) => {
            const callDate = new Date(call.callDateTime);
            const dayStartMs = new Date(callDate.getFullYear(), callDate.getMonth(), callDate.getDate(), firstHour, 0, 0, 0).getTime();
            const topMin = Math.max(0, (start - dayStartMs) / 60000);
            const heightMin = (end - start) / 60000;
            const top = (topMin / 60) * HOUR_HEIGHT_PX;
            // Enforced in pixels, not minutes: a 30-min call (the drag-and-drop
            // default) previously rendered at 24px tall — enough for exactly
            // one stacked line, so only the time showed and the HCP/HCO name
            // was silently clipped by the block's own overflow:hidden.
            const height = Math.max(34, (heightMin / 60) * HOUR_HEIGHT_PX);
            const widthPct = 100 / totalCols;
            const leftPct = col * widthPct;
            const time = new Date(call.callDateTime).toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' });
            return {
                ...call,
                key: call.id,
                timeLabel: time,
                // A teammate's call (My Schedule now spans the shared
                // territory, not just the viewer's own calls) gets its
                // owner's name tagged on — otherwise it reads as the
                // viewer's own.
                displayName: (call.isEvent ? (call.eventTitle || 'Event') : (call.hcpName || call.hcoName || 'Visit'))
                    + (call.isMine ? '' : ` · ${call.ownerName || ''}`),
                // visitState(), not raw call.status — see its doc comment.
                statusStyle: pillStyle(visitState(call).color),
                visitLabel: visitState(call).label,
                blockStyle: `top:${top}px;height:${height}px;left:${leftPct}%;width:calc(${widthPct}% - 4px);`,
            };
        });
    }

    get gridHeightPx() {
        return this.hours.length * HOUR_HEIGHT_PX;
    }

    get gridHeightStyle() {
        return `height:${this.gridHeightPx}px;`;
    }

    // MARK: - Drag-and-drop scheduling

    handleDragOver(event) {
        event.preventDefault();
        event.dataTransfer.dropEffect = 'copy';
        this.dropDayKey = event.currentTarget.dataset.day;
    }

    handleDragLeave(event) {
        if (this.dropDayKey === event.currentTarget.dataset.day) { this.dropDayKey = null; }
    }

    // Derives the exact day+hour from the drop position and hands it to the
    // parent (mySchedule.js) to open the scheduling modal pre-filled —
    // deliberately does not create the Planned_Call__c itself, so the rep
    // always gets a chance to review/adjust (duration, call type, ...)
    // before anything is saved.
    handleDrop(event) {
        event.preventDefault();
        const dayKey = event.currentTarget.dataset.day;
        this.dropDayKey = null;
        const token = event.dataTransfer.getData('text/plain');
        if (!token) { return; }
        const [prefix, id] = token.split(':');
        if (prefix !== 'hcp' && prefix !== 'hco') { return; }

        const rect = event.currentTarget.getBoundingClientRect();
        const offsetY = event.clientY - rect.top;
        const firstHour = this.hours[0];
        const lastHour = this.hours[this.hours.length - 1];
        const rawHour = firstHour + Math.floor(offsetY / HOUR_HEIGHT_PX);
        const hour = Math.min(Math.max(rawHour, firstHour), lastHour);
        // lightning-input-field expects DateTime values as UTC ISO strings
        // (ending in "Z") — building the string by hand with no timezone
        // marker made Salesforce treat the dropped local hour as if it were
        // already UTC, silently shifting the prefilled time by the rep's UTC
        // offset. Building a real Date from the local day/hour and letting
        // toISOString() do the UTC conversion keeps the prefilled time
        // matching exactly where the rep dropped it.
        const [year, month, day] = dayKey.split('-').map(Number);
        const callDateTime = new Date(year, month - 1, day, hour, 0, 0, 0).toISOString();

        this.dispatchEvent(new CustomEvent('scheduledrop', {
            detail: {
                hcpId: prefix === 'hcp' ? id : null,
                hcoId: prefix === 'hco' ? id : null,
                callDateTime,
            },
        }));
    }

    handleBlockClick(event) {
        this.dispatchEvent(new CustomEvent('edit', { detail: { id: event.currentTarget.dataset.id } }));
    }
}