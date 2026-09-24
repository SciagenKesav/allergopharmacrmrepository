# Revised Build Plan — Sample Management Module

Re-plans the build spec's 7 phases (§22) around what this audit actually found: a real, non-trivial Salesforce backend already exists for a large fraction of this module, while the iPad app has almost nothing to extend and needs near-total net-new work in every phase. Every requirement ID from `BUILD_SPEC.md` is mapped to exactly one phase below (cross-check against `03_gap_matrix.csv`'s 238 rows).

**Reading the phase tables:** `Reuse` column is the dominant recommendation from the gap matrix for that group of IDs (Reuse as-is / Extend / Refactor / Replace / Build new); most rows are mixed SF=Extend + iOS=Build new, called out explicitly where that split matters.

---

## Phase 0 (new) — Fix what's already broken, before building more on top of it

Not in the original 7-phase plan. The audit found several items that are either (a) actively broken for any live user today, or (b) foundational decisions that every later phase depends on. Doing these first avoids building new features on top of a known-bad pattern.

| Action | Why first | Related IDs |
|---|---|---|
| **Patch the cold-chain submission block.** `SampleDropService.beforeInsert` hard-blocks any cold-chain product missing tag/status fields that the `cvrSampleDrops` LWC never renders. If any cold-chain product exists in production, it is un-submittable right now. | Live breaking bug, independent of the wider build | SM-CC-01..07 |
| **Decide the Address-object design** (new child object vs. denormalized Account fields + Address child) — see Open Question #1 in `04_gap_report.md`. | Gates ~20 of 37 licensing IDs and the entire mid-level-practitioner subsystem | SM-LIC-01 |
| **Decide the sharing/FLS posture** for new Sample Management Apex, given 56% of the existing engine is `without sharing` with zero `stripInaccessible` usage anywhere in the org. | Every new Apex class in Phases 1-6 needs to know this before being written, not after | SM-SEC-01..04 |
| **Refactor `SampleLimitChecker.usage()`** to batch its per-limit SOQL query (single `IN`-clause query instead of one query per limit per drop row) before adding any new eligibility/limit logic on top of it. | Already close to the 100-SOQL governor limit; every phase below adds more calls into this path | Code quality §1.2 |
| **Batch-write the 8 missing Apex test classes** (`UCPMPComplianceService`, `UCPMPComplianceController`, `UCPMPDisclosureController`, `SampleLimitGuardService`, `SampleLotExpiryBatch`, `HcpLicenseExpiryBatch`, `SampleAttemptLogService`, `SampleExpenditureService`) before extending any of them. | Can't safely refactor/extend untested classes | Code quality §1.6 |
| **Seed `UCPMP_Tenant_Config__c`** with real (or the documented demo-fixture) values. | Currently 0 records — every disclosure field renders blank; needed to validate Phase 6 work as it lands, not just at the end | SM-DIS (prep) |

**Effort:** M. **Owner decision needed:** Open Questions #1, #2, #6 in the gap report must be answered before this phase's Address/sharing items can start.

---

## Phase 1 — Foundation

Original scope: repo findings, design doc, data model, permission sets, settings metadata, ledger, trigger framework.

**What already exists (Reuse/Extend):** the trigger framework convention (thin trigger → static service method) is consistent across 22 existing triggers and directly extensible — new `Sample_*` triggers should follow the identical shape. The core data model objects (`Sample_Lot__c`, `Sample_Transaction__c`, `Sample_Drop__c`, `Sample_Allocation__c`, `Sample_Limit__c`) already exist with real fields, not stubs.

**What's missing (Build new):** `Sample_Setting__mdt` (all 25 SM-CFG settings) doesn't exist — no Custom Metadata Type for configuration exists in the sample domain at all. `Sample_Ledger_Entry__c` (append-only, hash-chained) doesn't exist — `Sample_Transaction__c` is doing this job today but isn't immutable. `Sample_Jurisdiction_Rule__mdt` (the rules-engine-pack switch) doesn't exist. `Product_Type__c`'s current free-text values need migrating into the real taxonomy (SM-PRD-01).

| IDs | Count | SF Reuse | iOS Reuse | Effort |
|---|---:|---|---|---|
| SM-GEN-01..03 | 3 | N/A (concepts only) | N/A | S |
| SM-PRD-01..06 | 6 | Extend (taxonomy migration needed) | Build new | M |
| SM-CFG-01..25 | 25 | Build new (`Sample_Setting__mdt`) | Build new (settings sync) | L |
| SM-AUD-01..04 | 4 | Extend (enable History Tracking) + Build new (ledger hash chain) | N/A mostly | L |
| SM-SEC-01..04 | 4 | Extend (permission sets exist for other objects; Sample-specific ones partially exist) | Build new (device security) | M |

**Sequencing note:** Phase 0's Address-object and sharing-posture decisions must land before this phase's permission-set work is finalized.

---

## Phase 2 — Inventory Core

Original scope: products/My Setup/Rep Roster/lots, transactions (transfer/receipt/return/adjustment), My Samples (web + iPad), inventory counts, seed script, setup wizard.

**What already exists (Reuse/Extend — this is the strongest phase for SF reuse in the whole plan):** `SampleTransactionService.cls` already implements transfer-out decrement, signed-quantity adjustments, cold-chain gating on 4 of 5 transaction types, and **Batch Lot ID carry-over logic that matches the spec's match/overwrite/create-new rule almost verbatim.** This is genuinely close to production-ready and should be extended, not rebuilt.

**What's missing (Build new):** Rep Roster (`SM-RR-01..05`) is entirely absent on both platforms — this cascades into ship-to address auto-fill (SM-TRF-03) and Return-To validation (SM-RET-01), so it should be built early in this phase, not last. `Sample_Receipt__c`, `Sample_Lot_Item__c` (TagAlert), `Sample_Inventory__c`/`Sample_Inventory_Item__c` don't exist — the entire physical-count subsystem (§13) is from scratch. The "My Samples" hub (SM-MYS-01) — the single biggest missing user-facing surface in the whole audit — doesn't exist on either platform. **On iOS, this entire phase is a from-scratch build**: no lot, transaction, transfer, receipt, adjustment, or inventory concept exists anywhere in the client.

| IDs | Count | SF Reuse | iOS Reuse | Effort |
|---|---:|---|---|---|
| SM-SET-01/02 (My Setup) | 2 | Extend | Build new | S |
| SM-RR-01..05 (Rep Roster) | 5 | Build new | Build new | M |
| SM-SETUP-01..07 (setup wizard) | 7 | Extend (seed script pattern exists elsewhere) | N/A (admin/web only) | M |
| SM-MYS-01..04 (My Samples hub) | 4 | Build new (LWC) | Build new (screen) | L |
| SM-LOT-01..04 | 4 | Extend, fix SM-LOT-02 conflict | Build new | M |
| SM-TXN-01 | 1 | Refactor (fix Return_To__c conflict) | Build new | S |
| SM-TRF-01..07 (Transfer) | 7 | **Reuse as-is** for 5 of 7 (incl. Batch Lot ID carry-over) | Build new | M |
| SM-RCP-01..05 (Receipt) | 5 | Extend | Build new | M |
| SM-RET-01..03 (Return) | 3 | Extend, fix SM-RET-01 conflict | Build new | S |
| SM-ADJ-01..04 (Adjustment) | 4 | Extend (add cold-chain to Adjustment) | Build new | S |
| SM-UNL-01..03 (Unlock) | 3 | **Refactor — SM-UNL-03 is a live data-integrity gap** | N/A | M |
| SM-INV-01..07 (physical counts) | 7 | Build new | Build new | L |

**Sequencing note:** Rep Roster before Transfer/Return (dependency); Unlock reversal fix (SM-UNL-03) should land here or in Phase 0, not be deferred to the end.

---

## Phase 3 — Licensing & Eligibility

Original scope: address licenses + propagation, status lifecycle, one-time drop, vendor integration, mid-level/authorized receiver, controlled substances, restrictions.

**What already exists (Reuse/Extend):** `SampleEligibilityService.cls` is a genuinely well-designed, single-point eligibility engine (product/license/opt-in/lot/limits) with FEFO lot assignment and a hypnotic/sedative/tranquillizer block that already cites the UCPMP clause verbatim — extend this, don't replace it. `HcpLicenseExpiryBatch.cls` correctly implements the Valid→Expired transition already. `Sample_Eligible__c` is a portable formula analogue of "License Valid To Sample." The controlled-substance signature gate (SM-CS-03) in `SampleDropService.cls` is correctly independent of opt-in and correctly blocks at submission.

**What's missing (Build new — this is the largest single blocked area):** the Address object itself (Phase 0 decision) gates almost everything here. No propagation service exists (`AddressLicenseService` — confirmed absent). The entire mid-level-practitioner subsystem — `Account_Authorization__c`, `Sample_State_Credential_Setting__c`, supervising-physician picking/validation, DEA checksum — is completely absent on both platforms. DEA/CDS license modeling doesn't exist beyond a single free-text field. **iOS has zero rules-engine mirror for anything in this phase.**

| IDs | Count | SF Reuse | iOS Reuse | Effort |
|---|---:|---|---|---|
| SM-LIC-01 (Address object) | 1 | Build new — root dependency | Build new | XL |
| SM-LIC-02/03 (vendor validation, prescriber qualification) | 2 | Extend | Build new | M |
| SM-LIC-04..08 (fields/status/formula) | 5 | Extend once Address exists | Build new | M |
| SM-LIC-09..16 (status lifecycle, one-time drop) | 8 | Extend (add New/Sampled values) | Build new | M |
| SM-LIC-17..20 (propagation) | 4 | Build new | Build new (local mirror) | L |
| SM-MLP-01..11 (mid-level practitioners) | 11 | Build new | Build new | XL |
| SM-CS-01..06 (controlled substances) | 6 | Extend SM-CS-03/06 (reuse); Build new SM-CS-01/02 (DEA/CDS) | Build new | L |

**Sequencing note:** this phase cannot meaningfully start until Phase 0's Address-object decision is made and the object exists. Consider splitting: land SM-LIC-01 through 08 (Address + status lifecycle) as a sub-phase before attempting SM-MLP (which depends on Address for supervising-physician state matching).

---

## Phase 4 — Call Sampling (iPad)

Original scope: samples section, mass add, lot ordering, warnings, limits, barcode, cold chain, custom text, BRC/alt samples/promo, signature (all features), submit → disbursement, unlock.

**What already exists (SF-side Extend):** the disbursement-creation path (`SampleDropService.createTransactions()`) works. Cold-chain and custom-text *fields* exist on the object schema. The `ContentDocument`-Id signature storage pattern is sound and ready to receive real capture output.

**What's missing (near-total Build new, especially iOS):** this is where the audit's single most dangerous finding lives — the iPad's only visible "sample limit" is a hardcoded, wrong, non-blocking cap that could be mistaken for the real UCPMP rule. Barcode scanning is 100% absent on both platforms (no VisionKit, GS1 parsing, matching, or activity log). The CVR's "Capture Signature" action is a one-line stub with no drawing surface at all. Cold-chain/custom-text fields, though present in schema, are **structurally unreachable from the only UI that creates the parent records today** — a live conflict, not just a future gap.

| IDs | Count | SF Reuse | iOS Reuse | Effort |
|---|---:|---|---|---|
| SM-CALL-01..16 (samples section, mass add, limits) | 16 | Extend eligibility/limit engine | Build new — replace hardcoded cap with real rule mirror | L |
| SM-BAR-01..09 (barcode scanning) | 9 | Extend (matching logic against existing lot data) | **Build new — no scanning capability exists at all** | L |
| SM-SIG-01..08, 10..15 (signature, excl. remote) | 13 | Extend (storage pattern reusable) | **Build new — no real capture UI exists** | L |
| SM-SIG-09 (Remote Sampling entry point) | 1 | Build new | Build new | M (depends on Phase 5 remote infra) |
| SM-CC-01..07 (cold chain) | 7 | Extend (fields exist; **fix the live submission block first, Phase 0**) | Build new | M |
| SM-CT-01/02 (custom text) | 2 | Extend | Build new | S |
| SM-HV-01 (high-value/alt samples) | 1 | Extend | Build new | S |
| SM-CALL-15/16 (submit → disbursement, unlock) | overlaps Phase 2 | Extend | Build new | — |

**Sequencing note:** do not build the barcode/signature/mass-add UI before Phase 3's eligibility rules and Phase 2's lot/transaction model exist on the client — this phase is the "front end" for those, not independent of them.

---

## Phase 5 — Consent & Remote

Original scope: opt-in in-person + remote link/QR site, remote sampling.

**What already exists (Reuse/Extend):** `ConsentCaptureView.swift`'s `SignatureSheet` is a real, working in-person consent-plus-signature capture screen (channel toggles, live Canvas pad, 21 CFR Part 11 attestation copy) — the closest existing precedent for in-person opt-in and, with real stroke validation added, for Phase 4's signature work too.

**What's missing (Build new — the largest single infrastructure gap in the audit):** no Experience Cloud, Salesforce Site, or any guest-user-accessible surface exists anywhere in the org. No token-signing/expiry/single-use scheme exists (nothing to secure, because nothing exists). No real push-notification channel exists on iOS (`LocalNotificationService` is local-only, no APNs entitlement). The schema anticipates remote signing (`Signature_Type__c` picklist values) but nothing populates or reads them.

| IDs | Count | SF Reuse | iOS Reuse | Effort |
|---|---:|---|---|---|
| SM-OPT-01..05 (in-person opt-in) | 5 | Extend (Consent__c pattern) | Extend (`ConsentCaptureView` pattern) | M |
| SM-OPT-06..12 (remote opt-in) | 7 | **Build new — Experience Cloud/Site from zero** | Build new (pending list, push) | XL |

**Sequencing note:** the Experience Cloud/Site build-out here directly unblocks Phase 4's SM-SIG-09 (Remote Sampling) — consider building the guest-user infrastructure once, shared by both.

---

## Phase 6 — UCPMP

Original scope: rules engine pack, valuation engine, counters, 2% dashboard, disclosure wizard + PDF/Excel, submission workflow, complaint evidence pack, retention.

**What already exists (Reuse/Extend — the second-strongest phase for SF reuse, after Phase 2):** `SampleLimitChecker`/`SampleLimitSeeder`/`SampleLimitGuardService` implement the 12-pack rule correctly and are tamper-resistant — the single best-built subsystem in the audit. `UCPMPComplianceService.getExpenditureSummary()` computes the 2%-cap dashboard correctly. **`UCPMPDisclosureController.cls`/`UCPMPDisclosureForm.page` already generate a real Annexure PDF whose methodology text matches the spec's demo fixture almost verbatim** — extend this into a persisted/versioned record rather than building a new generator.

**What's missing:** the valuation engine lacks the FY-scoped average-price/provisional-vs-final machinery Circular 3/2025 requires (SM-PRD-05 price master doesn't exist). The ₹1,000 informational-item cap and authorized-receiver enforcement are absent. The disclosure has no persisted/versioned/lockable backing record (SM-DIS-04) — every generation today is a stateless PDF render. No deadline/reminder/escalation, association-membership tracking, or complaint-evidence-pack generator exists. **On iOS, every one of the 16 UCPMP rules is MISSING or CONFLICTING** — most urgently SM-UC-05's wrong hardcoded cap (Phase 4 fixes the symptom; this phase owns the correct rule the client should mirror).

| IDs | Count | SF Reuse | iOS Reuse | Effort |
|---|---:|---|---|---|
| SM-UC-01..04, 06..10, 13..16 | 12 | Extend (mostly fields + validation rules) | N/A mostly (server-authoritative) | M |
| SM-UC-05 (12-pack limit) | 1 | **Reuse as-is** | Build new (mirror only, per SM-IOS-03) | S (SF) / M (iOS) |
| SM-UC-11/12 (2% cap, valuation) | 2 | Extend (price master needed) | N/A | L |
| SM-DIS-01..06 (disclosure) | 6 | **Extend — real generator exists, needs persistence layer** | N/A (admin/web only) | L |

**Sequencing note:** SM-PRD-05 (price master, Phase 1) is a prerequisite for SM-UC-11/12's provisional-vs-final variance logic — don't start that sub-item until Phase 1's data-model work lands.

---

## Phase 7 — Allocations, Inventory Orders, Reports, Integrations, Guides, Regression

Original scope unchanged. **What already exists:** `SampleAllocationService.applyDisbursements()` tracks consumption correctly, but only after the fact — over-allocation is never blocked. RCPA's Personal Order Booking flow (`RCPAViews.swift`, `POBLine`) is a structurally similar rep-initiated product+qty order UI, directly adaptable for Inventory Order lines, and `AccountsView.swift`'s search/filter pattern is a ready template for the Inventory Order Lines search bar (SM-IO-02). **What's missing:** `Sample_Allocation__c`'s own page layout is missing most of its fields (Period_Start__c, Allocated_To_User__c, etc. all absent) — the object is currently non-functional for admins via the standard page. No Named Credential precedent exists anywhere in the org for the license-vendor/ERP/fulfilment-vendor integrations this phase calls for.

| IDs | Count | SF Reuse | iOS Reuse | Effort |
|---|---:|---|---|---|
| SM-ALC-01..04 | 4 | Extend (consumption tracking exists; add blocking + real layout) | N/A (admin/web only) | M |
| SM-IO-01..03 | 3 | Build new (adapt RCPA POB pattern) | Build new | M |

Plus: reports/dashboards, integration hardening (first Named Credential in the org), `ADMIN_GUIDE.md`/`USER_GUIDE.md`, full regression, `REQUIREMENTS_TRACEABILITY.md` at 100%.

---

## Overall Effort Summary

| Phase | SF characterization | iOS characterization | Rough effort |
|---|---|---|---|
| 0 (new) | Fix conflicts + decisions | Fix conflicts | M |
| 1 Foundation | Extend + Build new (settings, ledger) | Build new | L |
| 2 Inventory Core | **Strongest reuse phase** — Extend | Build new (entire phase) | L |
| 3 Licensing & Eligibility | Build new (Address, MLP) + Extend (eligibility engine) | Build new (entire phase) | XL |
| 4 Call Sampling (iPad) | Extend | **Build new (entire phase)** | L |
| 5 Consent & Remote | Build new (Experience Cloud) | Build new | XL |
| 6 UCPMP | **Second-strongest reuse phase** — Extend | Build new (mirror only) | L |
| 7 Allocations/Reports/Integrations | Extend + Build new | Build new | M |

**Net read:** Salesforce work is dominated by *Extend* and *Refactor* (a real engine exists to build on, with specific conflicts to fix first), while every iOS phase is *Build new* — the client has no lot, transaction, licensing, rules-engine, barcode, or real-signature capability to extend anywhere in the codebase. Plan iOS effort and timeline independently from the (more favorable) Salesforce reuse picture; don't let SF's head start create an unrealistic expectation for how fast the iPad side can follow.
