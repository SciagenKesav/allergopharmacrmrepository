import { LightningElement, track, wire } from 'lwc';
import { CurrentPageReference } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getContext from '@salesforce/apex/SupportController.getContext';
import listRequests from '@salesforce/apex/SupportController.listRequests';
import createRequest from '@salesforce/apex/SupportController.createRequest';
import uploadFile from '@salesforce/apex/SupportController.uploadFile';
import myCallsForUnlock from '@salesforce/apex/SupportController.myCallsForUnlock';
import { ACCEPT, CATEGORY_HINTS, MAX_FILES, errorText, humanSize, readFile, relTime, statusClass, uuid } from 'c/supportUtil';

const PAGE = 30;

export default class SupportCenter extends LightningElement {
    @track ctx = { categories: [], priorities: [] };
    @track tab = 'open';
    @track search = '';
    @track rows = [];
    @track hasMore = false;
    @track total = 0;
    @track loading = false;
    @track error = '';
    @track selectedId;
    @track showNew = false;

    // new request form
    @track form = { category: 'Sync Problem', subject: '', description: '', priority: 'Normal', callId: '' };
    @track files = [];
    @track calls = [];
    @track formError = '';
    @track saving = false;

    _cursor = { at: null, id: null };
    _searchTimer;
    _linkedId;

    @wire(CurrentPageReference)
    pageRef(ref) {
        const id = ref && ref.state && ref.state.c__id;
        if (id && id !== this._linkedId) {
            this._linkedId = id;
            this.selectedId = id;
        }
    }

    connectedCallback() { this.init(); }

    async init() {
        try { this.ctx = await getContext(); } catch (e) { this.error = errorText(e); }
        await this.reload();
    }

    // ------------------------------------------------------------------ list

    get tabs() {
        const list = [{ value: 'open', label: 'Open' }, { value: 'closed', label: 'Closed' }];
        if (this.ctx.hasTeam) list.push({ value: 'team', label: 'My team' });
        return list.map((t) => ({ ...t, cls: t.value === this.tab ? 'tab tab-on' : 'tab', selected: t.value === this.tab }));
    }

    filter(withCursor) {
        const f = { pageSize: PAGE, text: this.search || null, scope: this.tab === 'team' ? 'team' : 'mine' };
        f.view = this.tab === 'team' ? 'all' : this.tab;
        if (withCursor && this._cursor.at) { f.cursorAt = this._cursor.at; f.cursorId = this._cursor.id; }
        return f;
    }

    async reload() {
        this.loading = true;
        this.error = '';
        this._cursor = { at: null, id: null };
        try {
            const p = await listRequests({ filter: this.filter(false) });
            this.rows = p.rows;
            this.total = p.total || p.rows.length;
            this.apply(p);
        } catch (e) {
            this.error = errorText(e);
        } finally {
            this.loading = false;
        }
    }

    async loadMore() {
        if (!this.hasMore || this.loading) return;
        this.loading = true;
        try {
            const p = await listRequests({ filter: this.filter(true) });
            this.rows = [...this.rows, ...p.rows];
            this.apply(p);
        } catch (e) {
            this.error = errorText(e);
        } finally {
            this.loading = false;
        }
    }

    apply(p) {
        this.hasMore = p.hasMore;
        this._cursor = { at: p.nextAt, id: p.nextId };
    }

    get items() {
        return this.rows.map((r) => {
            const mineWaiting = this.tab !== 'team' && r.isOpen && r.awaiting === 'Requester';
            const unread = this.tab !== 'team' && r.unreadForRequester;
            return {
                ...r,
                key: r.id,
                cls: 'item' + (r.id === this.selectedId ? ' item-on' : '') + (unread ? ' item-unread' : ''),
                statusClass: statusClass(r.status),
                turn: mineWaiting ? 'Waiting on you' : '',
                unread,
                ago: relTime(r.lastActivityAt),
                files: r.attachmentCount > 0 ? String(r.attachmentCount) : '',
                who: this.tab === 'team' ? r.requesterName : ''
            };
        });
    }
    get hasItems() { return this.rows.length > 0; }
    get showEmpty() { return !this.loading && this.rows.length === 0 && !this.error; }
    get emptyTitle() {
        if (this.search) return 'No requests match your search';
        if (this.tab === 'closed') return 'No closed requests yet';
        if (this.tab === 'team') return 'Nothing from your team';
        return 'Nothing open';
    }
    get emptyText() {
        if (this.search) return 'Try a different word, or clear the search.';
        if (this.tab === 'team') return 'Requests raised by people who report to you appear here, and you are copied on them.';
        return 'If something is not working, raise a request and the Business Admin team will reply here.';
    }
    get countText() {
        if (!this.rows.length) return '';
        return this.hasMore ? 'Showing ' + this.rows.length + ' of ' + (this.total >= 10000 ? '10,000+' : this.total) : this.rows.length + (this.rows.length === 1 ? ' request' : ' requests');
    }
    get layoutClass() { return this.selectedId ? 'layout has-selection' : 'layout'; }

    setTab(e) {
        const t = e.currentTarget.dataset.tab;
        if (t === this.tab) return;
        this.tab = t;
        this.selectedId = null;
        this.reload();
    }
    searchChanged(e) {
        const v = e.target.value;
        clearTimeout(this._searchTimer);
        this._searchTimer = setTimeout(() => { this.search = v.trim(); this.reload(); }, 350);
    }
    open(e) { this.selectedId = e.currentTarget.dataset.id; }
    back() { this.selectedId = null; }
    refresh() { this.reload(); }

    handleChange(e) {
        const row = e.detail.row;
        this.rows = this.rows.map((r) => (r.id === row.id ? row : r));
    }

    // ------------------------------------------------------------------ new request

    get categoryOptions() { return this.ctx.categories.map((c) => ({ label: c, value: c })); }
    get priorityOptions() { return this.ctx.priorities.map((c) => ({ label: c, value: c })); }
    get callOptions() { return this.calls.map((c) => ({ label: c.label, value: c.id })); }
    get categoryHint() { return CATEGORY_HINTS[this.form.category] || ''; }
    get isUnlock() { return this.form.category === 'Unlock Submitted Call'; }
    get managerNote() {
        return this.ctx.managerName ? 'Your manager, ' + this.ctx.managerName + ', is copied automatically.' : 'The Business Admin team will reply here.';
    }
    get pendingFiles() { return this.files.map((f) => ({ ...f, sizeText: humanSize(f.size), isImage: !!f.previewUrl })); }
    get canAttachMore() { return this.files.length < MAX_FILES; }
    get accept() { return ACCEPT; }
    get sendDisabled() { return this.saving; }
    get sendLabel() { return this.saving ? 'Sending...' : 'Send request'; }

    openNew() {
        this.form = { category: 'Sync Problem', subject: '', description: '', priority: 'Normal', callId: '' };
        this.files = [];
        this.formError = '';
        this.showNew = true;
    }
    closeNew() { if (!this.saving) this.showNew = false; }

    async categoryChanged(e) {
        this.form = { ...this.form, category: e.detail.value };
        if (this.isUnlock && !this.calls.length) {
            try { this.calls = await myCallsForUnlock(); } catch (err) { this.formError = errorText(err); }
        }
    }
    subjectChanged(e) { this.form = { ...this.form, subject: e.target.value }; }
    descriptionChanged(e) { this.form = { ...this.form, description: e.target.value }; }
    priorityChanged(e) { this.form = { ...this.form, priority: e.detail.value }; }
    callChanged(e) { this.form = { ...this.form, callId: e.detail.value }; }

    pickFiles() { this.template.querySelector('input[type=file]').click(); }
    handlePicked(e) { this.addFiles(Array.from(e.target.files)); e.target.value = ''; }
    handlePaste(e) {
        const list = Array.from((e.clipboardData && e.clipboardData.files) || []);
        if (list.length) { e.preventDefault(); this.addFiles(list); }
    }
    async addFiles(list) {
        this.formError = '';
        for (const f of list) {
            if (this.files.length >= MAX_FILES) { this.formError = 'You can add up to ' + MAX_FILES + ' files.'; break; }
            try { this.files = [...this.files, await readFile(f)]; } catch (err) { this.formError = err.message; }
        }
    }
    removeFile(e) { this.files = this.files.filter((f) => f.key !== e.currentTarget.dataset.key); }

    async submit() {
        this.formError = '';
        if (!this.form.subject.trim()) { this.formError = 'Give the request a short subject.'; return; }
        if (this.isUnlock && !this.form.callId) { this.formError = 'Choose the submitted call you want unlocked.'; return; }
        this.saving = true;
        try {
            const id = await createRequest({
                subject: this.form.subject, description: this.form.description, category: this.form.category,
                priority: this.form.priority, callId: this.isUnlock ? this.form.callId : null, clientId: uuid()
            });
            const failed = [];
            for (const f of this.files) {
                try { await uploadFile({ parentId: id, fileName: f.name, base64: f.base64 }); } catch (err) { failed.push(f.name); }
            }
            this.dispatchEvent(new ShowToastEvent({
                title: 'Request sent',
                message: failed.length ? 'Some files were not added: ' + failed.join(', ') : 'You will see the reply here.',
                variant: failed.length ? 'warning' : 'success'
            }));
            this.showNew = false;
            this.tab = 'open';
            await this.reload();
            this.selectedId = id;
        } catch (e) {
            this.formError = errorText(e);
        } finally {
            this.saving = false;
        }
    }
}