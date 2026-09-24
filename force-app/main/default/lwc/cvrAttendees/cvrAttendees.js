import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { deleteRecord } from 'lightning/uiRecordApi';

/// CVR_Attendee__c (group-call HCP attendees) child list — see cvrKeyMessages.js
/// for the shared Master-Detail add/delete pattern this copies. No in-place
/// edit — an attendee is either on the call or not; to change who, delete and
/// re-add, same as accountBrowser's own list-membership UX.
export default class CvrAttendees extends LightningElement {
    @api cvrId;
    @api locked = false;
    @api rows = [];

    showAdd = false;
    isSaving = false;

    get hasRows() {
        return (this.rows || []).length > 0;
    }

    handleAdd() {
        this.showAdd = true;
    }

    handleCancelAdd() {
        this.showAdd = false;
        this.isSaving = false;
    }

    handleSubmit() {
        this.isSaving = true;
    }

    handleSuccess() {
        this.showAdd = false;
        this.isSaving = false;
        this.dispatchEvent(new ShowToastEvent({ title: 'Saved', message: 'Attendee added.', variant: 'success' }));
        this.dispatchEvent(new CustomEvent('refresh'));
    }

    handleError(event) {
        this.isSaving = false;
        this.dispatchEvent(new ShowToastEvent({
            title: 'Couldn’t add attendee',
            message: event.detail?.detail || event.detail?.message || 'Check the highlighted fields and try again.',
            variant: 'error',
        }));
    }

    async handleDelete(event) {
        const id = event.currentTarget.dataset.id;
        try {
            await deleteRecord(id);
            this.dispatchEvent(new ShowToastEvent({ title: 'Removed', message: 'Attendee removed.', variant: 'success' }));
            this.dispatchEvent(new CustomEvent('refresh'));
        } catch (e) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Couldn’t remove attendee', message: e.body?.message || 'Try again.', variant: 'error',
            }));
        }
    }
}