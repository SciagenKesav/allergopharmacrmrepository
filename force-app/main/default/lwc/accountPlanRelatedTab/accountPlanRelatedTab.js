import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getPlanCalls from '@salesforce/apex/AccountPlanController.getPlanCalls';
import unlinkCallFromPlan from '@salesforce/apex/AccountPlanController.unlinkCallFromPlan';

export default class AccountPlanRelatedTab extends LightningElement {
    @api workspace;
    @api recordId;
    @api planName;

    calls = [];
    isLoadingCalls = true;
    showAssociateCallModal = false;
    showStakeholderModal = false;
    showTeamMemberModal = false;
    showGoalModal = false;

    connectedCallback() {
        this.loadCalls();
    }

    async loadCalls() {
        this.isLoadingCalls = true;
        try {
            this.calls = await getPlanCalls({ planId: this.recordId });
        } catch (e) {
            this.calls = [];
        } finally {
            this.isLoadingCalls = false;
        }
    }

    get hasStakeholders() {
        return this.workspace?.stakeholders?.length > 0;
    }

    get hasTeamMembers() {
        return this.workspace?.teamMembers?.length > 0;
    }

    get hasGoals() {
        return this.workspace?.goals?.length > 0;
    }

    get hasCalls() {
        return this.calls.length > 0;
    }

    get callRows() {
        return this.calls.map((c) => ({ ...c, key: `${c.kind}-${c.id}`, isUnlinking: this.unlinkingKey === `${c.kind}-${c.id}` }));
    }

    handleUploadFinished(event) {
        const count = event.detail.files.length;
        this.dispatchEvent(new ShowToastEvent({
            title: 'Uploaded',
            message: `${count} file${count === 1 ? '' : 's'} attached to this Account Plan.`,
            variant: 'success',
        }));
    }

    handleAssociateCall() {
        this.showAssociateCallModal = true;
    }

    handleCloseAssociateModal() {
        this.showAssociateCallModal = false;
    }

    handleCallLinked() {
        this.showAssociateCallModal = false;
        this.loadCalls();
    }

    async handleUnlinkCall(event) {
        const id = event.currentTarget.dataset.id;
        const kind = event.currentTarget.dataset.kind;
        this.unlinkingKey = `${kind}-${id}`;
        try {
            await unlinkCallFromPlan({ callId: id, kind });
            this.dispatchEvent(new ShowToastEvent({ title: 'Unlinked', message: 'Call removed from this Account Plan.', variant: 'success' }));
            await this.loadCalls();
        } catch (e) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Couldn’t unlink call',
                message: e.body?.message || 'Try again.',
                variant: 'error',
            }));
        } finally {
            this.unlinkingKey = undefined;
        }
    }

    handleAddStakeholder() {
        this.showStakeholderModal = true;
    }

    handleCloseStakeholderModal() {
        this.showStakeholderModal = false;
    }

    handleStakeholderCreated() {
        this.showStakeholderModal = false;
        this.dispatchEvent(new CustomEvent('planchildcreated'));
    }

    handleAddTeamMember() {
        this.showTeamMemberModal = true;
    }

    handleCloseTeamMemberModal() {
        this.showTeamMemberModal = false;
    }

    handleTeamMemberCreated() {
        this.showTeamMemberModal = false;
        this.dispatchEvent(new CustomEvent('planchildcreated'));
    }

    handleAddGoal() {
        this.showGoalModal = true;
    }

    handleCloseGoalModal() {
        this.showGoalModal = false;
    }

    handleGoalCreated() {
        this.showGoalModal = false;
        this.dispatchEvent(new CustomEvent('planchildcreated'));
    }
}