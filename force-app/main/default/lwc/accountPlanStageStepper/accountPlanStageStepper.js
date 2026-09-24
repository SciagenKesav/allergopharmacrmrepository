import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import markStageComplete from '@salesforce/apex/AccountPlanController.markStageComplete';

// Hand-rolled stage stepper — deliberately not Salesforce's native Path
// component, so the whole Account Plan page stays under version-controlled
// component code (matching this app's RCPA build) rather than mixing in a
// declarative metadata feature.
const STAGES = ['Prospect', 'Early', 'Mid', 'Partnership', 'Synergistic'];

export default class AccountPlanStageStepper extends LightningElement {
    @api recordId;
    @api stage;
    @api nextStage;
    isAdvancing = false;

    get steps() {
        const currentIndex = STAGES.indexOf(this.stage);
        return STAGES.map((label, index) => ({
            label,
            key: label,
            isComplete: index < currentIndex,
            isCurrent: index === currentIndex,
            dotClass: index < currentIndex ? 'step-dot step-dot-complete'
                : index === currentIndex ? 'step-dot step-dot-current' : 'step-dot',
            labelClass: index <= currentIndex ? 'step-label step-label-active' : 'step-label',
            connectorClass: index < currentIndex ? 'step-connector step-connector-complete' : 'step-connector',
        }));
    }

    get hasNextStage() {
        return !!this.nextStage;
    }

    get isFinalStage() {
        return !this.nextStage;
    }

    async handleMarkComplete() {
        this.isAdvancing = true;
        try {
            const newStage = await markStageComplete({ planId: this.recordId });
            this.dispatchEvent(new ShowToastEvent({
                title: 'Stage updated',
                message: `Advanced to ${newStage}.`,
                variant: 'success',
            }));
            this.dispatchEvent(new CustomEvent('stageadvanced', { detail: { stage: newStage } }));
        } catch (e) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Couldn’t advance stage',
                message: e.body?.message || 'Try again.',
                variant: 'error',
            }));
        } finally {
            this.isAdvancing = false;
        }
    }
}