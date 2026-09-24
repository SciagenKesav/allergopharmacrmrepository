import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import exportToPowerPoint from '@salesforce/apex/AccountPlanController.exportToPowerPoint';

const TEMPLATE_OPTIONS = [
    { label: 'Standard Account Plan Template', value: 'standard' },
    { label: 'Executive Summary Template', value: 'executive' },
];

export default class AccountPlanExportTab extends LightningElement {
    @api recordId;
    templateName = 'standard';
    templateOptions = TEMPLATE_OPTIONS;
    isExporting = false;

    handleTemplateChange(event) {
        this.templateName = event.detail.value;
    }

    async handleExport() {
        this.isExporting = true;
        try {
            await exportToPowerPoint({ planId: this.recordId, templateName: this.templateName });
        } catch (e) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Export to PowerPoint',
                message: e.body?.message || 'This feature isn’t available yet.',
                variant: 'info',
            }));
        } finally {
            this.isExporting = false;
        }
    }
}