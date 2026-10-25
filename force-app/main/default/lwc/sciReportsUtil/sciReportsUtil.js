// Shared helpers for the Reports workspace: period maths (Monday-start weeks), ISO dates, CSV export.
export const PERIOD_OPTIONS = [
    { label: 'Today', value: 'today' }, { label: 'This Week', value: 'week' }, { label: 'Last Week', value: 'lastweek' },
    { label: 'This Month', value: 'month' }, { label: 'Last Month', value: 'lastmonth' }, { label: 'This Quarter', value: 'quarter' },
    { label: 'Year to Date', value: 'ytd' }, { label: 'Custom Range', value: 'custom' }
];
const MON = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

export function iso(d) {
    const m = String(d.getMonth() + 1).padStart(2, '0');
    const day = String(d.getDate()).padStart(2, '0');
    return `${d.getFullYear()}-${m}-${day}`;
}
export function parseIso(s) {
    const [y, m, d] = s.split('-').map(Number);
    return new Date(y, m - 1, d);
}
function fmtDay(d) { return `${d.getDate()} ${MON[d.getMonth()]}`; }
function fmtFull(d) { return `${fmtDay(d)} ${d.getFullYear()}`; }
function addDays(d, n) { const x = new Date(d.getFullYear(), d.getMonth(), d.getDate()); x.setDate(x.getDate() + n); return x; }

export function computePeriod(name, from, to) {
    const t = new Date();
    const today = new Date(t.getFullYear(), t.getMonth(), t.getDate());
    const monday = addDays(today, -((today.getDay() + 6) % 7));
    let start = today, end = today, label = PERIOD_OPTIONS.find(p => p.value === name)?.label;
    switch (name) {
        case 'today': break;
        case 'week': start = monday; break;
        case 'lastweek': start = addDays(monday, -7); end = addDays(monday, -1); break;
        case 'month': start = new Date(today.getFullYear(), today.getMonth(), 1); break;
        case 'lastmonth': start = new Date(today.getFullYear(), today.getMonth() - 1, 1); end = new Date(today.getFullYear(), today.getMonth(), 0); break;
        case 'quarter': start = new Date(today.getFullYear(), Math.floor(today.getMonth() / 3) * 3, 1); break;
        case 'ytd': start = new Date(today.getFullYear(), 0, 1); break;
        case 'custom': {
            start = from ? parseIso(from) : today; end = to ? parseIso(to) : start;
            if (end < start) end = start;
            label = null; break;
        }
        default: break;
    }
    const range = start.getTime() === end.getTime() ? fmtFull(start) : `${fmtDay(start)} – ${fmtFull(end)}`;
    return { name, start: iso(start), end: iso(end), range, label: label ? `${label} (${range})` : range, periodName: label || 'Custom' };
}

export function csvEscape(v) {
    const s = v === null || v === undefined ? '' : String(v);
    return `"${s.replace(/"/g, '""')}"`;
}
export function downloadCsv(filename, columns, rows) {
    const lines = [columns.map(c => csvEscape(c.label)).join(',')];
    rows.forEach(r => lines.push(columns.map(c => csvEscape(r[c.key])).join(',')));
    const blob = new Blob([lines.join('\n')], { type: 'text/csv;charset=utf-8;' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url; a.download = `${filename}.csv`;
    document.body.appendChild(a); a.click(); document.body.removeChild(a);
    URL.revokeObjectURL(url);
}

// Sorting rule: strip %, ₹, $, commas and +; numbers compare numerically and come before "—"; otherwise natural text order.
export function cellNumber(v) {
    if (v === null || v === undefined) return NaN;
    const s = String(v).replace(/[%₹$,+]/g, '').trim();
    if (s === '' || s === '—') return NaN;
    return Number(s);
}
export function compareCells(a, b) {
    const na = cellNumber(a), nb = cellNumber(b);
    if (!isNaN(na) && !isNaN(nb)) return na - nb;
    const dashA = a === '—', dashB = b === '—';
    if (!isNaN(na) && dashB) return -1;
    if (!isNaN(nb) && dashA) return 1;
    return String(a ?? '').localeCompare(String(b ?? ''), undefined, { numeric: true, sensitivity: 'base' });
}
