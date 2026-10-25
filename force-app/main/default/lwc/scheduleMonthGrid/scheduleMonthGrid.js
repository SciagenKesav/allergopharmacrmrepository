import { LightningElement, api } from 'lwc';
import { visitState } from 'c/sciagenColors';

const DAY_MS = 24 * 60 * 60 * 1000;

// LOCAL calendar-day key -- same reasoning as mySchedule.js's localDayKey: toISOString()
// would roll a local-midnight Date back a day in any negative-offset timezone.
function localDayKey(d) {
    const year = d.getFullYear();
    const month = String(d.getMonth() + 1).padStart(2, '0');
    const day = String(d.getDate()).padStart(2, '0');
    return `${year}-${month}-${day}`;
}

/// Month view -- ports CalendarPlannerView.swift's monthMode: a Monday-first 6-row grid of
/// day boxes, each listing its calls as colour-coded chips (status dot + time + name).
/// Clicking a chip dispatches `opencall` (the parent opens the call exactly like the app);
/// "+N more" dispatches `openday` so the parent can show that day in the Agenda.
export default class ScheduleMonthGrid extends LightningElement {
    @api calls = [];
    @api rangeStart; // Date -- Monday of the first displayed week (may fall in the previous month)
    @api anchorDate; // Date -- any day within the month being shown

    hideSunday = false;

    get hideSundayLabel() {
        return this.hideSunday ? 'Mon–Sat' : 'Mon–Sun';
    }

    handleToggleHideSunday() {
        this.hideSunday = !this.hideSunday;
    }

    get gridClass() {
        return this.hideSunday ? 'month-grid month-grid-six' : 'month-grid';
    }

    get dayCount() {
        return this.hideSunday ? 6 : 7;
    }

    get weekdayLabels() {
        const base = new Date(2000, 0, 3); // a Monday
        return Array.from({ length: this.dayCount }, (_, i) => {
            const d = new Date(base.getTime() + i * DAY_MS);
            return { key: i, label: d.toLocaleDateString(undefined, { weekday: 'short' }) };
        });
    }

    get weeks() {
        const start = this.rangeStart instanceof Date ? this.rangeStart : new Date(this.rangeStart);
        const anchor = this.anchorDate instanceof Date ? this.anchorDate : new Date(this.anchorDate);
        const anchorMonth = anchor.getMonth();
        const todayKey = localDayKey(new Date());
        const maxVisible = 3;

        const callsByDay = new Map();
        for (const c of (this.calls || [])) {
            const key = localDayKey(new Date(c.callDateTime));
            if (!callsByDay.has(key)) { callsByDay.set(key, []); }
            callsByDay.get(key).push(c);
        }

        const weeks = [];
        let cursor = new Date(start);
        for (let w = 0; w < 6; w++) {
            const days = [];
            for (let d = 0; d < 7; d++) {
                const key = localDayKey(cursor);
                if (!(this.hideSunday && d === 6)) {
                    const dayCalls = (callsByDay.get(key) || [])
                        .slice()
                        .sort((a, b) => a.callDateTime.localeCompare(b.callDateTime));
                    const visible = dayCalls.slice(0, maxVisible).map((c) => this.decorateCall(c));
                    const overflow = dayCalls.length - visible.length;
                    const isCurrentMonth = cursor.getMonth() === anchorMonth;
                    const isToday = key === todayKey;
                    days.push({
                        key,
                        dayNumber: cursor.getDate(),
                        cellClass: `month-cell${isCurrentMonth ? '' : ' month-cell-outside'}${isToday ? ' month-cell-today' : ''}`,
                        dayNumberClass: isToday ? 'month-day-number month-day-number-today' : 'month-day-number',
                        calls: visible,
                        overflowCount: overflow > 0 ? overflow : 0,
                        hasOverflow: overflow > 0,
                    });
                }
                cursor = new Date(cursor.getTime() + DAY_MS);
            }
            weeks.push({ key: `week-${w}`, days });
        }
        return weeks;
    }

    decorateCall(call) {
        const time = new Date(call.callDateTime).toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' });
        const color = call.isEvent ? '6D5BD0' : visitState(call).color;
        return {
            ...call,
            key: call.id,
            timeLabel: time,
            displayName: call.isEvent ? (call.eventTitle || 'Event') : (call.hcpName || call.hcoName || 'Visit'),
            dotStyle: `background-color:#${color};`,
            chipStyle: `background-color:#${color}1F;`,
        };
    }

    handleCallClick(event) {
        event.stopPropagation();
        this.dispatchEvent(new CustomEvent('opencall', { detail: { id: event.currentTarget.dataset.id } }));
    }

    handleMoreClick(event) {
        event.stopPropagation();
        this.dispatchEvent(new CustomEvent('openday', { detail: { day: event.currentTarget.dataset.day } }));
    }
}
