import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getResetRequests from '@salesforce/apex/DeviceResetAdminController.getResetRequests';

const STATUS_OPTIONS = [
    { label: 'All', value: 'All' },
    { label: 'Pending Approval', value: 'Pending Approval' },
    { label: 'Approved', value: 'Approved' },
    { label: 'Rejected', value: 'Rejected' },
    { label: 'Used', value: 'Used' },
];

const STATUS_CLASS = {
    'Pending Approval': 'slds-badge_lightest',
    'Approved':         'slds-badge slds-theme_success',
    'Rejected':         'slds-badge slds-theme_error',
    'Used':             'slds-badge slds-theme_shade',
};

export default class DeviceResetAdmin extends LightningElement {
    @track requests = [];
    @track isLoading = false;
    @track errorMessage = '';
    @track statusFilter = 'All';
    @track copySuccess = false;

    statusOptions = STATUS_OPTIONS;
    _copyTimer;

    connectedCallback() {
        this.loadRequests();
    }

    get isEmpty() { return !this.isLoading && this.requests.length === 0; }
    get hasRequests() { return !this.isLoading && this.requests.length > 0; }

    async loadRequests() {
        this.isLoading = true;
        this.errorMessage = '';
        try {
            const raw = await getResetRequests({ statusFilter: this.statusFilter });
            const baseUrl = window.location.origin;
            const now = new Date();
            this.requests = raw.map(r => {
                const expires = r.OTP_Expires__c ? new Date(r.OTP_Expires__c) : null;
                const isExpired = expires ? expires < now : false;
                return {
                    ...r,
                    recordUrl: `${baseUrl}/lightning/r/Device_Reset_Request__c/${r.Id}/view`,
                    OwnerName: r.Owner ? r.Owner.Name : '—',
                    ManagerName: r.Manager__r ? r.Manager__r.Name : '—',
                    showOTP: r.Status__c === 'Approved' && r.OTP__c,
                    statusClass: STATUS_CLASS[r.Status__c] || '',
                    isExpired,
                    expiresLabel: expires
                        ? (isExpired
                            ? 'Expired ' + this._formatDate(expires)
                            : 'Expires ' + this._formatDate(expires))
                        : '—',
                    createdLabel: r.CreatedDate ? this._formatDate(new Date(r.CreatedDate)) : '—',
                };
            });
        } catch (e) {
            this.errorMessage = e.body ? e.body.message : String(e);
        } finally {
            this.isLoading = false;
        }
    }

    handleStatusFilter(evt) {
        this.statusFilter = evt.detail.value;
        this.loadRequests();
    }

    handleCopyOTP(evt) {
        const code = evt.currentTarget.dataset.otp;
        if (!code) return;
        try {
            navigator.clipboard.writeText(code);
        } catch (_) {
            // Clipboard API may be blocked — fall back to execCommand
            const el = document.createElement('textarea');
            el.value = code;
            document.body.appendChild(el);
            el.select();
            document.execCommand('copy');
            document.body.removeChild(el);
        }
        this.copySuccess = true;
        clearTimeout(this._copyTimer);
        this._copyTimer = setTimeout(() => { this.copySuccess = false; }, 2500);
    }

    _formatDate(d) {
        return d.toLocaleDateString('en-IN', {
            day: '2-digit', month: 'short', year: 'numeric',
            hour: '2-digit', minute: '2-digit'
        });
    }
}