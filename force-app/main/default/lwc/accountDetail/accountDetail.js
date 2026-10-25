import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { deleteRecord } from 'lightning/uiRecordApi';
import getAccountDetail from '@salesforce/apex/SciagenAccountController.getAccountDetail';
import isKeyAccountManager from '@salesforce/apex/SciagenAccountController.isKeyAccountManager';
import submitEditDcr from '@salesforce/apex/SciagenAccountController.submitEditDcr';
import getAccountHierarchy from '@salesforce/apex/SciagenAccountController.getAccountHierarchy';
import unassignFromMyTerritory from '@salesforce/apex/AccountTerritoryUnassignController.unassignFromMyTerritory';
import { BRAND, pillStyle, CLASSIFICATION_COLOR, TIER_COLOR, DCR_STATUS_COLOR, PREFERENCE_COLOR, callStatusColor,
         ACAROID_READINESS_COLOR, ACAROID_CAN_ADMINISTER_COLOR, ACAROID_TIER_COLOR } from 'c/sciagenColors';

const SECTIONS = [
    { key: 'profile', label: 'Profile', icon: 'utility:contact' },
    { key: 'timeline', label: 'Timeline', icon: 'utility:date_time' },
    { key: 'segmentation', label: 'Segmentation', icon: 'utility:priority' },
    { key: 'engagement', label: 'Engagement', icon: 'utility:trending' },
    { key: 'activity', label: 'Activity', icon: 'utility:call' },
    { key: 'related', label: 'Related', icon: 'utility:relate' },
    { key: 'hierarchy', label: 'Hierarchy', icon: 'utility:hierarchy' },
    { key: 'dcr', label: 'DCR', icon: 'utility:edit_form' },
];

const HCP_EDIT_FIELDS = [
    'Name', 'Prefix__c', 'First_Name__c', 'Last_Name__c', 'Primary_Country__c', 'HCP_Type__c', 'Specialty__c',
    'Focus_Area__c', 'License_Number__c', 'Licensing_Body__c', 'Phone__c', 'Email__c', 'Account_Code__c',
];
const HCO_EDIT_FIELDS = [
    'Name', 'HCO_Type__c', 'Speciality__c', 'Billing_Street__c', 'Billing_City__c', 'Billing_State__c',
    'Billing_Country__c', 'Billing_Postal_Code__c', 'Website__c', 'Phone__c', 'Email__c', 'Account_Code__c',
];

// Hierarchy graph node icon: HCO = violet / HCP = primary, a solid circular avatar in each node pill.
function nodeIconName(type) {
    return type === 'HCO' ? 'utility:company' : 'utility:user';
}
function nodeIconStyle(type) {
    return `background-color:#${type === 'HCO' ? BRAND.violet : BRAND.primary};`;
}

// Compact quick-edit set only — the full Acaroid capture experience (every
// rep-owned field, grouped by section) lives on the iPad; this covers just
// the fields that most directly move the score/tier so a manager or rep at
// a desk can make a quick correction.
// Every rep-editable HCP field the iPad app's Acaroid capture form writes
// (AcaroidTargetingView.swift's HCP field dict) — kept in sync with that list
// and with REP_ACCOUNT_FIELDS in the Salesforce permission-set generator, so
// a rep sees exactly the same capture fields on both platforms.
const ACAROID_HCP_EDIT_FIELDS = [
    'Acaroid_Subspecialty_Interest__c', 'Acaroid_Practice_Setting__c', 'Acaroid_AR_Patients_Week__c',
    'Acaroid_Asthma_Patients_Week__c', 'Acaroid_HCP_Paed_Share_Pct__c', 'Acaroid_Eligible_Asthma_Share_Pct__c',
    'Acaroid_HCP_Affordability_Band__c', 'Acaroid_Practises_AIT__c', 'Acaroid_AIT_Patients_On_Therapy__c',
    'Acaroid_Current_AIT_Product__c', 'Acaroid_Allergy_Testing_Freq__c', 'Acaroid_Allergy_Test_Types__c',
    'Acaroid_AIT_Training__c', 'Acaroid_SCIT_Attitude__c', 'Acaroid_Key_Barriers__c', 'Acaroid_Adoption_Stage__c',
    'Acaroid_Own_Clinic_Fridge__c', 'Acaroid_Own_Clinic_Emergency_Kit__c', 'Acaroid_Society_Memberships__c',
    'Acaroid_Society_Office_Bearer__c', 'Acaroid_Is_Teaching_Faculty__c', 'Acaroid_Referral_Network_Size__c',
    'Acaroid_Preferred_Channel__c', 'Acaroid_Patients_Initiated__c', 'Acaroid_HCP_Active_Patients__c',
    'Acaroid_Patients_Referred__c', 'Acaroid_Last_Initiation_Date__c',
];
// Every rep-editable HCO field the iPad app's Acaroid capture form writes,
// across its main capture screen and its separate Readiness Audit screen —
// same sync note as ACAROID_HCP_EDIT_FIELDS above.
const ACAROID_HCO_EDIT_FIELDS = [
    'Acaroid_Has_Allergy_Dept__c', 'Acaroid_Has_Pulmonology_Dept__c', 'Acaroid_Has_Paed_Resp_Dept__c',
    'Acaroid_Has_ENT_Dept__c', 'Acaroid_Allergy_Testing__c', 'Acaroid_AIT_Offered__c', 'Acaroid_AIT_Product_Source__c',
    'Acaroid_Est_AIT_Patients__c', 'Acaroid_Est_AR_Asthma_OPD_Month__c', 'Acaroid_HCO_Paed_Share_Pct__c',
    'Acaroid_Payer_Mix__c', 'Acaroid_HCO_Affordability_Band__c', 'Acaroid_HCO_Active_Patients__c',
    'Acaroid_New_Initiations_MTD__c', 'Acaroid_Patients_Updosing__c', 'Acaroid_Patients_Maintenance__c',
    'Acaroid_Vials_In_Stock__c', 'Acaroid_Earliest_Inuse_Expiry__c', 'Acaroid_Storage_Location__c',
    'Acaroid_Has_2_8C_Fridge__c', 'Acaroid_Has_Emergency_Kit__c', 'Acaroid_Anaphylaxis_Trained_Staff__c',
    'Acaroid_Has_Observation_Area__c', 'Acaroid_Temp_Monitoring__c', 'Acaroid_Fridge_Power_Backup__c',
    'Acaroid_Fridge_Capacity_Vials__c', 'Acaroid_Readiness_Audit_Date__c',
];


export default class AccountDetail extends NavigationMixin(LightningElement) {
    // "Unassign from Territory": removes only the link to the running user's own territory
    // (AccountTerritoryUnassignService); the account record is never deleted.
    isConfirmingUnassign = false;
    isUnassigning = false;
    unassignCommentInput = '';

    _recordId;
    record;
    isLoading = false;
    isEditing = false;
    isSaving = false;
    isEditingSegmentation = false;
    isSavingSegmentation = false;
    isEditingAcaroid = false;
    isSavingAcaroid = false;
    isEditingProfileSummary = false;
    isSavingProfileSummary = false;
    showAddOfficeWindow = false;
    editingOfficeWindowId = null;
    isSavingOfficeWindow = false;
    showCallReportPanel = false;
    showAddAffiliation = false;
    isSavingAffiliation = false;
    error;
    activeSection = 'profile';
    hierarchy;
    isHierarchyLoading = false;

    @api
    get recordId() {
        return this._recordId;
    }
    set recordId(value) {
        this._recordId = value;
        this.isEditing = false;
        this.isSaving = false;
        this.isEditingSegmentation = false;
        this.isSavingSegmentation = false;
        this.isEditingProfileSummary = false;
        this.isSavingProfileSummary = false;
        this.showAddOfficeWindow = false;
        this.editingOfficeWindowId = null;
        this.isSavingOfficeWindow = false;
        this.showCallReportPanel = false;
        this.showAddAffiliation = false;
        this.isSavingAffiliation = false;
        this.activeSection = 'profile';
        this.hierarchy = undefined;
        this.loadDetail();
    }

    // MARK: - Unassign from Territory

    handleOpenUnassignConfirm() {
        this.isConfirmingUnassign = true;
        this.unassignCommentInput = '';
    }

    handleCloseUnassignConfirm() {
        this.isConfirmingUnassign = false;
        this.unassignCommentInput = '';
    }

    handleUnassignCommentChange(event) {
        this.unassignCommentInput = event.target.value;
    }

    get isUnassignConfirmDisabled() {
        return this.isUnassigning || !this.unassignCommentInput || !this.unassignCommentInput.trim();
    }

    async handleConfirmUnassign() {
        const comment = this.unassignCommentInput.trim();
        if (!comment) {
            return;
        }
        this.isUnassigning = true;
        try {
            const outcome = await unassignFromMyTerritory({ accountId: this._recordId, comment });
            this.isConfirmingUnassign = false;
            this.unassignCommentInput = '';
            // outcome.immediate is always false now — the link isn't removed until a steward
            // approves the request (see AccountTerritoryUnassignService) — but the check is kept
            // rather than hardcoding the navigate-away below, so this LWC doesn't have to change
            // again if that ever becomes a fast-path for some request type in the future.
            this.dispatchEvent(new ShowToastEvent({
                title: outcome.immediate ? 'Removed from your territory' : 'Submitted for review',
                message: outcome.message,
                variant: 'success',
            }));
            if (outcome.immediate) {
                // The account no longer belongs to this user's territory, so send them back to
                // the Accounts list (which reloads without it) rather than leave them on its detail.
                this[NavigationMixin.Navigate]({
                    type: 'standard__navItemPage',
                    attributes: { apiName: 'Account_Browser_Page' },
                });
            }
        } catch (e) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Couldn’t unassign from territory',
                message: (e && e.body && e.body.message) || 'An unknown error occurred.',
                variant: 'error',
            }));
        } finally {
            this.isUnassigning = false;
        }
    }

    async loadDetail() {
        if (!this._recordId) {
            this.record = undefined;
            return;
        }
        this.isLoading = true;
        this.error = undefined;
        try {
            this.record = await getAccountDetail({ accountId: this._recordId });
        } catch (e) {
            this.error = reduceError(e);
        } finally {
            this.isLoading = false;
        }
    }

    get isHCP() {
        return this.record?.type === 'HCP';
    }

    get isHCO() {
        return this.record?.type === 'HCO';
    }

    // MARK: - Section rail (left-hand nav replacing the old top tab bar)

    get sections() {
        return SECTIONS.map((s) => ({
            ...s,
            navClass: s.key === this.activeSection ? 'section-nav-item active' : 'section-nav-item',
        }));
    }

    handleSectionSelect(event) {
        this.activeSection = event.currentTarget.dataset.key;
        if (this.activeSection === 'hierarchy' && !this.hierarchy) {
            this.loadHierarchy();
        }
    }

    async loadHierarchy() {
        this.isHierarchyLoading = true;
        try {
            this.hierarchy = await getAccountHierarchy({ accountId: this._recordId });
        } catch (e) {
            this.hierarchy = null;
        } finally {
            this.isHierarchyLoading = false;
        }
    }

    get isProfileSection() {
        return this.activeSection === 'profile';
    }

    get isTimelineSection() {
        return this.activeSection === 'timeline';
    }

    get isSegmentationSection() {
        return this.activeSection === 'segmentation';
    }

    get isEngagementSection() {
        return this.activeSection === 'engagement';
    }

    get isActivitySection() {
        return this.activeSection === 'activity';
    }

    get isRelatedSection() {
        return this.activeSection === 'related';
    }

    get isHierarchySection() {
        return this.activeSection === 'hierarchy';
    }

    get hasHierarchyParent() {
        return !!this.hierarchy?.parent;
    }

    get hasHierarchyChildren() {
        return this.hierarchy?.children?.length > 0;
    }

    get hasHierarchyAffiliatedHCPs() {
        return this.hierarchy?.affiliatedHCPs?.length > 0;
    }

    get isHierarchyEmpty() {
        return this.hierarchy && !this.hasHierarchyParent && !this.hasHierarchyChildren && !this.hasHierarchyAffiliatedHCPs;
    }

    get hierarchySelfIconName() {
        return nodeIconName(this.hierarchy?.selfType);
    }

    get hierarchySelfIconStyle() {
        return nodeIconStyle(this.hierarchy?.selfType);
    }

    get hierarchyParent() {
        const p = this.hierarchy?.parent;
        return p ? { ...p, iconName: nodeIconName(p.type), iconStyle: nodeIconStyle(p.type) } : null;
    }

    // An HCP's "parent" node is its Primary HCO (see getAccountHierarchy); everything else keeps the
    // generic "Parent Account" wording. Doubles as the relationship label on the connector line.
    get hierarchyParentLabel() {
        return this.hierarchy?.selfType === 'HCP' ? 'Primary HCO' : 'Parent Account';
    }

    get hierarchyChildren() {
        return (this.hierarchy?.children || []).map((c) => ({
            ...c, iconName: nodeIconName(c.type), iconStyle: nodeIconStyle(c.type),
        }));
    }

    get hierarchyAffiliatedHCPs() {
        return (this.hierarchy?.affiliatedHCPs || []).map((h) => ({
            ...h, iconName: nodeIconName(h.type), iconStyle: nodeIconStyle(h.type),
        }));
    }

    handleHierarchyNavigate(event) {
        const id = event.currentTarget.dataset.id;
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: id, objectApiName: 'Sciagen_Account__c', actionName: 'view' },
        });
    }

    get isDcrSection() {
        return this.activeSection === 'dcr';
    }

    get hasAffiliations() {
        return this.record?.affiliations?.length > 0;
    }

    get hasPublications() {
        return this.record?.publications?.length > 0;
    }

    get hasCongressEvents() {
        return this.record?.congressEvents?.length > 0;
    }

    get hasClinicalTrials() {
        return this.record?.clinicalTrials?.length > 0;
    }

    get hasSegmentation() {
        return !!this.record?.segmentation;
    }

    get classificationPillStyle() {
        return pillStyle(CLASSIFICATION_COLOR[this.record?.segmentation?.classification]);
    }

    get tierPillStyle() {
        return pillStyle(TIER_COLOR[this.record?.segmentation?.tier]);
    }

    get hasScientificImpact() {
        const r = this.record;
        return !!(r && (r.totalArticles || r.totalCitations || r.avgCitationsPerArticle || r.avgCoauthorsPerArticle
            || r.uniqueJournalCount || r.guidelineCount || r.activelyPublishedYears || r.reachFlag || r.emergingExpert));
    }

    get emergingExpertLabel() {
        return this.record?.emergingExpert ? 'Yes' : 'No';
    }

    get hasEngagement() {
        return this.hasPublications || this.hasCongressEvents || this.hasClinicalTrials || this.hasScientificImpact || this.hasOfficeWindows;
    }

    // DCR entries have their own dedicated DCR tab (dcrRows below) — showing
    // them here too was a straight duplicate, so the Timeline only carries
    // the kinds it's the sole home for.
    get timelineEntries() {
        return (this.record?.timeline || []).filter((t) => t.kind !== 'DCR');
    }

    get hasTimeline() {
        return this.timelineEntries.length > 0;
    }

    get timelineRows() {
        const colorByKind = { Planned: BRAND.amber, Email: BRAND.accent };
        return this.timelineEntries.map((t, index) => ({
            ...t,
            key: `${t.kind}-${index}`,
            kindStyle: pillStyle(colorByKind[t.kind] || BRAND.primary),
        }));
    }

    get hasCallVisitReports() {
        return this.record?.callVisitReports?.length > 0;
    }

    get cvrRows() {
        return (this.record?.callVisitReports || []).map((c) => ({ ...c, statusStyle: pillStyle(callStatusColor(c.status)) }));
    }

    get hasDataChangeRequests() {
        return this.record?.dataChangeRequests?.length > 0;
    }

    get dcrRows() {
        return (this.record?.dataChangeRequests || []).map((d) => ({ ...d, statusStyle: pillStyle(DCR_STATUS_COLOR[d.status]) }));
    }

    get affiliationRows() {
        return (this.record?.affiliations || []).map((a) => ({ ...a, typeStyle: pillStyle(a.type === 'HCO' ? BRAND.violet : BRAND.primary) }));
    }

    get hasDegrees() {
        return this.record?.degrees?.length > 0;
    }

    get degreeRows() {
        return (this.record?.degrees || []).map((value, index) => ({ value, key: `degree-${index}`, label: `Degree ${index + 1}` }));
    }

    get hasDigitalPresence() {
        const r = this.record;
        return !!(r && (r.linkedInUrl || r.twitterUrl || r.youtubeUrl || r.instagramUrl));
    }

    get hasExternalIds() {
        return this.record?.externalIds && Object.keys(this.record.externalIds).length > 0;
    }

    get externalIdRows() {
        const ids = this.record?.externalIds || {};
        return Object.keys(ids).map((key) => ({ key, label: key, value: ids[key] }));
    }

    // MARK: - Profile Summary / photo placeholder

    get initials() {
        const r = this.record;
        if (!r) return '';
        if (this.isHCP) {
            const f = (r.firstName || '').charAt(0);
            const l = (r.lastName || '').charAt(0);
            return (f + l).toUpperCase() || (r.name || '').charAt(0).toUpperCase();
        }
        return (r.name || '').trim().split(/\s+/).map((w) => w.charAt(0)).join('').slice(0, 2).toUpperCase();
    }

    get focusAreaSummary() {
        return this.record?.focusArea || 'No focus area recorded.';
    }

    get hasProfileStats() {
        const r = this.record;
        return !!(r && (r.age || r.experienceYears));
    }

    // MARK: - Record Info footer (Created By / Last Modified By) — a single
    // muted line rather than its own card; this used to live inside the
    // Address Information card, which made "who created/edited this record"
    // read as if it were part of the account's own address.
    get recordInfoLine() {
        const r = this.record;
        if (!r) return null;
        const parts = [];
        if (r.createdByName) parts.push(`Created by ${r.createdByName}`);
        if (r.lastModifiedByName) {
            parts.push(`last modified by ${r.lastModifiedByName}${this.lastModifiedDisplay ? ` on ${this.lastModifiedDisplay}` : ''}`);
        }
        return parts.length ? parts.join(', ') : null;
    }

    handleEditProfileSummary() {
        this.isEditingProfileSummary = true;
    }

    handleCancelProfileSummaryEdit() {
        this.isEditingProfileSummary = false;
        this.isSavingProfileSummary = false;
    }

    handleProfileSummarySubmit() {
        this.isSavingProfileSummary = true;
    }

    handleProfileSummarySaveSuccess() {
        this.isEditingProfileSummary = false;
        this.isSavingProfileSummary = false;
        this.dispatchEvent(new ShowToastEvent({ title: 'Saved', message: 'Profile summary updated.', variant: 'success' }));
        this.loadDetail();
    }

    handleProfileSummarySaveError(event) {
        this.isSavingProfileSummary = false;
        this.dispatchEvent(new ShowToastEvent({
            title: 'Couldn’t save profile summary',
            message: event.detail?.detail || event.detail?.message || 'Check the highlighted field and try again.',
            variant: 'error',
        }));
    }

    // MARK: - Primary affiliation (used to default a new Call Report's HCO —
    // see callReportDefaultHcoId/Address below). NOT used for the Address
    // Information card's own map any more: AffiliationSyncService now keeps
    // an HCP's own Billing_*/Geolocation__c fields mirroring its primary
    // HCO's, so record.latitude/longitude (see hasLocation/mapMarkers below)
    // is the current, single source of truth — reading it via the
    // affiliation join here too used to show the exact same address twice.

    get primaryAffiliation() {
        const rows = this.record?.affiliations || [];
        return rows.find((a) => a.isPrimary) || rows[0] || null;
    }

    get primaryAffiliationFullAddress() {
        const a = this.primaryAffiliation;
        if (!a) return '';
        return [a.street, a.city, a.state, a.postalCode].filter(Boolean).join(', ');
    }

    // MARK: - Address Information card's map (both HCP and HCO — the
    // underlying fields were always populated for both, this card just
    // didn't render a map before)

    get hasLocation() {
        return !!(this.record && this.record.latitude != null && this.record.longitude != null);
    }

    get mapMarkers() {
        const r = this.record;
        if (!r || r.latitude == null || r.longitude == null) return [];
        const description = [r.billingStreet, r.billingCity, r.billingState, r.billingPostalCode].filter(Boolean).join(', ');
        return [{ location: { Latitude: r.latitude, Longitude: r.longitude }, title: r.name, description }];
    }

    // MARK: - Multichannel Consent (HCP only)

    get hasConsent() {
        return !!this.record?.consent;
    }

    get consentCapturedDisplay() {
        const raw = this.record?.consent?.capturedAt;
        if (!raw) return null;
        const d = new Date(raw);
        return Number.isNaN(d.getTime()) ? null : d.toLocaleString();
    }

    get consentSignedLabel() {
        return this.record?.consent?.signed ? 'Signed' : null;
    }

    get consentEmailLabel() {
        return this.record?.consent?.emailOptedIn ? 'Email opted-in' : 'Email opted-out';
    }

    get consentEmailStyle() {
        return pillStyle(this.record?.consent?.emailOptedIn ? BRAND.accent : BRAND.red);
    }

    get consentChannelsLabel() {
        const n = this.record?.consent?.subscribedChannelCount || 0;
        return `${n} channel${n === 1 ? '' : 's'}`;
    }

    get lastModifiedDisplay() {
        const raw = this.record?.lastModified;
        if (!raw) return null;
        const d = new Date(raw);
        return Number.isNaN(d.getTime()) ? null : d.toLocaleDateString();
    }

    get editFields() {
        return this.isHCP ? HCP_EDIT_FIELDS : HCO_EDIT_FIELDS;
    }

    handleEdit() {
        this.isEditing = true;
    }

    handleCancelEdit() {
        this.isEditing = false;
        this.isSaving = false;
    }

    // A Key Account Manager's edit never saves directly — it files an
    // Edit HCP/Edit HCO DCR for approval instead (see
    // SciagenAccountController.submitEditDcr).
    @wire(isKeyAccountManager)
    kamFlag;

    get isKam() {
        return this.kamFlag?.data === true;
    }

    get saveButtonLabel() {
        return this.isKam ? 'Submit for Approval' : 'Save';
    }

    async handleSubmit(event) {
        if (!this.isKam) {
            this.isSaving = true;
            return;
        }
        event.preventDefault();
        this.isSaving = true;
        const requested = {};
        Object.entries(event.detail.fields || {}).forEach(([api, value]) => {
            requested[api] = value == null ? '' : String(value);
        });
        try {
            await submitEditDcr({ accountId: this._recordId, requested });
            this.isEditing = false;
            this.dispatchEvent(new ShowToastEvent({
                title: 'Submitted for approval',
                message: 'Your changes were sent as a Data Change Request. They will apply once approved.',
                variant: 'success',
            }));
            this.loadDetail();
        } catch (e) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Couldn’t submit request',
                message: e.body?.message || 'Please try again.',
                variant: 'error',
            }));
        } finally {
            this.isSaving = false;
        }
    }

    handleSaveSuccess() {
        this.isEditing = false;
        this.isSaving = false;
        this.dispatchEvent(new ShowToastEvent({ title: 'Saved', message: 'Account updated.', variant: 'success' }));
        this.loadDetail();
        this.dispatchEvent(new CustomEvent('accountsaved', { detail: { recordId: this._recordId } }));
    }

    handleSaveError(event) {
        this.isSaving = false;
        this.dispatchEvent(new ShowToastEvent({
            title: 'Couldn’t save account',
            message: event.detail?.detail || event.detail?.message || 'Check the highlighted fields and try again.',
            variant: 'error',
        }));
    }

    get segmentationEditButtonLabel() {
        return this.hasSegmentation ? 'Edit' : 'Add Segmentation';
    }

    get acaroidEditFields() {
        const names = this.isHCP ? ACAROID_HCP_EDIT_FIELDS : ACAROID_HCO_EDIT_FIELDS;
        return names.map((name) => ({ key: name, name }));
    }

    // Card/section title — pulled from the Product master (Product__c.Brand_Name__c) via
    // AcaroidConfig.brandName, never hardcoded, so a different brand needs no code change.
    // The Acaroid targeting card on the Segmentation tab is switched off for now (not needed yet).
    // Flip to true to show it again; all of its logic and fields are still in place.
    get showAcaroidCard() { return false; }

    get acaroidBrandLabel() {
        return `${this.record?.acaroid?.brandName || 'Acaroid'} Targeting`;
    }

    get acaroidTierLabel() {
        return this.isHCO ? 'HCO Tier' : 'Target Tier';
    }

    get hasAcaroid() {
        return !!(this.record?.acaroid?.tier || this.record?.acaroid?.score != null);
    }

    get acaroidTierPillStyle() {
        return pillStyle(ACAROID_TIER_COLOR?.[this.record?.acaroid?.tier]);
    }

    get acaroidReadinessPillStyle() {
        return pillStyle(ACAROID_READINESS_COLOR?.[this.record?.acaroid?.readinessStatus]);
    }

    get acaroidCanAdministerPillStyle() {
        return pillStyle(ACAROID_CAN_ADMINISTER_COLOR?.[this.record?.acaroid?.canAdminister]);
    }

    handleEditAcaroid() {
        this.isEditingAcaroid = true;
    }

    handleCancelAcaroidEdit() {
        this.isEditingAcaroid = false;
        this.isSavingAcaroid = false;
    }

    handleAcaroidSubmit() {
        this.isSavingAcaroid = true;
    }

    handleAcaroidSaveSuccess() {
        this.isEditingAcaroid = false;
        this.isSavingAcaroid = false;
        this.dispatchEvent(new ShowToastEvent({ title: 'Saved', message: 'Acaroid targeting data updated.', variant: 'success' }));
        this.loadDetail();
    }

    handleAcaroidSaveError(event) {
        this.isSavingAcaroid = false;
        this.dispatchEvent(new ShowToastEvent({
            title: 'Couldn’t save Acaroid targeting data',
            message: event.detail?.detail || event.detail?.message || 'Check the highlighted fields and try again.',
            variant: 'error',
        }));
    }

    handleEditSegmentation() {
        this.isEditingSegmentation = true;
    }

    handleCancelSegmentationEdit() {
        this.isEditingSegmentation = false;
        this.isSavingSegmentation = false;
    }

    handleSegmentationSubmit() {
        this.isSavingSegmentation = true;
    }

    handleSegmentationSaveSuccess() {
        this.isEditingSegmentation = false;
        this.isSavingSegmentation = false;
        this.dispatchEvent(new ShowToastEvent({ title: 'Saved', message: 'Segmentation updated.', variant: 'success' }));
        this.loadDetail();
    }

    handleSegmentationSaveError(event) {
        this.isSavingSegmentation = false;
        this.dispatchEvent(new ShowToastEvent({
            title: 'Couldn’t save segmentation',
            message: event.detail?.detail || event.detail?.message || 'Check the highlighted fields and try again.',
            variant: 'error',
        }));
    }

    /// Opens the callVisitReportDetail editor inline (same expand/collapse
    /// panel pattern as Office Windows below), pre-filled with this account as
    /// the HCP (or, on an HCO's page, as the HCO; Call_Visit_Report__c.HCP__c
    /// is required, so an HCO-page call report still needs the rep to pick the
    /// HCP it's actually with). Replaces the earlier standard-page navigation
    /// so Key Messages/Promo Drops/Attendees can be added without leaving
    /// Account Detail.
    get callReportDefaultHcpId() {
        return this.isHCO ? null : this.recordId;
    }

    // Starting a Call Report from an HCP with multiple affiliated HCOs should
    // default to the PRIMARY one (same one the Address card above shows) —
    // not leave the field blank for the rep to search from scratch every time.
    get callReportDefaultHcoId() {
        if (this.isHCO) return this.recordId;
        return this.primaryAffiliation ? this.primaryAffiliation.accountId : null;
    }

    get callReportDefaultHcoAddress() {
        return this.isHCO ? null : this.primaryAffiliationFullAddress;
    }

    handleAddCallReport() {
        this.showCallReportPanel = true;
    }

    handleCloseCallReportPanel() {
        this.showCallReportPanel = false;
        this.loadDetail();
    }

    get hasOfficeWindows() {
        return this.record?.officeWindows?.length > 0;
    }

    get officeWindowRows() {
        return (this.record?.officeWindows || []).map((w) => ({
            ...w,
            preferenceStyle: pillStyle(PREFERENCE_COLOR[w.preference]),
            isEditing: w.id === this.editingOfficeWindowId,
        }));
    }

    handleAddOfficeWindow() {
        this.showAddOfficeWindow = true;
    }

    handleCancelAddOfficeWindow() {
        this.showAddOfficeWindow = false;
        this.isSavingOfficeWindow = false;
    }

    handleEditOfficeWindow(event) {
        this.editingOfficeWindowId = event.currentTarget.dataset.id;
    }

    handleCancelEditOfficeWindow() {
        this.editingOfficeWindowId = null;
        this.isSavingOfficeWindow = false;
    }

    handleOfficeWindowSubmit() {
        this.isSavingOfficeWindow = true;
    }

    handleOfficeWindowSaveSuccess() {
        this.showAddOfficeWindow = false;
        this.editingOfficeWindowId = null;
        this.isSavingOfficeWindow = false;
        this.dispatchEvent(new ShowToastEvent({ title: 'Saved', message: 'Office time saved.', variant: 'success' }));
        this.loadDetail();
    }

    handleOfficeWindowSaveError(event) {
        this.isSavingOfficeWindow = false;
        this.dispatchEvent(new ShowToastEvent({
            title: 'Couldn’t save office time',
            message: event.detail?.detail || event.detail?.message || 'Check the highlighted fields and try again.',
            variant: 'error',
        }));
    }

    async handleDeleteOfficeWindow(event) {
        const id = event.currentTarget.dataset.id;
        try {
            await deleteRecord(id);
            this.dispatchEvent(new ShowToastEvent({ title: 'Deleted', message: 'Office time removed.', variant: 'success' }));
            this.loadDetail();
        } catch (e) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Couldn’t delete office time',
                message: e.body?.message || 'Try again.',
                variant: 'error',
            }));
        }
    }

    // MARK: - Related tab: New Affiliation + link to Hierarchy

    handleAddAffiliation() {
        this.showAddAffiliation = true;
    }

    handleCancelAddAffiliation() {
        this.showAddAffiliation = false;
        this.isSavingAffiliation = false;
    }

    handleAffiliationSubmit() {
        this.isSavingAffiliation = true;
    }

    handleAffiliationSaveSuccess() {
        this.showAddAffiliation = false;
        this.isSavingAffiliation = false;
        this.dispatchEvent(new ShowToastEvent({ title: 'Saved', message: 'Affiliation added.', variant: 'success' }));
        this.loadDetail();
    }

    handleAffiliationSaveError(event) {
        this.isSavingAffiliation = false;
        this.dispatchEvent(new ShowToastEvent({
            title: 'Couldn’t save affiliation',
            message: event.detail?.detail || event.detail?.message || 'Check the highlighted fields and try again.',
            variant: 'error',
        }));
    }

    // Reuses the existing Hierarchy tab/tree rather than building a second
    // graph view — this just switches the section rail the same way clicking
    // "Hierarchy" in the nav does, lazy-loading it on first visit.
    handleViewHierarchy() {
        this.activeSection = 'hierarchy';
        if (!this.hierarchy) {
            this.loadHierarchy();
        }
    }
}

function reduceError(error) {
    if (error?.body?.message) {
        return error.body.message;
    }
    return 'An unknown error occurred.';
}