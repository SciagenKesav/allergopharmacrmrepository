import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import createAudit from '@salesforce/apex/RCPAController.createAudit';

function today() {
    return new Date().toISOString().slice(0, 10);
}

export default class NewRcpaAuditModal extends LightningElement {
    @track chemistId;
    @track territoryId;
    @track auditDate = today();

    isSaving = false;
    chemistFilter = { criteria: [{ fieldPath: 'Type__c', operator: 'eq', value: 'HCO' }] };

    get isSaveDisabled() {
        return this.isSaving || !this.chemistId;
    }

    handleChemistChange(event) {
        this.chemistId = event.detail.recordId;
    }

    handleTerritoryChange(event) {
        this.territoryId = event.detail.recordId;
    }

    handleAuditDateChange(event) {
        this.auditDate = event.target.value;
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
            const newId = await createAudit({
                chemistId: this.chemistId,
                territoryId: this.territoryId,
                auditDate: this.auditDate,
            });
            this.dispatchEvent(new ShowToastEvent({ title: 'Created', message: 'RCPA Audit created.', variant: 'success' }));
            this.dispatchEvent(new CustomEvent('created', { detail: { id: newId } }));
        } catch (e) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Couldn’t create RCPA Audit',
                message: e.body?.message || 'Check the highlighted fields and try again.',
                variant: 'error',
            }));
        } finally {
            this.isSaving = false;
        }
    }
}