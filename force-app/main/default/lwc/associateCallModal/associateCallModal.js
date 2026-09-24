import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getLinkableCalls from '@salesforce/apex/AccountPlanController.getLinkableCalls';
import linkCallToPlan from '@salesforce/apex/AccountPlanController.linkCallToPlan';

export default class AssociateCallModal extends LightningElement {
    @api planId;
    @api planName;

    options = [];
    isLoading = true;
    linkingId;

    get planLabel() {
        return this.planName || 'this Account Plan';
    }

    get hasOptions() {
        return this.options.length > 0;
    }

    get rows() {
        return this.options.map((o) => ({ ...o, key: `${o.kind}-${o.id}`, isLinking: this.linkingId === o.id }));
    }

    connectedCallback() {
        this.loadOptions();
    }

    async loadOptions() {
        this.isLoading = true;
        try {
            this.options = await getLinkableCalls({ planId: this.planId });
        } catch (e) {
            this.options = [];
        } finally {
            this.isLoading = false;
        }
    }

    async handleLink(event) {
        const id = event.currentTarget.dataset.id;
        const kind = event.currentTarget.dataset.kind;
        this.linkingId = id;
        try {
            await linkCallToPlan({ callId: id, kind, planId: this.planId });
            this.dispatchEvent(new ShowToastEvent({ title: 'Linked', message: 'Call linked to this Account Plan.', variant: 'success' }));
            this.dispatchEvent(new CustomEvent('linked'));
        } catch (e) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Couldn’t link call',
                message: e.body?.message || 'Try again.',
                variant: 'error',
            }));
        } finally {
            this.linkingId = undefined;
        }
    }

    handleClose() {
        this.dispatchEvent(new CustomEvent('close'));
    }

    stopPropagation(event) {
        event.stopPropagation();
    }
}