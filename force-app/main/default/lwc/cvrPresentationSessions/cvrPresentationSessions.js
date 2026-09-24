import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getPresentationLibrary from '@salesforce/apex/SciagenCLMController.getPresentationLibrary';
import getPresentationDetail from '@salesforce/apex/SciagenCLMController.getPresentationDetail';
import logPresentationSession from '@salesforce/apex/SciagenCLMController.logPresentationSession';
import { pillStyle, CLM_BRAND_COLOR } from 'c/sciagenColors';

/// Presentation_Session__c child list for a Call_Visit_Report__c. Unlike the
/// other 4 CVR child sections (cvrKeyMessages/cvrPromoDrops/cvrAttendees/
/// cvrInternalAttendees), "Log Presentation" is NOT a bare
/// lightning-record-edit-form — it spans Presentation_Session__c +
/// Slide_Event__c + auto-generated Key_Message__c in one atomic Apex call
/// (SciagenCLMController.logPresentationSession), so this is a custom form.
export default class CvrPresentationSessions extends LightningElement {
    @api cvrId;
    @api locked = false;
    @api rows = [];

    showLogForm = false;
    isLoadingPresentations = false;
    isLoadingSlides = false;
    isSaving = false;

    presentationOptions = [];
    selectedPresentationId = '';
    presentationDetail;
    checkedSlideIds = [];
    startTime;
    endTime;
    annotationSec;
    videoTotalSec;
    videoWatchedSec;

    get displayRows() {
        return (this.rows || []).map((r) => ({
            ...r,
            brandStyle: pillStyle(CLM_BRAND_COLOR[r.brand]),
        }));
    }

    get hasRows() {
        return (this.rows || []).length > 0;
    }

    async handleAdd() {
        this.showLogForm = true;
        this.resetForm();
        this.isLoadingPresentations = true;
        try {
            const items = await getPresentationLibrary({ searchTerm: '', brand: '', productId: null });
            this.presentationOptions = items.map((p) => ({ label: `${p.name} (${p.brand})`, value: p.id }));
        } catch (e) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Couldn’t load presentations', message: e.body?.message || 'Try again.', variant: 'error',
            }));
        } finally {
            this.isLoadingPresentations = false;
        }
    }

    resetForm() {
        this.selectedPresentationId = '';
        this.presentationDetail = undefined;
        this.checkedSlideIds = [];
        this.startTime = undefined;
        this.endTime = undefined;
        this.annotationSec = undefined;
        this.videoTotalSec = undefined;
        this.videoWatchedSec = undefined;
    }

    handleCancelAdd() {
        this.showLogForm = false;
        this.isSaving = false;
    }

    async handlePresentationChange(event) {
        this.selectedPresentationId = event.detail.value;
        this.presentationDetail = undefined;
        this.checkedSlideIds = [];
        if (!this.selectedPresentationId) {
            return;
        }
        this.isLoadingSlides = true;
        try {
            this.presentationDetail = await getPresentationDetail({ presentationId: this.selectedPresentationId });
            this.checkedSlideIds = (this.presentationDetail?.slides || []).map((s) => s.id);
        } catch (e) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Couldn’t load slides', message: e.body?.message || 'Try again.', variant: 'error',
            }));
        } finally {
            this.isLoadingSlides = false;
        }
    }

    get slideCheckRows() {
        return (this.presentationDetail?.slides || []).map((s) => ({
            ...s,
            checked: this.checkedSlideIds.includes(s.id),
        }));
    }

    get hasSlideRows() {
        return this.slideCheckRows.length > 0;
    }

    get hasVideoSlideChecked() {
        return this.slideCheckRows.some((s) => s.checked && s.isVideo);
    }

    handleSlideToggle(event) {
        const slideId = event.currentTarget.dataset.id;
        const checked = event.target.checked;
        if (checked && !this.checkedSlideIds.includes(slideId)) {
            this.checkedSlideIds = [...this.checkedSlideIds, slideId];
        } else if (!checked) {
            this.checkedSlideIds = this.checkedSlideIds.filter((id) => id !== slideId);
        }
    }

    handleStartTimeChange(event) {
        this.startTime = event.target.value;
    }

    handleEndTimeChange(event) {
        this.endTime = event.target.value;
    }

    handleAnnotationSecChange(event) {
        this.annotationSec = event.target.value;
    }

    handleVideoTotalSecChange(event) {
        this.videoTotalSec = event.target.value;
    }

    handleVideoWatchedSecChange(event) {
        this.videoWatchedSec = event.target.value;
    }

    get canSave() {
        return !!this.selectedPresentationId && this.checkedSlideIds.length > 0 && !this.isSaving;
    }

    async handleSave() {
        this.isSaving = true;
        try {
            const slides = this.checkedSlideIds.map((slideId, index) => ({
                slideId, sequence: index + 1, timeSpentSec: null,
            }));
            // Sent as a JSON string, not a plain array — the Aura/LWC bridge
            // doesn't reliably populate the fields of a custom Apex class
            // passed as a parameter (see SciagenCLMController.logPresentationSession).
            await logPresentationSession({
                cvrId: this.cvrId,
                presentationId: this.selectedPresentationId,
                startTime: this.startTime || null,
                endTime: this.endTime || null,
                annotationSec: this.annotationSec ? parseInt(this.annotationSec, 10) : null,
                videoTotalSec: this.videoTotalSec ? parseInt(this.videoTotalSec, 10) : null,
                videoWatchedSec: this.videoWatchedSec ? parseInt(this.videoWatchedSec, 10) : null,
                slidesJson: JSON.stringify(slides),
            });
            this.dispatchEvent(new ShowToastEvent({ title: 'Saved', message: 'Presentation session logged.', variant: 'success' }));
            this.showLogForm = false;
            this.dispatchEvent(new CustomEvent('refresh'));
        } catch (e) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Couldn’t log presentation', message: e.body?.message || 'Try again.', variant: 'error',
            }));
        } finally {
            this.isSaving = false;
        }
    }
}