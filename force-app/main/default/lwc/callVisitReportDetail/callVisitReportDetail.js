import { LightningElement, api, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { updateRecord } from 'lightning/uiRecordApi';
import getCVRDetail from '@salesforce/apex/SciagenCVRController.getCVRDetail';
import submitCallReport from '@salesforce/apex/SciagenCVRController.submitCallReport';
import getCallBackdateLimitDays from '@salesforce/apex/SciagenCVRController.getCallBackdateLimitDays';
import getSessionsForCVR from '@salesforce/apex/SciagenCLMController.getSessionsForCVR';
import { pillStyle, callStatusColor } from 'c/sciagenColors';

/// Per-CVR editor — composes cvrHeaderForm with five Master-Detail child list
/// components (Key Messages/Promo Drops/Attendees/Internal Attendees/
/// Presentation Sessions). The children only render once a CVR Id exists
/// (Master-Detail children can't be created without their parent). See the
/// "Call Visit Report — Salesforce LWC Feature" and "CLM — Library + Session
/// Logging" plans for the full mapping.
export default class CallVisitReportDetail extends LightningElement {
    _recordId;
    @api defaultHcpId;
    @api defaultHcoId;
    @api defaultHcoAddress;
    // When opened via "Log Visit" from a Planned_Call__c row, set once — after
    // the header's first save this gets Resulting_CVR__c pointed at the new
    // CVR, then cleared so it only ever fires once.
    @api sourcePlannedCallId;

    @api
    get recordId() {
        return this._recordId;
    }
    set recordId(value) {
        this._recordId = value;
        this.loadDetail();
    }

    detail;
    presentationSessions = [];
    isLoading = false;
    isSubmitting = false;

    // Hierarchy Custom Setting (User > Profile > Org default) — same one
    // iOS resolves for its own "how many days back can this be edited"
    // check (RootView.swift's isCVREditable / store.callBackdateLimitDays),
    // wired here so both apps enforce the identical window.
    @wire(getCallBackdateLimitDays) wiredBackdateLimit;

    get callBackdateLimitDays() {
        return this.wiredBackdateLimit?.data ?? 30;
    }

    // Date-only comparison, built the same "parse as local midnight" way
    // scheduleWeekGrid.js's drop-time fix does — appending T00:00:00 avoids
    // the UTC-parses-as-midnight-then-shifts-back-a-day trap a bare
    // "YYYY-MM-DD" string hits in negative-offset timezones.
    get isPastEditWindow() {
        if (!this.detail?.visitDate) { return false; }
        const visit = new Date(`${this.detail.visitDate}T00:00:00`);
        const cutoff = new Date();
        cutoff.setDate(cutoff.getDate() - this.callBackdateLimitDays);
        cutoff.setHours(0, 0, 0, 0);
        return visit < cutoff;
    }

    async loadDetail() {
        if (!this._recordId) {
            this.detail = undefined;
            this.presentationSessions = [];
            return;
        }
        this.isLoading = true;
        try {
            const [cvrDetail, sessions] = await Promise.all([
                getCVRDetail({ cvrId: this._recordId }),
                getSessionsForCVR({ cvrId: this._recordId }),
            ]);
            this.detail = cvrDetail;
            this.presentationSessions = sessions;
        } catch (e) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Couldn’t load call report', message: e.body?.message || 'Try again.', variant: 'error',
            }));
        } finally {
            this.isLoading = false;
        }
    }

    get hasRecord() {
        return !!this._recordId;
    }

    // Template-safe accessors — `detail` starts undefined (no record yet) and
    // stays undefined for a beat after hasRecord flips true (loadDetail is
    // async), so a direct {detail.x} binding in the template throws on that
    // render since LWC doesn't add optional chaining for you.
    get headerRecordStatus() {
        return this.detail?.recordStatus;
    }

    get keyMessageRows() {
        return this.detail?.keyMessages || [];
    }

    get promoDropRows() {
        return this.detail?.promoDrops || [];
    }

    get sampleDropRows() {
        return this.detail?.sampleDrops || [];
    }

    get attendeeRows() {
        return this.detail?.attendees || [];
    }

    get internalAttendeeRows() {
        return this.detail?.internalAttendees || [];
    }

    get presentationSessionRows() {
        return this.presentationSessions || [];
    }

    get statusStyle() {
        return pillStyle(callStatusColor(this.detail?.recordStatus));
    }

    get canSubmit() {
        return this.hasRecord && this.detail && this.detail.recordStatus !== 'Submitted' && !this.isPastEditWindow;
    }

    get isLocked() {
        return this.hasRecord && (this.detail?.recordStatus === 'Submitted' || this.isPastEditWindow);
    }

    async handleHeaderSave(event) {
        const newId = event.detail.id;
        const isFirstSave = !this._recordId;
        this._recordId = newId;
        await this.loadDetail();
        this.dispatchEvent(new CustomEvent('recordcreated', { detail: { id: newId } }));

        if (isFirstSave && this.sourcePlannedCallId) {
            try {
                await updateRecord({ fields: { Id: this.sourcePlannedCallId, Resulting_CVR__c: newId } });
            } catch (e) {
                // Non-fatal — the call report itself saved fine; the schedule
                // linkage is a convenience, not a hard requirement.
            }
            this.sourcePlannedCallId = null;
        }
    }

    handleHeaderCancel() {
        this.dispatchEvent(new CustomEvent('close'));
    }

    handleChildRefresh() {
        this.loadDetail();
    }

    handleBack() {
        this.dispatchEvent(new CustomEvent('close'));
    }

    async handleSubmit() {
        this.isSubmitting = true;
        try {
            await submitCallReport({ cvrId: this._recordId });
            this.dispatchEvent(new ShowToastEvent({ title: 'Submitted', message: 'Call report submitted and locked.', variant: 'success' }));
            await this.loadDetail();
        } catch (e) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Couldn’t submit call report', message: e.body?.message || 'Try again.', variant: 'error',
            }));
        } finally {
            this.isSubmitting = false;
        }
    }
}