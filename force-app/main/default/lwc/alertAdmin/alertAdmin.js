import { LightningElement } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getAlerts from '@salesforce/apex/AlertAdminController.getAlerts';
import getProfileOptions from '@salesforce/apex/AlertAdminController.getProfileOptions';
import getUserOptions from '@salesforce/apex/AlertAdminController.getUserOptions';
import getActiveUserOptions from '@salesforce/apex/AlertAdminController.getActiveUserOptions';
import saveAlert from '@salesforce/apex/AlertAdminController.saveAlert';
import setActive from '@salesforce/apex/AlertAdminController.setActive';
import { BRAND, pillStyle, ALERT_PRIORITY_COLOR, ALERT_TYPE_COLOR } from 'c/sciagenColors';

const TYPE_OPTIONS = [
    { label: 'Company', value: 'Company' },
    { label: 'Content', value: 'Content' },
    { label: 'DCR', value: 'DCR' },
];
const PRIORITY_OPTIONS = [
    { label: 'Urgent', value: 'Urgent' },
    { label: 'Important', value: 'Important' },
    { label: 'Normal', value: 'Normal' },
];
const AUDIENCE_OPTIONS = [
    { label: 'All Users', value: 'All Users' },
    { label: 'Profile', value: 'Profile' },
    { label: 'User', value: 'User' },
    { label: 'Multiple Users', value: 'Multiple Users' },
];

const TYPE_FILTER_OPTIONS = [{ label: 'All Types', value: 'All' }, ...TYPE_OPTIONS];
const PRIORITY_FILTER_OPTIONS = [{ label: 'All Priorities', value: 'All' }, ...PRIORITY_OPTIONS];
const STATUS_FILTER_OPTIONS = [
    { label: 'All Statuses', value: 'All' },
    { label: 'Active', value: 'Active' },
    { label: 'Inactive', value: 'Inactive' },
];
const SORT_OPTIONS = [
    { label: 'Newest First', value: 'activationDesc' },
    { label: 'Oldest First', value: 'activationAsc' },
    { label: 'Priority: High to Low', value: 'priorityDesc' },
    { label: 'Title: A to Z', value: 'titleAsc' },
];
const PRIORITY_RANK = { Urgent: 3, Important: 2, Normal: 1 };

const USER_SEARCH_DEBOUNCE_MS = 300;

function emptyForm() {
    return {
        id: null,
        title: '',
        message: '',
        type: 'Company',
        priority: 'Normal',
        audienceType: 'All Users',
        targetProfileId: null,
        targetUserId: null,
        targetUserLabel: '',
        targetUserIds: [],
        activationDate: new Date().toISOString(),
        expirationDate: null,
    };
}

export default class AlertAdmin extends LightningElement {
    alerts = [];
    isLoading = false;
    isSaving = false;
    error;

    form = emptyForm();
    profileOptions = [];
    activeUserOptions = [];
    userSearchTerm = '';
    userOptions = [];
    userSearchTimer;

    typeOptions = TYPE_OPTIONS;
    priorityOptions = PRIORITY_OPTIONS;
    audienceOptions = AUDIENCE_OPTIONS;
    typeFilterOptions = TYPE_FILTER_OPTIONS;
    priorityFilterOptions = PRIORITY_FILTER_OPTIONS;
    statusFilterOptions = STATUS_FILTER_OPTIONS;
    sortOptions = SORT_OPTIONS;

    filterType = 'All';
    filterPriority = 'All';
    filterStatus = 'All';
    sortBy = 'activationDesc';

    connectedCallback() {
        this.loadAlerts();
        this.loadProfileOptions();
        this.loadActiveUserOptions();
    }

    async loadAlerts() {
        this.isLoading = true;
        this.error = undefined;
        try {
            this.alerts = await getAlerts();
        } catch (e) {
            this.error = reduceError(e);
        } finally {
            this.isLoading = false;
        }
    }

    async loadProfileOptions() {
        try {
            const options = await getProfileOptions();
            this.profileOptions = options.map((o) => ({ label: o.name, value: o.id }));
        } catch (e) {
            this.error = reduceError(e);
        }
    }

    async loadActiveUserOptions() {
        try {
            const options = await getActiveUserOptions();
            this.activeUserOptions = options.map((o) => ({ label: o.name, value: o.id }));
        } catch (e) {
            this.error = reduceError(e);
        }
    }

    // MARK: - List

    get filteredAlerts() {
        return this.alerts.filter((a) => {
            if (this.filterType !== 'All' && a.type !== this.filterType) return false;
            if (this.filterPriority !== 'All' && a.priority !== this.filterPriority) return false;
            if (this.filterStatus === 'Active' && !a.isActive) return false;
            if (this.filterStatus === 'Inactive' && a.isActive) return false;
            return true;
        });
    }

    get rows() {
        const sorted = [...this.filteredAlerts].sort((a, b) => {
            switch (this.sortBy) {
                case 'activationAsc':
                    return new Date(a.activationDate) - new Date(b.activationDate);
                case 'priorityDesc':
                    return (PRIORITY_RANK[b.priority] || 0) - (PRIORITY_RANK[a.priority] || 0);
                case 'titleAsc':
                    return (a.title || '').localeCompare(b.title || '');
                case 'activationDesc':
                default:
                    return new Date(b.activationDate) - new Date(a.activationDate);
            }
        });

        return sorted.map((a) => ({
            ...a,
            rowClass: a.id === this.form.id ? 'result-row selected' : 'result-row',
            typeStyle: pillStyle(ALERT_TYPE_COLOR[a.type]),
            priorityStyle: pillStyle(ALERT_PRIORITY_COLOR[a.priority]),
            statusLabel: a.isActive ? 'Active' : 'Inactive',
            statusStyle: a.isActive ? pillStyle(BRAND.accent) : pillStyle(BRAND.subtle),
        }));
    }

    get hasAlerts() {
        return this.rows.length > 0;
    }

    get hasAnyAlerts() {
        return this.alerts.length > 0;
    }

    get emptyMessage() {
        return this.hasAnyAlerts ? 'No alerts match these filters.' : 'No alerts yet.';
    }

    handleFilterTypeChange(event) {
        this.filterType = event.detail.value;
    }

    handleFilterPriorityChange(event) {
        this.filterPriority = event.detail.value;
    }

    handleFilterStatusChange(event) {
        this.filterStatus = event.detail.value;
    }

    handleSortChange(event) {
        this.sortBy = event.detail.value;
    }

    handleSelectRow(event) {
        const id = event.currentTarget.dataset.id;
        const found = this.alerts.find((a) => a.id === id);
        if (!found) return;
        this.form = {
            id: found.id,
            title: found.title,
            message: found.message || '',
            type: found.type,
            priority: found.priority,
            audienceType: found.audienceType,
            targetProfileId: found.targetProfileId,
            targetUserId: found.targetUserId,
            targetUserLabel: found.audienceType === 'User' ? found.audienceLabel : '',
            targetUserIds: found.targetUserIds ? [...found.targetUserIds] : [],
            activationDate: found.activationDate,
            expirationDate: found.expirationDate,
        };
        this.userSearchTerm = '';
        this.userOptions = [];
    }

    handleNewAlert() {
        this.form = emptyForm();
        this.userSearchTerm = '';
        this.userOptions = [];
    }

    get isEditingExisting() {
        return !!this.form.id;
    }

    get formHeading() {
        return this.isEditingExisting ? 'Edit Alert' : 'New Alert';
    }

    // MARK: - Form

    get isProfileAudience() {
        return this.form.audienceType === 'Profile';
    }

    get isUserAudience() {
        return this.form.audienceType === 'User';
    }

    get isMultipleUsersAudience() {
        return this.form.audienceType === 'Multiple Users';
    }

    handleFieldChange(event) {
        const field = event.target.dataset.field;
        this.form = { ...this.form, [field]: event.target.value };
    }

    handleAudienceChange(event) {
        this.form = {
            ...this.form,
            audienceType: event.detail.value,
            targetProfileId: null,
            targetUserId: null,
            targetUserLabel: '',
            targetUserIds: [],
        };
        this.userSearchTerm = '';
        this.userOptions = [];
    }

    handleTargetUsersChange(event) {
        this.form = { ...this.form, targetUserIds: event.detail.value };
    }

    handleUserSearchChange(event) {
        this.userSearchTerm = event.target.value;
        window.clearTimeout(this.userSearchTimer);
        this.userSearchTimer = window.setTimeout(() => this.runUserSearch(), USER_SEARCH_DEBOUNCE_MS);
    }

    async runUserSearch() {
        if (!this.userSearchTerm || this.userSearchTerm.length < 2) {
            this.userOptions = [];
            return;
        }
        try {
            this.userOptions = await getUserOptions({ searchTerm: this.userSearchTerm });
        } catch (e) {
            this.error = reduceError(e);
        }
    }

    handlePickUser(event) {
        const id = event.currentTarget.dataset.id;
        const found = this.userOptions.find((u) => u.id === id);
        if (!found) return;
        this.form = { ...this.form, targetUserId: found.id, targetUserLabel: found.name };
        this.userSearchTerm = '';
        this.userOptions = [];
    }

    get hasUserResults() {
        return this.userOptions.length > 0;
    }

    async handleSave() {
        this.isSaving = true;
        try {
            // Individual scalar parameters, not a wrapped object — Apex's
            // saveAlert used to take one AlertInput DTO and every field
            // arrived null server-side (confirmed via network capture: the
            // wire payload had the real values, Apex saw only nulls). Scalar
            // params sidestep whatever was silently dropping the wrapper.
            await saveAlert({
                alertId: this.form.id,
                title: this.form.title,
                message: this.form.message,
                type: this.form.type,
                priority: this.form.priority,
                audienceType: this.form.audienceType,
                targetProfileId: this.form.targetProfileId,
                targetUserId: this.form.targetUserId,
                targetUserIds: this.form.targetUserIds,
                activationDate: this.form.activationDate,
                expirationDate: this.form.expirationDate,
            });
            this.dispatchEvent(new ShowToastEvent({ title: 'Saved', message: 'Alert saved.', variant: 'success' }));
            await this.loadAlerts();
            this.handleNewAlert();
        } catch (e) {
            this.dispatchEvent(new ShowToastEvent({ title: 'Could not save alert', message: reduceError(e), variant: 'error' }));
        } finally {
            this.isSaving = false;
        }
    }

    async handleToggleActive() {
        this.isSaving = true;
        try {
            await setActive({ alertId: this.form.id, isActive: !this.isCurrentlyActive });
            this.dispatchEvent(new ShowToastEvent({ title: 'Updated', message: 'Alert status updated.', variant: 'success' }));
            await this.loadAlerts();
            this.handleNewAlert();
        } catch (e) {
            this.dispatchEvent(new ShowToastEvent({ title: 'Could not update alert', message: reduceError(e), variant: 'error' }));
        } finally {
            this.isSaving = false;
        }
    }

    get isCurrentlyActive() {
        const found = this.alerts.find((a) => a.id === this.form.id);
        return found ? found.isActive : true;
    }

    get toggleActiveLabel() {
        return this.isCurrentlyActive ? 'Deactivate' : 'Reactivate';
    }

    get toggleActiveVariant() {
        return this.isCurrentlyActive ? 'destructive' : 'brand';
    }
}

function reduceError(error) {
    if (error?.body?.message) {
        return error.body.message;
    }
    return 'An unknown error occurred.';
}