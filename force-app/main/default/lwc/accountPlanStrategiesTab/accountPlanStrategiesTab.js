import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { BRAND, pillStyle } from 'c/sciagenColors';

const STATUS_COLOR = { Open: BRAND.subtle, 'In Progress': BRAND.primary, Postponed: BRAND.amber, Completed: BRAND.accent };

export default class AccountPlanStrategiesTab extends LightningElement {
    @api workspace;
    @api recordId;
    @api planName;

    showNewActionItemModal = false;

    get strategies() {
        return (this.workspace?.strategies || []).map((s) => ({
            ...s,
            shareWithDisplay: (s.shareWith || []).join(', ') || '—',
            barStyle: `width: ${s.progressPercent || 0}%;`,
            activities: (s.activities || []).map((a) => ({
                ...a,
                barStyle: `width: ${a.progressPercent || 0}%;`,
                completeClass: a.isComplete ? 'activity-name activity-complete' : 'activity-name',
            })),
        }));
    }

    get allActionItems() {
        const rows = [];
        for (const s of this.workspace?.strategies || []) {
            for (const a of s.activities || []) {
                for (const ai of a.actionItems || []) {
                    rows.push({
                        ...ai,
                        strategyName: s.name,
                        statusPillStyle: pillStyle(STATUS_COLOR[ai.status]),
                        shareWithDisplay: (ai.shareWith || []).join(', ') || '—',
                    });
                }
            }
        }
        return rows;
    }

    get hasStrategies() {
        return this.strategies.length > 0;
    }

    get hasActionItems() {
        return this.allActionItems.length > 0;
    }

    handleAddActionItem() {
        this.showNewActionItemModal = true;
    }

    handleCloseModal() {
        this.showNewActionItemModal = false;
    }

    handleActionItemCreated() {
        this.showNewActionItemModal = false;
        this.dispatchEvent(new CustomEvent('actionitemcreated'));
    }

    // MARK: - New Strategy (Plan_Strategy__c had no create UI anywhere —
    // this tab only ever displayed strategies synced in from the iPad app)

    showNewStrategyForm = false;
    isSavingStrategy = false;

    handleAddStrategy() {
        this.showNewStrategyForm = true;
    }

    handleCancelStrategy() {
        this.showNewStrategyForm = false;
    }

    handleStrategySubmit() {
        this.isSavingStrategy = true;
    }

    handleStrategySaveSuccess() {
        this.isSavingStrategy = false;
        this.showNewStrategyForm = false;
        this.dispatchEvent(new ShowToastEvent({ title: 'Added', message: 'Strategy added to this Account Plan.', variant: 'success' }));
        this.dispatchEvent(new CustomEvent('strategycreated'));
    }

    handleStrategySaveError(event) {
        this.isSavingStrategy = false;
        this.dispatchEvent(new ShowToastEvent({
            title: 'Couldn’t add strategy',
            message: event.detail?.detail || event.detail?.message || 'Check the highlighted fields and try again.',
            variant: 'error',
        }));
    }
}