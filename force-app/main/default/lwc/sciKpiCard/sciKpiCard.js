import { LightningElement, api } from 'lwc';

export default class SciKpiCard extends LightningElement {
    @api label;
    @api value;
    @api delta;
    @api deltaDir;
    @api positiveIsGood = false;

    get arrow() { return this.deltaDir === 'down' ? 'utility:arrowdown' : (this.deltaDir === 'up' ? 'utility:arrowup' : 'utility:dash'); }
    get deltaClass() {
        let tone = 'flat';
        if (this.deltaDir === 'up') tone = this.positiveIsGood ? 'good' : 'bad';
        if (this.deltaDir === 'down') tone = this.positiveIsGood ? 'bad' : 'good';
        return `badge ${tone}`;
    }
}