import { LightningElement, api } from 'lwc';
import SCIAGEN_LOGO from '@salesforce/resourceUrl/SciagenLogo';

export default class SciagenLogo extends LightningElement {
    @api size = 'medium'; // small | medium | large

    logoUrl = SCIAGEN_LOGO;

    get sizeClass() {
        return `logo logo-${this.size}`;
    }
}