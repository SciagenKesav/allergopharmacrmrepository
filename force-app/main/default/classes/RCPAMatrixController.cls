/**
 * Backend for the RCPA analytics views (Doctor-Product Matrix, Master Matrix,
 * RCPA Trail) — the web-side port of the iPad app's RCPAMatrixViews.swift /
 * RCPAModels.swift computations, kept over the same RCPA_Audit__c/RCPA_Line__c/
 * RCPA_Competitor__c schema RCPAController.cls already reads.
 *
 * Security: `with sharing` + WITH USER_MODE on every query, matching
 * RCPAController's conventions.
 */
public with sharing class RCPAMatrixController {

    // MARK: - Doctor picker

    public class DoctorOption {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public Integer moleculeCount;
    }

    @AuraEnabled(cacheable=true)
    public static List<DoctorOption> getDoctorOptions() {
        Map<Id, String> nameByDoctor = new Map<Id, String>();
        Map<Id, Set<String>> moleculesByDoctor = new Map<Id, Set<String>>();
        for (RCPA_Line__c line : [
            SELECT Prescriber__c, Prescriber__r.Name, Molecule__c
            FROM RCPA_Line__c
            WHERE Prescriber__c != null
            WITH USER_MODE
        ]) {
            nameByDoctor.put(line.Prescriber__c, line.Prescriber__r.Name);
            if (!moleculesByDoctor.containsKey(line.Prescriber__c)) {
                moleculesByDoctor.put(line.Prescriber__c, new Set<String>());
            }
            moleculesByDoctor.get(line.Prescriber__c).add(line.Molecule__c);
        }
        List<DoctorOption> options = new List<DoctorOption>();
        for (Id doctorId : nameByDoctor.keySet()) {
            DoctorOption o = new DoctorOption();
            o.id = doctorId;
            o.name = nameByDoctor.get(doctorId);
            o.moleculeCount = moleculesByDoctor.get(doctorId).size();
            options.add(o);
        }
        return options; // sorted client-side (JS) by name — trivial at this scale
    }

    // MARK: - Doctor-Product Matrix + RCPA Trail

    public class BrandQty {
        @AuraEnabled public String brand;
        @AuraEnabled public Decimal qty;
        @AuraEnabled public Boolean isOwn;
    }

    // Comparable so List<MoleculeRow>.sort() can alphabetize by molecule name,
    // matching RCPAMatrixViews.swift's row ordering.
    public class MoleculeRow implements Comparable {
        @AuraEnabled public String molecule;
        @AuraEnabled public String ownBrand;
        @AuraEnabled public List<BrandQty> brands;
        @AuraEnabled public Decimal total;

        public Integer compareTo(Object other) {
            return molecule.compareTo(((MoleculeRow) other).molecule);
        }
    }

    public class TrailPoint {
        @AuraEnabled public String auditDate;
        @AuraEnabled public String chemistName;
        @AuraEnabled public Decimal ownUnits;
        @AuraEnabled public Decimal competitorUnits;
        @AuraEnabled public String trend;
    }

    public class MoleculeTrail {
        @AuraEnabled public String molecule;
        @AuraEnabled public String ownBrand;
        @AuraEnabled public List<TrailPoint> points;
    }

    public class DoctorMatrix {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String specialty;
        @AuraEnabled public String rep;
        @AuraEnabled public String lastAuditDate;
        @AuraEnabled public Integer auditCount;
        @AuraEnabled public List<MoleculeRow> rows;
        @AuraEnabled public List<MoleculeTrail> trails;
    }

    @AuraEnabled
    public static DoctorMatrix getDoctorMatrix(Id prescriberId) {
        List<Sciagen_Account__c> docs = [
            SELECT Id, Name, Specialty__c FROM Sciagen_Account__c WHERE Id = :prescriberId WITH USER_MODE LIMIT 1
        ];
        if (docs.isEmpty()) {
            throw new AuraHandledException('Prescriber not found or not accessible.');
        }

        // One query, chronological — feeds both the matrix rows and the trail
        // points, same as RCPAMatrix.doctorMatrices(from:)/trail(from:doctorKey:)
        // computing over the same in-memory audit list on the iPad side.
        List<RCPA_Line__c> lines = [
            SELECT Molecule__c, Own_Brand__c, Own_Units_Per_Week__c, Trend__c,
                   Audit__c, Audit__r.Audit_Date__c, Audit__r.Rep__c, Audit__r.Chemist__r.Name,
                   (SELECT Brand__c, Company__c, Units_Per_Week__c FROM Competitors__r)
            FROM RCPA_Line__c
            WHERE Prescriber__c = :prescriberId
            WITH USER_MODE
            ORDER BY Audit__r.Audit_Date__c ASC
        ];

        Map<String, MoleculeRow> rowByMolecule = new Map<String, MoleculeRow>();
        Map<String, List<TrailPoint>> pointsByMolecule = new Map<String, List<TrailPoint>>();
        Set<Id> auditIds = new Set<Id>();
        Date lastAuditDate = null;
        String rep = null;

        for (RCPA_Line__c line : lines) {
            auditIds.add(line.Audit__c);
            if (line.Audit__r?.Audit_Date__c != null &&
                (lastAuditDate == null || line.Audit__r.Audit_Date__c > lastAuditDate)) {
                lastAuditDate = line.Audit__r.Audit_Date__c;
                rep = line.Audit__r.Rep__c;
            }

            // -- matrix row: accumulate brand -> qty for this molecule --
            MoleculeRow row = rowByMolecule.get(line.Molecule__c);
            if (row == null) {
                row = new MoleculeRow();
                row.molecule = line.Molecule__c;
                row.ownBrand = line.Own_Brand__c;
                row.brands = new List<BrandQty>();
                rowByMolecule.put(line.Molecule__c, row);
            }
            addQty(row.brands, line.Own_Brand__c, line.Own_Units_Per_Week__c, true);
            for (RCPA_Competitor__c comp : line.Competitors__r) {
                addQty(row.brands, comp.Brand__c, comp.Units_Per_Week__c, false);
            }

            // -- trail point for this molecule --
            TrailPoint pt = new TrailPoint();
            pt.auditDate = line.Audit__r?.Audit_Date__c != null ? line.Audit__r.Audit_Date__c.format() : null;
            pt.chemistName = line.Audit__r?.Chemist__r != null ? line.Audit__r.Chemist__r.Name : null;
            pt.ownUnits = line.Own_Units_Per_Week__c;
            Decimal compUnits = 0;
            for (RCPA_Competitor__c comp : line.Competitors__r) {
                compUnits += (comp.Units_Per_Week__c != null ? comp.Units_Per_Week__c : 0);
            }
            pt.competitorUnits = compUnits;
            pt.trend = line.Trend__c;
            if (!pointsByMolecule.containsKey(line.Molecule__c)) {
                pointsByMolecule.put(line.Molecule__c, new List<TrailPoint>());
            }
            pointsByMolecule.get(line.Molecule__c).add(pt);
        }

        DoctorMatrix result = new DoctorMatrix();
        result.id = docs[0].Id;
        result.name = docs[0].Name;
        result.specialty = docs[0].Specialty__c;
        result.rep = rep;
        result.lastAuditDate = lastAuditDate != null ? lastAuditDate.format() : null;
        result.auditCount = auditIds.size();

        result.rows = new List<MoleculeRow>();
        for (MoleculeRow row : rowByMolecule.values()) {
            sortBrandQty(row.brands);
            row.total = 0;
            for (BrandQty bq : row.brands) row.total += bq.qty;
            result.rows.add(row);
        }
        result.rows.sort();

        result.trails = new List<MoleculeTrail>();
        for (String molecule : pointsByMolecule.keySet()) {
            MoleculeTrail trail = new MoleculeTrail();
            trail.molecule = molecule;
            trail.ownBrand = rowByMolecule.get(molecule).ownBrand;
            trail.points = pointsByMolecule.get(molecule);
            result.trails.add(trail);
        }
        return result;
    }

    private static void addQty(List<BrandQty> brands, String brand, Decimal qty, Boolean isOwn) {
        if (String.isBlank(brand) || qty == null || qty == 0) return;
        for (BrandQty bq : brands) {
            if (bq.brand == brand && bq.isOwn == isOwn) {
                bq.qty += qty;
                return;
            }
        }
        BrandQty bq = new BrandQty();
        bq.brand = brand;
        bq.qty = qty;
        bq.isOwn = isOwn;
        brands.add(bq);
    }

    // Own brand first, then descending qty — matches RCPAMatrixViews.swift's
    // BrandQty sort exactly. Small lists (a handful of brands per molecule),
    // so a plain insertion sort is simpler than a Comparator implementation.
    private static void sortBrandQty(List<BrandQty> brands) {
        for (Integer i = 1; i < brands.size(); i++) {
            BrandQty key = brands[i];
            Integer j = i - 1;
            while (j >= 0 && isAfter(brands[j], key)) {
                brands[j + 1] = brands[j];
                j--;
            }
            brands[j + 1] = key;
        }
    }

    private static Boolean isAfter(BrandQty a, BrandQty b) {
        if (a.isOwn != b.isOwn) return !a.isOwn; // own sorts before competitor
        return a.qty < b.qty; // then descending qty
    }

    // MARK: - Master Matrix (flattened observations)

    public class RxObservation {
        @AuraEnabled public Id doctorId;
        @AuraEnabled public String doctorName;
        @AuraEnabled public String specialty;
        @AuraEnabled public String classification;
        @AuraEnabled public String molecule;
        @AuraEnabled public String brand;
        @AuraEnabled public Boolean isOwn;
        @AuraEnabled public Decimal units;
    }

    // Not cacheable — the Segmentation__c bulk lookup below binds :doctorIds
    // alongside WITH USER_MODE, same tmpVar1 compilation issue as
    // getRCPATargets (see its comment).
    @AuraEnabled
    public static List<RxObservation> getRxObservations() {
        List<RCPA_Line__c> lines = [
            SELECT Molecule__c, Own_Brand__c, Own_Units_Per_Week__c,
                   Prescriber__c, Prescriber__r.Name, Prescriber__r.Specialty__c,
                   (SELECT Brand__c, Units_Per_Week__c FROM Competitors__r)
            FROM RCPA_Line__c
            WHERE Prescriber__c != null
            WITH USER_MODE
        ];

        Set<Id> doctorIds = new Set<Id>();
        for (RCPA_Line__c line : lines) doctorIds.add(line.Prescriber__c);

        // Single bulk lookup for the doctor-grouped crosstab's "Seg" column —
        // never one query per doctor.
        Map<Id, String> classificationByDoctor = new Map<Id, String>();
        for (Segmentation__c seg : [
            SELECT HCP__c, Classification__c FROM Segmentation__c WHERE HCP__c IN :doctorIds WITH USER_MODE
        ]) {
            classificationByDoctor.put(seg.HCP__c, seg.Classification__c);
        }

        List<RxObservation> observations = new List<RxObservation>();
        for (RCPA_Line__c line : lines) {
            String classification = classificationByDoctor.containsKey(line.Prescriber__c)
                ? classificationByDoctor.get(line.Prescriber__c) : 'Unclassified';

            if (line.Own_Units_Per_Week__c != null && line.Own_Units_Per_Week__c > 0) {
                observations.add(buildObservation(line, classification, line.Own_Brand__c, line.Own_Units_Per_Week__c, true));
            }
            for (RCPA_Competitor__c comp : line.Competitors__r) {
                if (comp.Units_Per_Week__c != null && comp.Units_Per_Week__c > 0) {
                    observations.add(buildObservation(line, classification, comp.Brand__c, comp.Units_Per_Week__c, false));
                }
            }
        }
        return observations;
    }

    private static RxObservation buildObservation(RCPA_Line__c line, String classification, String brand, Decimal units, Boolean isOwn) {
        RxObservation obs = new RxObservation();
        obs.doctorId = line.Prescriber__c;
        obs.doctorName = line.Prescriber__r != null ? line.Prescriber__r.Name : null;
        obs.specialty = line.Prescriber__r != null ? line.Prescriber__r.Specialty__c : null;
        obs.classification = classification;
        obs.molecule = line.Molecule__c;
        obs.brand = brand;
        obs.isOwn = isOwn;
        obs.units = units;
        return obs;
    }

    // MARK: - Molecule catalog. One entry per DISTINCT Product__c.Parent_Molecule__c
    // value — that field (the generic/chemical composition, e.g. "Dermatophagoides
    // farinae 100%") is what actually identifies a molecule in this org's real
    // product data; there's no live Level__c='Molecule' parent record above the
    // SKU-level Product__c rows to read a molecule catalog from anymore. "Own
    // brand" for each molecule is just the Name shared by every SKU under that
    // molecule (e.g. "ACAROID DF") — Parent_Molecule__c/Name pairs are 1:1 in
    // practice, since every SKU variant of one branded product carries the same
    // molecule. Therapy area comes from Parent_Therapy__c (Division__c, the
    // older source, isn't populated on this org's current catalog).

    public class MoleculeCatalogItem {
        @AuraEnabled public String molecule;
        @AuraEnabled public String ownBrand;
        @AuraEnabled public Decimal unitValuePerStrip;
        @AuraEnabled public String therapyArea;
    }

    @AuraEnabled(cacheable=true)
    public static List<MoleculeCatalogItem> getMoleculeCatalog() {
        Map<String, MoleculeCatalogItem> byMolecule = new Map<String, MoleculeCatalogItem>();
        for (Product__c p : [
            SELECT Name, Parent_Molecule__c, Parent_Therapy__c, Unit_Value_Per_Strip__c
            FROM Product__c
            WHERE Active__c = true
            WITH USER_MODE
            ORDER BY Name
        ]) {
            if (String.isBlank(p.Parent_Molecule__c) || byMolecule.containsKey(p.Parent_Molecule__c)) continue;
            MoleculeCatalogItem item = new MoleculeCatalogItem();
            item.molecule = p.Parent_Molecule__c;
            item.ownBrand = p.Name;
            item.unitValuePerStrip = p.Unit_Value_Per_Strip__c;
            item.therapyArea = p.Parent_Therapy__c;
            byMolecule.put(p.Parent_Molecule__c, item);
        }
        return byMolecule.values();
    }

    /// Distinct Product__c.Competitor1__c values recorded for one molecule — feeds the
    /// "Competitor 1" picker on the New RCPA Audit form. Read without field-level
    /// enforcement on purpose: it's reference data (competitor brand names) every rep
    /// needs, and Competitor1__c isn't on every user's permission sets.
    @AuraEnabled(cacheable=true)
    public static List<String> getCompetitor1ForMolecule(String molecule) {
        Set<String> names = new Set<String>();
        if (String.isNotBlank(molecule)) {
            for (Product__c p : [
                SELECT Competitor1__c FROM Product__c
                WHERE Parent_Molecule__c = :molecule AND Active__c = true AND Competitor1__c != null
            ]) {
                if (String.isNotBlank(p.Competitor1__c)) names.add(p.Competitor1__c.trim());
            }
        }
        List<String> result = new List<String>(names);
        result.sort();
        return result;
    }

    // MARK: - Target Qty (web-side only; does not sync with the iPad app's
    // local-only UserDataStore.rcpaTargets — see the RCPA plan doc)

    // Not cacheable (the query binds :repName). Also deliberately queried into a
    // List first rather than iterated as an inline `for (X : [SELECT ...])` —
    // the inline form combined with WITH USER_MODE + a bind variable against
    // RCPA_Target__c hit a platform SOQL-compilation bug ("Variable does not
    // exist: tmpVar1"); assigning to a list first avoids it.
    @AuraEnabled
    public static Map<String, Decimal> getRCPATargets() {
        Map<String, Decimal> targets = new Map<String, Decimal>();
        String repName = UserInfo.getName();
        List<RCPA_Target__c> existing = [
            SELECT Molecule__c, Target_Qty__c FROM RCPA_Target__c WHERE Rep__c = :repName WITH USER_MODE
        ];
        for (RCPA_Target__c t : existing) {
            targets.put(t.Molecule__c, t.Target_Qty__c);
        }
        return targets;
    }

    @AuraEnabled
    public static Decimal saveRCPATarget(String molecule, Decimal qty) {
        String repName = UserInfo.getName();
        RCPA_Target__c target = new RCPA_Target__c(
            Rep__c = repName,
            Molecule__c = molecule,
            Target_Qty__c = qty,
            Target_Key__c = repName + '|' + molecule
        );
        upsert target RCPA_Target__c.Target_Key__c;
        return qty;
    }
}