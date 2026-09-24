import { LightningElement } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getProductOptions from '@salesforce/apex/AccountPlanController.getProductOptions';
import getHcpOptionsForHco from '@salesforce/apex/AccountPlanController.getHcpOptionsForHco';

const PRODUCT_SEARCH_DEBOUNCE_MS = 300;
const HCP_SEARCH_DEBOUNCE_MS = 300;

/// Shared "New Account Plan" modal — the full field set (Account, Plan,
/// Details, Mission Statement, Differentiation Strategy, Key Initiatives,
/// SWOT) behind Cancel / Save & New / Submit. Used by both accountPlanBrowser
/// (the Account Plans page) and kamHomeDashboard (the KAM Dashboard page) so
/// the two Account-Plan-list surfaces offer the identical create flow
/// instead of each maintaining its own copy of this form.
///
/// Deliberately dumb about what happens after a save: it just dispatches
/// `created` (detail: { id, keepOpen }) and `close`, leaving navigation/
/// refresh/toast-on-close entirely to whichever page embeds it.
export default class NewAccountPlanModal extends LightningElement {
    isSaving = false;
    error;
    pendingAction = 'submit'; // 'submit' | 'saveNew' — which button triggered the current submission
    formCounter = 0;
    formInstances = [{ key: 'plan-form-0' }];

    // MARK: - Applied Products (dynamic search) — Applied_Products__c is a
    // plain Text field (not a Lookup), so there's no native lookup widget for
    // it; this builds up a chip list from Product__c search results and
    // joins the chosen names into the field's text value on submit.
    productSearchTerm = '';
    productResults = [];
    selectedProducts = [];
    productDebounceTimer;

    get hasProductResults() {
        return this.productResults.length > 0;
    }

    get hasSelectedProducts() {
        return this.selectedProducts.length > 0;
    }

    get appliedProductsText() {
        return this.selectedProducts.map((p) => p.name).join(', ');
    }

    handleProductSearchChange(event) {
        this.productSearchTerm = event.target.value;
        window.clearTimeout(this.productDebounceTimer);
        this.productDebounceTimer = window.setTimeout(() => this.runProductSearch(), PRODUCT_SEARCH_DEBOUNCE_MS);
    }

    async runProductSearch() {
        if (!this.productSearchTerm) {
            this.productResults = [];
            return;
        }
        try {
            const results = await getProductOptions({ searchTerm: this.productSearchTerm });
            const selectedIds = new Set(this.selectedProducts.map((p) => p.id));
            this.productResults = results.filter((p) => !selectedIds.has(p.id));
        } catch (e) {
            this.productResults = [];
        }
    }

    handleProductSelect(event) {
        const id = event.currentTarget.dataset.id;
        const name = event.currentTarget.dataset.name;
        if (!this.selectedProducts.some((p) => p.id === id)) {
            this.selectedProducts = [...this.selectedProducts, { id, name }];
        }
        this.productSearchTerm = '';
        this.productResults = [];
    }

    handleProductRemove(event) {
        const id = event.currentTarget.dataset.id;
        this.selectedProducts = this.selectedProducts.filter((p) => p.id !== id);
    }

    // MARK: - HCP (scoped to the selected HCO) — HCP__c is a real Lookup, but
    // its own field-level filter only narrows to Type__c = 'HCP' org-wide;
    // this further restricts the search to HCPs actually affiliated with
    // whichever HCO is picked above, via Affiliation__c. Single-select
    // (unlike Applied Products' chip list) since the field only holds one Id.
    selectedHcoId;
    hcpSearchTerm = '';
    hcpResults = [];
    selectedHcp;
    hcpDebounceTimer;

    get hasHcpResults() {
        return this.hcpResults.length > 0;
    }

    get hcpSearchDisabled() {
        return !this.selectedHcoId;
    }

    get hcpSearchPlaceholder() {
        return this.selectedHcoId ? 'Search HCPs…' : 'Select an HCO first';
    }

    handleHcoChange(event) {
        // lightning-input-field's change event reports a Lookup's value as a
        // single-element array (e.g. ["001..."]), not a scalar Id — passing
        // that straight to an Apex action parameter typed `Id` is rejected
        // ("Value provided is invalid for action parameter 'hcoId' of type
        // 'Id'"), so unwrap it here.
        const rawValue = event.detail.value;
        const newHcoId = Array.isArray(rawValue) ? rawValue[0] : rawValue;
        if (newHcoId !== this.selectedHcoId) {
            // A different HCO invalidates any HCP already chosen for the old one.
            this.selectedHcp = undefined;
            this.hcpSearchTerm = '';
            this.hcpResults = [];
        }
        this.selectedHcoId = newHcoId;
    }

    handleHcpSearchChange(event) {
        this.hcpSearchTerm = event.target.value;
        window.clearTimeout(this.hcpDebounceTimer);
        this.hcpDebounceTimer = window.setTimeout(() => this.runHcpSearch(), HCP_SEARCH_DEBOUNCE_MS);
    }

    async runHcpSearch() {
        if (!this.selectedHcoId) {
            this.hcpResults = [];
            return;
        }
        try {
            this.hcpResults = await getHcpOptionsForHco({
                hcoId: this.selectedHcoId,
                searchTerm: this.hcpSearchTerm,
            });
        } catch (e) {
            this.hcpResults = [];
        }
    }

    handleHcpSelect(event) {
        const id = event.currentTarget.dataset.id;
        const name = event.currentTarget.dataset.name;
        this.selectedHcp = { id, name };
        this.hcpSearchTerm = '';
        this.hcpResults = [];
    }

    handleHcpClear() {
        this.selectedHcp = undefined;
    }

    handleCancel() {
        this.dispatchEvent(new CustomEvent('close'));
    }

    handleSaveAndNewClick() {
        this.pendingAction = 'saveNew';
    }

    handleSubmitClick() {
        this.pendingAction = 'submit';
    }

    handleSubmit(event) {
        // Applied_Products__c and HCP__c aren't rendered as ordinary
        // lightning-input-fields (they're driven by the custom search widgets
        // above), so the auto-built fields object needs their values injected
        // by hand here.
        event.preventDefault();
        this.isSaving = true;
        this.error = undefined;
        const fields = {
            ...event.detail.fields,
            Applied_Products__c: this.appliedProductsText,
            HCP__c: this.selectedHcp ? this.selectedHcp.id : null,
        };
        event.target.submit(fields);
    }

    handleSuccess(event) {
        this.isSaving = false;
        const planId = event.detail.id;
        const keepOpen = this.pendingAction === 'saveNew';

        this.dispatchEvent(new ShowToastEvent({
            title: 'Created',
            message: keepOpen ? 'Account plan created — form cleared for the next one.' : 'Account plan created.',
            variant: 'success',
        }));
        this.dispatchEvent(new CustomEvent('created', { detail: { id: planId, keepOpen } }));

        if (keepOpen) {
            // Swapping the key tears down the old form (and every input-field
            // in it) and mounts a fresh one — lightning-record-edit-form has
            // no built-in reset, so this is the reliable way to clear it.
            this.formCounter += 1;
            this.formInstances = [{ key: `plan-form-${this.formCounter}` }];
            this.productSearchTerm = '';
            this.productResults = [];
            this.selectedProducts = [];
            this.selectedHcoId = undefined;
            this.hcpSearchTerm = '';
            this.hcpResults = [];
            this.selectedHcp = undefined;
        } else {
            this.dispatchEvent(new CustomEvent('close'));
        }
    }

    handleError(event) {
        this.isSaving = false;
        this.error = event.detail?.detail || event.detail?.message || 'Check the highlighted fields and try again.';
        this.dispatchEvent(new ShowToastEvent({
            title: 'Couldn’t create plan',
            message: this.error,
            variant: 'error',
        }));
    }

    stopPropagation(event) {
        event.stopPropagation();
    }
}