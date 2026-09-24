import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

/// Create/edit form for Planned_Call__c — the Salesforce equivalent of iOS's
/// ScheduleCallSheet. Follows the exact record-edit-form + saving-guard
/// pattern established in accountDetail.js for Segmentation/Office Window
/// (hidden pre-filled lookup for a known default, onsubmit/onsuccess/onerror
/// with Save/Cancel disabled while in flight). No `note` field — Planned_Call__c
/// has no field to bind one to (see the plan's Context section).
export default class ScheduleCallForm extends LightningElement {
    @api recordId; // set = edit, null = create
    @api defaultHcpId;
    @api defaultHcoId;
    @api defaultDateTime; // ISO string, used only for a new record

    kind = 'HCP'; // only relevant when creating (recordId is null)
    isEvent = false;
    isSaving = false;

    connectedCallback() {
        if (this.defaultHcoId && !this.defaultHcpId) {
            this.kind = 'HCO';
        }
    }

    get isEditing() {
        return !!this.recordId;
    }

    get title() {
        return this.isEditing ? 'Edit Visit' : 'Schedule a Visit';
    }

    get isHcpKind() {
        return this.kind === 'HCP';
    }

    get isHcoKind() {
        return this.kind === 'HCO';
    }

    get kindButtons() {
        return ['HCP', 'HCO'].map((k) => ({ key: k, label: k, variant: k === this.kind ? 'brand' : 'neutral' }));
    }

    handleKindChange(event) {
        this.kind = event.currentTarget.dataset.value;
    }

    handleEventToggle(event) {
        this.isEvent = event.target.checked;
    }

    handleSubmit(event) {
        // Planned visits can't land on a Sunday — Date#getDay() reads the
        // field's value back in the browser's own local time, same as every
        // other "which day is this on" check in My Schedule (mySchedule.js's
        // localDayKey and friends), so this agrees with whatever day the rep
        // actually sees on the picker.
        const callDateTime = event.detail.fields.Call_DateTime__c;
        if (callDateTime && new Date(callDateTime).getDay() === 0) {
            event.preventDefault();
            this.dispatchEvent(new ShowToastEvent({
                title: 'Can’t schedule on a Sunday',
                message: 'Planned visits can’t be scheduled on a Sunday. Please choose a different day.',
                variant: 'error',
            }));
            return;
        }
        this.isSaving = true;
    }

    handleSuccess() {
        this.isSaving = false;
        this.dispatchEvent(new ShowToastEvent({ title: 'Saved', message: 'Visit scheduled.', variant: 'success' }));
        this.dispatchEvent(new CustomEvent('save'));
    }

    handleError(event) {
        this.isSaving = false;
        this.dispatchEvent(new ShowToastEvent({
            title: 'Couldn’t save visit',
            message: event.detail?.detail || event.detail?.message || 'Check the highlighted fields and try again.',
            variant: 'error',
        }));
    }

    handleCancel() {
        this.dispatchEvent(new CustomEvent('cancel'));
    }
}