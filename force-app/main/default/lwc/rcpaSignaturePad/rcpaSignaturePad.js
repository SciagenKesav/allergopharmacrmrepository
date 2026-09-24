import { LightningElement } from 'lwc';

/// Freehand signature capture — plain canvas, no library. Chosen over
/// recording raw stroke points (what the iPad app keeps locally) because
/// there's a real Salesforce field to persist a PNG data URL into
/// (RCPA_Audit__c.Chemist_Signature__c) but none for stroke geometry, and a
/// dataURL is exactly what an <img src> can render straight back on the
/// detail/read side later.
export default class RcpaSignaturePad extends LightningElement {
    isEmpty = true;
    isDrawing = false;
    lastX = 0;
    lastY = 0;

    get hasSignature() {
        return !this.isEmpty;
    }

    get canvas() {
        return this.template.querySelector('canvas');
    }

    get ctx() {
        return this.canvas.getContext('2d');
    }

    renderedCallback() {
        if (this._ctxReady) return;
        this._ctxReady = true;
        const ctx = this.ctx;
        ctx.lineWidth = 2;
        ctx.lineCap = 'round';
        ctx.strokeStyle = '#0F172A';
    }

    eventPoint(event) {
        const rect = this.canvas.getBoundingClientRect();
        return { x: event.clientX - rect.left, y: event.clientY - rect.top };
    }

    handlePointerDown(event) {
        this.isDrawing = true;
        const p = this.eventPoint(event);
        this.lastX = p.x;
        this.lastY = p.y;
    }

    handlePointerMove(event) {
        if (!this.isDrawing) return;
        const p = this.eventPoint(event);
        const ctx = this.ctx;
        ctx.beginPath();
        ctx.moveTo(this.lastX, this.lastY);
        ctx.lineTo(p.x, p.y);
        ctx.stroke();
        this.lastX = p.x;
        this.lastY = p.y;
        this.isEmpty = false;
    }

    handlePointerUp() {
        if (!this.isDrawing) return;
        this.isDrawing = false;
        if (!this.isEmpty) {
            this.dispatchEvent(new CustomEvent('change', { detail: { dataUrl: this.canvas.toDataURL('image/png') } }));
        }
    }

    handleClear() {
        this.ctx.clearRect(0, 0, this.canvas.width, this.canvas.height);
        this.isEmpty = true;
        this.dispatchEvent(new CustomEvent('change', { detail: { dataUrl: null } }));
    }
}