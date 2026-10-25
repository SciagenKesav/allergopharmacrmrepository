import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getDCRDetail from '@salesforce/apex/DCRReviewController.getDCRDetail';
import approveDCR from '@salesforce/apex/DCRReviewController.approveDCR';
import rejectDCR from '@salesforce/apex/DCRReviewController.rejectDCR';
import { pillStyle, DCR_STATUS_COLOR } from 'c/sciagenColors';

export default class DcrReviewDetail extends LightningElement {
    _recordId;
    record;
    isLoading = false;
    isSaving = false;
    error;
    isRejecting = false;
    rejectionReasonInput = '';
    isApproving = false;
    approvalCommentInput = '';

    @api
    get recordId() {
        return this._recordId;
    }
    set recordId(value) {
        this._recordId = value;
        this.isRejecting = false;
        this.rejectionReasonInput = '';
        this.isApproving = false;
        this.approvalCommentInput = '';
        this.loadDetail();
    }

    async loadDetail() {
        if (!this._recordId) {
            this.record = undefined;
            return;
        }
        this.isLoading = true;
        this.error = undefined;
        try {
            this.record = await getDCRDetail({ dcrId: this._recordId });
        } catch (e) {
            this.error = reduceError(e);
        } finally {
            this.isLoading = false;
        }
    }

    get statusPillStyle() {
        return pillStyle(DCR_STATUS_COLOR[this.record?.status]);
    }

    get isPending() {
        return this.record?.status === 'Pending Approval';
    }

    get isIdle() {
        return !this.isApproving && !this.isRejecting;
    }

    get hasPhoto() {
        return !!this.record?.photoContentVersionId;
    }

    // Session-authenticated file download URL — no lightning-file-preview
    // base component is available in this org, so this is the simplest
    // reliable way to render/open a ContentVersion.
    get photoUrl() {
        return `/sfc/servlet.shepherd/version/download/${this.record?.photoContentVersionId}`;
    }

    get hasSummary() {
        return !!this.record?.summary;
    }

    get hasRelatedHCO() {
        return !!this.record?.relatedHCOId;
    }

    get hasSubjectAccount() {
        return !!this.record?.subjectAccountId;
    }

    get hasRejectionReason() {
        return !!this.record?.rejectionReason;
    }

    get hasApprovalComment() {
        return !!this.record?.approvalComment;
    }

    get hasFlatFields() {
        return !!this.record && !this.record.isDiff && (this.record.flatFields || []).length > 0;
    }

    get hasDiffFields() {
        return !!this.record && this.record.isDiff && (this.record.diffFields || []).length > 0;
    }

    handleShowApprove() {
        this.isApproving = true;
    }

    handleCancelApprove() {
        this.isApproving = false;
        this.approvalCommentInput = '';
    }

    handleApprovalCommentChange(event) {
        this.approvalCommentInput = event.target.value;
    }

    handleConfirmApprove() {
        // Unlike Reject, a comment here is optional — a steward can still approve with
        // one click and nothing typed; the box is there for when they want to leave a note.
        const comment = this.approvalCommentInput.trim();
        this.runAction(async () => {
            await approveDCR({ dcrId: this._recordId, comment: comment || null });
            this.isApproving = false;
            this.approvalCommentInput = '';
            this.toast('Approved', 'Data change request approved.', 'success');
        });
    }

    handleShowReject() {
        this.isRejecting = true;
    }

    handleCancelReject() {
        this.isRejecting = false;
        this.rejectionReasonInput = '';
    }

    handleReasonChange(event) {
        this.rejectionReasonInput = event.target.value;
    }

    handleConfirmReject() {
        const reason = this.rejectionReasonInput.trim();
        if (!reason) {
            this.toast('Reason required', 'Enter a rejection reason before confirming.', 'error');
            return;
        }
        this.runAction(async () => {
            await rejectDCR({ dcrId: this._recordId, reason });
            this.isRejecting = false;
            this.rejectionReasonInput = '';
            this.toast('Rejected', 'Data change request rejected.', 'success');
        });
    }

    async runAction(action) {
        this.isSaving = true;
        try {
            await action();
            await this.loadDetail();
            // Tells the parent queue to refresh so this row's status pill
            // (and the summary counts) reflect the decision too.
            this.dispatchEvent(new CustomEvent('dcrdecided'));
        } catch (e) {
            this.toast('Something went wrong', reduceError(e), 'error');
        } finally {
            this.isSaving = false;
        }
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}

function reduceError(error) {
    if (error?.body?.message) {
        return error.body.message;
    }
    return 'An unknown error occurred.';
}