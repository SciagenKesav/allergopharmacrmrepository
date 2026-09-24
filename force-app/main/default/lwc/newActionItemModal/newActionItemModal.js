import { LightningElement, api, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import createActionItem from '@salesforce/apex/AccountPlanController.createActionItem';
import getActivityOptions from '@salesforce/apex/AccountPlanController.getActivityOptions';

const STATUS_OPTIONS = [
    { label: 'Open', value: 'Open' },
    { label: 'In Progress', value: 'In Progress' },
    { label: 'Postponed', value: 'Postponed' },
    { label: 'Completed', value: 'Completed' },
];

const SHARE_WITH_OPTIONS = [
    { label: 'NOAD', value: 'NOAD' },
    { label: 'PSS', value: 'PSS' },
    { label: 'MSL', value: 'MSL' },
    { label: 'ODM', value: 'ODM' },
];

export default class NewActionItemModal extends LightningElement {
    @api planId;
    @api planName;

    @track title = '';
    @track status = 'Open';
    @track description = '';
    @track startDate;
    @track dueDate;
    @track shareWith = [];
    @track accountId;

    activitySearchTerm = '';
    activityOptions = [];
    selectedActivity;
    isSearchingActivities = false;
    isSaving = false;

    statusOptions = STATUS_OPTIONS;
    shareWithOptions = SHARE_WITH_OPTIONS;

    get planLabel() {
        return this.planName || 'this Account Plan';
    }

    get hasActivityOptions() {
        return this.activityOptions.length > 0;
    }

    get hasSelectedActivity() {
        return !!this.selectedActivity;
    }

    get isSaveDisabled() {
        return this.isSaving || !this.title || !this.selectedActivity;
    }

    handleTitleChange(event) {
        this.title = event.target.value;
    }

    handleStatusChange(event) {
        this.status = event.detail.value;
    }

    handleDescriptionChange(event) {
        this.description = event.target.value;
    }

    handleStartDateChange(event) {
        this.startDate = event.target.value;
    }

    handleDueDateChange(event) {
        this.dueDate = event.target.value;
    }

    handleShareWithChange(event) {
        this.shareWith = event.detail.value;
    }

    handleAccountChange(event) {
        this.accountId = event.detail.recordId;
    }

    async handleActivitySearch(event) {
        this.activitySearchTerm = event.target.value;
        this.selectedActivity = undefined;
        if (!this.activitySearchTerm || this.activitySearchTerm.length < 2) {
            this.activityOptions = [];
            return;
        }
        this.isSearchingActivities = true;
        try {
            const results = await getActivityOptions({ planId: this.planId, searchTerm: this.activitySearchTerm });
            this.activityOptions = results;
        } catch (e) {
            this.activityOptions = [];
        } finally {
            this.isSearchingActivities = false;
        }
    }

    handleSelectActivity(event) {
        const id = event.currentTarget.dataset.id;
        this.selectedActivity = this.activityOptions.find((o) => o.id === id);
        this.activityOptions = [];
        this.activitySearchTerm = this.selectedActivity.label;
    }

    handleClearActivity() {
        this.selectedActivity = undefined;
        this.activitySearchTerm = '';
        this.activityOptions = [];
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
            await createActionItem({
                activityId: this.selectedActivity.id,
                title: this.title,
                status: this.status,
                description: this.description,
                startDate: this.startDate,
                dueDate: this.dueDate,
                shareWith: this.shareWith,
                accountId: this.accountId,
            });
            this.dispatchEvent(new ShowToastEvent({ title: 'Saved', message: 'Action Item created.', variant: 'success' }));
            this.dispatchEvent(new CustomEvent('created'));
        } catch (e) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Couldn’t create Action Item',
                message: e.body?.message || 'Check the highlighted fields and try again.',
                variant: 'error',
            }));
        } finally {
            this.isSaving = false;
        }
    }
}