import { LightningElement } from 'lwc';
import getRxObservations from '@salesforce/apex/RCPAMatrixController.getRxObservations';
import getMoleculeCatalog from '@salesforce/apex/RCPAMatrixController.getMoleculeCatalog';
import getRCPATargets from '@salesforce/apex/RCPAMatrixController.getRCPATargets';
import saveRCPATarget from '@salesforce/apex/RCPAMatrixController.saveRCPATarget';
import { CLASSIFICATION_COLOR, pillStyle } from 'c/sciagenColors';

const GROUP_OPTIONS = [
    { label: 'Doctor', value: 'doctor' },
    { label: 'Molecule', value: 'molecule' },
    { label: 'Therapy', value: 'therapy' },
    { label: 'Brand', value: 'brand' },
];

// Same bundled fallback the iPad app falls back to (RCPAData.molecules in
// RCPAModels.swift) when a molecule isn't found in the live Product__c
// catalog — e.g. the catalog has no Molecule-level record for it yet, or
// that record's Unit_Value_Per_Strip__c is blank. Without this, unitValue()
// silently returned 0 instead of a usable placeholder, which is why Potential
// Value / Our Value showed zero here while the app (which has this same
// fallback) showed real numbers for the exact same audit data.
//
// Keyed by this org's actual live "Molecule"-level Product__c.Name values
// (Emrok/Glaritus/Miqnaf), same reason as rcpaAuditForm.js's
// COMPETITORS_BY_MOLECULE — this org's Molecule-level records have no
// separate chemical name from their own brand, so `molecule` passed into
// unitValue()/therapyOf() below is always the brand-style name in practice.
const FALLBACK_MOLECULE_VALUES = {
    Emrok: { unitValuePerStrip: 42, therapyArea: 'Anti-Infectives' },
    Glaritus: { unitValuePerStrip: 850, therapyArea: 'Diabetology' },
    Miqnaf: { unitValuePerStrip: 120, therapyArea: 'Dermatology' },
};
const DEFAULT_UNIT_VALUE_PER_STRIP = 50;
const DEFAULT_THERAPY_AREA = 'Other';

// Web port of RCPAMasterMatrixView (RCPAMatrixViews.swift) — a filterable,
// group-able crosstab across every doctor/molecule/brand observation, plus
// the editable per-molecule Target Qty in the Brand-grouped table.
export default class RcpaMasterMatrix extends LightningElement {
    isLoading = true;
    error;

    allObservations = [];
    catalogByMolecule = {};
    targets = {};

    groupBy = 'doctor';
    groupOptions = GROUP_OPTIONS;
    showFilters = false;
    searchTerm = '';
    selectedTherapies = [];
    selectedMolecules = [];
    selectedBrands = [];
    selectedSegments = [];

    drill; // { title, rows: [{label, sub, value}] } | undefined

    async connectedCallback() {
        this.isLoading = true;
        this.error = undefined;
        try {
            const [observations, catalog, targets] = await Promise.all([
                getRxObservations(), getMoleculeCatalog(), getRCPATargets(),
            ]);
            this.allObservations = observations;
            this.catalogByMolecule = {};
            catalog.forEach((c) => { this.catalogByMolecule[c.molecule] = c; });
            this.targets = { ...targets };
        } catch (e) {
            this.error = reduceError(e);
        } finally {
            this.isLoading = false;
        }
    }

    unitValue(molecule) {
        return (
            this.catalogByMolecule[molecule]?.unitValuePerStrip ||
            FALLBACK_MOLECULE_VALUES[molecule]?.unitValuePerStrip ||
            DEFAULT_UNIT_VALUE_PER_STRIP
        );
    }

    therapyOf(molecule) {
        return (
            this.catalogByMolecule[molecule]?.therapyArea ||
            FALLBACK_MOLECULE_VALUES[molecule]?.therapyArea ||
            DEFAULT_THERAPY_AREA
        );
    }

    // MARK: - Empty states (distinct: no data at all vs. filtered to zero)

    get hasAnyData() {
        return this.allObservations.length > 0;
    }

    get filteredObservations() {
        const term = this.searchTerm.trim().toLowerCase();
        return this.allObservations.filter((o) => {
            if (term && !(o.doctorName || '').toLowerCase().includes(term)) return false;
            if (this.selectedTherapies.length && !this.selectedTherapies.includes(this.therapyOf(o.molecule))) return false;
            if (this.selectedMolecules.length && !this.selectedMolecules.includes(o.molecule)) return false;
            if (this.selectedBrands.length && !this.selectedBrands.includes(o.brand)) return false;
            if (this.selectedSegments.length && !this.selectedSegments.includes(o.classification || 'Unclassified')) return false;
            return true;
        });
    }

    get hasFilteredResults() {
        return this.filteredObservations.length > 0;
    }

    get hasActiveFilters() {
        return !!this.searchTerm || this.selectedTherapies.length > 0 || this.selectedMolecules.length > 0
            || this.selectedBrands.length > 0 || this.selectedSegments.length > 0;
    }

    get showNoDataYet() {
        return !this.isLoading && !this.error && !this.hasAnyData;
    }

    get showNoFilterResults() {
        return !this.isLoading && !this.error && this.hasAnyData && !this.hasFilteredResults;
    }

    get showMatrix() {
        return !this.isLoading && !this.error && this.hasFilteredResults;
    }

    // MARK: - KPI tiles

    get kpis() {
        const obs = this.filteredObservations;
        const total = obs.reduce((s, o) => s + o.units, 0);
        const own = obs.filter((o) => o.isOwn).reduce((s, o) => s + o.units, 0);
        const sharePct = total === 0 ? 0 : Math.round((own / total) * 100);
        const potentialValue = obs.reduce((s, o) => s + o.units * this.unitValue(o.molecule), 0);
        const ownValue = obs.filter((o) => o.isOwn).reduce((s, o) => s + o.units * this.unitValue(o.molecule), 0);
        return [
            { key: 'total', label: 'Total Rx Qty', value: total.toLocaleString(), tint: 'tint-primary' },
            { key: 'ours', label: 'Our Qty', value: own.toLocaleString(), tint: 'tint-accent' },
            { key: 'share', label: 'Our Share', value: `${sharePct}%`, tint: 'tint-violet' },
            { key: 'potential', label: 'Potential Value', value: formatInr(potentialValue), tint: 'tint-amber' },
            { key: 'ourvalue', label: 'Our Value', value: formatInr(ownValue), tint: 'tint-accent' },
        ];
    }

    // MARK: - Filters

    get therapyFilterOptions() {
        return this.uniqueOptions(this.allObservations.map((o) => this.therapyOf(o.molecule)));
    }

    get moleculeFilterOptions() {
        return this.uniqueOptions(this.allObservations.map((o) => o.molecule));
    }

    get brandFilterOptions() {
        return this.uniqueOptions(this.allObservations.map((o) => o.brand));
    }

    get segmentFilterOptions() {
        return this.uniqueOptions(this.allObservations.map((o) => o.classification || 'Unclassified'));
    }

    uniqueOptions(values) {
        return [...new Set(values)].filter(Boolean).sort().map((v) => ({ label: v, value: v }));
    }

    get filterToggleClass() {
        return this.hasActiveFilters ? 'filter-toggle filter-toggle-active' : 'filter-toggle';
    }

    handleToggleFilters() {
        this.showFilters = !this.showFilters;
    }

    handleSearchChange(event) {
        this.searchTerm = event.target.value;
    }

    handleTherapyFilterChange(event) {
        this.selectedTherapies = event.detail.value;
    }

    handleMoleculeFilterChange(event) {
        this.selectedMolecules = event.detail.value;
    }

    handleBrandFilterChange(event) {
        this.selectedBrands = event.detail.value;
    }

    handleSegmentFilterChange(event) {
        this.selectedSegments = event.detail.value;
    }

    handleClearFilters() {
        this.searchTerm = '';
        this.selectedTherapies = [];
        this.selectedMolecules = [];
        this.selectedBrands = [];
        this.selectedSegments = [];
    }

    handleGroupByChange(event) {
        this.groupBy = event.currentTarget.dataset.value;
    }

    get groupButtons() {
        return this.groupOptions.map((g) => ({
            ...g,
            buttonClass: g.value === this.groupBy ? 'mode-button mode-button-active' : 'mode-button',
        }));
    }

    get isBrandGrouping() {
        return this.groupBy === 'brand';
    }

    get isCrosstabGrouping() {
        return this.groupBy !== 'brand';
    }

    get isDoctorGrouping() {
        return this.groupBy === 'doctor';
    }

    // MARK: - Crosstab (Doctor / Molecule / Therapy grouping)

    get crosstabColumns() {
        const own = new Set();
        const comp = new Set();
        this.filteredObservations.forEach((o) => (o.isOwn ? own : comp).add(o.brand));
        return [
            ...[...own].sort().map((b) => ({ key: b, name: b, isOwn: true, headerClass: 'col-brand col-brand-own' })),
            ...[...comp].sort().map((b) => ({ key: b, name: b, isOwn: false, headerClass: 'col-brand' })),
        ];
    }

    get crosstabRows() {
        const columns = this.crosstabColumns;
        const groupKeyFn = {
            doctor: (o) => o.doctorId,
            molecule: (o) => o.molecule,
            therapy: (o) => this.therapyOf(o.molecule),
        }[this.groupBy];
        const groupLabelFn = {
            doctor: (o) => o.doctorName,
            molecule: (o) => o.molecule,
            therapy: (o) => this.therapyOf(o.molecule),
        }[this.groupBy];

        const byKey = new Map();
        for (const o of this.filteredObservations) {
            const key = groupKeyFn(o);
            if (!byKey.has(key)) {
                byKey.set(key, {
                    key, label: groupLabelFn(o), seg: o.classification || 'Unclassified',
                    perBrand: {}, total: 0, own: 0, value: 0, ownValue: 0,
                });
            }
            const row = byKey.get(key);
            row.perBrand[o.brand] = (row.perBrand[o.brand] || 0) + o.units;
            row.total += o.units;
            if (o.isOwn) { row.own += o.units; row.ownValue += o.units * this.unitValue(o.molecule); }
            row.value += o.units * this.unitValue(o.molecule);
        }

        return [...byKey.values()]
            .sort((a, b) => a.label.localeCompare(b.label))
            .map((row) => ({
                key: row.key,
                label: row.label,
                seg: row.seg,
                segStyle: pillStyle(CLASSIFICATION_COLOR[row.seg]),
                cells: columns.map((c) => ({
                    key: c.key,
                    isOwn: c.isOwn,
                    cellClass: c.isOwn ? 'col-brand col-brand-own' : 'col-brand',
                    hasValue: !!row.perBrand[c.name],
                    value: row.perBrand[c.name] || 0,
                })),
                total: row.total,
                own: row.own,
                potentialValue: formatInr(row.value),
                ownValue: formatInr(row.ownValue),
            }));
    }

    // MARK: - Brand grouping (with editable Target Qty)

    get brandRows() {
        const byBrand = new Map();
        for (const o of this.filteredObservations) {
            if (!byBrand.has(o.brand)) {
                byBrand.set(o.brand, {
                    brand: o.brand, isOwn: o.isOwn, molecule: o.molecule, total: 0, ownValue: 0, value: 0,
                });
            }
            const row = byBrand.get(o.brand);
            row.total += o.units;
            row.value += o.units * this.unitValue(o.molecule);
            if (o.isOwn) row.ownValue += o.units * this.unitValue(o.molecule);
        }

        return [...byBrand.values()]
            .sort((a, b) => a.brand.localeCompare(b.brand))
            .map((row) => {
                const targetQty = this.targets[row.molecule] || 0;
                return {
                    key: row.brand,
                    brand: row.brand,
                    brandClass: row.isOwn ? 'brand-name brand-name-own' : 'brand-name',
                    classLabel: row.isOwn ? 'Own' : 'Comp',
                    molecule: row.molecule,
                    therapy: this.therapyOf(row.molecule),
                    total: row.total,
                    potentialValue: formatInr(row.value),
                    ourValue: row.isOwn ? formatInr(row.ownValue) : '–',
                    targetQty,
                    targetValue: targetQty > 0 ? formatInr(targetQty * this.unitValue(row.molecule)) : '–',
                };
            });
    }

    async handleTargetChange(event) {
        const molecule = event.currentTarget.dataset.molecule;
        const qty = Math.max(0, parseInt(event.target.value, 10) || 0);
        this.targets = { ...this.targets, [molecule]: qty };
        try {
            await saveRCPATarget({ molecule, qty });
        } catch (e) {
            this.error = reduceError(e);
        }
    }

    // MARK: - Drill-down (a lightweight custom overlay, not a full modal
    // component, to keep this a single-file feature)

    handleKpiClick(event) {
        const kind = event.currentTarget.dataset.kind;
        const obs = this.filteredObservations;
        if (kind === 'share') {
            const byDoctor = new Map();
            for (const o of obs) {
                if (!byDoctor.has(o.doctorId)) byDoctor.set(o.doctorId, { name: o.doctorName, own: 0, total: 0 });
                const d = byDoctor.get(o.doctorId);
                d.total += o.units;
                if (o.isOwn) d.own += o.units;
            }
            const rows = [...byDoctor.values()]
                .map((d) => ({ label: d.name, sub: `${d.own} / ${d.total} units`, value: d.total === 0 ? 0 : Math.round((d.own / d.total) * 100), display: `${d.total === 0 ? 0 : Math.round((d.own / d.total) * 100)}%` }))
                .sort((a, b) => b.value - a.value)
                .map((row, i) => ({ ...row, key: `${row.label}-${i}` }));
            this.drill = { title: 'Our Share by Doctor', rows };
            return;
        }
        let rows = obs.filter((o) => kind !== 'ours' || o.isOwn).map((o) => ({
            label: `${o.brand} · ${o.units} units`,
            sub: `${o.doctorName} · ${o.molecule}`,
            value: o.units * this.unitValue(o.molecule),
            display: formatInr(o.units * this.unitValue(o.molecule)),
            isOwn: o.isOwn,
        }));
        rows = rows.sort((a, b) => b.value - a.value).map((row, i) => ({ ...row, key: `${row.label}-${i}` }));
        const titles = { total: 'Total Rx Qty', ours: 'Our Prescriptions', potential: 'Potential Value', ourvalue: 'Our Value' };
        this.drill = { title: titles[kind] || 'Details', rows };
    }

    handleCloseDrill() {
        this.drill = undefined;
    }

    handleDrillPanelClick(event) {
        event.stopPropagation();
    }

    get hasDrill() {
        return !!this.drill;
    }
}

function formatInr(value) {
    return `₹${Math.round(value).toLocaleString('en-IN')}`;
}

function reduceError(error) {
    if (error?.body?.message) return error.body.message;
    return 'An unknown error occurred.';
}