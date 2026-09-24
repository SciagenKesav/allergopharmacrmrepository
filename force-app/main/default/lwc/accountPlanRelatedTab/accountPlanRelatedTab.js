import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getPlanCalls from '@salesforce/apex/AccountPlanController.getPlanCalls';
import unlinkCallFromPlan from '@salesforce/apex/AccountPlanController.unlinkCallFromPlan';

// kind (from AccountPlanController.PlanCallItem) -> the object each linked
// call row's "View Call Report" action should navigate to.
const OBJECT_BY_KIND = {
    'Planned Call': 'Planned_Call__c',
    'Call Visit Report': 'Call_Visit_Report__c',
};

export default class AccountPlanRelatedTab extends NavigationMixin(LightningElement) {
    @api workspace;
    @api recordId;
    @api planName;

    calls = [];
    isLoadingCalls = true;
    showAssociateCallModal = false;

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

    // MARK: - New Team Member (Account_Team_Member__c has no create UI anywhere
    // today — this tab only ever displayed rows synced in from the iPad app)

    showNewTeamMemberForm = false;
    isSavingTeamMember = false;

    handleAddTeamMember() {
        this.showNewTeamMemberForm = true;
    }

    handleCancelTeamMember() {
        this.showNewTeamMemberForm = false;
    }

    handleTeamMemberSubmit() {
        this.isSavingTeamMember = true;
    }

    handleTeamMemberSaveSuccess() {
        this.isSavingTeamMember = false;
        this.showNewTeamMemberForm = false;
        this.dispatchEvent(new ShowToastEvent({ title: 'Added', message: 'Team member added to this Account Plan.', variant: 'success' }));
        this.dispatchEvent(new CustomEvent('teammembercreated'));
    }

    handleTeamMemberSaveError(event) {
        this.isSavingTeamMember = false;
        this.dispatchEvent(new ShowToastEvent({
            title: 'Couldn’t add team member',
            message: event.detail?.detail || event.detail?.message || 'Check the highlighted fields and try again.',
            variant: 'error',
        }));
    }

    // MARK: - New Goal (Plan_Goal__c wasn't displayed anywhere in this
    // workspace at all, despite getPlanWorkspace already returning it)

    showNewGoalForm = false;
    isSavingGoal = false;

    handleAddGoal() {
        this.showNewGoalForm = true;
    }

    handleCancelGoal() {
        this.showNewGoalForm = false;
    }

    handleGoalSubmit() {
        this.isSavingGoal = true;
    }

    handleGoalSaveSuccess() {
        this.isSavingGoal = false;
        this.showNewGoalForm = false;
        this.dispatchEvent(new ShowToastEvent({ title: 'Added', message: 'Goal added to this Account Plan.', variant: 'success' }));
        this.dispatchEvent(new CustomEvent('goalcreated'));
    }

    handleGoalSaveError(event) {
        this.isSavingGoal = false;
        this.dispatchEvent(new ShowToastEvent({
            title: 'Couldn’t add goal',
            message: event.detail?.detail || event.detail?.message || 'Check the highlighted fields and try again.',
            variant: 'error',
        }));
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

    // Opens the actual scheduled call or filed report a Plan Calls row
    // points to — the only way to get from an Account Plan to My
    // Schedule/Call Reports used to be the other direction (associate an
    // existing call onto the plan); this closes the loop.
    handleViewCall(event) {
        const id = event.currentTarget.dataset.id;
        const kind = event.currentTarget.dataset.kind;
        const objectApiName = OBJECT_BY_KIND[kind];
        if (!id || !objectApiName) return;
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: id, objectApiName, actionName: 'view' },
        });
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
}