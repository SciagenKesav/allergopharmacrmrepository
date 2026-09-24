import { LightningElement, api } from 'lwc';
import getPlanWorkspace from '@salesforce/apex/AccountPlanController.getPlanWorkspace';

const TABS = [
    { key: 'dashboard', label: 'Dashboard' },
    { key: 'details', label: 'Details' },
    { key: 'strategies', label: 'Strategies' },
    { key: 'related', label: 'Related' },
    { key: 'export', label: 'Export' },
];

export default class AccountPlanWorkspace extends LightningElement {
    _recordId;
    workspace;
    isLoading = false;
    error;
    activeTab = 'dashboard';

    @api
    get recordId() {
        return this._recordId;
    }
    set recordId(value) {
        this._recordId = value;
        this.activeTab = 'dashboard';
        this.loadWorkspace();
    }

    async loadWorkspace() {
        if (!this._recordId) {
            this.workspace = undefined;
            return;
        }
        this.isLoading = true;
        this.error = undefined;
        try {
            this.workspace = await getPlanWorkspace({ planId: this._recordId });
        } catch (e) {
            this.error = e.body?.message || 'Failed to load this Account Plan.';
        } finally {
            this.isLoading = false;
        }
    }

    get tabs() {
        return TABS.map((t) => ({
            ...t,
            tabClass: t.key === this.activeTab ? 'tab-button tab-button-active' : 'tab-button',
        }));
    }

    handleTabSelect(event) {
        this.activeTab = event.currentTarget.dataset.key;
    }

    get isDashboardTab() {
        return this.activeTab === 'dashboard';
    }

    get isDetailsTab() {
        return this.activeTab === 'details';
    }

    get isStrategiesTab() {
        return this.activeTab === 'strategies';
    }

    get isRelatedTab() {
        return this.activeTab === 'related';
    }

    get isExportTab() {
        return this.activeTab === 'export';
    }

    get planName() {
        return this.workspace?.name;
    }

    handleStageAdvanced(event) {
        if (this.workspace) {
            this.workspace = { ...this.workspace, stage: event.detail.stage };
        }
        this.loadWorkspace();
    }

    handleRefresh() {
        this.loadWorkspace();
    }
}