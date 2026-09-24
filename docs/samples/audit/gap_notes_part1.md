# Gap Analysis Notes — Part 1 (Foundation, Data Model, Configuration, Setup Flow, Transactions/My Samples)

Scope: SM-GEN, SM-REG, SM-PRD, SM-SET, SM-RR, SM-CFG-01..25, SM-SETUP-01..07, SM-MYS,
SM-LOT, SM-TXN-01, SM-TRF, SM-RCP, SM-RET, SM-ADJ, SM-UNL (88 requirement IDs). Companion
to `gap_matrix_part1.csv`. All evidence is read-only: SFDX source under
`force-app/main/default/`, and read-only `sf data query`/inventory docs already produced by
prior passes (`docs/samples/audit/01_inventory_salesforce.md`,
`docs/samples/audit/02_inventory_ios.md`). No org data or source file was changed.

## 1. High-risk area #1: Inventory integrity

**Can `Calculated_Quantity`-style fields be changed outside a controlled service?** Mostly
no, and this is one of the better-built parts of the existing schema. `Sample_Lot__c`'s
on-hand quantity (`Available_Quantity__c`, the spec's `Calculated_Quantity__c` equivalent)
is written only from `SampleTransactionService.afterSave()`
(`force-app/main/default/classes/SampleTransactionService.cls:292-297`), and the
`Sciagen_Mobile_App_Access` permission set — the one granted to reps/the iPad app — gives
`Sample_Lot__c` **Read-only** access (no Create/Edit/Delete), per
`01_inventory_salesforce.md` §12.3. So an ordinary rep cannot directly edit a lot's
quantity through the UI/API. However, `Sample_Lot__c` also carries a directly-settable
`Initial_Quantity__c` field with its own validation rule (`Initial_Quantity_Positive`,
`force-app/main/default/objects/Sample_Lot__c/validationRules/`) — this conflicts with the
spec's explicit "no initial quantity field on a lot" requirement (SM-LOT-02, marked
CONFLICT in the matrix) and gives whoever can create `Sample_Lot__c` records (the
`Sciagen_Sample_Admin` permission set has full CRUD) a way to seed on-hand quantity outside
the Receipt/Transfer transaction flow.

**Is there a ledger?** Not an append-only one. The spec calls for an immutable,
hash-chained `Sample_Ledger_Entry__c` (§15, out of this slice's ID list but directly
relevant here). No such object exists anywhere in the org (`find objects -iname
"*Sample_Ledger*"` returns nothing). `Sample_Transaction__c` is doing the ledger's job today,
but it is an ordinary, directly-mutable custom object: `SampleTransactionService.beforeSave()`
only blocks *non-managers* from changing a transaction once `Inventory_Applied__c = true`
(`SampleTransactionService.cls:107-115`) — a user holding `Manage_Sample_Inventory`
(the `Sciagen_Sample_Admin` permission set) can still edit a posted transaction directly,
with no automatic reversing/re-posting entry and no hash chain to detect tampering.

**Could an offline retry double-decrement stock?** This is a real, concrete risk given the
current design, though the exact mechanics differ from a naive double-decrement. On the
iOS side, `SciagenCRMApp.swift`'s push layer has no formal outbox/idempotency-key
mechanism for *new* record creation — idempotency for **existing** records relies entirely
on `salesforceId == nil` (create-vs-update routing, `SalesforceRestDataService.swift:2805-2821`,
per `02_inventory_ios.md` §3) and, for CVR children, on `CVR.syncedChildIds` tracking keys
like `"sample:<SampleDrop.id>"` (`CLMModels.swift:369-378`). That protects a *retried push of
the same already-created local record*. But nothing in `Sample_Drop__c` carries a
client-generated idempotency/UUID key that the server can use to reject a **duplicate
insert** of conceptually the same drop line if the client's local id or sync state gets
confused (e.g. after an app reinstall, a failed-then-retried POST that actually succeeded
server-side, or the documented lack of any 409-conflict-specific handling —
`02_inventory_ios.md` §3: "no HTTP 409-specific branch exists ... any non-2xx response ...
throws a generic error"). On the server, `SampleDropService.createTransactions()` guards
against re-processing the *same* `Sample_Drop__c` row twice (`WHERE ... AND Transaction__c =
null`, `SampleDropService.cls:99`), but a second, distinct `Sample_Drop__c` insert with the
same content would sail through as a legitimate new disbursement and decrement the lot
again. Given the iOS client today has **no lot concept at all** (confirmed absent,
`02_inventory_ios.md` line 49) and the sample flow it does have pushes only
`{CVR__c, Product__c, Qty__c}` with no lot/idempotency key
(`SalesforceRestDataService.swift:2446-2469`), this risk is currently latent rather than
actively exploitable — but it will become live the moment a lot-aware, offline-capable
iPad sample flow (per the full BUILD_SPEC vision) is built on top of the current server
contract without adding a client-UUID idempotency key to `Sample_Drop__c`/`Sample_Transaction__c`.

**Are transactions immutable after submit?** No, not fully, and this is the single sharpest
finding in this slice: **SM-UNL-03 is MISSING/CONFLICT**. `SupportUnlockService.unlock()`
(`force-app/main/default/classes/SupportUnlockService.cls:33-55`) only flips
`Call_Visit_Report__c.Record_Status__c` back to `'Saved'` — it never touches any
`Sample_Transaction__c` or `Sample_Drop__c` record. `SampleDropService.createTransactions()`
only processes a `Sample_Drop__c` whose `Transaction__c` is still `null`
(`SampleDropService.cls:184`, `WHERE ... AND Transaction__c = null`). That means an
**existing** drop line — same `Id`, `Transaction__c` already populated from the original
submit — is never re-processed after unlock: if a rep unlocks a call, edits the quantity or
lot on an existing sample line, and resubmits, the *original* Disbursement transaction is
neither reversed nor re-posted, and the *edited* values are never reflected in a new
transaction either. The on-hand lot quantity and the ledger silently diverge from what the
call now says was actually given out. This is exactly the scenario the spec's SM-UNL-03
("Unlock reverses and re-posts ledger entries; never edits history in place") exists to
prevent, and it is not implemented at all today.

## 2. Data migration needs

- **`Product__c.Product_Type__c`** is free Text and already populated on all 12 live
  records with values (`DP 100%`, `DP+DF Mix`, `DF 100%`) unrelated to the spec's
  Detail/Sample/Alt-Sample/BRC/Promo/HV-Promo/Reprint taxonomy (SM-PRD-01, SM-GEN-02).
  Introducing the real taxonomy means deciding whether to repurpose this field (migrating
  the 12 existing values into a mapped equivalent, or a separate field) — not a green-field
  add.
- **`Sample_Lot__c.Initial_Quantity__c`** (SM-LOT-02 conflict): the field/validation rule
  exists but the object has 0 records in the sandbox today (`01_inventory_salesforce.md`
  §11), so removing or repurposing it carries effectively no data-migration risk *in this
  org* — but any other environment where lots have already been seeded via this field would
  need a migration plan before the field's semantics changed.
- **`Sciagen_Account__c` license fields** (SM-REG-02/03): license data lives flat on the
  Account object (`License_Number__c`, `License_Expiry_Date__c`,
  `License_Verification_Status__c`, 41 of 152 accounts already populated per
  `01_inventory_salesforce.md` §1.1). Moving to a per-state Address child object (as the
  full spec's SM-LIC-01 requires, and as SM-REG-02/03 depend on) means migrating those 41
  populated records into whatever new Address-equivalent structure is chosen.
- **`Return_To__c`** (SM-RET-01/SM-RR-04): currently free Text. Converting to an
  admin-configurable picklist validated against real destination records needs a value-set
  design plus a decision about how any historical free-text values map to the new controlled
  values (no data exists yet in the sandbox — `Sample_Transaction__c` has 0 records — so this
  is low-risk here but should be flagged for any environment with real data).

## 3. Breaking-change items

- **SM-PRD-05 (price master) / UCPMP valuation**: `UCPMPComplianceService.cls` currently
  computes sample value from the single flat `Product__c.Sample_Unit_Value_INR__c`. Adding a
  proper FY-versioned `Sample_Price__c` object per the spec changes where the existing 2%-cap
  compliance dashboard (`ucpmpComplianceDashboard` LWC / `UCPMPComplianceController.cls`)
  sources its unit price — a live, already-shipped feature — so this is a breaking change for
  that dashboard's numbers unless the cutover is carefully staged (dual-read old/new during
  transition).
- **SM-UNL-01/SM-CFG-24 actor model**: the existing unlock mechanism is a Support-agent
  workflow (`Support_Agent` + `Support_Unlock_Calls` custom permission, routed through
  `Support_Request__c` tickets), not a `Sciagen_Sample_Admin`/`Manage_Sample_Inventory`
  action as the spec's "only a Sample Admin can unlock" implies. If the module is built to
  match the spec literally (Sample Admin unlocks directly, no ticket), that is a workflow
  change for whoever currently uses the Support Console for this — a process/permission
  change for existing users of that flow, not just an additive feature.
- **`Sample_Transaction__c.Return_To__c`** going from free Text to a validated picklist
  (SM-RET-01) is additive in this empty sandbox, but in any org with real Return transaction
  history it would be a breaking change for existing records/reports filtering on the old
  free-text values.

## 4. Offline/online rule-parity gaps

Every rule in this slice that exists on the server today has **no** offline/iOS mirror at
all, because the iOS client has no lot/transaction/transfer/receipt/return/adjustment
concept whatsoever (`02_inventory_ios.md` line 49, confirmed by exhaustive grep). Concretely,
within this slice's scope:

- **Lot selection/expiry/cold-chain rules** (`SampleEligibilityService.cls`, full class read)
  — FEFO lot assignment, `Expiry_Date__c >= today` filtering, cold-chain completeness checks
  — all exist only in Apex; the iPad's `CallReviewView.samplesCard` has no lot picker at all
  (`02_inventory_ios.md` §5.1), so there is nothing to keep in parity yet, but the full-spec
  build must design the Swift mirror from scratch rather than "port" anything.
- **Sample/yearly-limit enforcement** (SM-CFG-18): server-side `Sample_Limit__c` +
  `SampleLimitChecker.cls` implement real warn/block logic; the iOS client instead has a
  **hardcoded 3-product cap** (`Services/CLMData.swift:20-32`) that is **UI-advisory only and
  does not block save/submit** (`CLMViews.swift:1050-1070`, per `02_inventory_ios.md` §11
  items 1–3) — this is an existing, live parity gap today (not just a future one): a rep can
  submit a call over the client-displayed limit and the client will not stop them, while the
  server has no visibility into this specific 3-product cap at all (it isn't the same rule as
  `Max_Packs_Per_HCP_Per_Year__c`).
- **Transfer/Receipt/Return/Adjustment validation** (cold-chain completeness, quantity ≤
  available, reason requirements) exists only in `SampleTransactionService.cls`; there is no
  client-side equivalent because there is no client-side transaction concept at all.

## 5. Top reusable pieces and worst gaps

**Surprisingly reusable (SF side):**
1. **Batch Lot ID carry-over on transfer (SM-TRF-05)** — `SampleTransactionService.
   landTransfersIn()` implements the spec's match/overwrite/create-new logic essentially
   verbatim (`SampleTransactionService.cls:340-385`). This is ready to extend, not rebuild.
2. **Transfer-out decrement-with-floor-at-zero (SM-TRF-01)** and the **signed-quantity
   Adjustment convention (SM-ADJ-01)** — both match the spec's intended semantics exactly
   (`SampleTransactionService.cls:193-211`).
3. **Cold-chain gating on Disbursement/Transfer/Receipt/Return** (SM-TRF-06, SM-RCP-04,
   part of SM-RET-02) — a consistent `coldChainComplete()` check is applied across four of
   the five transaction types (only Adjustment is missing it, SM-ADJ-04).
4. **Return-to-cold-storage-only enforcement** — stricter than the spec asks for; a Return of
   a cold-chain lot is blocked unless the destination warehouse has cold storage
   (`SampleTransactionService.cls:167-169`), a good control worth keeping.
5. **`Sample_Attempt__e` platform-event audit pattern** for blocked attempts
   (`SampleDropService.cls:67`, `01_inventory_salesforce.md` §12.4) — a well-designed,
   rollback-independent audit trail pattern worth reusing for other hard-block events in
   this module.

**Worst gaps/conflicts:**
1. **SM-UNL-03 — unlock does not reverse/re-post ledger entries** (MISSING/CONFLICT): the
   single highest-severity finding in this slice; see §1 above. A rep can unlock, edit an
   already-posted sample line, and resubmit with the stock/ledger never corrected.
2. **SM-MYS-01 — no "My Samples" hub exists on either platform**: the single biggest missing
   user-facing surface in the whole module; nothing to extend from (no `mySamples` LWC, no
   matching iPad screen).
3. **SM-LOT-02 — `Initial_Quantity__c` conflicts with the spec's "no initial quantity on a
   lot" rule**, undermining the "quantity only enters via Receipt/Transfer" inventory-control
   principle at its root.
4. **Rep Roster (SM-RR-01..05) is entirely absent**, which cascades into MISSING/CONFLICT
   status for ship-to address auto-fill (SM-TRF-03), Return-To validation (SM-RET-01/SM-RR-04),
   and the whole setup wizard's steps 2–3 (SM-SETUP-02/03).
5. **iOS sample-limit enforcement is display-only** (SM-CFG-18): the existing hardcoded
   3-product yearly cap is cosmetic and does not block submission — a live compliance gap
   today, not just a future build item.

## CSV row count check

`gap_matrix_part1.csv` contains exactly **88 data rows** (plus the header row), one per
requirement ID in scope, each appearing exactly once — verified programmatically by
comparing the full 88-ID list from the task prompt against the CSV's `Req_ID` column
(0 missing, 0 extra, 0 duplicates).
