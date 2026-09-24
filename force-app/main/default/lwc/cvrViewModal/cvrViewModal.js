import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getCVRDetail from '@salesforce/apex/SciagenCVRController.getCVRDetail';
import { pillStyle, callStatusColor } from 'c/sciagenColors';

/// Read-only Call Visit Report viewer — opened from accountDetail's Activity
/// tab when a rep clicks an already-submitted/drafted CVR row. Deliberately
/// a separate, always-read-only component rather than reusing
/// callVisitReportDetail's isReadOnly/locked branch, mirroring how the iPad
/// app keeps CVRDetailView (view) and CallFlowView/CallReviewView (edit) as
/// entirely separate screens rather than one component with a mode flag —
/// see CVRView.swift's CVRDetailView for the section order this follows
/// (header, call info, attendees, key messages, samples, promo items, call
/// notes). Presentation/slide analytics are intentionally omitted: unlike
/// the CVR header and its Master-Detail children, no Salesforce object
/// tracks per-slide session data today, so there's nothing to show here.
export default class CvrViewModal extends LightningElement {
    _recordId;
    isLoading = false;
    detail;

    @api
    get recordId() {
        return this._recordId;
    }
    set recordId(value) {
        this._recordId = value;
        this.loadDetail();
    }

    async loadDetail() {
        if (!this._recordId) { return; }
        this.isLoading = true;
        try {
            this.detail = await getCVRDetail({ cvrId: this._recordId });
        } catch (error) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Couldn’t load call visit report',
                message: error?.body?.message || error?.message || 'Unknown error',
                variant: 'error',
            }));
            this.handleClose();
        } finally {
            this.isLoading = false;
        }
    }

    get title() {
        return this.detail?.hcpName || this.detail?.hcoName || 'Call Visit Report';
    }

    get subtitle() {
        const parts = [];
        if (this.detail?.hcpName && this.detail?.hcoName) { parts.push(this.detail.hcoName); }
        if (this.detail?.callType) { parts.push(this.detail.callType); }
        if (this.detail?.visitDate) { parts.push(this.detail.visitDate); }
        return parts.join(' · ');
    }

    get statusStyle() {
        return pillStyle(callStatusColor(this.detail?.recordStatus));
    }

    get isLocked() {
        return this.detail?.recordStatus === 'Submitted';
    }

    get hasKeyMessages() {
        return this.detail?.keyMessages?.length > 0;
    }

    get hasSamples() {
        return this.detail?.sampleDrops?.length > 0;
    }

    get hasPromo() {
        return this.detail?.promoDrops?.length > 0;
    }

    get hasAttendees() {
        return this.detail?.attendees?.length > 0;
    }

    get hasInternalAttendees() {
        return this.detail?.internalAttendees?.length > 0;
    }

    get hasNotes() {
        return !!(this.detail?.preCallNotes || this.detail?.discussionSummary
            || this.detail?.nextCallNotes || this.detail?.nextVisitDate);
    }

    get signatureLabel() {
        return this.detail?.signatureCaptured ? 'Captured' : '—';
    }

    handleClose() {
        this.dispatchEvent(new CustomEvent('close'));
    }

    stopPropagation(event) {
        event.stopPropagation();
    }
}