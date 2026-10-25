import { LightningElement, api, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import createStrategy from '@salesforce/apex/AccountPlanController.createStrategy';

const SHARE_WITH_OPTIONS = [
    { label: 'NOAD', value: 'NOAD' },
    { label: 'PSS', value: 'PSS' },
    { label: 'MSL', value: 'MSL' },
    { label: 'ODM', value: 'ODM' },
];

export default class NewStrategyModal extends LightningElement {
    @api planId;
    @api planName;

    @track strategyName = '';
    @track detail = '';
    @track shareWith = [];

    isSaving = false;
    shareWithOptions = SHARE_WITH_OPTIONS;

    get planLabel() {
        return this.planName || 'this Account Plan';
    }

    get isSaveDisabled() {
        return this.isSaving || !this.strategyName;
    }

    handleNameChange(event) {
        this.strategyName = event.target.value;
    }

    handleDetailChange(event) {
        this.detail = event.target.value;
    }

    handleShareWithChange(event) {
        this.shareWith = event.detail.value;
    }

    handleClose() {
        this.dispatchEvent(new CustomEvent('close'));
    }

    stopPropagation(event) {
        event.stopPropagation();
    }

    async handleSave() {
        this.isSaving = true;
        try {
            await createStrategy({
                planId: this.planId,
                strategyName: this.strategyName,
                detail: this.detail,
                shareWith: this.shareWith,
            });
            this.dispatchEvent(new ShowToastEvent({ title: 'Saved', message: 'Strategy added.', variant: 'success' }));
            this.dispatchEvent(new CustomEvent('created'));
        } catch (e) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Couldn’t add Strategy',
                message: e.body?.message || 'Check the highlighted fields and try again.',
                variant: 'error',
            }));
        } finally {
            this.isSaving = false;
        }
    }
}