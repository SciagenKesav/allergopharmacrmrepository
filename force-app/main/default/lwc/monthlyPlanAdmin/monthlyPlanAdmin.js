import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { NavigationMixin } from 'lightning/navigation';
import getPlans from '@salesforce/apex/MonthlyPlanAdminController.getPlans';
import unlockPlan from '@salesforce/apex/MonthlyPlanAdminController.unlockPlan';

function monthValue(d) {
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-01`;
}

export default class MonthlyPlanAdmin extends NavigationMixin(LightningElement) {
    month = monthValue(new Date());
    search = '';
    @track data = { plans: [], frozen: 0, draft: 0, requested: 0, allowed: true };
    loading = false;
    error;
    // Unlock dialog
    unlockRow;
    reason = '';
    saving = false;
    searchTimer;

    connectedCallback() { this.load(); }

    get monthOptions() {
        const now = new Date();
        const out = [];
        for (let i = -2; i <= 3; i++) {
            const d = new Date(now.getFullYear(), now.getMonth() + i, 1);
            out.push({ label: d.toLocaleDateString(undefined, { month: 'long', year: 'numeric' }), value: monthValue(d) });
        }
        return out;
    }

    get rows() {
        return (this.data.plans || []).map((p) => ({
            ...p,
            isFrozen: p.status === 'Frozen',
            statusClass: p.status === 'Frozen' ? 'badge badge-frozen' : 'badge badge-draft',
            unlockHistory: p.unlockCount > 0 ? `${p.unlockCount}× · last by ${p.lastUnlockedBy || '—'}` : '—',
            disabledUnlock: !p.canUnlock,
            rowClass: p.requestId ? 'row-requested' : ''
        }));
    }
    get hasRows() { return this.rows.length > 0; }
    get notAllowed() { return this.data && this.data.allowed === false; }
    get dialogOpen() { return !!this.unlockRow; }
    get confirmDisabled() { return this.saving || !this.reason || !this.reason.trim(); }

    async load() {
        this.loading = true;
        this.error = undefined;
        try {
            this.data = await getPlans({ monthStart: this.month, search: this.search });
        } catch (e) {
            this.error = (e && e.body && e.body.message) || 'Could not load the plans.';
        } finally {
            this.loading = false;
        }
    }

    monthChanged(e) { this.month = e.detail.value; this.load(); }
    searchChanged(e) {
        this.search = e.target.value;
        clearTimeout(this.searchTimer);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.searchTimer = setTimeout(() => this.load(), 350);
    }

    openRequest(e) {
        this[NavigationMixin.Navigate]({ type: 'standard__recordPage', attributes: { recordId: e.currentTarget.dataset.id, actionName: 'view' } });
    }

    startUnlock(e) {
        const row = this.rows.find((r) => r.id === e.currentTarget.dataset.id);
        this.unlockRow = row;
        this.reason = row && row.requestNote ? `Requested by the rep: ${row.requestNote}` : '';
    }
    reasonChanged(e) { this.reason = e.target.value; }
    cancelUnlock() { this.unlockRow = undefined; this.reason = ''; }

    async confirmUnlock() {
        this.saving = true;
        try {
            await unlockPlan({ planId: this.unlockRow.id, reason: this.reason });
            this.dispatchEvent(new ShowToastEvent({
                title: 'Plan unlocked',
                message: `${this.unlockRow.repName} can change the ${this.unlockRow.month} plan and freeze it again.`,
                variant: 'success'
            }));
            this.cancelUnlock();
            await this.load();
        } catch (err) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Could not unlock', message: (err && err.body && err.body.message) || 'Something went wrong.', variant: 'error'
            }));
        } finally {
            this.saving = false;
        }
    }
}