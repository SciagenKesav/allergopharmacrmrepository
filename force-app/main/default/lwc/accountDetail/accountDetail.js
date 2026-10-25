import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { deleteRecord, updateRecord } from 'lightning/uiRecordApi';
import { getObjectInfo } from 'lightning/uiObjectInfoApi';
import getAccountDetail from '@salesforce/apex/SciagenAccountController.getAccountDetail';
import isKeyAccountManager from '@salesforce/apex/SciagenAccountController.isKeyAccountManager';
import submitEditDcr from '@salesforce/apex/SciagenAccountController.submitEditDcr';
import getAccountHierarchy from '@salesforce/apex/SciagenAccountController.getAccountHierarchy';
import unassignFromMyTerritory from '@salesforce/apex/SciagenAccountTerritoryController.unassignFromMyTerritory';
import { BRAND, pillStyle, CLASSIFICATION_COLOR, TIER_COLOR, DCR_STATUS_COLOR, PREFERENCE_COLOR, callStatusColor } from 'c/sciagenColors';
import SCIAGEN_ACCOUNT_OBJECT from '@salesforce/schema/Sciagen_Account__c';

const SECTIONS = [
    { key: 'profile', label: 'Profile', icon: 'utility:contact' },
    { key: 'timeline', label: 'Timeline', icon: 'utility:date_time' },
    { key: 'segmentation', label: 'Segmentation', icon: 'utility:priority' },
    { key: 'engagement', label: 'Engagement', icon: 'utility:trending' },
    { key: 'activity', label: 'Activity', icon: 'utility:call' },
    { key: 'related', label: 'Related', icon: 'utility:relate' },
    { key: 'hierarchy', label: 'Hierarchy', icon: 'utility:hierarchy' },
    { key: 'navigation', label: 'Navigation', icon: 'utility:location' },
    { key: 'dcr', label: 'DCR', icon: 'utility:edit_form' },
];

// Hierarchy tree pill coloring — matches accountBrowser's affiliationRows convention (HCO=violet, HCP=primary).
function typeStyle(type) {
    return pillStyle(type === 'HCO' ? BRAND.violet : BRAND.primary);
}

// Hierarchy graph node icon — same HCO=violet/HCP=primary convention as
// typeStyle above, but a solid circular avatar (not a translucent pill),
// matching the org-chart node style used in the Hierarchy tab.
function nodeIconName(type) {
    return type === 'HCO' ? 'utility:company' : 'utility:user';
}
function nodeIconStyle(type) {
    return `background-color:#${type === 'HCO' ? BRAND.violet : BRAND.primary};`;
}

export default class AccountDetail extends NavigationMixin(LightningElement) {
    _recordId;
    record;
    isLoading = false;
    isEditing = false;
    isSaving = false;
    isEditingSegmentation = false;
    isSavingSegmentation = false;
    isEditingProfileSummary = false;
    isSavingProfileSummary = false;
    showAddOfficeWindow = false;
    editingOfficeWindowId = null;
    isSavingOfficeWindow = false;
    showCallReportPanel = false;
    showAddAffiliation = false;
    isSavingAffiliation = false;
    editingAffiliationId = null;
    showCvrView = false;
    viewingCvrId = null;
    error;
    activeSection = 'profile';
    hierarchy;
    isHierarchyLoading = false;

    // Drives whether the Edit affordances on this page render at all — reflects
    // the running user's actual object permission (profile + permission sets),
    // e.g. a Standard Platform User / Sales Rep with read-only access to
    // Sciagen_Account__c. Checking real permission here (rather than hardcoding
    // a profile-name check) means this stays correct if access is ever changed.
    @wire(getObjectInfo, { objectApiName: SCIAGEN_ACCOUNT_OBJECT })
    accountObjectInfo;

    get canEdit() {
        return this.accountObjectInfo?.data?.updateable ?? false;
    }

    // "Unassign from Territory" — available to every user (see
    // SciagenAccountTerritoryController's doc comment). Never deletes the
    // Account record itself: a Business Unit Head's own request applies
    // immediately; anyone else's instead files a DCR for a Business Unit
    // Head to approve before anything is actually removed. A comment is
    // required either way — it's filed as the thread's first DCR_Comment__c
    // for a Business Admin to read/reply to from the DCR Review Queue.
    isConfirmingUnassign = false;
    isUnassigning = false;
    unassignCommentInput = '';

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
        this.editingAffiliationId = null;
        this.showCvrView = false;
        this.viewingCvrId = null;
        this.activeSection = 'profile';
        this.hierarchy = undefined;
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

    // HCPs' "parent" node here is their Primary HCO (see getAccountHierarchy);
    // everything else keeps the generic "Parent Account" wording. Doubles as
    // the connector-line relationship label in the hier-tree graph.
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

    get isNavigationSection() {
        return this.activeSection === 'navigation';
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

    // MARK: - Header segmentation badges (HCP only) — mirrors
    // AccountDetailsView.swift's header Chip row exactly: Class <A/B/C>,
    // Tier, KOL, Priority, then HCP Type, each shown only when set. Same
    // pillStyle() + color tokens as the rest of this file, just surfaced up
    // in the compact-layout-style header instead of buried in Segmentation.
    get headerBadges() {
        if (!this.isHCP) return [];
        const seg = this.record?.segmentation;
        const badges = [];
        if (seg?.classification && seg.classification !== 'Unclassified') {
            badges.push({ key: 'classification', label: `Class ${seg.classification}`, style: pillStyle(CLASSIFICATION_COLOR[seg.classification]) });
        }
        if (seg?.tier && seg.tier !== 'None') {
            badges.push({ key: 'tier', label: seg.tier, style: pillStyle(TIER_COLOR[seg.tier]) });
        }
        if (seg?.isKOL) {
            badges.push({ key: 'kol', label: 'KOL', style: pillStyle(BRAND.amber) });
        }
        if (seg?.priority && seg.priority !== 'None') {
            badges.push({ key: 'priority', label: seg.priority, style: pillStyle(BRAND.primary) });
        }
        if (this.record?.hcpType) {
            badges.push({ key: 'hcpType', label: this.record.hcpType, style: pillStyle(BRAND.subtle) });
        }
        return badges;
    }

    get hasHeaderBadges() {
        return this.headerBadges.length > 0;
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

    get hasTimeline() {
        return this.record?.timeline?.length > 0;
    }

    get timelineRows() {
        const colorByKind = { DCR: BRAND.violet, Planned: BRAND.amber, Email: BRAND.accent };
        return (this.record?.timeline || []).map((t, index) => ({
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
        return (this.record?.affiliations || []).map((a) => ({
            ...a,
            typeStyle: pillStyle(a.type === 'HCO' ? BRAND.violet : BRAND.primary),
            isEditingThisRow: a.affiliationId === this.editingAffiliationId,
        }));
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

    // MARK: - Navigation tab's map (both HCP and HCO share record.latitude/
    // longitude — an HCO's own billing address for an HCO, its primary
    // affiliation's HCO for an HCP, mirrored by AffiliationSyncService.cls).
    // Same lightning-map + marker shape as accountBrowser's map view, just
    // one pin instead of the whole filtered list.

    get hasLocation() {
        return !!(this.record && this.record.latitude != null && this.record.longitude != null);
    }

    get mapMarkers() {
        const r = this.record;
        if (!r || r.latitude == null || r.longitude == null) return [];
        const description = [r.billingStreet, r.billingCity, r.billingState, r.billingPostalCode].filter(Boolean).join(', ');
        return [{ location: { Latitude: r.latitude, Longitude: r.longitude }, title: r.name, description }];
    }

    get navigationAddress() {
        const r = this.record;
        if (!r) return '';
        return [r.billingStreet, r.billingCity, r.billingState, r.billingPostalCode, r.billingCountry].filter(Boolean).join(', ');
    }

    get navigationEmptyMessage() {
        return this.isHCP
            ? 'No location yet — set a primary affiliation on the Related tab to inherit its address.'
            : 'No location yet — add a billing address on this account to geocode it.';
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

    // MARK: - Key Account Manager "Delete" (unassign from my territory)

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
            this.dispatchEvent(new ShowToastEvent({
                title: outcome.immediate ? 'Removed from your territory' : 'Submitted for approval',
                message: outcome.message,
                variant: 'success',
            }));
            // Only navigate away when the record actually stopped showing up
            // for this user (immediate) — a pending-approval DCR hasn't
            // removed anything yet, so the record is still right where it was.
            if (outcome.immediate) {
                this[NavigationMixin.Navigate]({
                    type: 'standard__navItemPage',
                    attributes: { apiName: 'Account_Browser_Page' },
                });
            }
        } catch (e) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Couldn’t unassign from territory',
                message: e?.body?.message || 'An unknown error occurred.',
                variant: 'error',
            }));
        } finally {
            this.isUnassigning = false;
        }
    }

    // Only real Call_Visit_Report__c rows are clickable — see CVRItem.isCVR's
    // doc comment; the Planned_Call__c-sourced "Completed" rows merged into
    // this same Activity list have no CVR record to open a read-only view for.
    handleCvrRowClick(event) {
        const { id, isCvr } = event.currentTarget.dataset;
        if (isCvr !== 'true') { return; }
        this.viewingCvrId = id;
        this.showCvrView = true;
    }

    handleCloseCvrView() {
        this.showCvrView = false;
        this.viewingCvrId = null;
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

    // Edit an existing affiliation row — same 3 fields as the New form
    // (Affiliation__c only has HCO__c/HCP__c/Is_Primary__c), just bound to
    // that row's own record-id instead of creating a new one. Distinct from
    // handleSetPrimaryAffiliation below, which only ever flips Is_Primary__c
    // for affiliations that don't need any other correction.
    handleEditAffiliation(event) {
        this.editingAffiliationId = event.currentTarget.dataset.affiliationId;
    }

    handleCancelEditAffiliation() {
        this.editingAffiliationId = null;
        this.isSavingAffiliation = false;
    }

    handleAffiliationEditSubmit() {
        this.isSavingAffiliation = true;
    }

    handleAffiliationEditSaveSuccess() {
        this.editingAffiliationId = null;
        this.isSavingAffiliation = false;
        this.dispatchEvent(new ShowToastEvent({ title: 'Saved', message: 'Affiliation updated.', variant: 'success' }));
        this.loadDetail();
    }

    handleAffiliationEditSaveError(event) {
        this.isSavingAffiliation = false;
        this.dispatchEvent(new ShowToastEvent({
            title: 'Couldn’t update affiliation',
            message: event.detail?.detail || event.detail?.message || 'Check the highlighted fields and try again.',
            variant: 'error',
        }));
    }

    // Marks an EXISTING affiliation row primary (the New-affiliation form
    // above already lets Is_Primary__c be set at creation — this is the
    // other half, for affiliations that predate that choice or need to
    // change). AffiliationSync.trigger + AffiliationSyncService handle
    // demoting the old primary and re-mirroring address/geolocation onto
    // this HCP; this handler just fires the one DML and reloads.
    async handleSetPrimaryAffiliation(event) {
        const affiliationId = event.currentTarget.dataset.affiliationId;
        if (!affiliationId) return;
        this.isSavingAffiliation = true;
        try {
            await updateRecord({ fields: { Id: affiliationId, Is_Primary__c: true } });
            this.dispatchEvent(new ShowToastEvent({ title: 'Updated', message: 'Primary affiliation set.', variant: 'success' }));
            this.loadDetail();
        } catch (e) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Couldn’t set primary affiliation',
                message: e.body?.message || 'Try again.',
                variant: 'error',
            }));
        } finally {
            this.isSavingAffiliation = false;
        }
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