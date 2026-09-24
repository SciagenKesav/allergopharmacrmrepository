# Sciagen CRM — Sample Management Pre-Build Audit: Gap Report

**Audit date:** 2026-09-24. **Scope:** all 238 requirement IDs in `docs/samples/BUILD_SPEC.md`, assessed separately for the Salesforce backend (`~/Documents/SciagenCRM-Salesforce`) and the iPadOS SwiftUI app (`~/Documents/SciagenCRM-iPadOS-OldOrg`), against the live `sciagen-sandbox` org. Read-only throughout — no source file, org record, or metadata was created, modified, deployed, or deleted. `sf apex run test` was not run (it can write data); see `06_org_commands_to_run.md`.

This report is the narrative companion to `03_gap_matrix.csv` (238 rows, one per requirement ID, machine-verified for complete coverage — see the Coverage Verification section below).

---

## Executive Summary

**Readiness (EXISTS = 1 point, PARTIAL = 0.5 point, out of 238):**

| Platform | Score | Readiness % |
|---|---|---|
| **Salesforce backend** | 58.0 / 238 | **24.4%** |
| **iPad app** | 8.5 / 238 | **3.6%** |

The honest framing: this is not a green-field build, but it is much closer to green-field than the phrase "some sample-ledger/disclosure code may already exist" (from the build prompt itself) suggests for the *iPad app specifically*. On Salesforce, a real, non-trivial sample-inventory engine already exists — lots, transactions, eligibility checks, a 12-pack UCPMP limiter, and a working disclosure-PDF generator that matches the spec's own demo-fixture clue text almost verbatim. On iOS, essentially nothing does: the client has no lot, transaction, or inventory concept anywhere, and its one visible "sample limit" feature is a hardcoded, non-UCPMP, non-blocking display value that could be mistaken for the real rule if not looked at closely.

**Top 10 gaps (highest blast-radius, across both platforms):**
1. **SM-LIC-01 and everything downstream of it** — no Address object exists; licensing is flat on Account. Root cause blocking ~20 of the 37 licensing/eligibility IDs.
2. **SM-MYS-01 "My Samples" hub** — the single biggest missing user-facing surface; nothing to extend on either platform.
3. **SM-MLP-01..10 (mid-level practitioners)** — the entire collaborative-relationship/supervising-physician/DEA-validation subsystem is completely absent.
4. **SM-BAR-01..09 (barcode scanning)** — 100% absent on both platforms; no VisionKit, GS1 parsing, or activity log.
5. **Remote signing/opt-in (SM-SIG-09, SM-OPT-06..09)** — zero Experience Cloud/Site infrastructure and no real push-notification channel exist to build on.
6. **SM-INV-01..07 (physical sample-inventory counts)** — the entire object model (`Sample_Inventory__c`) doesn't exist.
7. **SM-RR-01..05 (Rep Roster)** — entirely absent, which cascades into ship-to address auto-fill, Return-To validation, and setup-wizard steps.
8. **SM-IOS-01/03/04 (iPad data model + rules engine + screens)** — essentially nothing exists on the client to extend; this is the single largest XL item in the whole audit.
9. **SM-DIS-04 (disclosure persistence)** — every "generation" is a stateless, unlocked, unversioned PDF; no backing record exists.
10. **SM-CFG-01..25 (configuration)** — no `Sample_Setting__mdt` exists at all; none of the 25 admin-tunable settings are implemented.

**Top 5 conflicts (things that actively contradict the spec, not just absent):**
1. **SM-LIC-01** — license data lives flat on Account on *both* platforms, not per-Address; blocks the multi-state licensing model the spec requires.
2. **SM-UC-05 on iOS** — the client shows a hardcoded, non-UCPMP yearly sample cap (48/36/60 packs by product) instead of the legal 12-pack limit, and it's display-only — doesn't block submission. This is the single most dangerous finding in the whole audit because it could be mistaken for "the UCPMP rule is implemented" at a glance.
3. **SM-LOT-02** — `Sample_Lot__c.Initial_Quantity__c` lets an admin seed on-hand quantity directly, contradicting the spec's "quantity only enters via Receipt/Transfer" inventory-control principle.
4. **SM-AUD-01** — Field History Tracking is *explicitly disabled* on `Sample_Lot__c`, `Sample_Transaction__c`, and `Call_Visit_Report__c` — the exact objects the spec requires it on.
5. **SM-UNL-02/03** — unlocking a submitted call never reverses or re-posts the original Disbursement transaction; an edited sample line after unlock silently diverges from stock/ledger reality.

**Top 5 things that are surprisingly reusable:**
1. **`SampleEligibilityService.cls` / `SampleTransactionService.cls`** — a genuinely well-designed core engine: FEFO lot assignment, hypnotic/sedative/tranquillizer hard-blocking (with a UCPMP clause citation baked into the error message), cold-chain gating, row-locking for concurrent transfers.
2. **`SampleLimitChecker`/`SampleLimitSeeder`/`SampleLimitGuardService`** — the 12-packs-per-drug-per-HCP-per-year rule is the single strongest result in the whole audit: genuinely company-wide counting, tamper-resistant (can't be deleted, relaxed, or raised).
3. **`UCPMPComplianceService`/`UCPMPDisclosureController`/`UCPMPDisclosureForm.page`** — a real, working Annexure PDF generator whose auto-drafted methodology text ends in the exact clue sentence from the audit brief: *"Source: Sciagen Sample Management ledger."* Architecturally capable of reproducing the demo fixture; just unseeded and untested.
4. **Batch Lot ID transfer carry-over (SM-TRF-05)** — `SampleTransactionService.landTransfersIn()` implements the spec's match/overwrite/create-new logic essentially verbatim.
5. **The `ContentDocument`-Id signature-storage pattern** (`Call_Visit_Report__c.Signature_Image__c`) — already sidesteps the spec's own 32KB-truncation warning. (Note: `RCPA_Audit__c.Chemist_Signature__c` uses the *anti-pattern* — a base64 image in a LongTextArea — and must not be copied.)

---

## Summary Table by Spec Section

Status counts (SF: EXISTS/PARTIAL/MISSING/CONFLICT/N-A — iOS: same order). No `UNVERIFIED` status was used anywhere in the final matrix — every one of the 238 IDs was resolved to a concrete finding by reading actual source, with the single exception of Apex test coverage percentages (addressed narratively in §3 below, not as a per-ID status).

| Spec Section | N | SF: E/P/M/C/N | iOS: E/P/M/C/N |
|---|---:|---|---|
| §1 Concepts | 3 | 0/2/1/0/0 | 0/1/2/0/0 |
| §2 Regulatory Rules (US-PDMA pack) | 9 | 1/2/6/0/0 | 0/2/7/0/0 |
| §3.1 Data Model / Product Catalog | 6 | 1/3/1/1/0 | 0/1/5/0/0 |
| §3.2 Data Model / My Setup | 2 | 0/1/1/0/0 | 0/0/2/0/0 |
| §3.3 Data Model / Rep Roster | 5 | 0/0/5/0/0 | 0/0/5/0/0 |
| §3.4 Data Model / Sample Lot | 4 | 0/2/1/1/0 | 0/0/3/0/1 |
| §3.5 Data Model / Sample Transaction | 1 | 0/0/0/1/0 | 0/0/0/0/1 |
| §4 Config Settings | 25 | 0/11/14/0/0 | 0/0/25/0/0 |
| §5 Setup Flow | 7 | 1/4/2/0/0 | 0/1/2/0/4 |
| §6.1 My Samples | 4 | 1/1/2/0/0 | 1/0/3/0/0 |
| §6.2 Transfer | 7 | 4/1/2/0/0 | 0/0/7/0/0 |
| §6.3 Receipt | 5 | 1/2/2/0/0 | 0/0/4/0/1 |
| §6.4 Return | 3 | 0/1/1/1/0 | 0/0/3/0/0 |
| §6.5 Adjustment | 4 | 1/3/0/0/0 | 0/0/4/0/0 |
| §6.6 Unlock | 3 | 0/1/1/1/0 | 0/0/2/0/1 |
| §7 Licensing | 20 | 2/4/13/1/0 | 0/0/17/1/2 |
| §8 Mid-Level Practitioners | 11 | 0/1/10/0/0 | 0/0/9/0/2 |
| §9 Controlled Substances | 6 | 2/1/3/0/0 | 0/0/6/0/0 |
| §10.1-10.2 Calls with Samples | 16 | 1/10/5/0/0 | 0/1/15/0/0 |
| §10.3 Barcode Scanning | 9 | 0/1/5/0/3 | 0/0/9/0/0 |
| §10.4-10.7 Signature Capture | 15 | 0/4/9/0/2 | 0/1/12/1/1 |
| §11 Sample Opt-In | 12 | 1/4/7/0/0 | 0/4/5/0/3 |
| §12.1 Cold Chain | 7 | 1/3/2/0/1 | 0/0/6/0/1 |
| §12.2 Custom Text | 2 | 0/1/1/0/0 | 0/0/2/0/0 |
| §12.3 High-Value/Alt Samples | 1 | 0/1/0/0/0 | 0/0/1/0/0 |
| §12.4 Allocations | 4 | 0/1/3/0/0 | 0/0/0/0/4 |
| §12.5 Inventory Orders | 3 | 0/0/3/0/0 | 0/0/3/0/0 |
| §13 Sample Inventory | 7 | 0/0/7/0/0 | 0/0/6/0/1 |
| §14 Security/Sharing | 4 | 0/3/0/0/1 | 0/0/2/1/1 |
| §15 Audit Trail | 4 | 0/0/3/1/0 | 0/0/1/0/3 |
| §16 IN-UCPMP Rules | 16 | 2/9/5/0/0 | 0/1/14/1/0 |
| §17 UCPMP Disclosure | 6 | 0/1/5/0/0 | 0/0/0/0/6 |
| §19 iOS Architecture | 7 | 0/0/0/0/7 | 0/3/2/2/0 |
| **Total** | **238** | 19/78/120/7/14 | 1/15/184/6/32 |

---

## High-Risk Area #1 — Inventory Integrity

Can `Calculated_Quantity`-style fields be changed outside a controlled service? Mostly no — `Sample_Lot__c.Available_Quantity__c` is written only from `SampleTransactionService.afterSave()`, and the mobile permission set grants reps **read-only** access to `Sample_Lot__c`. But `Sample_Lot__c` also carries a directly-settable `Initial_Quantity__c` field with its own validation rule — this conflicts with the spec's explicit "no initial quantity field on a lot" requirement (SM-LOT-02, CONFLICT) and lets a Sample Admin seed on-hand quantity outside the Receipt/Transfer flow.

Is there a ledger? Not an append-only one. No `Sample_Ledger_Entry__c`-equivalent object exists anywhere. `Sample_Transaction__c` does the ledger's job today but is an ordinary, directly-mutable object: a user holding `Manage_Sample_Inventory` can still edit a posted transaction directly, with no automatic reversing entry and no hash chain to detect tampering.

Could an offline retry double-decrement stock? This is a real, concrete risk given the current design. The iOS push layer has no formal outbox/idempotency-key mechanism for *new* record creation. `SampleDropService.createTransactions()` guards against re-processing the *same* `Sample_Drop__c` row twice, but a second, distinct insert with identical content would sail through as a legitimate new disbursement. This risk is currently latent (the iOS client has no lot concept to exercise it) but will become live the moment a lot-aware offline sample flow is built without adding a client-UUID idempotency key.

Are transactions immutable after submit? **No — this is the sharpest finding in the whole audit.** `SupportUnlockService.unlock()` only flips the CVR's status back to `Saved`; it never touches any `Sample_Transaction__c`/`Sample_Drop__c` record. If a rep unlocks a call, edits the quantity or lot on an existing sample line, and resubmits, the original Disbursement transaction is neither reversed nor re-posted, and the edited values are never reflected anywhere. On-hand lot quantity and the ledger silently diverge from what the call now says was given out. This is exactly what SM-UNL-03 exists to prevent, and it is not implemented at all today.

## High-Risk Area #2 — License Model

The license model is per-Account, not per-Address, and **no Address object exists at all** — confirmed by an empty search for any `*Address*` object in the schema. All licensing fields live flat on `Sciagen_Account__c`; the iOS `HCP` struct mirrors this exactly. This is a direct CONFLICT with SM-LIC-01, and it is the root cause behind roughly two-thirds of the 37 licensing/eligibility IDs.

There *is* a status lifecycle, but it doesn't match the spec's New/Sampled/Valid/Expired/Invalid model — `License_Verification_Status__c` has `Unverified`/`Verified`/`Invalid`/`Expired`/`Pending`, missing both `New` and `Sampled`, so the entire one-time-sample-drop workflow is unimplemented. What does exist is genuinely good: `HcpLicenseExpiryBatch.cls` is a real, already-scheduled daily job correctly flipping Verified→Expired, and a `Sample_Eligible__c` formula field is a close, portable analogue of the spec's "License Valid To Sample" formula.

There is no propagation logic across same-state addresses, because there is nothing to propagate across — a targeted search for an `AddressLicenseService` class found nothing, and none of SM-LIC-17/18/19/20's copy/delete-cascade/update-cascade behaviors exist in any form.

## High-Risk Area #3 — Signature Capture & Storage

The receiving schema is better than the spec's own benchmark-truncation warning implies: `Call_Visit_Report__c.Signature_Image__c` stores a `ContentDocument` Id, not raw base64 — already sidestepping the 32KB truncation trap. (By contrast, `RCPA_Audit__c.Chemist_Signature__c` uses exactly the anti-pattern the spec warns against — a base64 PNG in a LongTextArea — and must not be copied into the new module.)

But the actual capture pipeline for samples doesn't exist end to end on either platform. No SHA-256/hash field exists anywhere in the org. A real lock/unlock mechanism exists on `Call_Visit_Report__c`, but it's generic to call submission, not signature-driven — none of the four recapture-matrix branches (SM-SIG-12..15) exist. Most importantly: **nobody writes the signature image.** `SampleDropService.cls` *reads* `CVR__r.Signature_Image__c` to snapshot it, but no Apex class was found that creates the `ContentVersion` in the first place. On iOS, the CVR's "Capture Signature" action is a one-line stub that appends a boolean flag — no drawing surface, no image, no stroke data. Two *real* signature pads exist elsewhere (Consent, RCPA) but are DragGesture/Canvas-based (not PencilKit), enforce no minimum point-count or stroke-length, and — critically — never push stroke data to Salesforce at all, only signer metadata.

**Bottom line:** the storage design is sound and reusable; everything upstream of it is missing.

## High-Risk Area #4 — UCPMP Compliance

The rules engine that exists is real and uneven in a way that tracks exactly which clauses are easy to code versus which need a richer data model. The **12-packs-per-drug-per-HCP-per-year rule (SM-UC-05)** is the strongest result in the whole audit: a hard-block, non-deletable `Sample_Limit__c` record counts usage from completed disbursements **by HCP+Product regardless of which rep performed them** — genuinely company-wide, exactly as the clause requires — with tamper-resistant guard rails blocking any attempt to delete, relax, or raise it.

The 3-patient-pack rule and smallest-market-pack rule have the fields but no validation rule cross-checking them. The "not for sale" legend is half-real (the disbursement statement mentions it, but nothing gates lot *activation* on it). The hypnotic/sedative/tranquillizer block works mechanically at two independent enforcement points, but rides on a generic "restricted" checkbox rather than a dedicated therapeutic classification — if an admin leaves it unticked on a genuinely hypnotic product, nothing stops it being sampled. The 2% cap and 5.1(g) valuation are partially built (a working dashboard, real per-transaction value snapshotting) but lack the FY-scoped average-price and provisional-vs-final machinery Circular 3/2025 requires. The ₹1,000 informational-item cap and authorized-receiver model are simply absent.

**On the iPad side, every one of these 16 rules is either MISSING or actively CONFLICTING.** The only "sample limit" logic on device is a hardcoded, non-UCPMP, display-only cap on exactly 3 named products (48/36/60 packs — not the legal 12), computed from incomplete local history, and it does not block Save/Submit. This is the single most consequential finding in the whole audit: if this were ever mistaken for "the UCPMP rule is implemented on iPad," a rep could offline-drop far more than 12 packs with no client-side error.

## High-Risk Area #5 — UCPMP Annexure Disclosure

Contrary to what "find the code that produced it" might suggest, **this is not a dead end.** A working, non-trivial disclosure generator exists: `UCPMPDisclosureController.cls` + `UCPMPDisclosureForm.page` (Visualforce, `renderAs="pdf"`) render the Annexure; `UCPMPComplianceService.generateDisclosureForm(fy)` calls `getContentAsPDF()`; `UCPMPComplianceController.generateDisclosure(fy)` saves the result as a `ContentVersion` File. The auto-drafted methodology paragraph ends in **the exact sentence the audit's clue is built around: "Source: Sciagen Sample Management ledger."**

Data sources are correct by construction: company-profile fields come from a Hierarchy Custom Setting (`UCPMP_Tenant_Config__c`, currently 0 records — every value renders blank today); the free-samples line aggregates `Sample_Expenditure_Tracking__c`, counting `COUNT_DISTINCT(HCP_Account__c)` where packs given > 0 — precisely the spec's "distinct HCPs given ≥1 sample pack" definition. The valuation formula matches clause 5.1(g) as coded, but without the FY-scoped average-price/provisional-vs-final machinery the clause requires. PDF generation is real and working, but education-programme lines are explicitly left blank for manual completion, and the DSC line renders empty — this is a **draft worksheet for a human to file externally**, confirmed by the page's own footer ("...Review before filing.").

**Reproducibility:** the arithmetic would reproduce the demo fixture *if fed matching data*, but none of that data exists today — `UCPMP_Tenant_Config__c` and `Sample_Expenditure_Tracking__c` both have 0 rows, and no test class exists for any UCPMP class. What's genuinely missing, not just untested: no persisted/versioned/lockable disclosure record (SM-DIS-04 — every generation is a stateless re-render), no deadline/reminder/escalation model, no association-membership/submission-workflow tracking, no configurable extension-date mechanism.

## High-Risk Area #6 — Offline/Online Rule Parity

This is the dominant, cross-cutting theme of the entire audit, not an edge case. **Every rule that exists at all today exists only on the server.** Concretely:

- The one sample-limit check visible on the client (`UserDataStore.samplesUsedThisYear`) sums only from on-device CVR history, can under-report, and — critically — is **display-only**: nothing gates `save()`/`submit()` on it, and the push payload for `Sample_Drop__c` sends only `{CVR__c, Product__c, Qty__c}`, giving the server no lot/limit context at all. Today's actual behavior: the app lets a rep believe a sample was successfully logged, and the server can silently reject it on sync, with no evidence the client surfaces that rejection back to the rep in a recoverable way — the textbook violation of the spec's own "server is authoritative... the iPad can never create a compliant-looking record the server would reject" rule (§0.5 of the build spec).
- FEFO lot assignment, cold-chain breach-blocking, hypnotic/sedative blocking, and sample opt-in expiry all exist only server-side with zero client mirror — a rep has no way to know offline whether a drop will be rejected until sync.
- Controlled-substance signature requirements (SM-CS-03/06) are solidly enforced server-side but the iOS product model carries no `Is_Controlled_Substance__c`/`Requires_Signature__c` field at all to even recognize a line as controlled.

Building the "shared Swift rules engine mirroring server rules" (SM-IOS-03) is a prerequisite most of the offline-parity requirements in §7-13 implicitly depend on.

## High-Risk Area #7 — Sharing & Permissions

Can reps see/edit other reps' lots or transactions? OWD on both `Sample_Lot__c` and `Sample_Transaction__c` is Private — but unlike `Sciagen_Account__c`/`Planned_Call__c`/`RCPA_Audit__c`, which all have dedicated Apex-managed-sharing trigger/service pairs, **no equivalent exists for either sample object.** Absent a role hierarchy grant, visibility is governed only by owner + role hierarchy (the live role hierarchy itself is UNVERIFIED from source — no `roles/` directory is tracked). The mobile permission set gives reps read-only on lots and create/read/edit (no delete) on transactions — a sensible design — while Sample Admin gets full CRUD + View/Modify All. Net effect: reps most likely cannot see each other's data today, which is the right default, but should be explicitly confirmed live before the new module assumes it, since `SampleTransactionService.cls` is deliberately `without sharing` for the cross-owner writes a transfer requires — a controlled bypass for one mechanic, not a general visibility grant.

Is there an auditor read-only persona today? No — no `Sample_Auditor` permission set exists anywhere, and there's no physical-inventory-count object for an auditor to reconcile against.

**A related, structurally important finding:** `Consent__c` has Private OWD but zero Apex-managed sharing, and both broadly-assigned rep permission sets grant `viewAllRecords=true` on it — so Private OWD on HCP consent/PII is effectively moot today. This isn't one of the 238 IDs directly, but `Sample_Consent__c` in the full spec is architecturally adjacent, and the same mistake shouldn't be repeated.

## High-Risk Area #8 — Remote Signing

There is **no Experience Cloud, Salesforce Site, or any other guest-user-accessible surface anywhere in this org** — confirmed by an empty search across `experiences/`, `networks/`, `sites/`, `digitalExperiences/` (only the stock, unconfigured app-launcher tiles exist). The schema *anticipates* remote signing — `Sample_Transaction__c.Signature_Type__c` has `In_Person`/`Remote_Link`/`Remote_QR` picklist values — but nothing populates or consumes them.

Consequently there is no token scheme, no expiry window, and no single-use enforcement to evaluate — none of that infrastructure exists to be secure or insecure. `LocalNotificationService.swift` is confirmed local-only with no APNs entitlement anywhere, so "rep sees a confirmation (push + in-app)" (SM-OPT-08) currently has no push half at all. This is the largest single net-new build item identified anywhere in the audit (rated XL for both SM-OPT-07 and SM-SIG-09).

---

## §3 Code Quality & Platform Health Findings

Full detail in `03_code_quality.md`. Headlines that materially affect how the new module should be built:

- **Trigger framework:** consistent "thin trigger → static service method" pattern across 22 existing triggers, safe to extend — but `Call_Visit_Report__c` already has two independently-ordered triggers; a third (for samples) has no framework enforcing sequencing.
- **Bulkification — one real, concrete violation:** `SampleDropService` → `SampleEligibilityService` → `SampleLimitChecker.usage()` issues one SOQL query per applicable `Sample_Limit__c`, per sample-drop row, unbatched. With the 4 default seeded limits, a call report with 8-10 sample lines could push a single transaction to 80-150+ SOQL queries — uncomfortably close to the 100-query governor limit. **Fix before extending this path.**
- **Sharing — the single most relevant finding given the module's "strict sharing" requirement:** 56% of non-test Apex classes (40 of 72) are `without sharing`, including essentially the *entire* existing sample engine. Zero use of `Security.stripInaccessible`/`SECURITY_ENFORCED` anywhere in the org, and only partial `USER_MODE` coverage even in the one `with sharing` entry point. Sharing/FLS enforcement today happens only at the very top (one LWC controller); any new module entry point must replicate that pattern explicitly rather than assume the service layer underneath protects anything.
- **No hard-coded Ids** — clean.
- **Test quality is genuinely good** (real, value-specific assertions across the sample domain) but 8 classes — including `UCPMPComplianceService`, `UCPMPComplianceController`, `UCPMPDisclosureController`, `SampleLimitGuardService` — have **no dedicated test class at all**.
- **Swift concurrency and error handling are sound** — `@MainActor` correctness is real (if not compiler-enforced, since the project is Swift 5.0, not Swift 6 strict concurrency), zero unguarded force-unwraps in data-parsing paths, sync errors are consistently logged rather than swallowed.
- **API version drift:** `sourceApiVersion` is 67.0, but 100% of the existing `Sample_*`/`UCPMP*` Apex classes are pinned at 62.0 — building new metadata at the current version will create a third version tier inside the sample domain unless the older classes are deliberately re-pinned.
- **No Process Builder/Workflow Rule debt** — clean; all automation is Apex.
- **Blank slate for integration and scanning:** no Named Credential precedent anywhere in the org (the one outbound callout uses a raw API key in a query string); no barcode/GS1 capability on the client at all; `Sample_*` objects are absent from the existing `Sync_Object_Config__mdt` sync-policy table.

---

## Data Migration Needs

1. **`Product__c.Product_Type__c`** is free Text, already populated on all 12 live records with values unrelated to the spec's taxonomy (Detail/Sample/Alt-Sample/BRC/Promo/HV-Promo/Reprint) — introducing the real taxonomy means migrating these 12 values, not a green-field add.
2. **License fields off `Sciagen_Account__c` onto a new Address object** — 41 of 152 Account records currently have `License_Number__c` populated; these need a migration path onto per-address rows once the Address object exists.
3. **`License_Verification_Status__c` values need remapping, not just copying** — `Unverified` → the spec's `New` semantics aren't equivalent (New specifically means "eligible for a one-time drop"), and `Pending` (currently unused by any Apex found) needs a decision.
4. **`Sample_Lot__c.Initial_Quantity__c`** (SM-LOT-02 conflict) — the field exists but the object has 0 records in this sandbox, so removing/repurposing it is low-risk *here*, but any environment with seeded lots via this field needs a migration plan first.
5. **`Return_To__c`** — currently free Text with 0 existing records; converting to a validated picklist needs a value-set design, low-risk only because there's no data yet.
6. **iOS local cache/blob migration** — `UserDataStore`'s single JSON blob embeds `HCP.licenseNumber` flat and signature/consent PII directly; moving to per-Address licensing and/or an encrypted store needs an explicit version-bump migration path so no rep's unsynced local records are silently lost.
7. **Field History Tracking retroactivity** — turning on `enableHistory` does not create history for past changes; a hash-chained ledger needs a one-time "genesis" bootstrap entry before any further transactions are trusted.

## Breaking-Change List

1. **UCPMP valuation source swap:** `UCPMPComplianceService.cls` currently reads `Product__c.Sample_Unit_Value_INR__c` directly. Adding a proper FY-versioned price master (SM-PRD-05) changes where the *already-shipped* 2%-cap compliance dashboard sources its numbers — needs a staged, dual-read cutover.
2. **Unlock actor model change:** the existing unlock mechanism is a Support-agent ticket workflow (`Support_Request__c`), not a direct Sample-Admin action as the spec implies. Building to the spec literally is a process/permission change for existing Support Console users.
3. **`Return_To__c` free-Text → picklist** is additive in this empty sandbox but breaking for any org with real Return history.
4. **Renaming `License_Verification_Status__c` values** breaks `HcpLicenseExpiryBatch.cls` and `SampleEligibilityService.cls`'s hardcoded string comparisons unless updated simultaneously.
5. **Renaming `Product__c.Is_Restricted__c`/`Restriction_Reason__c`** to the spec's `Therapeutic_Restriction__c` breaks the hypnotic/sedative/tranquillizer block silently unless both call sites (`SampleTransactionService.cls`, `SampleEligibilityService.cls`) are updated together.
6. **Cold-chain sample lines are currently un-submittable through the only UI that creates them** — `SampleDropService.beforeInsert` hard-blocks any cold-chain product missing tag/status fields the `cvrSampleDrops` LWC never renders. This is already broken for any live cold-chain product, not a future regression — flag for immediate attention regardless of the wider build timeline.
7. **Replacing UserDefaults-blob persistence with SwiftData (SM-IOS-01)** touches `UserDataStore`/`AccountStore`, which every other feature (CVR, RCPA, expenses, leave, KAM) depends on — an app-wide architecture change, not an isolated module addition.
8. **Rebuilding the CVR "Capture Signature" stub into a real capture flow** changes behavior for live users — today it's zero-friction; a real flow with padlock/biometric-unlock/point-count validation correctly adds friction that didn't exist before. Flag in rollout communications.
9. **Introducing a persisted, versioned `UCPMP_Disclosure__c` record (SM-DIS-04)** changes the disclosure feature from "stateless re-render on demand" to "stateful, lockable record" — a workflow change for whoever currently just re-clicks "generate."

## Open Questions For You

These are the decisions that actually block starting Phase 1 — not a general wishlist:

1. **Address object design:** should HCP licensing move to a genuinely new `Address__c`-equivalent child object (matching the spec exactly, largest effort), or should the existing flat Account fields be kept as a denormalized "primary state" convenience alongside a new Address child (smaller migration, some duplication)? This decision gates ~20 of the 37 licensing IDs and the mid-level-practitioner subsystem.
2. **Sharing/FLS posture:** the existing sample engine is `without sharing` end-to-end by design (transfers need to touch another rep's lots). Should the new module keep that pattern (enforce only at entry points, as it does today) or go stricter? This is a real architectural decision, not just a bug to fix — "strict sharing" per the build spec's working rules needs a concrete design, not just an intention.
3. **Unlock/reversal semantics:** should unlock start reversing/re-posting ledger entries (SM-UNL-03) as a standalone fix *before* the wider module build, given it's a live data-integrity gap today? Or is it acceptable to bundle into the broader Phase 3/6 work?
4. **UCPMP_Tenant_Config__c seeding:** who owns entering the real company profile (CIN, PAN, domestic sales revenue) and will the demo fixture (₹250 crore sales, "Allergopharma (demo)") be used for initial testing, or should a genuine dry-run be seeded immediately?
5. **US-PDMA pack priority:** the build spec marks this pack "optional, inactive by default," and this audit found it roughly as unbuilt as IN-UCPMP-specific requirements. Confirm it stays deprioritized relative to the default jurisdiction, since several Phase 2-3 IDs (SM-REG-*) would otherwise compete for the same engineering time.
6. **Existing cold-chain break:** given finding #6 in the breaking-change list (cold-chain products are already un-submittable through the live web form if any exist in production), should this be patched immediately as a standalone hotfix, independent of and before the wider Sample Management build?
7. **API version re-pin:** should the 101 existing `Sample_*`/`UCPMP*` classes pinned at API v62.0 be re-pinned to the current version (67.0+) as part of Phase 1, to avoid a permanent three-tier version split in the sample domain?

---

## Coverage Verification

`03_gap_matrix.csv` was assembled by merging the four parallel sub-audits' CSVs and verified programmatically:
- **238 data rows**, one per requirement ID in `BUILD_SPEC.md`.
- **0 missing IDs** (every one of the 238 unique `SM-*` IDs extracted from the spec appears in the matrix).
- **0 extra IDs** (no row references an ID not present in the spec).
- **0 duplicate IDs.**
- Every row has exactly the 10 required columns (`Req_ID,Area,Requirement_Summary,SF_Status,SF_Evidence,iOS_Status,iOS_Evidence,Reuse_Recommendation,Effort,Risk_Notes`), confirmed via a Python `csv` round-trip parse (catches any ragged row from unescaped commas/quotes).
