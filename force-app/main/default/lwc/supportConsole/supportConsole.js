import { LightningElement, track, wire } from 'lwc';
import { CurrentPageReference } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getContext from '@salesforce/apex/SupportConsoleController.getContext';
import getBoard from '@salesforce/apex/SupportConsoleController.getBoard';
import listRequests from '@salesforce/apex/SupportConsoleController.listRequests';
import exportRows from '@salesforce/apex/SupportConsoleController.exportRows';
import assign from '@salesforce/apex/SupportConsoleController.assign';
import setStatus from '@salesforce/apex/SupportConsoleController.setStatus';
import setPriority from '@salesforce/apex/SupportConsoleController.setPriority';
import { errorText, priorityClass, relTime, slaText, statusClass } from 'c/supportUtil';

const PAGE = 50;
const SORTS = {
    activity: { field: 'Last_Activity_At__c', dir: 'DESC', label: 'Latest activity' },
    newest: { field: 'CreatedDate', dir: 'DESC', label: 'Newest first' },
    oldest: { field: 'CreatedDate', dir: 'ASC', label: 'Oldest first' },
    sla: { field: 'SLA_Due_At__c', dir: 'ASC', label: 'First reply due soonest' }
};

export default class SupportConsole extends LightningElement {
    @track ctx = { agents: [], categories: [], priorities: [], resolutions: [], statuses: [] };
    @track board;
    @track view = 'open';
    @track f = { text: '', category: '', priority: '', assignedToId: '', territory: '', fromDate: '', toDate: '', sort: 'activity' };
    @track rows = [];
    @track selected = [];
    @track selectedId;
    @track hasMore = false;
    @track total = 0;
    @track loading = false;
    @track error = '';
    @track showInsights = true;
    @track stale = false;
    @track bulkAssignee = '';
    @track bulkPriority = '';
    @track bulkResolution = 'Answered';
    @track bulkMessage = '';
    @track exporting = false;

    _cursor = { at: null, id: null };
    _timer;
    _debounce;
    _boardTimer;
    _snapshot = '';
    _linkedId;

    @wire(CurrentPageReference)
    pageRef(ref) {
        const id = ref && ref.state && ref.state.c__id;
        if (id && id !== this._linkedId) { this._linkedId = id; this.selectedId = id; }
    }

    connectedCallback() {
        this.init();
        this._timer = setInterval(() => { if (!document.hidden) this.refreshBoard(true); }, 60000);
    }
    disconnectedCallback() { clearInterval(this._timer); clearTimeout(this._debounce); clearTimeout(this._boardTimer); }

    async init() {
        try { this.ctx = await getContext(); } catch (e) { this.error = errorText(e); return; }
        await Promise.all([this.refreshBoard(false), this.reload()]);
    }

    // ------------------------------------------------------------------ board

    async refreshBoard(watch) {
        try {
            const b = await getBoard();
            const snap = [b.open, b.needsReply, b.unassigned, b.openedToday].join('|');
            if (watch && this._snapshot && snap !== this._snapshot) this.stale = true;
            this.board = b;
        } catch (e) {
            if (!watch) this.error = errorText(e);
        }
    }

    get tiles() {
        const b = this.board;
        if (!b) return [];
        const t = (label, value, view, tone) => ({
            label, value, view, key: label, tone,
            cls: 'tile' + (view ? ' tile-click' : '') + (view && view === this.view ? ' tile-on' : '') + (tone ? ' tile-' + tone : ''),
            clickable: !!view
        });
        return [
            t('Open', b.open, 'open'),
            t('Needs a reply', b.needsReply, 'needsReply', b.needsReply > 0 ? 'warn' : ''),
            t('Unassigned', b.unassigned, 'unassigned', b.unassigned > 0 ? 'warn' : ''),
            t('Overdue', b.overdue, 'overdue', b.overdue > 0 ? 'bad' : ''),
            t('Waiting on rep', b.waiting, 'waiting'),
            t('Assigned to me', b.mine, 'mine'),
            t('Raised today', b.openedToday, null),
            t('Resolved today', b.resolvedToday, null),
            t('Avg first reply (7 d)', b.avgFirstResponseHours == null ? '-' : b.avgFirstResponseHours + ' h', null)
        ];
    }
    get oldestText() { return this.board && this.board.oldestOpenDays != null ? 'Oldest open request: ' + this.board.oldestOpenDays + ' days' : ''; }
    get trend() {
        if (!this.board) return [];
        const max = Math.max(1, ...this.board.trend.map((d) => Math.max(d.raised, d.resolved)));
        return this.board.trend.map((d) => ({
            key: d.day,
            label: new Date(d.day + 'T00:00:00').toLocaleDateString(undefined, { day: 'numeric', month: 'short' }),
            raisedStyle: 'height:' + Math.round((d.raised / max) * 100) + '%',
            resolvedStyle: 'height:' + Math.round((d.resolved / max) * 100) + '%',
            title: d.raised + ' raised, ' + d.resolved + ' resolved'
        }));
    }
    get categories() {
        if (!this.board) return [];
        const max = Math.max(1, ...this.board.byCategory.map((c) => c.count));
        return this.board.byCategory.map((c) => ({ key: c.category, category: c.category, count: c.count, style: 'width:' + Math.round((c.count / max) * 100) + '%' }));
    }
    get insightsLabel() { return this.showInsights ? 'Hide insights' : 'Show insights'; }
    toggleInsights() { this.showInsights = !this.showInsights; }

    // ------------------------------------------------------------------ views and filters

    get views() {
        const b = this.board || {};
        const v = (value, label, count) => ({ value, label, count: count == null ? '' : count, key: value, cls: value === this.view ? 'vtab vtab-on' : 'vtab', selected: value === this.view });
        return [v('open', 'All open', b.open), v('needsReply', 'Needs reply', b.needsReply), v('unassigned', 'Unassigned', b.unassigned), v('mine', 'Mine', b.mine),
                v('overdue', 'Overdue', b.overdue), v('waiting', 'Waiting on rep', b.waiting), v('closed', 'Closed'), v('all', 'Everything')];
    }
    setView(e) { this.selectView(e.currentTarget.dataset.view); }
    selectView(v) { if (!v) return; this.view = v; this.selected = []; this.reload(); }
    tileClick(e) { this.selectView(e.currentTarget.dataset.view); }

    get categoryOptions() { return [{ label: 'All categories', value: '' }, ...this.ctx.categories.map((c) => ({ label: c, value: c }))]; }
    get priorityOptions() { return [{ label: 'Any priority', value: '' }, ...this.ctx.priorities.map((c) => ({ label: c, value: c }))]; }
    get assigneeOptions() { return [{ label: 'Anyone', value: '' }, { label: 'Unassigned', value: 'none' }, ...this.ctx.agents.map((a) => ({ label: a.name, value: a.id }))]; }
    get sortOptions() { return Object.keys(SORTS).map((k) => ({ label: SORTS[k].label, value: k })); }
    get bulkAssigneeOptions() { return [{ label: 'Choose an admin', value: '' }, ...this.ctx.agents.map((a) => ({ label: a.name, value: a.id }))]; }
    get bulkPriorityOptions() { return [{ label: 'Set priority', value: '' }, ...this.ctx.priorities.map((c) => ({ label: c, value: c }))]; }
    get resolutionOptions() { return this.ctx.resolutions.map((r) => ({ label: r, value: r })); }
    get hasFilters() { const f = this.f; return !!(f.text || f.category || f.priority || f.assignedToId || f.territory || f.fromDate || f.toDate); }

    filterChanged(e) {
        const name = e.currentTarget.dataset.name;
        const value = e.detail && e.detail.value !== undefined ? e.detail.value : e.target.value;
        this.f = { ...this.f, [name]: value };
        clearTimeout(this._debounce);
        this._debounce = setTimeout(() => this.reload(), name === 'text' || name === 'territory' ? 400 : 50);
    }
    sortChanged(e) { this.f = { ...this.f, sort: e.detail.value }; this.reload(); }
    clearFilters() { this.f = { text: '', category: '', priority: '', assignedToId: '', territory: '', fromDate: '', toDate: '', sort: this.f.sort }; this.reload(); }

    buildFilter(withCursor) {
        const s = SORTS[this.f.sort] || SORTS.activity;
        const out = {
            view: this.view, pageSize: PAGE, sortField: s.field, sortDir: s.dir,
            text: this.f.text || null, category: this.f.category || null, priority: this.f.priority || null,
            assignedToId: this.f.assignedToId || null, territory: this.f.territory || null,
            fromDate: this.f.fromDate || null, toDate: this.f.toDate || null
        };
        if (withCursor && this._cursor.at) { out.cursorAt = this._cursor.at; out.cursorId = this._cursor.id; }
        return out;
    }

    // ------------------------------------------------------------------ list

    async reload() {
        this.loading = true;
        this.error = '';
        this.stale = false;
        this._cursor = { at: null, id: null };
        try {
            const p = await listRequests({ filter: this.buildFilter(false) });
            this.rows = p.rows;
            this.total = p.total == null ? p.rows.length : p.total;
            this.hasMore = p.hasMore;
            this._cursor = { at: p.nextAt, id: p.nextId };
            this.selected = [];
            if (this.board) this._snapshot = [this.board.open, this.board.needsReply, this.board.unassigned, this.board.openedToday].join('|');
        } catch (e) {
            this.error = errorText(e);
        } finally {
            this.loading = false;
        }
    }

    async refreshAll() { await this.refreshBoard(false); await this.reload(); }

    async loadMore() {
        if (!this.hasMore || this.loading) return;
        this.loading = true;
        try {
            const p = await listRequests({ filter: this.buildFilter(true) });
            this.rows = [...this.rows, ...p.rows];
            this.hasMore = p.hasMore;
            this._cursor = { at: p.nextAt, id: p.nextId };
        } catch (e) {
            this.error = errorText(e);
        } finally {
            this.loading = false;
        }
    }

    get lines() {
        return this.rows.map((r) => {
            const sla = slaText(r);
            const on = this.selected.includes(r.id);
            return {
                ...r,
                key: r.id,
                rowClass: 'row' + (r.id === this.selectedId ? ' row-open' : '') + (r.unreadForSupport ? ' row-unread' : ''),
                checked: on,
                statusClass: statusClass(r.status),
                priorityClass: priorityClass(r.priority),
                turn: r.isOpen ? (r.awaiting === 'Support' ? 'Needs reply' : 'Waiting on rep') : '',
                turnClass: r.isOpen && r.awaiting === 'Support' ? 'turn turn-you' : 'turn',
                assigned: r.assignedName || 'Unassigned',
                assignedClass: r.assignedName ? '' : 'unassigned',
                sla: sla.text,
                slaClass: sla.late ? 'sla sla-late' : 'sla',
                ago: relTime(r.lastActivityAt),
                raised: relTime(r.createdAt),
                counts: (r.commentCount || 0) + (r.attachmentCount ? ' - ' + r.attachmentCount + ' file' + (r.attachmentCount > 1 ? 's' : '') : ''),
                who: r.requesterName + (r.territory ? ' - ' + r.territory : '')
            };
        });
    }
    get hasRows() { return this.rows.length > 0; }
    get showEmpty() { return !this.loading && !this.rows.length && !this.error; }
    get countText() {
        if (!this.rows.length) return '0 requests';
        const shown = this.rows.length.toLocaleString();
        return this.hasMore ? 'Showing ' + shown + ' of ' + (this.total >= 10000 ? '10,000+' : this.total.toLocaleString()) : shown + (this.rows.length === 1 ? ' request' : ' requests');
    }
    get allChecked() { return this.rows.length > 0 && this.selected.length === this.rows.length; }
    get selectedCount() { return this.selected.length; }
    get hasSelection() { return this.selected.length > 0; }
    get bulkAssigneeMissing() { return !this.bulkAssignee; }
    get bulkLabel() { return this.selected.length + ' selected'; }
    get pageClass() { return this.selectedId ? 'body has-drawer' : 'body'; }

    toggleAll(e) { this.selected = e.target.checked ? this.rows.map((r) => r.id) : []; }
    toggleOne(e) {
        const id = e.currentTarget.dataset.id;
        this.selected = e.target.checked ? [...this.selected, id] : this.selected.filter((x) => x !== id);
    }
    stop(e) { e.stopPropagation(); }
    openRow(e) { this.selectedId = e.currentTarget.dataset.id; }
    closeDrawer() { this.selectedId = null; }

    handleChange(e) {
        const row = e.detail.row;
        this.rows = this.rows.map((r) => (r.id === row.id ? row : r));
        clearTimeout(this._boardTimer);
        this._boardTimer = setTimeout(() => this.refreshBoard(false), 800);
    }

    // ------------------------------------------------------------------ bulk actions

    bulkAssigneeChanged(e) { this.bulkAssignee = e.detail.value; }
    bulkPriorityChanged(e) { this.bulkPriority = e.detail.value; if (e.detail.value) this.runBulk(() => setPriority({ ids: this.selected, priority: e.detail.value }), 'Priority updated'); }
    bulkResolutionChanged(e) { this.bulkResolution = e.detail.value; }
    doAssign() { if (this.bulkAssignee) this.runBulk(() => assign({ ids: this.selected, userId: this.bulkAssignee }), 'Assigned'); }
    assignToMe() { this.runBulk(() => assign({ ids: this.selected, userId: this.ctx.userId }), 'Assigned to you'); }
    doWaiting() { this.runBulk(() => setStatus({ ids: this.selected, status: 'Waiting on Rep', resolutionType: null }), 'Marked waiting on rep'); }
    doResolve() { this.runBulk(() => setStatus({ ids: this.selected, status: 'Resolved', resolutionType: this.bulkResolution }), 'Resolved'); }
    doClose() { this.runBulk(() => setStatus({ ids: this.selected, status: 'Closed', resolutionType: this.bulkResolution }), 'Closed'); }
    clearSelection() { this.selected = []; this.bulkMessage = ''; }

    async runBulk(action, doneText) {
        this.bulkMessage = '';
        try {
            const res = await action();
            const failed = res.filter((r) => !r.ok);
            const ok = res.length - failed.length;
            this.dispatchEvent(new ShowToastEvent({
                title: doneText + ': ' + ok + ' of ' + res.length,
                message: failed.length ? failed.slice(0, 2).map((r) => r.message).join(' ') : '',
                variant: failed.length ? 'warning' : 'success'
            }));
            if (failed.length) this.bulkMessage = failed.length + ' could not be updated: ' + failed[0].message;
            this.bulkPriority = '';
            await this.refreshBoard(false);
            const keep = this.selected;
            await this.reload();
            this.selected = failed.length ? keep.filter((id) => failed.some((f) => f.id === id)) : [];
        } catch (e) {
            this.bulkMessage = errorText(e);
        }
    }

    // ------------------------------------------------------------------ export

    async exportCsv() {
        this.exporting = true;
        try {
            const data = await exportRows({ filter: this.buildFilter(false) });
            const head = ['Number', 'Subject', 'Category', 'Priority', 'Status', 'Raised by', 'Territory', 'Manager', 'Assigned to', 'Raised', 'Last activity', 'First reply due', 'Resolution', 'Messages', 'Files', 'Call', 'Source'];
            const cell = (v) => { const s = v == null ? '' : String(v); return /[",\r\n]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s; };
            const lines = data.map((r) => [r.name, r.subject, r.category, r.priority, r.status, r.requesterName, r.territory, r.managerName, r.assignedName,
                r.createdAt, r.lastActivityAt, r.slaDueAt, r.resolution, r.commentCount, r.attachmentCount, r.callSummary, r.source].map(cell).join(','));
            const csv = [head.join(','), ...lines].join('\r\n');
            const a = document.createElement('a');
            a.href = 'data:text/csv;charset=utf-8,' + encodeURIComponent('﻿' + csv);
            a.download = 'support-requests.csv';
            document.body.appendChild(a);
            a.click();
            document.body.removeChild(a);
            if (data.length >= 2000) this.dispatchEvent(new ShowToastEvent({ title: 'Export limited to 2,000 requests', message: 'Narrow the filters to export the rest.', variant: 'info' }));
        } catch (e) {
            this.error = errorText(e);
        } finally {
            this.exporting = false;
        }
    }
}