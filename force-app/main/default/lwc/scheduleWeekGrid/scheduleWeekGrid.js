import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import searchAccounts from '@salesforce/apex/SciagenAccountController.searchAccounts';
import getTerritoryOptions from '@salesforce/apex/SciagenAccountController.getTerritoryOptions';
import { visitState } from 'c/sciagenColors';
import { holidayOn } from 'c/sciagenHolidays';

const HOUR_HEIGHT_PX = 54;
const MIN_BLOCK_PX = 28;
const DAY_MS = 24 * 60 * 60 * 1000;
const SEARCH_DEBOUNCE_MS = 300;
const BOOKMARK_KEY = 'sciagenScheduleBookmarks';
const EVENT_COLOR = '6D5BD0';

// LOCAL calendar-day key -- see mySchedule.js's localDayKey for why this must never be
// `.toISOString().slice(0,10)` (that rolls back a day in any negative-offset timezone).
function localDayKey(d) {
    const year = d.getFullYear();
    const month = String(d.getMonth() + 1).padStart(2, '0');
    const day = String(d.getDate()).padStart(2, '0');
    return `${year}-${month}-${day}`;
}

function endOf(startMs, durationMin) {
    return startMs + Math.max(10, durationMin || 30) * 60000;
}

/// Week grid -- ports CalendarPlannerView.swift's week / scheduler layout: a collapsible
/// account panel (drag an HCP/HCO onto the week, bookmark favourites), a day-header row
/// (today circle, holiday and Time Off flags), a 24h-or-8-to-8 hour grid with colour-coded
/// call blocks laid out side by side when they overlap, tap-an-empty-slot to schedule, and a
/// right-click menu on each block. It never writes data itself: opening a call, a new slot
/// or a drop, and every menu action go to mySchedule through events.
export default class ScheduleWeekGrid extends LightningElement {
    @api calls = [];
    @api rangeStart; // Date, Monday of the visible week
    @api timeOff = []; // [{ fromDate, toDate, leaveType, status }] -- 'YYYY-MM-DD' strings
    @api readOnly = false; // viewing another user's schedule

    hideSunday = false;
    fullDay = false;
    panelCollapsed = true;
    panelKind = 'HCP';
    panelSearch = '';
    panelTerritory = '';
    panelAccounts = [];
    territoryOptions = [];
    bookmarks = [];
    dropDayKey = null;
    searchTimeout;
    menu = null; // { x, y, callId }

    connectedCallback() {
        this.loadBookmarks();
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

    // MARK: - Header controls

    get hideSundayLabel() { return this.hideSunday ? 'Mon–Sat' : 'Mon–Sun'; }
    get fullDayLabel() { return this.fullDay ? '24h' : '8–8'; }
    get hideSundayClass() { return this.hideSunday ? 'pill-toggle pill-toggle-on' : 'pill-toggle'; }
    get fullDayClass() { return this.fullDay ? 'pill-toggle pill-toggle-on' : 'pill-toggle'; }

    handleToggleHideSunday() { this.hideSunday = !this.hideSunday; }
    handleToggleFullDay() { this.fullDay = !this.fullDay; }

    // MARK: - Account panel

    get showPanel() { return !this.readOnly; }
    get panelExpanded() { return !this.panelCollapsed; }

    get panelKindButtons() {
        return ['HCP', 'HCO'].map((k) => ({ key: k, label: `${k}s`, variant: k === this.panelKind ? 'brand' : 'neutral' }));
    }

    get panelCountLabel() { return `All (${this.panelAccounts.length})`; }

    get territoryMenuItems() {
        return [
            { key: 'all', value: '', label: 'All Territories', checked: !this.panelTerritory },
            ...this.territoryOptions.map((t) => ({ key: t, value: t, label: t, checked: t === this.panelTerritory })),
        ];
    }

    get hasPanelTerritory() { return !!this.panelTerritory; }
    get panelTerritoryLabel() { return `Territory: ${this.panelTerritory}`; }

    handleTogglePanel() { this.panelCollapsed = !this.panelCollapsed; }

    handlePanelKindChange(event) {
        this.panelKind = event.currentTarget.dataset.value;
        this.loadPanelAccounts();
    }

    handlePanelTerritorySelect(event) {
        this.panelTerritory = event.detail.value;
        this.loadPanelAccounts();
    }

    handlePanelTerritoryClear() {
        this.panelTerritory = '';
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

    // Bookmarked accounts pin to the top of the panel. Kept in this browser's localStorage
    // (the app keeps them on the device), so they are per-browser rather than per-user.
    loadBookmarks() {
        try {
            const raw = window.localStorage.getItem(BOOKMARK_KEY);
            this.bookmarks = raw ? JSON.parse(raw) : [];
        } catch (e) {
            this.bookmarks = [];
        }
    }

    saveBookmarks() {
        try {
            window.localStorage.setItem(BOOKMARK_KEY, JSON.stringify(this.bookmarks));
        } catch (e) {
            // Storage blocked: bookmarks just last for this page view.
        }
    }

    toRow(token, name, subtitle, isHcp) {
        const bookmarked = this.bookmarks.some((b) => b.token === token);
        return {
            token, name, subtitle, isHcp,
            avatarClass: isHcp ? 'avatar avatar-hcp' : 'avatar avatar-hco',
            iconName: isHcp ? 'utility:user' : 'utility:company',
            bookmarkIcon: bookmarked ? 'utility:favorite' : 'utility:favorite_alt',
            bookmarkClass: bookmarked ? 'bookmark-btn bookmark-on' : 'bookmark-btn',
        };
    }

    get bookmarkRows() {
        return this.bookmarks
            .map((b) => this.toRow(b.token, b.name, b.subtitle, b.isHcp))
            .sort((a, b) => a.name.localeCompare(b.name));
    }

    get hasBookmarks() { return this.bookmarks.length > 0; }

    get panelRows() {
        const prefix = this.panelKind.toLowerCase();
        return this.panelAccounts.map((a) => this.toRow(`${prefix}:${a.id}`, a.name, a.subtitle, this.panelKind === 'HCP'));
    }

    handleBookmarkToggle(event) {
        event.stopPropagation();
        const token = event.currentTarget.dataset.token;
        if (this.bookmarks.some((b) => b.token === token)) {
            this.bookmarks = this.bookmarks.filter((b) => b.token !== token);
        } else {
            const row = this.panelRows.find((r) => r.token === token);
            if (!row) { return; }
            this.bookmarks = [...this.bookmarks, { token, name: row.name, subtitle: row.subtitle, isHcp: row.isHcp }];
        }
        this.saveBookmarks();
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
        return this.hours.map((h) => ({ key: h, label: `${h}:00` }));
    }

    get gridHeightStyle() {
        return `height:${this.hours.length * HOUR_HEIGHT_PX}px;`;
    }

    get days() {
        const start = this.rangeStart instanceof Date ? this.rangeStart : new Date(this.rangeStart);
        const list = [];
        for (let i = 0; i < 7; i++) {
            const d = new Date(start.getFullYear(), start.getMonth(), start.getDate() + i);
            if (!(this.hideSunday && d.getDay() === 0)) { list.push(d); }
        }
        return list;
    }

    get innerStyle() {
        return `width:${50 + this.days.length * 168}px;`;
    }

    isTimeOff(key) {
        return (this.timeOff || []).some((t) => t.fromDate <= key && key <= t.toDate);
    }

    get dayColumns() {
        const hours = this.hours;
        const todayKey = localDayKey(new Date());
        const callsByDay = new Map();
        for (const c of (this.calls || [])) {
            const k = localDayKey(new Date(c.callDateTime));
            if (!callsByDay.has(k)) { callsByDay.set(k, []); }
            callsByDay.get(k).push(c);
        }
        return this.days.map((d) => {
            const key = localDayKey(d);
            const holiday = holidayOn(d);
            const timeOff = this.isTimeOff(key);
            const isToday = key === todayKey;
            let numClass = 'day-number';
            if (isToday) { numClass += ' day-number-today'; } else if (holiday) { numClass += ' day-number-holiday'; }
            return {
                key,
                weekday: d.toLocaleDateString(undefined, { weekday: 'short' }),
                dayNumber: d.getDate(),
                numClass,
                holidayName: holiday ? holiday.name : null,
                isTimeOff: timeOff,
                columnClass: this.dropDayKey === key ? 'day-column drop-target' : 'day-column',
                tintClass: timeOff ? 'day-tint day-tint-timeoff' : (holiday ? 'day-tint day-tint-holiday' : 'day-tint'),
                cells: hours.map((h) => ({ key: `${key}-${h}`, day: key, hour: h })),
                blocks: this.layoutBlocks(callsByDay.get(key) || [], hours[0]),
            };
        });
    }

    /// Google/Outlook-style layout, same as the app's overlapLayout(): calls whose times
    /// overlap form a cluster; each is given a column within it and the day's width is
    /// divided among that cluster's columns.
    layoutBlocks(dayCalls, firstHour) {
        const sorted = dayCalls
            .map((c) => ({ call: c, start: new Date(c.callDateTime).getTime() }))
            .sort((a, b) => a.start - b.start);
        const placed = [];
        let idx = 0;
        while (idx < sorted.length) {
            let clusterEnd = endOf(sorted[idx].start, sorted[idx].call.durationMin);
            let j = idx + 1;
            while (j < sorted.length && sorted[j].start < clusterEnd) {
                clusterEnd = Math.max(clusterEnd, endOf(sorted[j].start, sorted[j].call.durationMin));
                j += 1;
            }
            const colEnds = [];
            const assigned = [];
            for (const item of sorted.slice(idx, j)) {
                let col = colEnds.findIndex((e) => e <= item.start);
                if (col === -1) { col = colEnds.length; colEnds.push(0); }
                colEnds[col] = endOf(item.start, item.call.durationMin);
                assigned.push({ ...item, col });
            }
            const cols = Math.max(1, colEnds.length);
            assigned.forEach((a) => placed.push({ ...a, cols }));
            idx = j;
        }
        return placed.map(({ call, start, col, cols }) => this.decorateBlock(call, start, col, cols, firstHour));
    }

    // Two visits to the same HCP less than 90 minutes apart (neither cancelled) are flagged.
    hasConflict(call, startMs) {
        if (!call.hcpId) { return false; }
        return (this.calls || []).some((o) => o.id !== call.id && o.hcpId === call.hcpId && o.status !== 'Cancelled'
            && Math.abs(new Date(o.callDateTime).getTime() - startMs) < 90 * 60000);
    }

    decorateBlock(call, startMs, col, cols, firstHour) {
        const d = new Date(startMs);
        const minutesFromTop = (d.getHours() - firstHour) * 60 + d.getMinutes();
        const top = Math.max(0, (minutesFromTop * HOUR_HEIGHT_PX) / 60);
        const duration = call.durationMin || 30;
        const height = Math.max(MIN_BLOCK_PX, (duration * HOUR_HEIGHT_PX) / 60);
        const inset = 4;
        const slot = (168 - inset * 2) / cols;
        const gap = cols > 1 ? 2 : 0;
        const state = call.isEvent ? { color: EVENT_COLOR, label: 'Event' } : visitState(call);
        const conflict = this.hasConflict(call, startMs);
        const name = call.isEvent ? (call.eventTitle || call.hcoName || 'Event') : (call.hcpName || call.hcoName || 'Visit');
        return {
            ...call,
            key: call.id,
            timeLabel: d.toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' }),
            displayName: name,
            nameClass: cols > 2 ? 'block-name block-name-one' : 'block-name',
            detailLine: `${call.callType || ''} · ${duration}m`,
            showDetail: height > 40 && cols < 3,
            showChip: height > 54 && cols === 1,
            chipLabel: state.label,
            chipStyle: `background-color:#${state.color}22;color:#${state.color};`,
            timeStyle: `color:#${state.color};`,
            conflict,
            blockClass: conflict ? 'call-block call-block-conflict' : 'call-block',
            blockStyle: `top:${top}px;left:${inset + col * slot}px;width:${slot - gap}px;height:${height}px;`
                + `background-color:#${state.color}24;border-left-color:#${state.color};`,
        };
    }

    // MARK: - Scheduling: drop an account, or tap an empty slot

    isSunday(dayKey) {
        const [y, m, d] = dayKey.split('-').map(Number);
        return new Date(y, m - 1, d).getDay() === 0;
    }

    blockSunday() {
        this.dispatchEvent(new ShowToastEvent({
            title: 'Can’t schedule on a Sunday',
            message: 'Planned visits can’t be scheduled on a Sunday. Please choose a different day.',
            variant: 'warning',
        }));
    }

    handleDragOver(event) {
        if (this.readOnly) { return; }
        event.preventDefault();
        event.dataTransfer.dropEffect = 'copy';
        this.dropDayKey = event.currentTarget.dataset.day;
    }

    handleDragLeave(event) {
        if (this.dropDayKey === event.currentTarget.dataset.day) { this.dropDayKey = null; }
    }

    // The day and hour come from the drop position; mySchedule opens the scheduling form
    // pre-filled with them, so the rep can adjust duration / call type before anything is saved.
    handleDrop(event) {
        event.preventDefault();
        const dayKey = event.currentTarget.dataset.day;
        this.dropDayKey = null;
        if (this.readOnly) { return; }
        const token = event.dataTransfer.getData('text/plain');
        if (!token) { return; }
        const [prefix, id] = token.split(':');
        if (prefix !== 'hcp' && prefix !== 'hco') { return; }
        if (this.isSunday(dayKey)) { this.blockSunday(); return; }

        const rect = event.currentTarget.getBoundingClientRect();
        const offsetY = event.clientY - rect.top;
        const rawHour = this.hours[0] + Math.floor(offsetY / HOUR_HEIGHT_PX);
        const hour = Math.min(Math.max(rawHour, this.hours[0]), this.hours[this.hours.length - 1]);

        this.dispatchEvent(new CustomEvent('scheduledrop', {
            detail: {
                hcpId: prefix === 'hcp' ? id : null,
                hcoId: prefix === 'hco' ? id : null,
                callDateTime: `${dayKey}T${String(hour).padStart(2, '0')}:00:00`,
            },
        }));
    }

    handleCellClick(event) {
        if (this.readOnly) { return; }
        const { day, hour } = event.currentTarget.dataset;
        if (this.isSunday(day)) { this.blockSunday(); return; }
        this.dispatchEvent(new CustomEvent('slotclick', {
            detail: { callDateTime: `${day}T${String(hour).padStart(2, '0')}:00:00` },
        }));
    }

    // MARK: - Call blocks: open on click, actions on right-click

    handleBlockClick(event) {
        event.stopPropagation();
        this.dispatchEvent(new CustomEvent('opencall', { detail: { id: event.currentTarget.dataset.id } }));
    }

    handleBlockContext(event) {
        event.preventDefault();
        event.stopPropagation();
        this.menu = { x: event.clientX, y: event.clientY, callId: event.currentTarget.dataset.id };
    }

    handleMenuClose() { this.menu = null; }

    get showMenu() { return !!this.menu && this.menuItems.length > 0; }

    get menuStyle() {
        return this.menu ? `left:${this.menu.x}px;top:${this.menu.y}px;` : '';
    }

    /// Same actions as the app's contextMenu on a week block, by state: an unassigned CLM
    /// placeholder can be assigned / edited / deleted; a completed visit can be viewed (and
    /// rescheduled unless its report is submitted); anything else can be started or opened,
    /// rescheduled, marked completed or deleted. Viewing another user's schedule is read-only.
    get menuItems() {
        const c = this.menu ? (this.calls || []).find((x) => x.id === this.menu.callId) : null;
        if (!c) { return []; }
        const items = [];
        const add = (action, label, icon, danger) => items.push({
            key: action, action, label, icon, itemClass: danger ? 'menu-item menu-item-danger' : 'menu-item',
        });
        const done = c.status === 'Completed';
        const unassigned = c.isEvent && !c.hcpId
            && (c.programType === 'CLM Presentation' || (c.eventTitle || '').startsWith('Unassigned CLM'));
        if (c.isReportOnly || this.readOnly) {
            if (c.resultingCVRId) { add('open', 'View Call Report', 'utility:preview'); }
        } else if (unassigned) {
            add('open', 'Assign HCP & File Report', 'utility:adduser');
            add('edit', 'Edit Call', 'utility:edit');
            add('delete', 'Delete', 'utility:delete', true);
        } else if (done) {
            if (!c.isEvent) { add('open', 'View Call Report', 'utility:preview'); }
            if (!c.isLocked) { add('edit', 'Reschedule / Edit plan', 'utility:edit'); }
        } else {
            if (c.hcpId && !c.resultingCVRId) { add('open', 'Start call', 'utility:play'); }
            if (!c.isEvent && c.resultingCVRId) { add('open', 'Open Call Report', 'utility:description'); }
            if (!c.isLocked) { add('edit', 'Reschedule / Edit plan', 'utility:edit'); }
            add('complete', 'Mark completed', 'utility:check');
            add('delete', 'Delete', 'utility:delete', true);
        }
        return items;
    }

    handleMenuAction(event) {
        const action = event.currentTarget.dataset.action;
        const id = this.menu.callId;
        this.menu = null;
        this.dispatchEvent(new CustomEvent('blockaction', { detail: { id, action } }));
    }
}
