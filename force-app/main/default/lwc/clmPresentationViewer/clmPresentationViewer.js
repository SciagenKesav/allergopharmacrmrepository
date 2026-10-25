import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getPresentationDetail from '@salesforce/apex/SciagenCLMController.getPresentationDetail';
import { pillStyle, CLM_BRAND_COLOR } from 'c/sciagenColors';

/// Read-only slide viewer for one Presentation__c — no create/edit/delete
/// here, all writes to Presentation__c/Slide__c are CMS-owned
/// (see CMSContentReceiver.cls). Each slide's file lives in S3 (the CMS
/// uploads it there directly — Salesforce only stores the URL), so previewing
/// it is just opening that URL, not a Salesforce File-preview page.
export default class ClmPresentationViewer extends LightningElement {
    @api presentationId;

    detail;
    isLoading = false;
    expandedHtmlSlideId;
    currentIndex = 0;
    showEndState = false;

    connectedCallback() {
        this.loadDetail();
    }

    async loadDetail() {
        if (!this.presentationId) {
            return;
        }
        this.isLoading = true;
        this.currentIndex = 0;
        this.showEndState = false;
        try {
            this.detail = await getPresentationDetail({ presentationId: this.presentationId });
        } catch (e) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Couldn’t load presentation', message: e.body?.message || 'Try again.', variant: 'error',
            }));
        } finally {
            this.isLoading = false;
        }
    }

    get brandStyle() {
        return pillStyle(CLM_BRAND_COLOR[this.detail?.brand]);
    }

    get slideRows() {
        return (this.detail?.slides || []).map((s) => ({
            ...s,
            hasFile: !!s.assetUrl,
            isHtml: s.fileType === 'HTML' && !!s.htmlContent,
            isHtmlExpanded: this.expandedHtmlSlideId === s.id,
            durationLabel: s.isVideo && s.videoDurationSec ? `${s.videoDurationSec}s` : null,
        }));
    }

    get hasSlides() {
        return this.slideRows.length > 0;
    }

    // MARK: - Slide-by-slide navigation

    get isShowingSlide() {
        return this.hasSlides && !this.showEndState;
    }

    get currentSlide() {
        return this.slideRows[this.currentIndex];
    }

    get slidePositionLabel() {
        return `Slide ${this.currentIndex + 1} of ${this.slideRows.length}`;
    }

    get isFirstSlide() {
        return this.currentIndex === 0;
    }

    get isLastSlide() {
        return this.currentIndex === this.slideRows.length - 1;
    }

    get nextButtonLabel() {
        return this.isLastSlide ? 'Finish' : 'Next';
    }

    handlePrevSlide() {
        if (this.showEndState) {
            this.showEndState = false;
            return;
        }
        if (this.currentIndex > 0) {
            this.currentIndex -= 1;
            this.expandedHtmlSlideId = undefined;
        }
    }

    handleNextSlide() {
        if (this.isLastSlide) {
            this.showEndState = true;
            return;
        }
        this.currentIndex += 1;
        this.expandedHtmlSlideId = undefined;
    }

    handleRestart() {
        this.currentIndex = 0;
        this.showEndState = false;
    }

    handlePreview(event) {
        const assetUrl = event.currentTarget.dataset.url;
        if (assetUrl) {
            window.open(assetUrl, '_blank', 'noopener');
        }
    }

    handleToggleHtmlPreview(event) {
        const id = event.currentTarget.dataset.id;
        this.expandedHtmlSlideId = this.expandedHtmlSlideId === id ? undefined : id;
    }

    handleBack() {
        this.dispatchEvent(new CustomEvent('close'));
    }
}