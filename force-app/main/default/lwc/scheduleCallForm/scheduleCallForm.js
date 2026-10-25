import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

/// Create/edit form for Planned_Call__c — the Salesforce equivalent of iOS's
/// ScheduleCallSheet. Follows the exact record-edit-form + saving-guard
/// pattern established in accountDetail.js for Segmentation/Office Window
/// (hidden pre-filled lookup for a known default, onsubmit/onsuccess/onerror
/// with Save/Cancel disabled while in flight). No `note` field — Planned_Call__c
/// has no field to bind one to (see the plan's Context section).
const MIN_DURATION = 5;
const MAX_DURATION = 120;
const DURATION_STEP = 5;

export default class ScheduleCallForm extends LightningElement {
    @api recordId; // set = edit, null = create
    @api defaultHcpId;
    @api defaultHcoId;
    @api defaultDateTime; // ISO string, used only for a new record

    kind = 'HCP'; // only relevant when creating (recordId is null)
    isEvent = false;
    isSaving = false;
    callDateTime; // current value of the Date/Time field, for the Sunday warning
    duration = 30; // minutes — same default as the iPad app's ScheduleCallSheet

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

    get subtitle() {
        return this.isEditing ? 'Update the details of this planned call.' : 'Plan a call with an HCP or HCO.';
    }

    get saveLabel() {
        return this.isEditing ? 'Save' : 'Schedule';
    }

    get kindButtons() {
        return ['HCP', 'HCO'].map((k) => ({
            key: k,
            label: k,
            className: k === this.kind ? 'seg-btn seg-btn-active' : 'seg-btn',
        }));
    }

    handleKindChange(event) {
        this.kind = event.currentTarget.dataset.value;
    }

    // MARK: - Duration (stepper + quick picks; saved with the record)

    get durationChips() {
        return [15, 30, 45, 60, 90, 120].map((m) => ({
            value: m,
            label: m < 60 ? `${m} min` : m === 60 ? '1 hr' : m === 90 ? '1.5 hr' : '2 hr',
            className: m === Number(this.duration) ? 'chip chip-active' : 'chip',
        }));
    }

    get atMinDuration() {
        return Number(this.duration) <= MIN_DURATION;
    }

    get atMaxDuration() {
        return Number(this.duration) >= MAX_DURATION;
    }

    setDuration(value) {
        const n = Math.round(Number(value));
        this.duration = Number.isFinite(n) ? Math.min(MAX_DURATION, Math.max(MIN_DURATION, n)) : 30;
    }

    handleDurationDec() {
        this.setDuration(Number(this.duration) - DURATION_STEP);
    }

    handleDurationInc() {
        this.setDuration(Number(this.duration) + DURATION_STEP);
    }

    handleDurationChip(event) {
        this.setDuration(event.currentTarget.dataset.value);
    }

    handleDurationInput(event) {
        // Don't clamp mid-typing; just keep the raw number until blur/submit.
        const n = Number(event.target.value);
        if (Number.isFinite(n)) this.duration = n;
    }

    handleDurationBlur(event) {
        this.setDuration(event.target.value);
        event.target.value = this.duration;
    }

    // When editing an existing visit, seed the stepper from the saved value.
    handleLoad(event) {
        if (!this.isEditing) return;
        const saved = event.detail?.records?.[this.recordId]?.fields?.Duration_Min__c?.value;
        if (saved != null) this.duration = saved;
        const when = event.detail?.records?.[this.recordId]?.fields?.Call_DateTime__c?.value;
        if (when) this.callDateTime = when;
    }

    handleEventToggle(event) {
        this.isEvent = event.target.checked;
    }

    // Soft warning only: a Sunday visit can still be scheduled.
    get isSunday() {
        const v = this.callDateTime || this.defaultDateTime;
        return !!v && new Date(v).getDay() === 0;
    }

    handleDateTimeChange(event) {
        this.callDateTime = event.detail?.value;
    }

    handleSubmit(event) {
        this.savedOnSunday = this.isSunday || (event.detail.fields.Call_DateTime__c
            ? new Date(event.detail.fields.Call_DateTime__c).getDay() === 0 : false);
        // Duration_Min__c isn't a lightning-input-field any more (the stepper
        // above owns it), so inject it into the submitted fields.
        event.preventDefault();
        this.isSaving = true;
        this.setDuration(this.duration);
        const fields = { ...event.detail.fields, Duration_Min__c: this.duration };
        this.template.querySelector('lightning-record-edit-form').submit(fields);
    }

    handleSuccess() {
        this.isSaving = false;
        this.dispatchEvent(new ShowToastEvent(this.savedOnSunday
            ? { title: 'Scheduled on a Sunday', message: 'The visit is saved. Sunday is normally a non-working day.', variant: 'warning' }
            : { title: 'Saved', message: 'Visit scheduled.', variant: 'success' }));
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