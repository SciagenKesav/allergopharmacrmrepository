import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

/// Create/edit form for Call_Visit_Report__c's own fields (not its children —
/// those are separate sibling components under callVisitReportDetail). Follows
/// the exact record-edit-form + saving-guard pattern established in
/// scheduleCallForm.js / accountDetail.js's Office Window section.
export default class CvrHeaderForm extends LightningElement {
    @api recordId; // set = edit, null = create
    @api defaultHcpId;
    @api defaultHcoId;
    @api defaultHcoAddress;
    @api recordStatus; // only meaningful when recordId is set
    @api pastEditWindow = false; // Call_Backdate_Limit__c — see callVisitReportDetail.js

    isSaving = false;

    // Read-only context under the HCO field on a new report — confirms which
    // affiliated HCO (the HCP's primary, when they have more than one) the
    // visit's location actually defaulted to.
    get showDefaultHcoAddress() {
        return !this.isEditing && !!this.defaultHcoId && !!this.defaultHcoAddress;
    }

    get isEditing() {
        return !!this.recordId;
    }

    get title() {
        return this.isEditing ? 'Call Report' : 'New Call Report';
    }

    // Submitted call reports are locked — the header form becomes read-only,
    // matching iOS's isLocked behavior (Draft and Saved both stay editable).
    // A draft/saved report older than the Call_Backdate_Limit__c window also
    // locks, matching iOS RootView's isCVREditable.
    get isReadOnly() {
        return this.isEditing && (this.recordStatus === 'Submitted' || this.pastEditWindow);
    }

    handleSubmit() {
        this.isSaving = true;
    }

    handleSuccess(event) {
        this.isSaving = false;
        this.dispatchEvent(new ShowToastEvent({ title: 'Saved', message: 'Call report saved.', variant: 'success' }));
        this.dispatchEvent(new CustomEvent('save', { detail: { id: event.detail.id } }));
    }

    handleError(event) {
        this.isSaving = false;
        this.dispatchEvent(new ShowToastEvent({
            title: 'Couldn’t save call report',
            message: event.detail?.detail || event.detail?.message || 'Check the highlighted fields and try again.',
            variant: 'error',
        }));
    }

    handleCancel() {
        this.dispatchEvent(new CustomEvent('cancel'));
    }
}