import { LightningElement, api } from 'lwc';

const X0 = 44, X1 = 590, Y0 = 20, Y1 = 220;

export default class SciChart extends LightningElement {
    @api chart;

    get title() { return this.chart?.title; }
    get type() { return this.chart?.type; }
    get isHbar() { return this.type === 'hbar'; }
    get isEmpty() { return !this.chart || !this.chart.labels || this.chart.labels.length === 0 || !this.chart.series?.length; }
    get pct() { return !!this.chart?.percent; }
    get maxV() {
        if (this.chart?.maxValue) return this.chart.maxValue;
        let m = this.chart?.refLine || 0;
        (this.chart?.series || []).forEach(s => s.values.forEach(v => { if (v > m) m = v; }));
        if (this.pct) m = Math.max(m, 100);
        return m > 0 ? m : 1;
    }
    fmt(v) { const n = Math.round(v * 100) / 100; return this.pct ? `${n}%` : this.compact(n); }
    compact(n) {
        const a = Math.abs(n);
        if (a >= 10000000) return `${(n / 10000000).toFixed(1)}Cr`;
        if (a >= 100000) return `${(n / 100000).toFixed(1)}L`;
        return String(n);
    }
    get hbarRows() {
        if (this.isEmpty) return [];
        const s = this.chart.series[0], max = this.maxV;
        return this.chart.labels.map((l, i) => {
            const v = s.values[i] || 0;
            const color = (s.colors && s.colors[i]) || s.color || '#4F46E5';
            return { key: `h${i}`, label: l, text: this.fmt(v), style: `width:${Math.min(100, (v / max) * 100)}%;background:${color};` };
        });
    }
    get refStyle() {
        const r = this.chart?.refLine;
        return r ? `left:${Math.min(100, (r / this.maxV) * 100)}%;display:block;` : 'display:none;';
    }
    get refLineY() { const r = this.chart?.refLine; return r && this.type !== 'hbar' ? Y1 - (r / this.maxV) * (Y1 - Y0) : null; }
    get gridLines() {
        if (this.isEmpty || this.isHbar) return [];
        return [0, 0.25, 0.5, 0.75, 1].map((f, i) => {
            const y = Y1 - f * (Y1 - Y0);
            return { key: `g${i}`, y, ty: y + 3, label: this.fmt(this.maxV * f) };
        });
    }
    get slot() { return (X1 - X0) / Math.max(1, this.chart.labels.length); }
    get xLabels() {
        if (this.isEmpty || this.isHbar) return [];
        return this.chart.labels.map((l, i) => ({ key: `x${i}`, x: X0 + this.slot * (i + 0.5), text: l.length > 14 ? `${l.slice(0, 13)}…` : l }));
    }
    get bars() {
        if (this.isEmpty || (this.type !== 'bar' && this.type !== 'gbar')) return [];
        const k = this.chart.series.length, slot = this.slot, bw = Math.min(46, (slot * 0.7) / k), out = [];
        this.chart.labels.forEach((l, i) => {
            const startX = X0 + slot * i + (slot - bw * k) / 2;
            this.chart.series.forEach((s, j) => {
                const v = s.values[i] || 0, h = Math.max(0, (v / this.maxV) * (Y1 - Y0)), x = startX + bw * j;
                out.push({ key: `b${i}-${j}`, x, y: Y1 - h, w: bw - 2, h, color: (s.colors && s.colors[i]) || s.color || '#4F46E5', tx: x + (bw - 2) / 2, ty: Y1 - h - 4, text: this.fmt(v) });
            });
        });
        return out;
    }
    get lines() {
        if (this.isEmpty || this.type !== 'line') return [];
        return this.chart.series.map((s, j) => ({
            key: `l${j}`, color: s.color || '#4F46E5',
            points: s.values.map((v, i) => `${X0 + this.slot * (i + 0.5)},${Y1 - ((v || 0) / this.maxV) * (Y1 - Y0)}`).join(' ')
        }));
    }
    get dots() {
        if (this.isEmpty || this.type !== 'line') return [];
        const out = [];
        this.chart.series.forEach((s, j) => s.values.forEach((v, i) => {
            const y = Y1 - ((v || 0) / this.maxV) * (Y1 - Y0);
            out.push({ key: `d${j}-${i}`, x: X0 + this.slot * (i + 0.5), y, ty: y - 8, color: s.color || '#4F46E5', text: this.fmt(v || 0) });
        }));
        return out;
    }
    get showLegend() { return this.chart?.series?.length > 1; }
    get legend() { return (this.chart?.series || []).map(s => ({ name: s.name, style: `background:${s.color || '#4F46E5'};` })); }
}