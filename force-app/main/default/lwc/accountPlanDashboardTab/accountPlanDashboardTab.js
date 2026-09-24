import { LightningElement, api } from 'lwc';
import { BRAND, pillStyle } from 'c/sciagenColors';

const HEALTH_COLOR = { Good: BRAND.accent, 'At Risk': BRAND.amber, Poor: BRAND.red };
const GAUGE_RADIUS = 40;
const GAUGE_CIRCUMFERENCE = 2 * Math.PI * GAUGE_RADIUS;

export default class AccountPlanDashboardTab extends LightningElement {
    @api workspace;

    get gaugePercent() {
        return this.workspace?.actionItemProgressPercent || 0;
    }

    get gaugePercentDisplay() {
        return Math.round(this.gaugePercent);
    }

    get gaugeDashArray() {
        const filled = (this.gaugePercent / 100) * GAUGE_CIRCUMFERENCE;
        return `${filled} ${GAUGE_CIRCUMFERENCE}`;
    }

    get healthLabel() {
        return this.workspace?.health || 'Not Set';
    }

    get healthPillStyle() {
        return pillStyle(HEALTH_COLOR[this.workspace?.health] || BRAND.subtle);
    }

    get activePillStyle() {
        return pillStyle(this.workspace?.active ? BRAND.accent : BRAND.subtle);
    }

    get activeLabel() {
        return this.workspace?.active ? 'Active' : 'Inactive';
    }

    get strategyBarStyle() {
        return `width: ${this.workspace?.strategyProgressPercent || 0}%;`;
    }

    get activityBarStyle() {
        return `width: ${this.workspace?.activityProgressPercent || 0}%;`;
    }

    get actionItemBarStyle() {
        return `width: ${this.workspace?.actionItemProgressPercent || 0}%;`;
    }

    get hasUpcoming() {
        return this.workspace?.upcoming?.length > 0;
    }

    get hasStakeholders() {
        return this.workspace?.stakeholders?.length > 0;
    }

    get hasTeamMembers() {
        return this.workspace?.teamMembers?.length > 0;
    }

    get missionStatement() {
        return this.workspace?.objective || 'No mission statement set for this Account Plan yet.';
    }
}