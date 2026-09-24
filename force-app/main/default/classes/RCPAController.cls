/**
 * Backend for the RCPA (Retail Chemist Prescription Audit) browse/review
 * experience — list, search, filter, and read an audit with its prescriber
 * lines and each line's competitor lines.
 *
 * Security: `with sharing` enforces record-level sharing; every SOQL query
 * uses WITH USER_MODE (or AccessLevel.USER_MODE for a bound query string) so
 * field- and object-level security is enforced per running user. `searchAudits`
 * is left non-cacheable since rcpaBrowser re-invokes it after every filter
 * change; a cacheable imperative call would keep returning a stale result set.
 */
public with sharing class RCPAController {

    // MARK: - Wrapper types

    public class AuditSummary {
        @AuraEnabled public Id id;
        @AuraEnabled public String chemistName;
        @AuraEnabled public String chemistArea; // from Chemist__r.Billing_City__c — see AuditDetail.chemistArea's note
        @AuraEnabled public String territory;
        @AuraEnabled public String auditDate;
        @AuraEnabled public String status;
        @AuraEnabled public String rep;
        @AuraEnabled public Decimal pobUnits;
    }

    public class CompetitorItem {
        @AuraEnabled public Id id;
        @AuraEnabled public String company;
        @AuraEnabled public String brand;
        @AuraEnabled public Decimal unitsPerWeek;
    }

    public class LineItem {
        @AuraEnabled public Id id;
        @AuraEnabled public Id prescriberId;
        @AuraEnabled public String prescriberName;
        @AuraEnabled public String molecule;
        @AuraEnabled public String ownBrand;
        @AuraEnabled public Decimal ownUnitsPerWeek;
        @AuraEnabled public String trend;
        @AuraEnabled public String remarks;
        @AuraEnabled public List<CompetitorItem> competitors;
    }

    public class AuditDetail {
        @AuraEnabled public Id id;
        @AuraEnabled public String chemistName;
        // From the linked Chemist__c (Sciagen_Account__c) record, not a per-visit-typed
        // value — RCPA_Audit__c has no field of its own for what the rep typed that day,
        // so this is a reasonable stand-in, not a guaranteed exact match to the iPad app's
        // capture-time chemistArea/chemistPhone.
        @AuraEnabled public String chemistArea;
        @AuraEnabled public String chemistPhone;
        @AuraEnabled public String territory;
        @AuraEnabled public String auditDate;
        @AuraEnabled public String status;
        @AuraEnabled public String rep;
        @AuraEnabled public Decimal pobUnits;
        @AuraEnabled public String chemistSignerName;
        @AuraEnabled public Boolean chemistOtpVerified;
        @AuraEnabled public String competitorActivity;
        @AuraEnabled public String stockIssues;
        @AuraEnabled public String generalRemarks;
        @AuraEnabled public List<LineItem> lines;
    }

    // MARK: - List / search / filter

    @AuraEnabled
    public static List<AuditSummary> searchAudits(String searchTerm, String statusFilter, String territoryFilter) {
        String term = '%' + String.escapeSingleQuotes(searchTerm == null ? '' : searchTerm) + '%';

        List<String> whereClauses = new List<String>{ '(Chemist__r.Name LIKE :term OR Rep__c LIKE :term)' };
        Map<String, Object> binds = new Map<String, Object>{ 'term' => term };
        if (String.isNotBlank(statusFilter)) {
            whereClauses.add('Status__c = :statusFilter');
            binds.put('statusFilter', statusFilter);
        }
        if (String.isNotBlank(territoryFilter)) {
            whereClauses.add('Territory__r.Name = :territoryFilter');
            binds.put('territoryFilter', territoryFilter);
        }

        String query = 'SELECT Id, Chemist__r.Name, Chemist__r.Billing_City__c, Territory__r.Name, Audit_Date__c, ' +
            'Status__c, Rep__c, POB_Units__c ' +
            'FROM RCPA_Audit__c WHERE ' + String.join(whereClauses, ' AND ') + ' ORDER BY Audit_Date__c DESC LIMIT 100';

        List<RCPA_Audit__c> audits = Database.queryWithBinds(query, binds, AccessLevel.USER_MODE);

        List<AuditSummary> results = new List<AuditSummary>();
        for (RCPA_Audit__c a : audits) {
            AuditSummary summary = new AuditSummary();
            summary.id = a.Id;
            summary.chemistName = a.Chemist__r != null ? a.Chemist__r.Name : null;
            summary.chemistArea = a.Chemist__r != null ? a.Chemist__r.Billing_City__c : null;
            summary.territory = a.Territory__r != null ? a.Territory__r.Name : null;
            summary.auditDate = a.Audit_Date__c != null ? a.Audit_Date__c.format() : null;
            summary.status = a.Status__c;
            summary.rep = a.Rep__c;
            summary.pobUnits = a.POB_Units__c;
            results.add(summary);
        }
        return results;
    }

    // Reuses SciagenAccountController's territory query rather than duplicating it —
    // both browsers filter against the same Territory__c list.
    @AuraEnabled(cacheable=true)
    public static List<String> getTerritoryOptions() {
        return SciagenAccountController.getTerritoryOptions();
    }

    // MARK: - POB SKU catalog (Product__c SKU level) — the New Audit form's
    // SKU picker, same Product__c catalog (Level__c = 'SKU') the iPad app's
    // productSKUs reads, so the office-side POB entry offers the same items.
    // Display name is SKUCode__c (a formula field: Name & "-" & SKU__c, e.g.
    // "ACAROID DP-BB") rather than the plain Name, since Name alone is
    // shared by every SKU variant of the same branded product and can't
    // distinguish them from each other in the picker.

    public class SKUOption {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
    }

    @AuraEnabled(cacheable=true)
    public static List<SKUOption> getSKUCatalog() {
        List<SKUOption> options = new List<SKUOption>();
        for (Product__c p : [
            SELECT Id, Name, SKUCode__c FROM Product__c WHERE Level__c = 'SKU' AND Active__c = true WITH USER_MODE ORDER BY Name
        ]) {
            SKUOption o = new SKUOption();
            o.id = p.Id;
            o.name = String.isNotBlank(p.SKUCode__c) ? p.SKUCode__c : p.Name;
            options.add(o);
        }
        return options;
    }

    // MARK: - Detail

    @AuraEnabled
    public static AuditDetail getAuditDetail(Id auditId) {
        List<RCPA_Audit__c> matches = [
            SELECT Id, Chemist__r.Name, Chemist__r.Billing_City__c, Chemist__r.Phone__c, Territory__r.Name,
                   Audit_Date__c, Status__c, Rep__c, POB_Units__c,
                   Chemist_Signer_Name__c, Chemist_OTP_Verified__c, Competitor_Activity__c, Stock_Issues__c,
                   General_Remarks__c,
                   (SELECT Id, Prescriber__c, Prescriber__r.Name, Molecule__c, Own_Brand__c, Own_Units_Per_Week__c, Trend__c, Remarks__c,
                           (SELECT Id, Company__c, Brand__c, Units_Per_Week__c FROM Competitors__r)
                    FROM Lines__r)
            FROM RCPA_Audit__c
            WHERE Id = :auditId
            WITH USER_MODE
            LIMIT 1
        ];
        if (matches.isEmpty()) {
            throw new AuraHandledException('RCPA audit not found or not accessible.');
        }
        RCPA_Audit__c a = matches[0];

        AuditDetail detail = new AuditDetail();
        detail.id = a.Id;
        detail.chemistName = a.Chemist__r != null ? a.Chemist__r.Name : null;
        detail.chemistArea = a.Chemist__r != null ? a.Chemist__r.Billing_City__c : null;
        detail.chemistPhone = a.Chemist__r != null ? a.Chemist__r.Phone__c : null;
        detail.territory = a.Territory__r != null ? a.Territory__r.Name : null;
        detail.auditDate = a.Audit_Date__c != null ? a.Audit_Date__c.format() : null;
        detail.status = a.Status__c;
        detail.rep = a.Rep__c;
        detail.pobUnits = a.POB_Units__c;
        detail.chemistSignerName = a.Chemist_Signer_Name__c;
        detail.chemistOtpVerified = a.Chemist_OTP_Verified__c;
        detail.competitorActivity = a.Competitor_Activity__c;
        detail.stockIssues = a.Stock_Issues__c;
        detail.generalRemarks = a.General_Remarks__c;

        detail.lines = new List<LineItem>();
        for (RCPA_Line__c line : a.Lines__r) {
            LineItem li = new LineItem();
            li.id = line.Id;
            li.prescriberId = line.Prescriber__c;
            li.prescriberName = line.Prescriber__r != null ? line.Prescriber__r.Name : null;
            li.molecule = line.Molecule__c;
            li.ownBrand = line.Own_Brand__c;
            li.ownUnitsPerWeek = line.Own_Units_Per_Week__c;
            li.trend = line.Trend__c;
            li.remarks = line.Remarks__c;
            li.competitors = new List<CompetitorItem>();
            for (RCPA_Competitor__c comp : line.Competitors__r) {
                CompetitorItem ci = new CompetitorItem();
                ci.id = comp.Id;
                ci.company = comp.Company__c;
                ci.brand = comp.Brand__c;
                ci.unitsPerWeek = comp.Units_Per_Week__c;
                li.competitors.add(ci);
            }
            detail.lines.add(li);
        }
        return detail;
    }

    // MARK: - Prior-audit prefill (New Audit capture grid)
    //
    // When a rep adds a molecule and picks the prescriber (HCP) for that
    // line, the capture form calls this to check whether that same molecule
    // was already recorded for that HCP in an earlier audit — if so, the
    // line is prefilled with those values (own units, trend, remarks, and
    // each named competitor's units) so the rep edits forward from last
    // time instead of re-entering everything; if nothing existed, the form
    // returns null and the line is left exactly as it was.

    @AuraEnabled
    public static LineItem getPriorLineForPrescriber(Id prescriberId, String molecule) {
        if (prescriberId == null || String.isBlank(molecule)) {
            return null;
        }
        List<RCPA_Line__c> matches = [
            SELECT Id, Prescriber__r.Name, Molecule__c, Own_Brand__c, Own_Units_Per_Week__c, Trend__c, Remarks__c,
                   (SELECT Id, Company__c, Brand__c, Units_Per_Week__c FROM Competitors__r)
            FROM RCPA_Line__c
            WHERE Prescriber__c = :prescriberId AND Molecule__c = :molecule
            WITH USER_MODE
            ORDER BY Audit__r.Audit_Date__c DESC, CreatedDate DESC
            LIMIT 1
        ];
        if (matches.isEmpty()) {
            return null;
        }
        RCPA_Line__c line = matches[0];
        LineItem li = new LineItem();
        li.id = line.Id;
        li.prescriberName = line.Prescriber__r != null ? line.Prescriber__r.Name : null;
        li.molecule = line.Molecule__c;
        li.ownBrand = line.Own_Brand__c;
        li.ownUnitsPerWeek = line.Own_Units_Per_Week__c;
        li.trend = line.Trend__c;
        li.remarks = line.Remarks__c;
        li.competitors = new List<CompetitorItem>();
        for (RCPA_Competitor__c comp : line.Competitors__r) {
            CompetitorItem ci = new CompetitorItem();
            ci.id = comp.Id;
            ci.company = comp.Company__c;
            ci.brand = comp.Brand__c;
            ci.unitsPerWeek = comp.Units_Per_Week__c;
            li.competitors.add(ci);
        }
        return li;
    }
}