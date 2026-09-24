import { LightningElement, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import search from '@salesforce/apex/GlobalAccountSearchController.search';
import addToMyTerritory from '@salesforce/apex/GlobalAccountSearchController.addToMyTerritory';
import getSpecialtyOptions from '@salesforce/apex/SciagenAccountController.getSpecialtyOptions';

export default class GlobalAccountSearch extends LightningElement {
    name = '';
    nameMatchType = 'exact';
    firstName = '';
    lastName = '';
    specialty = '';
    primaryParentId;
    addressLine1 = '';
    addressMatchType = 'startsWith';
    city = '';
    state = '';
    postalCode = '';
    phone = '';

    results = [];
    selectedIds = new Set();
    isSearching = false;
    hasSearched = false;
    error;

    specialtyOptions = [{ label: '-- None --', value: '' }];

    nameMatchOptions = [
        { label: 'Exact', value: 'exact' },
        { label: 'Contains', value: 'contains' },
    ];

    addressMatchOptions = [
        { label: 'Starts', value: 'startsWith' },
        { label: 'Contains', value: 'contains' },
    ];

    parentAccountFilter = {
        criteria: [{ fieldPath: 'Type__c', operator: 'eq', value: 'HCO' }],
    };

    @wire(getSpecialtyOptions)
    wiredSpecialties({ data }) {
        if (data) {
            this.specialtyOptions = [{ label: '-- None --', value: '' }, ...data.map((s) => ({ label: s, value: s }))];
        }
    }

    handleFieldChange(event) {
        const field = event.target.dataset.field;
        this[field] = event.target.value;
    }

    handleNameMatchChange(event) {
        this.nameMatchType = event.detail.value;
    }

    handleAddressMatchChange(event) {
        this.addressMatchType = event.detail.value;
    }

    handleParentChange(event) {
        this.primaryParentId = event.detail.recordId;
    }

    get isNameExact() {
        return this.nameMatchType === 'exact';
    }

    get isAddressStartsWith() {
        return this.addressMatchType === 'startsWith';
    }

    async handleSearch() {
        this.error = undefined;
        this.isSearching = true;
        this.hasSearched = true;
        this.selectedIds = new Set();
        try {
            const criteria = {
                name: this.name || null,
                nameExact: this.isNameExact,
                firstName: this.firstName || null,
                lastName: this.lastName || null,
                specialty: this.specialty || null,
                primaryParentId: this.primaryParentId || null,
                addressLine1: this.addressLine1 || null,
                addressStartsWith: this.isAddressStartsWith,
                city: this.city || null,
                state: this.state || null,
                postalCode: this.postalCode || null,
                phone: this.phone || null,
            };
            const rows = await search({ criteriaJson: JSON.stringify(criteria) });
            this.results = rows.map((r) => ({ ...r, checked: false }));
        } catch (e) {
            this.error = reduceError(e);
            this.results = [];
        } finally {
            this.isSearching = false;
        }
    }

    get hasResults() {
        return this.results && this.results.length > 0;
    }

    get hasNoResults() {
        return this.hasSearched && !this.isSearching && !this.hasResults && !this.error;
    }

    get hasSelection() {
        return this.selectedIds.size > 0;
    }

    get hasNoSelection() {
        return this.selectedIds.size === 0;
    }

    handleRowCheckboxChange(event) {
        const id = event.target.dataset.id;
        const next = new Set(this.selectedIds);
        if (event.target.checked) {
            next.add(id);
        } else {
            next.delete(id);
        }
        this.selectedIds = next;
        this.results = this.results.map((r) => ({ ...r, checked: next.has(r.id) }));
    }

    async handleAddToTerritory() {
        try {
            await addToMyTerritory({ accountIds: Array.from(this.selectedIds) });
            this.dispatchEvent(new ShowToastEvent({
                title: 'Added to your territory',
                message: `${this.selectedIds.size} account(s) added.`,
                variant: 'success',
            }));
            await this.handleSearch();
        } catch (e) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Couldn’t add to territory',
                message: reduceError(e),
                variant: 'error',
            }));
        }
    }
}

function reduceError(error) {
    if (error?.body?.message) {
        return error.body.message;
    }
    return 'An unknown error occurred.';
}