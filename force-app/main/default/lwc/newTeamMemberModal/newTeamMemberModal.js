import { LightningElement, api, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import createTeamMember from '@salesforce/apex/AccountPlanController.createTeamMember';

const ACCESS_OPTIONS = [
    { label: 'Read', value: 'Read' },
    { label: 'Write', value: 'Write' },
];

export default class NewTeamMemberModal extends LightningElement {
    @api planId;
    @api planName;

    @track memberName = '';
    @track role = '';
    @track access = 'Read';

    isSaving = false;
    accessOptions = ACCESS_OPTIONS;

    get planLabel() {
        return this.planName || 'this Account Plan';
    }

    get isSaveDisabled() {
        return this.isSaving || !this.memberName;
    }

    handleNameChange(event) {
        this.memberName = event.target.value;
    }

    handleRoleChange(event) {
        this.role = event.target.value;
    }

    handleAccessChange(event) {
        this.access = event.detail.value;
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
            await createTeamMember({
                planId: this.planId,
                memberName: this.memberName,
                role: this.role,
                accessLevel: this.access,
            });
            this.dispatchEvent(new ShowToastEvent({ title: 'Saved', message: 'Team member added.', variant: 'success' }));
            this.dispatchEvent(new CustomEvent('created'));
        } catch (e) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Couldn’t add Team Member',
                message: e.body?.message || 'Check the highlighted fields and try again.',
                variant: 'error',
            }));
        } finally {
            this.isSaving = false;
        }
    }
}