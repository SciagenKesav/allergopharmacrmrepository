import { LightningElement } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getPresentationLibrary from '@salesforce/apex/SciagenCLMController.getPresentationLibrary';
import getBrandOptions from '@salesforce/apex/SciagenCLMController.getBrandOptions';
import getProductOptions from '@salesforce/apex/SciagenCLMController.getProductOptions';
import { pillStyle, CLM_BRAND_COLOR } from 'c/sciagenColors';

const SEARCH_DEBOUNCE_MS = 300;

/// "CLM Library" — top-level browse page for approved Presentation__c decks,
/// modeled on mySchedule.js's container/fetch/filter pattern. Always shows
/// only Approval_Status__c = 'Approved Promotional' (enforced server-side by
/// SciagenCLMController.getPresentationLibrary, not a client filter).
export default class ClmLibrary extends LightningElement {
    searchTerm = '';
    brand = '';
    productId = '';

    brandOptions = [];
    productOptions = [];
    items = [];
    isLoading = false;

    viewingPresentationId = null;
    searchTimeout;

    connectedCallback() {
        this.loadFilterOptions();
        this.loadLibrary();
    }

    async loadFilterOptions() {
        try {
            const [brands, products] = await Promise.all([getBrandOptions(), getProductOptions()]);
            this.brandOptions = brands;
            this.productOptions = products;
        } catch (e) {
            // Filter option lists are a convenience — fail quietly, matching mySchedule's loadFilterOptions.
        }
    }

    async loadLibrary() {
        this.isLoading = true;
        try {
            this.items = await getPresentationLibrary({
                searchTerm: this.searchTerm, brand: this.brand, productId: this.productId || null,
            });
        } catch (e) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Couldn’t load the CLM library', message: e.body?.message || 'Try again.', variant: 'error',
            }));
            this.items = [];
        } finally {
            this.isLoading = false;
        }
    }

    get brandComboOptions() {
        return [{ label: 'All Brands', value: '' }, ...this.brandOptions.map((b) => ({ label: b, value: b }))];
    }

    get productComboOptions() {
        return [{ label: 'All Products', value: '' }, ...this.productOptions.map((p) => ({ label: p.name, value: p.id }))];
    }

    handleSearchChange(event) {
        const value = event.target.value;
        window.clearTimeout(this.searchTimeout);
        this.searchTimeout = window.setTimeout(() => {
            this.searchTerm = value;
            this.loadLibrary();
        }, SEARCH_DEBOUNCE_MS);
    }

    handleBrandChange(event) {
        this.brand = event.detail.value;
        this.loadLibrary();
    }

    handleProductChange(event) {
        this.productId = event.detail.value;
        this.loadLibrary();
    }

    get decoratedItems() {
        return (this.items || []).map((item) => ({
            ...item,
            brandStyle: pillStyle(CLM_BRAND_COLOR[item.brand]),
            slideCountLabel: item.slideCount === 1 ? '1 slide' : `${item.slideCount} slides`,
        }));
    }

    get hasResults() {
        return this.decoratedItems.length > 0;
    }

    get isViewingPresentation() {
        return !!this.viewingPresentationId;
    }

    handleOpenPresentation(event) {
        this.viewingPresentationId = event.currentTarget.dataset.id;
    }

    handleCloseViewer() {
        this.viewingPresentationId = null;
    }
}