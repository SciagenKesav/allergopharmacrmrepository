import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { deleteRecord } from 'lightning/uiRecordApi';

/// Key_Message__c child list for a Call_Visit_Report__c — Master-Detail on
/// CVR__c, so add/edit/delete goes straight through lightning-record-edit-form
/// / lightning/uiRecordApi, the same pattern accountDetail.js already uses for
/// Office_Window__c. `locked` is true once the parent CVR is Submitted, which
/// also cascades Key_Message__c.Locked__c = true server-side (see
/// SciagenCVRController.submitCallReport) — hide Add/Edit/Delete then, since
/// editing a locked key message would be rejected by FLS/validation anyway.
export default class CvrKeyMessages extends LightningElement {
    @api cvrId;
    @api locked = false;
    @api rows = [];

    showAdd = false;
    editingId = null;
    isSaving = false;

    get displayRows() {
        return (this.rows || []).map((r) => ({ ...r, isEditing: r.id === this.editingId }));
    }

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

    handleEdit(event) {
        this.editingId = event.currentTarget.dataset.id;
    }

    handleCancelEdit() {
        this.editingId = null;
        this.isSaving = false;
    }

    handleSubmit() {
        this.isSaving = true;
    }

    handleSuccess() {
        this.showAdd = false;
        this.editingId = null;
        this.isSaving = false;
        this.dispatchEvent(new ShowToastEvent({ title: 'Saved', message: 'Key message saved.', variant: 'success' }));
        this.dispatchEvent(new CustomEvent('refresh'));
    }

    handleError(event) {
        this.isSaving = false;
        this.dispatchEvent(new ShowToastEvent({
            title: 'Couldn’t save key message',
            message: event.detail?.detail || event.detail?.message || 'Check the highlighted fields and try again.',
            variant: 'error',
        }));
    }

    async handleDelete(event) {
        const id = event.currentTarget.dataset.id;
        try {
            await deleteRecord(id);
            this.dispatchEvent(new ShowToastEvent({ title: 'Deleted', message: 'Key message removed.', variant: 'success' }));
            this.dispatchEvent(new CustomEvent('refresh'));
        } catch (e) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Couldn’t delete key message', message: e.body?.message || 'Try again.', variant: 'error',
            }));
        }
    }
}