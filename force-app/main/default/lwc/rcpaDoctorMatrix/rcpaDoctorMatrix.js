import { LightningElement, api, wire } from 'lwc';
import getDoctorOptions from '@salesforce/apex/RCPAMatrixController.getDoctorOptions';
import getDoctorMatrix from '@salesforce/apex/RCPAMatrixController.getDoctorMatrix';
import { pillStyle, TREND_COLOR } from 'c/sciagenColors';

// Web port of RCPADoctorMatrixView (RCPAMatrixViews.swift) — one doctor's full
// prescribing picture, molecule-by-molecule, plus the RCPA Trail timeline for
// molecules captured more than once.
export default class RcpaDoctorMatrix extends LightningElement {
    // Set by rcpaBrowser to the prescriber covered by whichever audit the rep
    // had open on the Audits tab — so switching to Doctor Matrix opens on a
    // doctor related to what they were just looking at, not always the
    // alphabetically-first doctor org-wide.
    @api defaultDoctorId;

    isLoadingOptions = true;
    isLoadingMatrix = false;
    error;
    doctorOptions = [];
    selectedDoctorId;
    matrix;

    @wire(getDoctorOptions)
    wiredOptions({ data, error }) {
        this.isLoadingOptions = false;
        if (data) {
            this.doctorOptions = [...data]
                .sort((a, b) => a.name.localeCompare(b.name))
                .map((o) => ({ label: `${o.name} (${o.moleculeCount} molecule${o.moleculeCount === 1 ? '' : 's'})`, value: o.id }));
            if (this.doctorOptions.length > 0 && !this.selectedDoctorId) {
                const hasDefault = this.defaultDoctorId && this.doctorOptions.some((o) => o.value === this.defaultDoctorId);
                this.selectedDoctorId = hasDefault ? this.defaultDoctorId : this.doctorOptions[0].value;
                this.loadMatrix();
            }
        } else if (error) {
            this.error = reduceError(error);
        }
    }

    get hasDoctors() {
        return this.doctorOptions.length > 0;
    }

    handleDoctorChange(event) {
        this.selectedDoctorId = event.detail.value;
        this.loadMatrix();
    }

    async loadMatrix() {
        if (!this.selectedDoctorId) return;
        this.isLoadingMatrix = true;
        this.error = undefined;
        try {
            this.matrix = await getDoctorMatrix({ prescriberId: this.selectedDoctorId });
        } catch (e) {
            this.error = reduceError(e);
            this.matrix = undefined;
        } finally {
            this.isLoadingMatrix = false;
        }
    }

    get hasMatrix() {
        return !!this.matrix;
    }

    get grandTotal() {
        return (this.matrix?.rows || []).reduce((sum, r) => sum + (r.total || 0), 0);
    }

    // One card per molecule — own brand + competitor columns, own-first,
    // trailing computed Total — mirrors moleculeCard/cell() (RCPAMatrixViews.swift).
    get moleculeCards() {
        return (this.matrix?.rows || []).map((row) => ({
            key: row.molecule,
            molecule: row.molecule,
            ownBrand: row.ownBrand,
            total: row.total,
            brands: row.brands.map((b, i) => ({
                key: i, brand: b.brand, qty: b.qty, isOwn: b.isOwn,
                headerClass: b.isOwn ? 'grid-cell grid-cell-header grid-cell-own' : 'grid-cell grid-cell-header',
                valueClass: b.isOwn ? 'grid-cell grid-cell-own grid-cell-own-value' : 'grid-cell',
            })),
        }));
    }

    // RCPA Trail — only molecules captured more than once get a timeline,
    // matching RCPADoctorMatrixView.trailSection's own filter.
    get trailCards() {
        return (this.matrix?.trails || [])
            .filter((t) => t.points && t.points.length > 1)
            .sort((a, b) => a.molecule.localeCompare(b.molecule))
            .map((trail) => {
                const first = trail.points[0];
                const last = trail.points[trail.points.length - 1];
                const firstTotal = first.ownUnits + first.competitorUnits;
                const lastTotal = last.ownUnits + last.competitorUnits;
                const firstShare = firstTotal === 0 ? 0 : Math.round((first.ownUnits / firstTotal) * 100);
                const lastShare = lastTotal === 0 ? 0 : Math.round((last.ownUnits / lastTotal) * 100);
                const shareDelta = lastShare - firstShare;
                const unitDelta = last.ownUnits - first.ownUnits;
                const isUp = shareDelta >= 0;
                return {
                    key: trail.molecule,
                    molecule: trail.molecule,
                    ownBrand: trail.ownBrand,
                    deltaClass: isUp ? 'trail-delta trail-delta-up' : 'trail-delta trail-delta-down',
                    deltaIcon: isUp ? '▲' : '▼',
                    deltaLabel: `${shareDelta >= 0 ? '+' : ''}${shareDelta}% share · ${unitDelta >= 0 ? '+' : ''}${unitDelta} u`,
                    points: trail.points.map((p, i) => {
                        const total = p.ownUnits + p.competitorUnits;
                        const sharePct = total === 0 ? 0 : Math.round((p.ownUnits / total) * 100);
                        return {
                            key: i,
                            auditDate: p.auditDate,
                            chemistName: p.chemistName,
                            ownUnits: p.ownUnits,
                            sharePct,
                            trend: p.trend,
                            trendStyle: pillStyle(TREND_COLOR[p.trend]),
                            isLast: i === trail.points.length - 1,
                            isNotLast: i < trail.points.length - 1,
                            nodeClass: i === trail.points.length - 1 ? 'trail-node trail-node-active' : 'trail-node',
                        };
                    }),
                };
            });
    }

    get hasTrails() {
        return this.trailCards.length > 0;
    }
}

function reduceError(error) {
    if (error?.body?.message) return error.body.message;
    return 'An unknown error occurred.';
}