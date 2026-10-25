import { LightningElement, api, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import createGoal from '@salesforce/apex/AccountPlanController.createGoal';

export default class NewGoalModal extends LightningElement {
    @api planId;
    @api planName;

    @track title = '';
    @track metric = '';
    @track target;
    @track current;
    @track unit = '';
    @track dueDate;

    isSaving = false;

    get planLabel() {
        return this.planName || 'this Account Plan';
    }

    get isSaveDisabled() {
        return this.isSaving || !this.title;
    }

    handleTitleChange(event) {
        this.title = event.target.value;
    }

    handleMetricChange(event) {
        this.metric = event.target.value;
    }

    handleTargetChange(event) {
        this.target = event.target.value;
    }

    handleCurrentChange(event) {
        this.current = event.target.value;
    }

    handleUnitChange(event) {
        this.unit = event.target.value;
    }

    handleDueDateChange(event) {
        this.dueDate = event.target.value;
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
            await createGoal({
                planId: this.planId,
                title: this.title,
                metric: this.metric,
                target: this.target === '' ? null : this.target,
                current: this.current === '' ? null : this.current,
                unit: this.unit,
                dueDate: this.dueDate || null,
            });
            this.dispatchEvent(new ShowToastEvent({ title: 'Saved', message: 'Goal added.', variant: 'success' }));
            this.dispatchEvent(new CustomEvent('created'));
        } catch (e) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Couldn’t add Goal',
                message: e.body?.message || 'Check the highlighted fields and try again.',
                variant: 'error',
            }));
        } finally {
            this.isSaving = false;
        }
    }
}