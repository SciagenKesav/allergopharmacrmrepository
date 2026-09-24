import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

const HEADER_FIELDS = ['Plan_Title__c', 'Status__c', 'Stage__c', 'Plan_Record_Type__c', 'Type__c', 'Active__c'];
const DETAIL_FIELDS = [
    'Division__c', 'HCO__c', 'HCP__c', 'Start_Date__c', 'End_Date__c',
    'Number_of_Locations__c', 'Total_Enrollment__c', 'Total_Revenue__c', 'OCM_APM__c',
    'Health__c', 'Medical_Engagement_Plan__c', 'Applied_Products__c',
];
const DESCRIPTION_FIELDS = ['Objective__c', 'Differentiation_Strategy__c', 'Key_Initiatives__c'];

export default class AccountPlanDetailsTab extends LightningElement {
    @api recordId;
    isEditing = false;
    isSaving = false;

    headerFields = HEADER_FIELDS;
    detailFields = DETAIL_FIELDS;
    descriptionFields = DESCRIPTION_FIELDS;

    get editButtonLabel() {
        return this.isEditing ? 'Cancel' : 'Edit';
    }

    handleEditToggle() {
        this.isEditing = !this.isEditing;
    }

    handleSubmit() {
        this.isSaving = true;
    }

    handleSuccess() {
        this.isEditing = false;
        this.isSaving = false;
        this.dispatchEvent(new ShowToastEvent({ title: 'Saved', message: 'Account Plan updated.', variant: 'success' }));
        this.dispatchEvent(new CustomEvent('plansaved'));
    }

    handleError(event) {
        this.isSaving = false;
        this.dispatchEvent(new ShowToastEvent({
            title: 'Couldn’t save Account Plan',
            message: event.detail?.detail || event.detail?.message || 'Check the highlighted fields and try again.',
            variant: 'error',
        }));
    }
}