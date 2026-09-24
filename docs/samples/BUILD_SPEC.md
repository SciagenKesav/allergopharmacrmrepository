# Claude Code Prompt — Sciagen CRM: Sample Management Module (full build)

> Paste everything below this line into Claude Code, run from the root of the Sciagen CRM monorepo (Salesforce SFDX project + iPad SwiftUI app).

---

## 0. Your role and how to work

You are the lead engineer building the **Sample Management** module for **Sciagen CRM**, a life-sciences field CRM.

- **Backend:** Salesforce (SFDX source format, Apex, custom objects, Custom Metadata, Permission Sets, LWC for admin/web screens, Apex REST for the mobile client, Experience Cloud / Salesforce Site for remote HCP signing).
- **Field client:** native **iPad app in SwiftUI** (iPhone layout must also work), **offline-first**, syncing to Salesforce.

The functional scope comes from three sources, summarised in full in this prompt:
1. A Veeva CRM "Samples Management – CSM Education" deck (release up to 21R3.2). This is the **functional benchmark**: build equivalent capability under **Sciagen's own naming and design**. Do **not** copy Veeva object/field/setting API names (`*_vod`), branding or UI assets.
2. India's **Uniform Code for Pharmaceutical Marketing Practices (UCPMP) 2024**, as amended up to **Circular No. 3 of 2025 (dated 1.9.2025)**. This is the **primary compliance jurisdiction** (default).
3. A sample **UCPMP Annexure disclosure output for FY 2026-27** that the product must generate (exact format in §17).

**Working rules**
1. **Explore first.** Before writing code, inspect the repo: existing objects (Account, Address, Call/Visit, Product, User, Territory), naming conventions, namespace/prefix, trigger framework, sync layer, SwiftUI architecture, test setup. Some sample-ledger/disclosure code may already exist (the disclosure sample says "Source: Sciagen Sample Management ledger"). **Extend, don't duplicate.** Write your findings to `docs/samples/00_repo_findings.md`.
2. **Plan.** Produce `docs/samples/01_design.md` (data model, ERD in Mermaid, sync design, rules engine, screen map) and wait for my approval before large-scale generation.
3. **Traceability is mandatory.** Every requirement below has an ID (e.g. `SM-LIC-07`). Maintain `docs/samples/REQUIREMENTS_TRACEABILITY.md`: requirement ID → Salesforce metadata/Apex class → Swift file(s) → test(s) → status. **No requirement may be silently dropped.** If something is out of scope or not applicable to a jurisdiction, mark it explicitly with the reason.
4. Build in the phases in §22. After each phase: run all Apex tests (≥ 90% coverage on new classes, meaningful asserts), Swift unit + UI tests, update the traceability file, and summarise what changed.
5. **Server is authoritative.** Every compliance rule is enforced in Apex (trigger/service layer) **and** mirrored on iPad for offline UX. The iPad can never create a compliant-looking record that the server would reject; if it does (stale offline data), the server rejects it and the app surfaces a clear, recoverable error.
6. Use Custom Metadata Types for configuration, Custom Labels for every user-facing message (translatable), Permission Sets (not profiles) for access, and a single trigger-per-object framework.
7. Ask me before: introducing a managed-package namespace, changing existing objects' OWD/sharing, or deleting anything.

---

## 1. Concepts and definitions

- **SM-GEN-01 Sample:** a unit of a prescription drug not intended for sale, given to promote the drug. (US: 21 CFR Part 203 / PDMA. India: UCPMP clause 5.1(ii) "free samples".)
- **SM-GEN-02 Sampling channels — all must be supported:**
  - Rep hand-carried disbursement on a call (electronic signature; also record paper-based signature cards with Sample Card ID).
  - **BRC (Business Reply Card) / Sample Order:** HCP requests; a third-party fulfilment vendor direct-ships to the HCP (Sample Order Transactions).
  - **Direct-ship to HCP.**
  - **Vouchers / co-pay cards.**
  - **Alternative Sample:** a sample product that does **not** require a lot number to disburse (e.g. voucher, co-pay card); needs a valid license status **and** a signature.
  - **Promotional items** and **High-Value Promotional Items** (medical books, anatomical models, demo devices) that need an HCP signature.
  - **Controlled substances** (special rules, §9).
  - **Reprint / educational literature** fulfilment (literature request → fulfilment vendor), logged against the call.
- **SM-GEN-03 Jurisdiction rule packs.** Implement a rules engine driven by Custom Metadata `Sample_Jurisdiction_Rule__mdt` keyed by country (and state where relevant):
  - **`IN-UCPMP` (default, active):** all UCPMP rules in §16.
  - **`US-PDMA` (optional pack, inactive by default):** PDMA written request + signature, State License Number (SLN) validation, DEA/CDS for controlled substances, PDMA vs non-PDMA products, Sunshine Act high-value item flags.
  - **Consent-based countries (e.g. Brazil):** sample opt-in (§11).
  - A country/org can have several packs active. Every validation in this prompt must say which pack(s) it belongs to.

---

## 2. Regulatory rules the system must enforce

### 2.1 US-PDMA pack (from the benchmark)
- **SM-REG-01** Every disbursement needs a written/electronic **request from the HCP**.
- **SM-REG-02** HCP must be **licensed to prescribe the product in that state**.
- **SM-REG-03** The company verifies the HCP's **State License Number** (SLN).
- **SM-REG-04** A **detailed receipt** of each disbursement comes back to the company (the signed e-signature record + transaction).
- **SM-REG-05** The e-signature capture page must show: HCP name, title, credentials, license #, call date, call address, samples disbursed/requested, quantity, manufacturer, distributor (for BRCs), and the disclaimer text.
- **SM-REG-06 PDMA vs non-PDMA products:** flag per product. For **non-PDMA** products (e.g. cosmetics not FDA-regulated), neither Sample Card ID nor Signature Date is required to submit a call with samples.
- **SM-REG-07 State nuances:** state-specific rules (e.g. Michigan mid-level practitioners) via `Sample_State_Setting__mdt` / data records (§8).
- **SM-REG-08 Expired SLN grace period:** optional, **off by default**, clearly marked non-compliant with PDMA. If enabled, store both the **actual expiration date** and a **grace-period date**; allow sampling only until the grace date; report every grace-period drop.
- **SM-REG-09 One-time sample drop:** see §7.4.

### 2.2 IN-UCPMP pack — see §16 (detailed).

---

## 3. Data model (Salesforce)

Create or extend the following. Use the repo's naming convention; names below are indicative. Enable **Field History Tracking** on every compliance field, and log all changes to the immutable ledger (§15).

### 3.1 Product catalog — extend `Product_Catalog__c` (or existing product object)
- **SM-PRD-01** Record types / Product Type picklist: `Detail`, `Sample`, `Alternative Sample`, `BRC`, `Promotional Item`, `High Value Promotional Item`, `Reprint/Literature`.
- **SM-PRD-02** `Parent_Product__c` — Sample (and BRC/Alt Sample) products must point to their **Detail** product.
- **SM-PRD-03** Flags: `Cold_Chain__c`, `Custom_Text_Enabled__c` (+ `Custom_Text_Required__c`), `Controlled_Substance__c`, `Controlled_Schedule__c` (multi-select, e.g. CII–CV), `PDMA_Regulated__c`, `Virtual_Lot_Enabled__c`, `Requires_Signature__c`, `Lot_Required__c` (false for Alternative Samples).
- **SM-PRD-04 UCPMP fields:** `Dosage_Form__c` (tablet/capsule/vial/gram/ml/other), `Strength__c`, `Units_Per_Sample_Pack__c`, `Smallest_Market_Pack_Units__c`, `Sample_Pack_Units__c` (must be ≤ smallest market pack; validation rule), `Free_Sample_Legend_Confirmed__c` (pack is marked "free medical sample not for sale" or analogous legend; required = true before a lot can be activated), `Therapeutic_Restriction__c` (picklist incl. `Hypnotic`, `Sedative`, `Tranquillizer`: such products **can never be sampled** in IN-UCPMP), `Source_Type__c` (`Manufactured In-house` / `Purchased from Supplier` / `Third-party Manufactured`), `Max_Patients_Per_Pack__c` (default 3), `Course_Of_Treatment_Units__c`, `Eligible_Prescriber_Credentials__c` (who is "qualified to prescribe" this product), `Is_Medical_Device__c` (UCPMP 14.2: code applies to devices mutatis mutandis).
- **SM-PRD-05 Price master** `Sample_Price__c`: product, FY, `Price_To_Stockist_Per_Unit__c`, `Purchase_Price_Per_Unit__c`, `Annual_Average_Price_Per_Unit__c`, effective dates, source (ERP), approved by/on. One active price per product+dosage form+strength+FY.
- **SM-PRD-06 Informational items (UCPMP 5.1(i)):** `Unit_Value_INR__c` on promotional items; server rejects any "other items for professional use" item valued **> ₹1,000 per item**; items must have no independent commercial value (checkbox attestation by admin).

### 3.2 User product access — `My_Setup_Product__c`
- **SM-SET-01** Junction of User ↔ Detail product: which Detail products a user may detail on calls. Admin screen: search user → edit their "My Setup" → select products.
- **SM-SET-02** Samples offered on a call are limited to Samples whose parent Detail product is in the user's My Setup **and** (if enabled) Territory Allowed Products (TSF-equivalent) **and** not blocked by Account Restricted Products or State Product Restrictions.

### 3.3 Rep Roster — `Rep_Roster__c`
- **SM-RR-01** One per sampling user: HR info (employee ID, hire/termination date), territory relationship, **ship-to / sample storage address** (usually the rep's storage locker; can be multiple storage locations with one primary), asset tag.
- **SM-RR-02** `Username_External_Id__c` must **exactly match** the User's Salesforce username. Validation + nightly job flags mismatches, because address auto-population on transfers depends on it.
- **SM-RR-03** Roster address is the compliance record of where the rep stores samples; address changes are history-tracked and require a reason.
- **SM-RR-04** Non-user roster records for **Return To** destinations (e.g. `HQ`, `Warehouse-Mumbai`), one per Return-To picklist value.
- **SM-RR-05** "View Signatures" action on Rep Roster → all signatures captured **by that user**, with Printable View → PDF.

### 3.4 Sample Lot — `Sample_Lot__c` (OWD **Private**; users see only lots they own)
- **SM-LOT-01** Fields: Sample product, `Lot_Number__c`, `Expiration_Date__c` (nullable), `Active__c`, `Calculated_Quantity__c` (running on-hand, maintained only by transaction service — never user-editable), `Batch_Lot_Id__c` (barcode payload, **case-sensitive**, admin/integration edit, end-user read), `Is_Virtual_Lot__c`, `U_M__c`, owner.
- **SM-LOT-02** Admin-owned lots are the **master lot catalog** (can also be imported / integrated from ERP). No "initial quantity" field on a lot; quantity only enters via Receipt/Transfer.
- **SM-LOT-03** `Sample_Lot_Item__c` child with record type `TagAlert` for cold-chain tag alert numbers (§12.1).
- **SM-LOT-04** A lot becomes **Active** for a user when they confirm receipt (subject to `Enable_Receipt_Activation`, §4.3).

### 3.5 Sample Transaction — `Sample_Transaction__c` (one object, record type per type, own page layout per type)
Record types: `Receipt`, `Transfer`, `Return`, `Adjustment`, `Disbursement`, `Inventory Variance` (system-generated from counts, optional).
Common fields: lot, product, quantity, U/M, transaction date, owner, status (`Draft/Submitted/Pending Receipt/Confirmed/Rejected/Voided`), reason, comments, `Custom_Text__c`, `Tag_Alert_Number__c`, `Cold_Chain_Status__c`, `Transferred_From__c` (User lookup), `Transferred_From_Name__c` (text, for distribution centre / person), `Transferred_To__c` (User lookup), `Transferred_To_Name__c` (text: recipient outside the system), ship address fields (auto from Rep Roster), `Return_To__c` picklist, `Adjust_For__c` (lookup to original transaction/call), `Call__c`, `Account__c`, `Unit_Value_Snapshot__c`, `Value_Snapshot_INR__c`, `Price_Basis__c`, `Ledger_Hash__c`.
- **SM-TXN-01** Best practice encoded in help text: for internal rep-to-rep transfers use the **lookup** fields; use the **text** fields only for parties outside the system.

### 3.6 Sample Receipt — `Sample_Receipt__c`
- **SM-RCP-01** Created for the recipient whenever a Transfer is submitted to them or a shipment is integrated from warehouse/ERP. Shows in **Pending Sample Receipts**. Fields: expected qty, confirmed qty, lot, `Transferred_From_Name__c`, tag alert, cold chain status, custom text, discrepancy flag.

### 3.7 Inventory — `Sample_Inventory__c` + `Sample_Inventory_Item__c`
- **SM-INV-01** Header (user, count date, type: `Periodic`, `Post-Receipt`, `Audit`, `Termination`), items per active lot: system qty vs counted qty, variance.

### 3.8 Call extensions — existing Call/Visit object
- `Call_Sample__c` child lines (product, lot, qty, type: Sample/BRC/Alt Sample/Promo/HV Promo, `Barcode_Scanned__c`, custom text, tag alert, cold chain status, ship-to address for BRC, delivery status).
- Call-level: `Signature__c` reference, `Signature_Date__c`, `Sample_Card_Id__c` (paper), `Signature_Location_Lat/Long__c`, `Signee_Account__c` (after swap), `Received_By_First/Middle/Last_Name__c` (authorized receiver), `Received_By_Relationship__c`, `Supervising_Physician__c` (lookup to Account Authorization) + snapshot fields `Supervising_Physician_Name__c`, `_Credentials__c`, `_License__c`, `Request_Receipt__c`, `Receipt_Email__c`, `Barcode_Scan_Used__c` (call-level flag for reporting), `Locked__c`, `Unlocked_By__c`, `Unlock_Reason__c`, `Sample_Disclaimer_Text__c` (snapshot of disclaimer shown).

### 3.9 Licensing on Address — extend `Address__c` (not Account)
See §7. Fields: `State__c`, `License_Number__c`, `License_Expiration_Date__c`, `License_Grace_Date__c`, `License_Status__c` (New / Sampled / Valid / Expired / Invalid), `License_Valid_To_Sample__c` (formula), `Sample_Status__c` (Valid/Pending/Invalid → green/yellow/red), `DEA_Number__c`, `DEA_Expiration_Date__c`, `DEA_Status__c`, `DEA_Address__c` (checkbox), `DEA_Schedules__c` (multi-select), `CDS_Number__c`, `CDS_Expiration_Date__c`, `CDS_Status__c` (Valid/Invalid), India: `Registration_Council__c` (State Medical Council / NMC / Dental Council / etc.), `Registration_Number__c`, `Registration_Year__c`, `Qualification__c`, `Validation_Source__c`, `Last_Validated_On__c`.

### 3.10 State / credential settings (data records, admin-maintained)
- `Sample_State_Setting__c`: state, `CDS_Required__c`, `State_Product_Restrictions`, `Collaborative_Agreement_Required_Credentials__c`, jurisdiction.
- `Sample_State_Credential_Setting__c`: state × credential (NP, PA, …) → requires supervising physician (Y/N), may sign for samples (Y/N).

### 3.11 Account Authorization — `Account_Authorization__c` (record type `Collaborative Relationship`, plus `Authorized Receiver` for UCPMP)
See §8.

### 3.12 Consent — `Sample_Consent__c` (multichannel consent equivalent)
See §11.

### 3.13 Sample limits — `Sample_Limit__c`
Account and/or user, product (or Detail group), quantity limit, period (start/end or rolling), limit type (per disbursement / per period), jurisdiction source (`UCPMP-12-packs`, company policy, etc.), disbursed-to-date roll-up, remaining.

### 3.14 Allocations and inventory orders
- `Product_Order_Allocation__c` (start/end date, product, detail, user/territory, allocated qty, used qty).
- `Inventory_Order__c` + `Inventory_Order_Line__c` (rep sample re-order requests to HQ/warehouse).

### 3.15 Disclosure — `UCPMP_Disclosure__c` (+ `UCPMP_Disclosure_Line__c`), Company Profile — `Company_Compliance_Profile__c`
See §17.

### 3.16 Ledger & logs
- `Sample_Ledger_Entry__c` (append-only, §15), `Mobile_Activity_Log__c` (barcode scan start/complete times, success/failure, device, app version), `Integration_Log__c`.

---

## 4. Configuration settings (Custom Metadata `Sample_Setting__mdt`, overridable per profile/user via hierarchy custom setting)

Implement each; default in brackets.
- **SM-CFG-01** `Disable_Sample_Receipt_Default` [false] — when false, Confirmed Qty defaults to expected qty; when true, the user must type the received quantity per line.
- **SM-CFG-02** `Enable_My_Samples_Login` [false] — shows a user lookup on My Samples so a manager/admin can view My Samples **on behalf of** another user (read or act per permission; every action records both acting and on-behalf user).
- **SM-CFG-03** `Enable_Receipt_Activation` [true] — whether a lot created by a transfer is Active immediately or only after receipt confirmation.
- **SM-CFG-04** `Enable_Expiration_Filter` [true] — lots with expiration date < today cannot be selected (list, manual, or barcode).
- **SM-CFG-05** `Tag_Alert_Regex` [`^[0-9]{10}$`] — format validation for cold-chain tag alert numbers.
- **SM-CFG-06** `Sample_Lot_Qty_Warning_Threshold` and **SM-CFG-07** `Sample_Lot_Exp_Warning_Threshold` (days) — trigger warning icons.
- **SM-CFG-08** Labels `Sample_Lot_Qty_Warning_Text` / `Sample_Lot_Exp_Warning_Text` — each accepts one parameter `{0}` replaced by **quantity remaining** / **expiration date**.
- **SM-CFG-09** `Enable_Samples_On_Sign_Save`, **SM-CFG-10** `Enable_Samples_On_Save`, **SM-CFG-11** `Disable_Sign_Button` — govern signature recapture (§10.7).
- **SM-CFG-12** `Allow_One_Time_Sample_Drop` [false for IN, true for US pack] — see §7.4.
- **SM-CFG-13** `License_Grace_Days` [0 = disabled].
- **SM-CFG-14** `Enable_Dual_License_Check` [true] — controlled substances require both DEA valid and state license valid.
- **SM-CFG-15** `Enable_Account_Restricted_Products`, **SM-CFG-16** `Enable_Territory_Allowed_Products`, **SM-CFG-17** `Enable_State_Product_Restrictions`.
- **SM-CFG-18** `Enable_Sample_Limits`, `Sample_Limit_Mode` (warn / block).
- **SM-CFG-19** `Enable_Sample_Opt_In`, `Opt_In_Validity_Mode` (`Calendar Months` | `Rolling`), `Opt_In_Validity_Months`.
- **SM-CFG-20** `Require_Signature_For_Controlled_Even_With_Opt_In` [true].
- **SM-CFG-21** `Enable_Signature_GPS_Stamp`, `Enable_Receipt_Email`, `Approved_Email_Template_Id`.
- **SM-CFG-22** `UCPMP_Year_Basis` [`Financial Year Apr–Mar`] or `Rolling 12 months`, used for the 12-packs-per-drug-per-HCP rule; document the choice for compliance sign-off.
- **SM-CFG-23** `UCPMP_Sample_Value_Cap_Pct` [2.0], `UCPMP_Cap_Alert_Thresholds` [50,75,90,100].
- **SM-CFG-24** `Unlock_Call_Policy` (`Require Second Signature` | `Adjustment Only` | `Both Allowed`).
- **SM-CFG-25** `Allocation_Date_Lookback_Years` [1].

---

## 5. End-to-end setup flow (admin) — "Manual Sample Setup" in 7 steps

Build a guided **Sample Setup Wizard** (LWC) that does these in order, and a seed-data script (`scripts/samples/seed.apex`) that does the same for demo/test orgs:
- **SM-SETUP-01** Create the **Detail** product and the **Sample** product (Type = Sample, Parent = Detail).
- **SM-SETUP-02** Give users access to the Detail product via **My Setup** (All Tabs → My Setup → edit each user → select products).
- **SM-SETUP-03** Create a **Rep Roster** for each sampling user (Username External ID = SFDC username; address = storage locker).
- **SM-SETUP-04** As Sample Admin, create the **Sample Lot(s)** (All Tabs → Sample Lots → New), or import the lot catalog.
- **SM-SETUP-05** **Transfer** samples to each user (My Samples → New Transfer; address auto-fills from Rep Roster).
- **SM-SETUP-06** User **confirms receipt** of the shipment (My Samples → Pending Sample Receipts → Confirm → Confirmed Qty → Save) → inventory updated, lot activated.
- **SM-SETUP-07** User records **calls with active sample products**.

The wizard shows a readiness checklist per user (My Setup ✓, Roster ✓ with matching username ✓, active lots ✓, first inventory count ✓).

---

## 6. Sample transactions and "My Samples"

Lifecycle: Warehouse ships lots to company HQ → **Transfers** (Sample Admin owns the shipment, transfers lots to each rep) → **Receipts** (rep confirms, in Sciagen or via integration from another sampling system) → **Disbursements** (to HCPs) → **Adjustments** (reconcile system vs actual) → **Returns** (unusable samples, e.g. rain-damaged) → **Inventories** (counts) → **Audit** (Sample Admin / third-party auditor audits disbursements and inventories).

### 6.1 My Samples (iPad screen + LWC web tab)
- **SM-MYS-01** Single hub for sample tasks: On-hand by lot (qty, expiry, warnings), **Pending Sample Receipts**, **Sample Inventories**, links **New Transfer / New Return / New Adjustment / New Inventory / View Transactions**, Inventory Orders, Allocations.
- **SM-MYS-02** **View Transactions**: every transaction type (Receipts, Adjustments, Transfers, Returns, Disbursements), filter by type/date/lot/product/status, drill into record-type-specific layouts.
- **SM-MYS-03** On-behalf-of lookup when `Enable_My_Samples_Login` = true.
- **SM-MYS-04** Disbursement transactions are **never created manually**; they are created when a Call with samples is **submitted (or saved, per config)**.

### 6.2 Transfer
- **SM-TRF-01** From-user's lot `Calculated_Quantity__c` is decremented immediately on submit; cannot go below zero.
- **SM-TRF-02** To-user gets a Pending Sample Receipt; the new lot is activated on confirmation (per SM-CFG-03).
- **SM-TRF-03** Ship-to address auto-fills from the recipient's Rep Roster (via Username External ID). If none found, block with a clear message.
- **SM-TRF-04** Transferring to someone outside the system uses `Transferred_To_Name__c` (text).
- **SM-TRF-05 Batch Lot ID carry-over:** On transfer submit, search the recipient's lots for a match on **Lot # + Sample + Owner (recipient)**. No match → create a new lot for the recipient including the transferred lot's `Batch_Lot_Id__c`. Match → **overwrite** the existing lot's Batch Lot ID with the transferred lot's. Active/inactive per `Enable_Receipt_Activation`.
- **SM-TRF-06** Cold-chain products require Tag Alert # and/or Cold Chain Status at transfer (§12.1).
- **SM-TRF-07** Custom text capturable at transfer (§12.2).

### 6.3 Receipt
- **SM-RCP-02** Confirm with Confirmed Qty (default per SM-CFG-01). If confirmed ≠ expected, require a discrepancy reason and auto-create a notification to Sample Admin; inventory updated by the **confirmed** qty.
- **SM-RCP-03** Receipts may originate from integration (warehouse/ERP/third-party sampling system) with `Transferred_From_Name__c` = distribution centre.
- **SM-RCP-04** Cold chain + custom text capturable at receipt.
- **SM-RCP-05** After confirming, prompt the user to submit an inventory count (best practice, SM-INV-03).

### 6.4 Return
- **SM-RET-01** My Samples → New Return. `Return_To__c` picklist is admin-configurable; **a Rep Roster record must exist for each Return-To value** (validation).
- **SM-RET-02** Reason (damaged, expired, recalled, termination, excess, other), decrements lot qty, cold chain + custom text capturable.
- **SM-RET-03** Expired and recalled lots: bulk "Return all" action.

### 6.5 Adjustment
- **SM-ADJ-01** My Samples → New Adjustment. Used when a lot is misplaced or a call recorded the wrong lot/quantity. Adjusts `Calculated_Quantity__c` by a signed quantity. Example to cover in tests: rep dropped 3 but logged 2 → adjustment of −1 (inventory reduced by 1 more). Help text must make the sign convention unmistakable.
- **SM-ADJ-02** `Reason__c` picklist admin-modifiable (lost, stolen, damaged, data-entry error, count variance, other). Theft/loss reasons trigger a Sample Admin alert (and, US pack, a significant-loss report workflow).
- **SM-ADJ-03** Adjustments above a configurable threshold require manager/admin approval (Salesforce Approval Process).
- **SM-ADJ-04** Cold chain + custom text capturable.

### 6.6 Unlock call (post-signature corrections)
- **SM-UNL-01** If a rep submits a signed call with the wrong lot/qty, only a **Sample Admin** can unlock it (reason required, audit-logged).
- **SM-UNL-02** Behaviour follows `Unlock_Call_Policy`: (a) re-open samples section and **require a second HCP signature**; or (b) leave call locked and require an **Adjustment** linked to the call; or both allowed with admin choice. Show the customer-compliance note in the admin UI: "Verify the business process and compliance rules before unlocking."
- **SM-UNL-03** Unlock reverses and re-posts ledger entries; never edits history in place.

---

## 7. HCP license validation

### 7.1 Principles
- **SM-LIC-01** License data lives on **Address**, not Account, because an HCP may practise in several states and needs a valid license in each. (India: configurable scope. State Medical Council registration can be state-scoped, NMC/Indian Medical Register national-scoped; `Sample_Jurisdiction_Rule__mdt.License_Scope__c` = `State` | `National`.)
- **SM-LIC-02** Licenses are normally validated by a **third-party vendor** (US: e.g. Knipper, QPharma; India: council registry or data vendor). Build an inbound integration (Bulk API upsert keyed on external ID) that sets status, number, expiry, `Validation_Source__c`, `Last_Validated_On__c`.
- **SM-LIC-03** HCP must be **qualified to prescribe the product** (UCPMP "shall not be supplied to any person who is not qualified to prescribe such a product"). Check the HCP's credential/qualification against `Eligible_Prescriber_Credentials__c` on the product.

### 7.2 Fields and behaviour
- **SM-LIC-04 License #:** state license number for that address's state; maintained automatically across all addresses of the account in the same state.
- **SM-LIC-05 License Expiration Date:** same automatic maintenance.
- **SM-LIC-06 License Status:** same automatic maintenance.
- **SM-LIC-07 License Valid To Sample:** formula (Valid/Invalid) deciding if the account can receive and sign for samples at that address: status ∈ {Valid} and expiration ≥ today (or ≤ grace date if grace enabled), or status = New and one-time drop allowed and not yet used.
- **SM-LIC-08 Sample Status indicator:** Valid = **green**, Pending = **yellow**, Invalid = **red**. Shown on Account header, Address list, and at the top of the Call (for the call address's state).

### 7.3 License status definitions
- **SM-LIC-09 New:** set when a rep creates a new HCP; license not validated; HCP may receive **one** one-time sample drop.
- **SM-LIC-10 Sampled:** one-time drop done; **no further samples until validated**.
- **SM-LIC-11 Valid:** validated by third party; can be sampled normally.
- **SM-LIC-12 Expired:** cannot be sampled (except grace, SM-REG-08).
- **SM-LIC-13 Invalid:** cannot be sampled.
- **SM-LIC-14** Nightly batch: move Valid → Expired when expiration < today; notify owning reps; recompute Sample Status.

### 7.4 One-time sample drop
- **SM-LIC-15** When enabled: the **New Account wizard** lets reps enter license # and expiration; status = New; exactly **one** sample disbursement allowed; on submit, status → Sampled; further sampling blocked until vendor validation.
- **SM-LIC-16** When disabled: the New Account wizard **hides/blocks** license # and expiration entry.

### 7.5 Control of license information (propagation rules; implement in Apex `AddressLicenseService`, bulk-safe, recursion-guarded)
- **SM-LIC-17** New address created **without** license info → search the account's other addresses in the **same state** for valid license info; if found, copy it to the new address; if no same-state address exists, leave blank.
- **SM-LIC-18** User **deletes** license info on an address → delete it from **all** other addresses of that account in the same state.
- **SM-LIC-19** User creates/updates an address **with** license info → copy to **all** the account's addresses in that state.
- **SM-LIC-20** Offline iPad applies the same rules locally; server re-applies on sync.

---

## 8. Mid-level practitioners and authorized receivers

### 8.1 Collaborative relationships (US pack)
- **SM-MLP-01** Support sampling to NPs and PAs in states where a collaborative relationship with a supervising physician (MD/DO) is required for the mid-level to sign for samples.
- **SM-MLP-02** `Account_Authorization__c` (Collaborative Relationship) fields: **Account** (mid-level), **Supervising Account** (physician), **Collaborative Relationship State**, **Start Date** (optional), **End Date** (optional), **Inactive** (checkbox).
- **SM-MLP-03** Create manually (Account Authorizations tab → New) **or** by bulk import (tab → Import wizard / Data Loader template). Provide a CSV template and an import LWC with validation preview.
- **SM-MLP-04** When a Call is created in a state where the account's credential requires a supervising physician (per `Sample_State_Credential_Setting__c`), show a **Supervising Physician** picklist on the call.
- **SM-MLP-05** Picklist options = Account Authorization records where: Account = call account; Collaborative Relationship State = state of call address; Inactive = false; Start Date blank or ≤ today; End Date blank or ≥ today.
- **SM-MLP-06** If the call contains a Sample, BRC or Alternative Sample, Supervising Physician is **required** to sign and submit. After signing it locks with the rest of the samples/promo section.
- **SM-MLP-07** Snapshot on call: Supervising Physician (lookup to authorization), Name, Credentials, State License # at time of call.
- **SM-MLP-08 Validation of the supervising physician** (block signature and submit if any fail):
  - Samples & Alternative Samples: physician's License Valid To Sample for the **call address state** = Valid.
  - BRCs: License Valid To Sample for the **ship-to address state** = Valid.
  - License Expiration ≥ today.
  - Controlled substances: DEA Status = Valid on the address matching the call address (Samples/Alt) or ship-to (BRC); DEA expiration ≥ today; DEA Address flag = true; DEA number passes the **DEA checksum algorithm**; if Dual License Check, License Valid To Sample = Valid; every selected controlled product's schedule ∈ address `DEA_Schedules__c`.
- **SM-MLP-09** Supervising physicians must sync to the iPad (visibility offline) even if outside the rep's territory. Add them to the sync scope automatically via the authorization records.
- **SM-MLP-10** Best practices: show **Associated Prescriber** on Account detail and Call layouts; add **Account Authorizations** related list and **Accounts (Associated Prescriber)** related list to the person-account page.

### 8.2 Authorized receiver (IN-UCPMP)
- **SM-MLP-11** UCPMP allows the sample to be handed "to the person qualified to prescribe … **or to a person authorized to receive the sample on their behalf**". Model `Account_Authorization__c` record type `Authorized Receiver` (HCP, receiver name, relationship/role, valid from/to, authorization document attachment). On the call, "Received by" = HCP (default) or an active authorized receiver; capture `Received_By_First/Middle/Last_Name__c`. The HCP's name and address are always recorded on the transaction.

---

## 9. Controlled substances

- **SM-CS-01 US pack:** in addition to SLN and DEA, some states require a **State Controlled Dangerous Substance (CDS)** license. Where `Sample_State_Setting__c.CDS_Required__c` = true, require `CDS_Status__c` = Valid and CDS expiration ≥ today on the call address. Error on Save/Submit if not. Admin configuration checklist (to include in the admin guide): admin edit / user read on CDS Required and CDS Status; state settings record per CDS state; FLS on CDS # and expiration; Valid/Invalid picklist values on the right address record types. **Open question to log in the design doc:** CDS number format per state (make regex configurable per state).
- **SM-CS-02** DEA checks as in SM-MLP-08, applied to the HCP themselves on every controlled-substance call.
- **SM-CS-03** **Signature always required** when the drop contains **at least one** controlled substance, even if the account has a valid Sample Opt-In and even if other lines are non-controlled (SM-CFG-20). Error text on Save/Submit explains why.
- **SM-CS-04** Equivalent of a "no sampling license & no signature required" section toggle: a call-layout-level config that marks sections where license/signature checks are skipped (non-PDMA/opt-in contexts); controlled substances override it.
- **SM-CS-05** Capture received-by first/last (middle optional) name on the acknowledgement for controlled drops.
- **SM-CS-06 IN-UCPMP:** products flagged **Hypnotic / Sedative / Tranquillizer** are **hard-blocked** from lots, transfers-to-reps, calls and BRCs (UCPMP 5.1(ii)(f)). Show which rule blocked it.

---

## 10. Calls with samples (iPad, SwiftUI) and electronic signature

### 10.1 Pre-checks
- **SM-CALL-01** Top of call shows the Sample Status indicator (green/yellow/red) for the **call address's state**. Red blocks adding samples (promo items still allowed unless restricted).
- **SM-CALL-02** Sample opt-in warning banner if consent required and missing/expired (§11).
- **SM-CALL-03** Supervising physician field when required (§8).

### 10.2 Samples & Promotional Items section
- **SM-CALL-04** **Mass add**: one screen to add multiple samples **and** promotional items at once (multi-select grid with quantity steppers).
- **SM-CALL-05** Lot picker ordering: lots with the **soonest expiration first**; lots **without** expiration **last**. Expired lots hidden when expiration filter on.
- **SM-CALL-06** Only the user's **active** lots with qty > 0; qty can't exceed on-hand.
- **SM-CALL-07** Warnings displayed **as icons above the Quantity field** (not beside it): sample-limit exceeded, lot quantity low (≤ threshold), lot expiring (≤ threshold days). Tapping an icon shows the message with the parameter filled in. Works offline on iPad and iPhone.
- **SM-CALL-08** Sample limits (§3.13) validated live and on submit (warn or block per config); state product restrictions validated too.
- **SM-CALL-09** Custom text entry per line where the product has it enabled (required/optional).
- **SM-CALL-10** Cold chain tag alert + status per line for cold-chain products (§12.1).
- **SM-CALL-11** BRC lines: ship-to address picker; license check against ship-to state; creates a Sample Order routed to the fulfilment vendor; status tracked (Requested → Sent to Vendor → Shipped → Delivered / Failed) = "Record Sample Delivery".
- **SM-CALL-12** Alternative Sample lines: no lot; still need valid license + signature.
- **SM-CALL-13** High-value promotional items: signature required; IN pack: ₹1,000 cap and "informational/educational only" validation.
- **SM-CALL-14** UCPMP checks per line (§16): 12-pack annual limit, pack-size/3-patient rule, no hypnotic/sedative/tranquillizer, HCP qualified to prescribe, legend confirmed.

### 10.3 Barcode scanning
- **SM-BAR-01** "Scan Barcode" button in the Samples section. Request camera permission on first use with a clear purpose string.
- **SM-BAR-02** Use VisionKit `DataScannerViewController` (fallback AVFoundation) supporting **1D and 2D** (incl. GS1 DataMatrix; parse GTIN/lot/expiry AIs where present). Position barcode in a white guide outline.
- **SM-BAR-03** On detection, match (case-sensitive) against `Batch_Lot_Id__c` of **all sample lots synced to the device**.
- **SM-BAR-04** Manual entry fallback when it can't scan.
- **SM-BAR-05** Confirmation sheet: show identified product/lot/expiry → enter quantity → **Add**.
- **SM-BAR-06** Validation on scanned lots: expiration filter; Account Restricted Products; Territory Allowed Products. On failure show an error and let the user scan another. Sample limits and state product restrictions still validate in the call.
- **SM-BAR-07** Supported only for sample products with **virtual lot numbers enabled** (config check; explain when not).
- **SM-BAR-08** Flag each line (and the call) as barcode-scanned for admin reporting.
- **SM-BAR-09** Log scan activity to `Mobile_Activity_Log__c`: scan start time, complete time, success/failure, error code, device, app version.

### 10.4 Signature page
- **SM-SIG-01** Displays the samples being dropped: **Product, Quantity, Distributed By** (company/distributor), plus the jurisdiction-required content (US pack: list in SM-REG-05; IN pack: HCP name, address, registration #, product, dosage form/strength, qty, date, "Free medical sample — not for sale" statement, rep name), and the configured **disclaimer** text (snapshot stored).
- **SM-SIG-02 Swap signee:** switch to another **valid** HCP who is affiliated with / in the account hierarchy of the call account. Re-run all license/eligibility checks for the new signee.
- **SM-SIG-03 GPS stamp:** optionally record location at capture (requires location permission; if denied, record "location unavailable", don't block unless config says so).
- **SM-SIG-04 Padlock:** tapping padlock hides **Accept / Cancel** so the HCP can't dismiss/accept; rep unlocks with device auth (Face ID/Touch ID/passcode).
- **SM-SIG-05** Capture with PencilKit. Validity: **≥ 3 data points and ≥ 100 px** stroke length. Too-short → "signature not valid".
- **SM-SIG-06 Storage:** the benchmark suffers truncation at a 32 KB field limit on long signatures. **Do better:** store as a ContentVersion (PNG) + compressed vector stroke JSON, with SHA-256 hash on the call; never truncate; enforce a sane max and show an error if exceeded rather than silently cutting.
- **SM-SIG-07 Email receipt:** "Request Receipt" checkbox + choose HCP email; after HCP signs and rep taps Accept, send an approved-template email receipt (queued offline, sent on sync). Log delivery.
- **SM-SIG-08 Lock:** after signature, samples/promo/supervising physician sections are locked.

### 10.5 Remote sampling
- **SM-SIG-09** Remote Sampling page lists pending remote requests; **More Actions** shows **Remote Sign** and **In Person Sign** with a signature icon next to each. Remote Sign sends an HCP link/QR (same infra as §11.2) to sign for a sample request/BRC.

### 10.6 Viewing signatures (admin)
- **SM-SIG-10** "View Signatures" on the Account's Calls related list → all signatures captured for that HCP; **Printable View** → PDF export.
- **SM-SIG-11** "View Signatures" on Rep Roster → all signatures captured by that user; Printable View → PDF.

### 10.7 Signature recapture rules (implement exactly; unit-test all branches)
- **SM-SIG-12** With **sample limits configured**: rep **cannot** clear/recapture the signature to adjust sample/BRC info before submit. With auto-sync the call syncs immediately on save, so there's no window. Show guidance before signing: "Make sure all sample details are correct before capturing the signature."
- **SM-SIG-13** Without sample limits and **all of** `Enable_Samples_On_Sign_Save`, `Enable_Samples_On_Save`, `Disable_Sign_Button` = false → cannot edit samples or recapture.
- **SM-SIG-14** Without sample limits and those settings = true → rep **can** clear signature, edit samples/BRC and have the HCP re-sign **before** submitting/syncing.
- **SM-SIG-15** Every recapture keeps the prior signature image in history (never deleted).

### 10.8 Submit
- **SM-CALL-15** On submit (or save, per config): server revalidates everything; creates Disbursement transactions; decrements lot quantities; snapshots unit price and value (§16.4); updates sample-limit and UCPMP counters; writes ledger entries; sets license status New→Sampled for one-time drops; queues receipt email.
- **SM-CALL-16** Paper-based fallback: record Sample Card ID + Signature Date + scanned card image (required unless non-PDMA).

---

## 11. Sample opt-in (consent)

### 11.1 In-person
- **SM-OPT-01** For countries where customers must consent to receive samples. Consent valid for a configured period: **calendar months** or **rolling** timeline.
- **SM-OPT-02** Indicator on the **Account** screen when signature/consent is required; alert on the **Call** screen.
- **SM-OPT-03** Capture: customer ticks consent and signs; show the validity period; save → back to Account.
- **SM-OPT-04** Record in `Sample_Consent__c`: account, channel, captured by, captured date, valid from/to, signature, method flags (`Captured_In_Person__c`, `Captured_Share_Link__c`, `Captured_QR_Code__c`), consent text version.

### 11.2 Remote opt-in (link or QR code)
- **SM-OPT-05** Entry points: Account → More Actions → Sample Opt-In, **or** the opt-in warning on the Call.
- **SM-OPT-06** Signature Set Up screen: choose method (**Share Link** via approved email/SMS/WhatsApp-if-enabled, or **QR Code**) → Next → prompts → share.
- **SM-OPT-07** HCP opens link/scans QR → Salesforce Site / Experience Cloud page (mobile-web, no login, signed single-use token, expires in N minutes) → reviews opt-in details → signs → **Accept**.
- **SM-OPT-08** Rep sees a confirmation (push + in-app, via Platform Event / polling); rep reviews the signature and either **Accepts** (creates consent record, sets method checkbox) or **Requests re-sign**.
- **SM-OPT-09** Improvement over the benchmark (where the rep must stay signed in until the HCP signs): the request persists server-side, so the rep can leave and accept later from a Pending Remote Signatures list.
- **SM-OPT-10** Prerequisites enforced: call sampling enabled + opt-in required config; FLS on the consent fields.
- **SM-OPT-11** Controlled substance drops still require a signature despite valid opt-in (SM-CS-03).
- **SM-OPT-12** Example scenario for a UI test: rep captures annual opt-in for Dr. A remotely via share link; afterwards she disburses samples without interruption for the validity period.

---

## 12. Additional features

### 12.1 Cold chain sampling
- **SM-CC-01** Cold-chain = hand-carried samples needing refrigeration (`Cold_Chain__c` on product).
- **SM-CC-02** Capture **Tag Alert Number** and **Cold Chain Status** at **Receipt confirmation, Call sample, Transfer, Return, Adjustment**.
- **SM-CC-03** iPad UX: arrow control opens **Tag Alert Number selection** (from `Sample_Lot_Item__c` TagAlert records for that lot, or new entry) → then **Cold Chain Status selection** (admin-defined values per object, e.g. OK / Excursion–Usable / Excursion–Quarantine).
- **SM-CC-04** Tag alert number validated by `Tag_Alert_Regex`.
- **SM-CC-05** Required-ness driven by layout config: either or both fields; if present on the layout they're validated.
- **SM-CC-06** Status "Excursion–Quarantine" blocks disbursement of that lot and prompts a Return.
- **SM-CC-07** Document in the admin guide: integration changes needed for the new fields and the regression/validation testing regulatory will need.

### 12.2 Custom text capture
- **SM-CT-01** Additional product info (e.g. voucher / co-pay card number for redemption tracking) captured at **Receipt, Disbursement, Transfer, Return**, and on the **Call** line.
- **SM-CT-02** Enabled per product; required vs optional configurable; label fixed ("Custom Text") but help text configurable; reportable (§18).

### 12.3 High-value promotional items & alternative samples
- **SM-HV-01** Special product types for **Sunshine Act** (US pack) transparency: HV promo items (books, models, demo devices) need HCP signature; Alternative Samples need valid license + signature. Include in transparency exports. IN pack: HV items limited per SM-PRD-06; gifts for personal benefit prohibited (UCPMP 8.1). Block any product flagged `Personal_Benefit__c`.

### 12.4 Allocations
- **SM-ALC-01** Product Order Allocation page **date filter** excludes allocations whose Start Date is more than `Allocation_Date_Lookback_Years` (1) before the **start of the current year**.
- **SM-ALC-02** Allocations sorted by **Start Date descending**; latest selected by default.
- **SM-ALC-03** **Allocation Product filter** shows only the products and Detail associated with the allocation.
- **SM-ALC-04** Allocation consumption decremented by disbursements/orders; over-allocation blocked.

### 12.5 Inventory orders
- **SM-IO-01** Rep creates Inventory Orders (re-supply) with lines; approval → warehouse/ERP integration → shipment → Receipt.
- **SM-IO-02** **Search bar** in the Inventory Order Lines section (visible when editing) filtering the product list on any term in the product name.
- **SM-IO-03** **Sortable columns** in Inventory Order Lines (tap header to sort asc/desc).

---

## 13. Sample inventory (physical counts)

- **SM-INV-02** New Inventory from My Samples → Sample Inventories → New Inventory: pre-populate all **Active** lots for the user with system qty; user enters counted qty; submit.
- **SM-INV-03** Best practice nudge: submit an inventory **immediately after confirming receipts**.
- **SM-INV-04** **Managers can create inventories for other users** (their reports); Sample Admin for anyone.
- **SM-INV-05** Variances: create Adjustment drafts (reason = Count Variance) needing approval; lock inventory after submit.
- **SM-INV-06** **Third-party auditors** get a read-only "Sample Auditor" permission set + audit inventory type; auditor counts can be entered via web.
- **SM-INV-07** Scheduled periodic counts (e.g. annual/semi-annual) with reminders and overdue escalation; mandatory termination count when Rep Roster termination date is set.

---

## 14. Security, sharing, PDMA-grade controls

- **SM-SEC-01** Permission sets: `Sample_Rep`, `Sample_Manager`, `Sample_Admin`, `Sample_Auditor` (read-only, all sample data), `Sample_Integration`, `UCPMP_Compliance_Officer`, `UCPMP_Executive_Signatory`.
- **SM-SEC-02** Sample Lot and Sample Transaction OWD Private; owner + role hierarchy (manager) + admin. Reps cannot edit `Calculated_Quantity__c`, cannot delete transactions, cannot edit submitted records.
- **SM-SEC-03** Submitted calls/transactions are immutable except via Admin Unlock / Adjustment paths.
- **SM-SEC-04** Device security on iPad: data encrypted at rest (Data Protection Complete), biometric re-auth for signature padlock and for opening app after idle timeout, jailbreak detection, remote wipe on deactivation.

---

## 15. Audit trail and data integrity

- **SM-AUD-01** Audit trail on **all sample orders and transactions**: Field History Tracking + append-only `Sample_Ledger_Entry__c` (who, when, device, before/after, reason) with a **hash chain** (each entry hashes the previous) and a nightly integrity verification job.
- **SM-AUD-02** Third-party auditors can perform inventory audits and reconcile ledger ↔ lots ↔ disbursements.
- **SM-AUD-03 Retention:** minimum **5 years**, or longer while any complaint/proceeding (ECPMP, ACPMP, court) is open. Legal-hold flag per HCP/product/period that blocks archival.
- **SM-AUD-04 Complaint evidence pack (UCPMP 10–11):** given a complaint (HCP, product, date range, rep), generate a pack within the 30-day response window: all disbursements, signatures, consent, license validation at time of drop, counts, ledger integrity proof, as PDF + CSV. Track complaint ID, received date, due date (received + 30 days), status.

---

## 16. IN-UCPMP rules (UCPMP 2024, updated 1.9.2025) — implement each as a named rule in the rules engine

- **SM-UC-01 (5.1(ii))** Free samples only to a person **qualified to prescribe** that product.
- **SM-UC-02** Rep-distributed samples handed **directly** to the prescriber or their **authorized receiver**; HCP **name and address recorded**.
- **SM-UC-03 (a)** Purpose limited to creating awareness of treatment options / acquiring experience. Record a purpose statement on the signature page and in product setup.
- **SM-UC-04 (b)** Pack limited to prescribed dosage for **≤ 3 patients** for the required course of treatment (validate `Units_Per_Sample_Pack__c` vs `Course_Of_Treatment_Units__c × Max_Patients_Per_Pack__c`, at product setup).
- **SM-UC-05 (b)** **≤ 12 sample packs per drug per HCP per year.** "Drug" = Detail/brand-molecule grouping (configurable: brand, or molecule+dosage form+strength). Count across **all reps, all channels (hand-carried, BRC, direct ship)**, company-wide. Enforce server-side at submit with real-time company-wide counters; offline iPad uses last-synced counters + local drops and warns when stale; server rejection path handled gracefully. Year basis per SM-CFG-22.
- **SM-UC-06 (c)** Each pack marked "free medical sample not for sale" (legend confirmation on product/lot before activation).
- **SM-UC-07 (d)** Pack ≤ **smallest pack in the market**.
- **SM-UC-08 (e)** Adequate **system of accountability and control**: covered by §6, §13, §15 (ledger, counts, reconciliation).
- **SM-UC-09 (f)** **No samples of hypnotics, sedatives or tranquillizers.**
- **SM-UC-10** Maintain per supply: **product name, doctor name, quantity, date of supply**, etc. Report available anytime (§18).
- **SM-UC-11** Monetary value of samples **≤ 2% of domestic sales per year**. Compliance dashboard: YTD value vs cap using `Domestic_Sales_Revenue__c` (entered by finance per FY, with provisional/final flag); alerts at configured thresholds; optional block at 100%.
- **SM-UC-12 (5.1(g) valuation, Circular 3/2025):**
  - Manufacturer's own samples: value **per unit** (per tablet/capsule/vial/gram/ml, etc.) at the **price charged to the stockist or immediate customer** for the **same dosage form and strength**.
  - Purchased from another supplier: **purchase price**.
  - Price recorded as the **average** price to stockist / average purchase price for the same dosage form and strength **on an annual basis**.
  - Implementation: at supply, snapshot `Unit_Value_Snapshot__c` from the current FY price master and compute **value = packs × units per pack × per-unit value**. At FY close, finance loads the final annual average; the disclosure engine recomputes with the final average and shows both (provisional vs final) with variance. Disclosure uses final.
- **SM-UC-13 (5.1(i))** Informational/educational items (books, calendars, diaries, journals incl. e-journals, dummy device models, clinical treatment guidelines, other professional-use items **≤ ₹1,000 per item**), no independent commercial value.
- **SM-UC-14 (8.1–8.4)** No gifts for personal benefit, no pecuniary advantage, travel, hospitality or cash grants via sample/promo channels: product types that could be misused are blocked.
- **SM-UC-15 (14.2)** Rules apply to medical devices as well (`Is_Medical_Device__c` products go through the same rules).
- **SM-UC-16 (4.4–4.5)** Rep compliance: on first login each FY, reps (including contract reps, flagged on Rep Roster) acknowledge the UCPMP code (store acknowledgement + version). Block sampling until acknowledged.

---

## 17. UCPMP annual disclosure (Annexure, clauses 5.1(g) & 14.4)

Build a **Disclosure Wizard** (LWC, compliance officer) that generates the exact Annexure form. Output **PDF** (matching the layout below) + **Excel**, versioned, lockable.

### 17.1 Company profile (`Company_Compliance_Profile__c`)
- 1(a) **CIN / FCRN**; 1(b) **Name of company/entity**; 1(c) **Registered office address**; 1(d) **Email**; 1(e) **PAN**. Validate CIN format (21 chars), PAN format (`^[A-Z]{5}[0-9]{4}[A-Z]$`), email.
- Association memberships (IPA, OPPI, IDMA, FICCI, other) with **"disclosing association"** (first chosen), date first disclosed, and history.

### 17.2 Form fields ("All fields are mandatory": the wizard blocks finalisation until every field is filled)
- **2. Return for the financial year** (e.g. `2026-27`, Apr 1–Mar 31).
- **3. Domestic sales revenues (in crore ₹)**: finance input, 4 decimals.
- **4. Particulars:**
  - **Free samples distributed (monetary value of sample packs)**: expenditure in crore ₹ (4 decimals) and **Number of recipient healthcare professionals** = distinct HCPs given ≥ 1 sample pack in the FY (auto from ledger).
  - **Education programmes organised directly by the company**: expenditure (crore ₹) + number of events.
  - **Education programmes organised through third parties (incl. associations, bodies)**: expenditure + number of events.
  - These two lines come from the Sciagen events/CME module if present (check the repo); otherwise manual entry with attachments. Footnote: *Education programmes include CME/CPD, conferences, workshops, training, seminars etc.* Note text: *Expenditure includes all expenses for the event: sponsorship, travel, lodging, hospitality, advertisements, stalls (incl. direct payments to third-party vendors), souvenirs, etc. For valuation: in-house production → price to stockist; third-party manufacturing → purchase price.*
  - **Remarks / methodology**: auto-drafted, editable, e.g.: *"Free samples are valued on a per-unit basis (tablet, capsule, vial, gram or ml) at the price charged to the stockist for the same dosage form and strength, or at the purchase price for products bought from another supplier (UCPMP 2024 clause 5.1(g)). Value of each hand-out = packs × units per pack × per-unit value, captured at the time of supply. Recipient healthcare professionals are the distinct doctors given at least one sample pack in the financial year. Total {packs} packs ({units} units). Source: Sciagen Sample Management ledger."*
- **Declaration** (3 statements verbatim: read the Code & info complies; company has complied and will continue to abide and assist authorities; info true to best of knowledge and belief), **Digital Signature Certificate** (DSC upload/signing hook: integrate with an e-sign/DSC provider interface, pluggable), **Designation**, **DIN or PAN of the executive head**, **Mobile**, **Email**.
- **For office use only:** eForm **SRN** and **filing date (DD/MM/YYYY)**, entered after submission.
- Footer: *"Prepared from Sciagen Sample Management on {dd MMM yyyy HH:mm}. Review before filing."*
- Demo fixture for tests (reproduce exactly): FY 2026-27, domestic sales 250.0000 crore, free samples 0.0001 crore, 1 recipient HCP, 3 packs (12 units), company "Allergopharma (demo)".

### 17.3 Submission workflow & rules
- **SM-DIS-01** Deadline: **within two months of FY end** (31 May). Reminders at 60/30/14/7/1 days; escalation to CEO (the **CEO is responsible for adherence**, 14.4).
- **SM-DIS-02** Submitted by the **executive head** (`UCPMP_Executive_Signatory` permission) to the **association** of which the company is a member (or uploaded on its website). If member of several: submit to **one**, record intimation to the others (generate intimation letters). Keep disclosing to the **same** association unless (i) membership ceases **and** (ii) the company decides to switch with intimation to **DoP** and the first association: enforce via workflow with required attachments.
- **SM-DIS-03** If not a member of any association → **DoP UCPMP portal** (record portal submission reference).
- **SM-DIS-04** Lock the disclosure after filing; amendments create a new version with reason; keep all versions ≥ 5 years.
- **SM-DIS-05** Drill-down: every number in the form links to the underlying ledger rows (HCP, product, date, qty, unit value).
- **SM-DIS-06** Transitional/extension dates configurable (e.g. FY 2024-25 was extended to 30.9.2025 by Circular 3/2025), so regulator extensions can be applied without code.

---

## 18. Reports & dashboards (Salesforce reports + iPad summary)

- Sample accountability: receipts vs disbursements vs returns vs adjustments vs on-hand, by rep/lot/product.
- UCPMP register: product, doctor, address, qty, date, value (SM-UC-10); 12-pack tracker per HCP per drug; 2% cap gauge.
- License: HCPs sampled with status, grace-period drops, one-time drops pending validation.
- Signatures: missing/invalid, recaptures, unlocks.
- Barcode adoption: % lines scanned, scan failures (from activity log).
- Cold chain excursions; custom-text (voucher/co-pay redemption); opt-in expiring in 30 days; inventory variances; overdue counts; allocations usage; expiring lots.

---

## 19. iPad app (SwiftUI) architecture

- **SM-IOS-01** Offline-first local store (SwiftData or Core Data, matching the repo) holding: user's lots, transactions, receipts, inventories, products, My Setup, accounts/addresses/licenses in territory + supervising physicians, authorizations, consents, limits & UCPMP counters, settings, labels.
- **SM-IOS-02** Sync engine: delta sync via Apex REST (`/sciagen/samples/v1/...`) or existing sync layer; outbox queue with idempotency keys (client UUID per record) so retries never double-decrement; auto-sync on save when online; conflict policy = server wins for compliance fields, with user-visible conflict messages.
- **SM-IOS-03** Shared Swift rules engine mirroring server rules (same rule IDs, same messages via synced labels); contract tests run the same JSON fixtures against Apex and Swift.
- **SM-IOS-04** Screens: My Samples hub; Pending Receipts; Transfer/Return/Adjustment forms; Inventory count; Transactions list; Call → Samples & Promo (mass add), Lot picker, Barcode scanner, Warning popovers, Signature page (padlock, swap signee, GPS, receipt email), Supervising Physician picker, Opt-in (in-person + remote set-up, pending list), Remote Sampling, Account sample status badge, New Account wizard (one-time drop fields conditional), Allocations, Inventory Orders (search + sortable columns).
- **SM-IOS-05** Permissions: camera, location; graceful denial handling.
- **SM-IOS-06** Accessibility (Dynamic Type, VoiceOver labels on status colours: never colour-only), localisation-ready, iPhone compact layouts.
- **SM-IOS-07** Activity log for scans and key sample events; crash-safe signature capture (persist strokes as they are drawn).

---

## 20. Integrations

- Warehouse/ERP → shipments → Receipts; lot master & Batch Lot IDs; price-to-stockist & purchase prices (annual averages); domestic sales revenue (finance).
- License validation vendor (inbound status updates; outbound new-HCP validation requests).
- BRC / direct-ship fulfilment vendor (outbound orders, inbound shipment/delivery status).
- Literature/reprint fulfilment.
- Email (approved templates) for receipts and opt-in links; SMS/WhatsApp optional via existing Sciagen channel if present.
- Bulk import templates: Sample Lots, Account Authorizations, Rep Rosters, Sample Limits, State settings.
- All integrations log to `Integration_Log__c` with retry and alerting.

---

## 21. Testing & acceptance

- Apex tests for every rule ID (positive + negative), bulk (200+ records), and sharing (`System.runAs` per permission set).
- Required scenarios: full 7-step setup → call → disbursement; transfer with Batch Lot ID match/no-match; receipt with discrepancy; return with no Rep Roster for Return-To (fail); adjustment 3-vs-2 example; one-time drop New→Sampled→blocked→Valid; license propagation (3 rules); mid-level with valid/invalid/expired/inactive/date-bounded supervisors; controlled substance with opt-in (still needs signature); DEA checksum; CDS state; cold chain regex; barcode expired/restricted lot; signature <3 points / <100 px; recapture matrix (all branches); unlock under each policy; opt-in calendar vs rolling; remote opt-in accept & re-sign; 13th pack for same drug/HCP/year rejected (across two reps, one offline); hypnotic product blocked; ₹1,001 promo item blocked; 2% cap alerts; disclosure demo fixture reproduces the expected numbers and text; ledger hash-chain tamper detection.
- Swift: unit tests for rules engine + sync outbox; UI tests for call-with-samples, scanning (mock scanner), signature, opt-in.
- Produce `docs/samples/ADMIN_GUIDE.md` (config steps incl. every FLS/layout step mentioned above) and `docs/samples/USER_GUIDE.md` (rep flows).

---

## 22. Delivery phases

1. **Foundation:** repo findings, design doc, data model, permission sets, settings metadata, ledger, trigger framework.
2. **Inventory core:** products/My Setup/Rep Roster/lots, transactions (transfer/receipt/return/adjustment), My Samples (web + iPad), inventory counts, seed script, setup wizard.
3. **Licensing & eligibility:** address licenses + propagation, status lifecycle, one-time drop, vendor integration, mid-level/authorized receiver, controlled substances, restrictions.
4. **Call sampling (iPad):** samples section, mass add, lot ordering, warnings, limits, barcode, cold chain, custom text, BRC/alt samples/promo, signature (all features), submit → disbursement, unlock.
5. **Consent & remote:** opt-in in-person + remote link/QR site, remote sampling.
6. **UCPMP:** rules engine pack, valuation engine, counters, 2% dashboard, disclosure wizard + PDF/Excel, submission workflow, complaint evidence pack, retention.
7. **Allocations & inventory orders**, reports/dashboards, integrations hardening, guides, full regression, traceability file at 100%.

Start with Phase 1 step 1 (repo exploration) now.
