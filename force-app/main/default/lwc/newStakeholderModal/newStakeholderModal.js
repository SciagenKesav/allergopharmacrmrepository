import { LightningElement, api, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import createStakeholder from '@salesforce/apex/AccountPlanController.createStakeholder';

const INFLUENCE_OPTIONS = [
    { label: 'Low', value: 'Low' },
    { label: 'Medium', value: 'Medium' },
    { label: 'High', value: 'High' },
    { label: 'Critical', value: 'Critical' },
];

const STRENGTH_OPTIONS = [
    { label: 'Weak', value: 'Weak' },
    { label: 'Developing', value: 'Developing' },
    { label: 'Strong', value: 'Strong' },
    { label: 'Advocate', value: 'Advocate' },
];

export default class NewStakeholderModal extends LightningElement {
    @api planId;
    @api planName;

    @track stakeholderName = '';
    @track role = '';
    @track influence = 'Medium';
    @track strength = 'Developing';

    isSaving = false;
    influenceOptions = INFLUENCE_OPTIONS;
    strengthOptions = STRENGTH_OPTIONS;

    get planLabel() {
        return this.planName || 'this Account Plan';
    }

    get isSaveDisabled() {
        return this.isSaving || !this.stakeholderName;
    }

    handleNameChange(event) {
        this.stakeholderName = event.target.value;
    }

    handleRoleChange(event) {
        this.role = event.target.value;
    }

    handleInfluenceChange(event) {
        this.influence = event.detail.value;
    }

    handleStrengthChange(event) {
        this.strength = event.detail.value;
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
            await createStakeholder({
                planId: this.planId,
                stakeholderName: this.stakeholderName,
                role: this.role,
                influence: this.influence,
                strength: this.strength,
            });
            this.dispatchEvent(new ShowToastEvent({ title: 'Saved', message: 'Stakeholder added.', variant: 'success' }));
            this.dispatchEvent(new CustomEvent('created'));
        } catch (e) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Couldn’t add Stakeholder',
                message: e.body?.message || 'Check the highlighted fields and try again.',
                variant: 'error',
            }));
        } finally {
            this.isSaving = false;
        }
    }
}