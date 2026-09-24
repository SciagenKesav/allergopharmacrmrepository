import { LightningElement, api, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import LightningConfirm from 'lightning/confirm';
import getContext from '@salesforce/apex/SupportController.getContext';
import getRequest from '@salesforce/apex/SupportController.getRequest';
import markRead from '@salesforce/apex/SupportController.markRead';
import addMessage from '@salesforce/apex/SupportController.addMessage';
import cancelRequest from '@salesforce/apex/SupportController.cancelRequest';
import reopenRequest from '@salesforce/apex/SupportController.reopenRequest';
import uploadFile from '@salesforce/apex/SupportController.uploadFile';
import getConsoleContext from '@salesforce/apex/SupportConsoleController.getContext';
import getConsoleRequest from '@salesforce/apex/SupportConsoleController.getRequest';
import consoleMarkRead from '@salesforce/apex/SupportConsoleController.markRead';
import consoleReply from '@salesforce/apex/SupportConsoleController.reply';
import consoleAssign from '@salesforce/apex/SupportConsoleController.assign';
import consolePriority from '@salesforce/apex/SupportConsoleController.setPriority';
import consoleStatus from '@salesforce/apex/SupportConsoleController.setStatus';
import unlockCall from '@salesforce/apex/SupportConsoleController.unlockCall';
import declineUnlock from '@salesforce/apex/SupportConsoleController.declineUnlock';
import { ACCEPT, MAX_FILES, absTime, errorText, humanSize, priorityClass, readFile, relTime, slaText, statusClass, uuid } from 'c/supportUtil';

const REPLY_MODES = [
    { value: 'Waiting on Rep', label: 'Send and wait for the rep' },
    { value: 'Open', label: 'Send and keep open' },
    { value: 'Resolved', label: 'Send and resolve' }
];

export default class SupportThread extends LightningElement {
    @api requestId;
    @api recordId;

    @track ctx = {};
    @track consoleCtx = { agents: [], resolutions: [], canUnlock: false };
    @track detail;
    @track text = '';
    @track pending = [];
    @track replyMode = 'Waiting on Rep';
    @track resolution = 'Answered';
    @track unlockOpen = false;
    @track unlockNote = '';
    @track declineOpen = false;
    @track declineReason = '';
    @track loading = false;
    @track sending = false;
    @track error = '';
    @track fileError = '';
    @track dragging = false;

    _timer;
    _loadedId;
    _scroll = false;

    get currentId() { return this.requestId || this.recordId; }
    get isAgent() { return this.ctx.isAgent === true; }

    connectedCallback() {
        this._timer = setInterval(() => {
            if (!document.hidden && !this.sending && this.currentId) this.load(true);
        }, 45000);
    }
    disconnectedCallback() { clearInterval(this._timer); }

    renderedCallback() {
        if (this.currentId && this.currentId !== this._loadedId) {
            this._loadedId = this.currentId;
            this.text = '';
            this.pending = [];
            this.unlockOpen = false;
            this.declineOpen = false;
            this.error = '';
            this.load(false);
        }
        if (this._scroll) {
            this._scroll = false;
            const box = this.template.querySelector('.thread');
            if (box) box.scrollTop = box.scrollHeight;
        }
    }

    async ensureContext() {
        if (this.ctx.userId) return;
        this.ctx = await getContext();
        if (this.ctx.isAgent) {
            try { this.consoleCtx = await getConsoleContext(); } catch (e) { /* agents without the console class still get the thread */ }
        }
    }

    async load(silent) {
        const id = this.currentId;
        if (!id) return;
        if (!silent) this.loading = true;
        try {
            await this.ensureContext();
            const fresh = this.isAgent ? await getConsoleRequest({ requestId: id }) : await getRequest({ requestId: id });
            if (id !== this.currentId) return;
            const grew = !this.detail || fresh.messages.length !== this.detail.messages.length;
            this.detail = fresh;
            this.error = '';
            if (grew) this._scroll = true;
            const unread = this.isAgent ? fresh.row.unreadForSupport : fresh.row.unreadForRequester && fresh.row.requesterId === this.ctx.userId;
            if (unread) {
                (this.isAgent ? consoleMarkRead : markRead)({ requestId: id }).catch(() => {});
                this.emitChange();
            }
        } catch (e) {
            if (!silent) this.error = errorText(e);
        } finally {
            this.loading = false;
        }
    }

    emitChange() {
        if (this.detail) this.dispatchEvent(new CustomEvent('change', { detail: { id: this.detail.row.id, row: this.detail.row } }));
    }

    // ------------------------------------------------------------------ view model

    get row() { return this.detail ? this.detail.row : null; }
    get hasDetail() { return !!this.detail; }
    get statusPillClass() { return this.row ? statusClass(this.row.status) : ''; }
    get priorityPillClass() { return this.row ? priorityClass(this.row.priority) : ''; }
    get sla() { return this.row ? slaText(this.row) : { text: '', late: false }; }
    get slaClass() { return this.sla.late ? 'sla sla-late' : 'sla'; }
    get showSla() { return this.isAgent && !!this.sla.text; }
    get turnLabel() {
        if (!this.row || !this.row.isOpen) return '';
        if (this.isAgent) return this.row.awaiting === 'Support' ? 'Needs a reply' : 'Waiting on the rep';
        return this.row.awaiting === 'Requester' ? 'Waiting on you' : 'With support';
    }
    get turnClass() { return this.row && this.row.awaiting === (this.isAgent ? 'Support' : 'Requester') ? 'turn turn-you' : 'turn'; }
    get isRequester() { return this.row && this.row.requesterId === this.ctx.userId; }
    get requestedBy() { return this.row ? this.row.requesterName + (this.row.territory ? ' - ' + this.row.territory : '') : ''; }
    get assignedLabel() { return this.row && this.row.assignedName ? this.row.assignedName : 'Not assigned yet'; }
    get managerLabel() { return this.row && this.row.managerName ? this.row.managerName : 'None on file'; }
    get hasCall() { return this.row && !!this.row.callSummary; }
    get raisedAt() { return this.row ? absTime(this.row.createdAt) : ''; }
    get showCancel() { return this.detail && this.detail.canCancel && this.isRequester && !this.isAgent; }
    get showReopen() { return this.detail && this.detail.canReopen && (this.isRequester || this.isAgent) && !this.detail.canCancel; }
    get closedNote() { return this.detail ? this.detail.closedNote : ''; }
    get showComposer() { return this.detail && this.detail.canReply; }
    get composerLabel() { return this.row && !this.row.isOpen ? 'Reply to reopen this request' : 'Reply'; }
    get canSend() { return !this.sending && this.text.trim().length > 0; }
    get canSendDisabled() { return !this.canSend; }
    get sendLabel() {
        if (this.sending) return 'Sending...';
        if (!this.isAgent) return 'Send';
        const m = REPLY_MODES.find((x) => x.value === this.replyMode);
        return m ? m.label : 'Send';
    }
    get replyModes() { return REPLY_MODES.map((m) => ({ ...m, selected: m.value === this.replyMode })); }
    get resolveSelected() { return this.replyMode === 'Resolved'; }
    get resolutionOptions() { return this.consoleCtx.resolutions.map((r) => ({ label: r, value: r })); }
    get agentOptions() {
        return [{ label: 'Not assigned', value: '' }, ...this.consoleCtx.agents.map((a) => ({ label: a.name, value: a.id }))];
    }
    get priorityOptions() { return (this.ctx.priorities || []).map((p) => ({ label: p, value: p })); }
    get assignedValue() { return this.row && this.row.assignedId ? this.row.assignedId : ''; }
    get isUnlockRequest() { return this.row && this.row.category === 'Unlock Submitted Call'; }
    get showUnlock() { return this.isAgent && this.isUnlockRequest && this.row.isOpen && this.row.unlockOutcome !== 'Unlocked' && this.consoleCtx.canUnlock; }
    get unlockOutcomeText() {
        if (!this.row || !this.isUnlockRequest || !this.row.unlockOutcome) return '';
        return this.row.unlockOutcome === 'Unlocked' ? 'Call unlocked. The rep can now edit and submit it again.' : 'Unlock declined.';
    }
    get pendingFiles() { return this.pending.map((f) => ({ ...f, sizeText: humanSize(f.size), isImage: !!f.previewUrl })); }
    get hasPending() { return this.pending.length > 0; }
    get canAttachMore() { return this.pending.length < MAX_FILES; }
    get accept() { return ACCEPT; }
    get composerClass() { return this.dragging ? 'composer composer-drag' : 'composer'; }

    get bubbles() {
        if (!this.detail) return [];
        const me = this.ctx.userId;
        const out = [];
        const d = this.detail;
        if (d.description || d.requestFiles.length) {
            out.push(this.bubble({
                id: 'opening', kind: 'Message', role: 'Requester', authorId: d.row.requesterId, authorName: d.row.requesterName,
                body: d.description, createdAt: d.row.createdAt, sentVia: d.row.source, attachments: d.requestFiles
            }, me, true));
        }
        d.messages.forEach((m) => out.push(this.bubble(m, me, false)));
        return out;
    }

    bubble(m, me, opening) {
        const isEvent = m.kind === 'Event';
        const mine = m.authorId === me;
        const roleLabel = { Requester: 'Rep', Support: 'Business Admin', Manager: 'Manager', System: '' }[m.role] || '';
        return {
            key: m.id,
            isEvent,
            wrapClass: isEvent ? 'evt' : 'msg ' + (mine ? 'msg-mine' : 'msg-theirs'),
            bubbleClass: 'bubble ' + (m.role === 'Support' ? 'bubble-support' : m.role === 'Manager' ? 'bubble-manager' : 'bubble-rep') + (mine ? ' bubble-me' : ''),
            author: mine ? 'You' : m.authorName,
            roleLabel: opening ? 'Original request' : roleLabel,
            time: absTime(m.createdAt),
            ago: relTime(m.createdAt),
            body: m.body,
            via: m.sentVia === 'iPad' ? 'from iPad' : '',
            images: (m.attachments || []).filter((a) => a.isImage).map((a) => ({ ...a, key: a.documentId })),
            files: (m.attachments || []).filter((a) => !a.isImage).map((a) => ({ ...a, key: a.documentId, label: a.title + '.' + a.extension, sizeText: humanSize(a.size) })),
            hasAttachments: !!(m.attachments && m.attachments.length)
        };
    }

    // ------------------------------------------------------------------ composer

    handleText(e) { this.text = e.target.value; }
    handleKey(e) {
        if ((e.ctrlKey || e.metaKey) && e.key === 'Enter' && this.canSend) this.send();
    }
    handleMode(e) { this.replyMode = e.target.value; }
    handleResolution(e) { this.resolution = e.detail.value; }
    pickFiles() { this.template.querySelector('input[type=file]').click(); }
    handlePicked(e) { this.addFiles(Array.from(e.target.files)); e.target.value = ''; }
    handlePaste(e) {
        const files = Array.from((e.clipboardData && e.clipboardData.files) || []);
        if (files.length) { e.preventDefault(); this.addFiles(files); }
    }
    handleDragOver(e) { e.preventDefault(); this.dragging = true; }
    handleDragLeave() { this.dragging = false; }
    handleDrop(e) {
        e.preventDefault();
        this.dragging = false;
        this.addFiles(Array.from(e.dataTransfer.files || []));
    }
    async addFiles(files) {
        this.fileError = '';
        for (const f of files) {
            if (this.pending.length >= MAX_FILES) { this.fileError = 'You can add up to ' + MAX_FILES + ' files to one message.'; break; }
            try { this.pending = [...this.pending, await readFile(f)]; } catch (err) { this.fileError = err.message; }
        }
    }
    removeFile(e) { this.pending = this.pending.filter((f) => f.key !== e.currentTarget.dataset.key); }

    async send() {
        if (!this.canSend) return;
        const id = this.currentId;
        this.sending = true;
        this.error = '';
        try {
            const clientId = uuid();
            let commentId;
            if (this.isAgent) {
                commentId = await consoleReply({
                    requestId: id, body: this.text.trim(), nextStatus: this.replyMode,
                    resolutionType: this.replyMode === 'Resolved' ? this.resolution : null, clientId
                });
            } else {
                commentId = await addMessage({ requestId: id, body: this.text.trim(), clientId });
            }
            const failed = [];
            for (const f of this.pending) {
                try { await uploadFile({ parentId: commentId, fileName: f.name, base64: f.base64 }); } catch (e) { failed.push(f.name + ': ' + errorText(e)); }
            }
            this.text = '';
            this.pending = [];
            if (failed.length) this.fileError = 'Your message was sent, but these files were not added. ' + failed.join(' ');
            this._scroll = true;
            await this.load(true);
            this.emitChange();
        } catch (e) {
            this.error = errorText(e);
        } finally {
            this.sending = false;
        }
    }

    // ------------------------------------------------------------------ actions

    async cancel() {
        const ok = await LightningConfirm.open({ message: 'Cancel this request? Support will stop looking at it.', label: 'Cancel request', variant: 'header', theme: 'warning' });
        if (!ok) return;
        await this.run(() => cancelRequest({ requestId: this.currentId }), 'Request cancelled.');
    }
    reopen() { return this.run(() => reopenRequest({ requestId: this.currentId }), 'Request reopened.'); }
    assignChanged(e) {
        const v = e.detail.value;
        return this.run(() => consoleAssign({ ids: [this.currentId], userId: v || null }), 'Assignment updated.');
    }
    priorityChanged(e) { return this.run(() => consolePriority({ ids: [this.currentId], priority: e.detail.value }), 'Priority updated.'); }
    closeNow() { return this.run(() => consoleStatus({ ids: [this.currentId], status: 'Closed', resolutionType: 'Answered' }), 'Request closed.'); }
    toggleUnlock() { this.unlockOpen = !this.unlockOpen; this.declineOpen = false; }
    toggleDecline() { this.declineOpen = !this.declineOpen; this.unlockOpen = false; }
    unlockNoteChanged(e) { this.unlockNote = e.target.value; }
    declineChanged(e) { this.declineReason = e.target.value; }
    confirmUnlock() {
        return this.run(() => unlockCall({ requestId: this.currentId, note: this.unlockNote }), 'Call unlocked. The rep can edit it on their next sync.', () => { this.unlockOpen = false; this.unlockNote = ''; });
    }
    confirmDecline() {
        return this.run(() => declineUnlock({ requestId: this.currentId, reason: this.declineReason }), 'Unlock declined.', () => { this.declineOpen = false; this.declineReason = ''; });
    }

    async run(action, done, after) {
        this.error = '';
        try {
            const r = await action();
            if (Array.isArray(r) && r.length && r[0].ok === false) throw new Error(r[0].message);
            this.dispatchEvent(new ShowToastEvent({ title: done, variant: 'success' }));
            if (after) after();
            this._scroll = true;
            await this.load(true);
            this.emitChange();
        } catch (e) {
            this.error = errorText(e);
        }
    }
}