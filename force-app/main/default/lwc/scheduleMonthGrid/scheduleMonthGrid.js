import { LightningElement, api } from 'lwc';
import { visitState } from 'c/sciagenColors';

const DAY_MS = 24 * 60 * 60 * 1000;
const MAX_VISIBLE_PER_DAY = 3;

// LOCAL calendar-day key — same reasoning as mySchedule.js's localDayKey and
// scheduleWeekGrid.js's own copy: `.toISOString().slice(0,10)` rolls a
// local-midnight Date back a day in any negative-offset timezone, so every
// "which day is this on" comparison here goes through this instead.
function localDayKey(d) {
    const year = d.getFullYear();
    const month = String(d.getMonth() + 1).padStart(2, '0');
    const day = String(d.getDate()).padStart(2, '0');
    return `${year}-${month}-${day}`;
}

/// Classic month calendar grid (always 6 rows x 7 columns, Monday-first) —
/// the third scheduler mode alongside Agenda and Week. Each cell shows up to
/// MAX_VISIBLE_PER_DAY calls (a colored status dot + time + name) with an
/// overflow count for the rest; clicking a call dispatches `edit`, same as
/// scheduleWeekGrid's blocks. No drag-and-drop here — a day cell has no hour
/// axis to derive a drop time from, so that stays a Week-mode capability.
export default class ScheduleMonthGrid extends LightningElement {
    @api calls = [];
    @api rangeStart; // Date — Monday of the first displayed week (may fall in the previous month)
    @api anchorDate; // Date — any day within the month actually being shown

    get weekdayLabels() {
        const base = new Date(2000, 0, 3); // a Monday
        return Array.from({ length: 7 }, (_, i) => {
            const d = new Date(base.getTime() + i * DAY_MS);
            return { key: i, label: d.toLocaleDateString(undefined, { weekday: 'short' }) };
        });
    }

    get weeks() {
        const start = this.rangeStart instanceof Date ? this.rangeStart : new Date(this.rangeStart);
        const anchor = this.anchorDate instanceof Date ? this.anchorDate : new Date(this.anchorDate);
        const anchorMonth = anchor.getMonth();
        const todayKey = localDayKey(new Date());

        const callsByDay = new Map();
        for (const c of (this.calls || [])) {
            const key = localDayKey(new Date(c.callDateTime));
            if (!callsByDay.has(key)) { callsByDay.set(key, []); }
            callsByDay.get(key).push(c);
        }

        const weeks = [];
        let cursor = new Date(start);
        // 6 rows covers every real month's worst case (a 31-day month that
        // starts on the last weekday-slot of its first displayed row).
        for (let w = 0; w < 6; w++) {
            const days = [];
            for (let d = 0; d < 7; d++) {
                const key = localDayKey(cursor);
                const dayCalls = (callsByDay.get(key) || [])
                    .slice()
                    .sort((a, b) => a.callDateTime.localeCompare(b.callDateTime));
                const visible = dayCalls.slice(0, MAX_VISIBLE_PER_DAY).map((c) => this.decorateCall(c));
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
                cursor = new Date(cursor.getTime() + DAY_MS);
            }
            weeks.push({ key: `week-${w}`, days });
        }
        return weeks;
    }

    decorateCall(call) {
        const time = new Date(call.callDateTime).toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' });
        return {
            ...call,
            key: call.id,
            timeLabel: time,
            // A teammate's call (My Schedule now spans the shared territory,
            // not just the viewer's own calls) gets its owner's name tagged
            // on — otherwise it reads as the viewer's own.
            displayName: (call.isEvent ? (call.eventTitle || 'Event') : (call.hcpName || call.hcoName || 'Visit'))
                + (call.isMine ? '' : ` · ${call.ownerName || ''}`),
            // visitState(), not raw call.status — see its doc comment in sciagenColors.js.
            dotStyle: `background-color:#${visitState(call).color};`,
        };
    }

    handleCallClick(event) {
        event.stopPropagation();
        this.dispatchEvent(new CustomEvent('edit', { detail: { id: event.currentTarget.dataset.id } }));
    }
}