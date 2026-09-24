import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { deleteRecord } from 'lightning/uiRecordApi';

/// Sample_Drop__c child list for a Call_Visit_Report__c — same Master-Detail
/// add/edit/delete pattern as cvrPromoDrops.js, except Product__c is a real
/// Lookup (not freeform text), so lightning-input-field renders it as a
/// standard record picker automatically.
export default class CvrSampleDrops extends LightningElement {
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
        this.dispatchEvent(new ShowToastEvent({ title: 'Saved', message: 'Sample drop saved.', variant: 'success' }));
        this.dispatchEvent(new CustomEvent('refresh'));
    }

    handleError(event) {
        this.isSaving = false;
        this.dispatchEvent(new ShowToastEvent({
            title: 'Couldn’t save sample drop',
            message: event.detail?.detail || event.detail?.message || 'Check the highlighted fields and try again.',
            variant: 'error',
        }));
    }

    async handleDelete(event) {
        const id = event.currentTarget.dataset.id;
        try {
            await deleteRecord(id);
            this.dispatchEvent(new ShowToastEvent({ title: 'Deleted', message: 'Sample drop removed.', variant: 'success' }));
            this.dispatchEvent(new CustomEvent('refresh'));
        } catch (e) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Couldn’t delete sample drop', message: e.body?.message || 'Try again.', variant: 'error',
            }));
        }
    }
}