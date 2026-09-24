import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { deleteRecord } from 'lightning/uiRecordApi';

/// CVR_Internal_Attendee__c (colleague attendees, real Users) child list — see
/// cvrKeyMessages.js for the shared Master-Detail add/delete pattern this
/// copies. Unlike iOS (which only ever captured free-text names for internal
/// attendees, never real Users — see the plan's Context), this links a real
/// Salesforce User, a genuine improvement over the iOS precedent rather than a
/// straight port.
export default class CvrInternalAttendees extends LightningElement {
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
        this.dispatchEvent(new ShowToastEvent({ title: 'Saved', message: 'Internal attendee added.', variant: 'success' }));
        this.dispatchEvent(new CustomEvent('refresh'));
    }

    handleError(event) {
        this.isSaving = false;
        this.dispatchEvent(new ShowToastEvent({
            title: 'Couldn’t add internal attendee',
            message: event.detail?.detail || event.detail?.message || 'Check the highlighted fields and try again.',
            variant: 'error',
        }));
    }

    async handleDelete(event) {
        const id = event.currentTarget.dataset.id;
        try {
            await deleteRecord(id);
            this.dispatchEvent(new ShowToastEvent({ title: 'Removed', message: 'Internal attendee removed.', variant: 'success' }));
            this.dispatchEvent(new CustomEvent('refresh'));
        } catch (e) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Couldn’t remove internal attendee', message: e.body?.message || 'Try again.', variant: 'error',
            }));
        }
    }
}