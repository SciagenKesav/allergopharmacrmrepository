# Code Quality & Platform Health — Pre-Build Audit (Part §3)

Read-only pass over `/Users/kesavamoorthi/Documents/SciagenCRM-Salesforce` (`force-app`,
API v67.0 per `sfdx-project.json`) and `/Users/kesavamoorthi/Documents/SciagenCRM-iPadOS-OldOrg`
(`SciagenCRM/`). No file was created, modified, or deployed in either repo or in the
`sciagen-sandbox` org; no `sf apex run test`, no anonymous Apex, no deploys were run.
This assesses only what affects building the new Sample Management module — it is not
a general lint report, and it does not repeat facts already established in
`01_inventory_salesforce.md` / `02_inventory_ios.md` except where a fact needed a
"does this create risk for the new build" angle added to it.

---

## 1. Apex

### 1.1 Trigger framework consistency

**Consistent, but there is no shared handler/dispatcher base class or interface.**
Every trigger is a 2–6 line (occasionally up to ~25 line) dispatcher that names the
object/events and immediately delegates to one or two static methods on a matching
`*Service` class — confirmed by reading 6 triggers across 5 different objects:

- `force-app/main/default/triggers/SampleDropTrigger.trigger` (4 lines) → `SampleDropService.beforeInsert`/`afterInsert`
- `force-app/main/default/triggers/SampleTransactionTrigger.trigger` (7 lines) → `SampleTransactionService.beforeSave`/`afterSave`
- `force-app/main/default/triggers/SampleLotTrigger.trigger` (3 lines) → `SampleLotService.beforeSave`
- `force-app/main/default/triggers/SampleCallTrigger.trigger` (4 lines) → `SampleDropService.beforeCallUpdate`/`afterCallSubmit`
- `force-app/main/default/triggers/SampleLimitGuard.trigger` (4 lines) → `SampleLimitGuardService.beforeLimitUpdate`/`beforeLimitDelete`
- `force-app/main/default/triggers/AffiliationSync.trigger` (18 lines) → `AffiliationSyncService.enforcePrimaryUniqueness`/`resyncHcpAddressesForAffiliationChange`, but this one also does its own `Set<Id> affectedHcpIds` collection loop inline (lines 8–17) rather than delegating 100% — a minor deviation from the otherwise-skinny pattern.

**Why it matters for this build:** there's no `TriggerHandler` interface, no recursion
guard convention, no declared execution-order mechanism — a new
`Sample_*` trigger just needs to follow the same "one thin trigger, one static
`*Service` method per event" shape the existing 22 triggers already use. That part is
low-risk to extend. The one thing to watch: `Call_Visit_Report__c` already has **two
independent triggers** — `SampleCallTrigger.trigger` and `SupportCallRelockTrigger.trigger`
(confirmed by `grep` over `triggers/*.trigger` for `on Call_Visit_Report__c`). Salesforce
does not guarantee execution order across multiple triggers on the same object; any new
Sample Management automation on `Call_Visit_Report__c` would become a *third*
independently-ordered trigger on that object with no framework enforcing sequencing.

### 1.2 Bulkification

A heuristic scan (`for (` blocks containing `[SELECT` or DML) across all 109 `.cls`
files threw many false positives — most hits are simple `for (X x : [SELECT ...])`
foreach-over-a-single-query patterns, which are correct Apex, not violations. Reading
the flagged sample-domain files closely surfaced **one real, concrete violation**:

**`SampleLimitChecker.evaluate()` → `usage()` issues one SOQL aggregate query per
applicable `Sample_Limit__c`, inside a loop, and this whole chain runs once per
`Sample_Drop__c` row on insert — not once per batch.**

- `force-app/main/default/classes/SampleDropService.cls:26-99` (`beforeInsert`) does
  bulk-prefetch `Call_Visit_Report__c` and `Product__c` into maps (lines 17-23) — that
  part is bulkified correctly — but then calls
  `SampleEligibilityService.check(req)` **inside** the per-drop `for` loop
  (`SampleDropService.cls:45`).
- `SampleEligibilityService.check()` (`force-app/main/default/classes/SampleEligibilityService.cls:38-90`)
  itself issues 2 unconditional SOQL queries per call (`Product__c` at line 42,
  `Sciagen_Account__c` at line 60), a consent query when opt-in is required
  (`hasOptIn()`, line 115), and 1-2 lot queries (`lot()`, lines 123-129) — then calls
  `SampleLimitChecker.checkLimits()` (line 80).
- `SampleLimitChecker.checkLimits()` (`SampleLimitChecker.cls:99-148`) issues its own
  `Product__c` query (line 105), a `User_Territory__c` query (line 107), the
  `Sample_Limit__c` query (line 111), a `Sample_Limit_Override__c` query (line 126),
  and a `callQuantities()` aggregate query (line 242) — then loops
  `for (Sample_Limit__c l : limits)` (line 135/153) calling `evaluate()`, which for
  every **non-`Per_Call`-scoped** limit calls `usage()` (`SampleLimitChecker.cls:199`),
  and `usage()` runs its own `Database.queryWithBinds('SELECT SUM(Quantity__c)...')`
  (`SampleLimitChecker.cls:269`) — **one additional SOQL query per applicable limit,
  per drop line.**

With the default seeded limit set (`SampleLimitSeeder.cls` creates 4+ `Sample_Limit__c`
records: a UCPMP HCP/Product cap, a per-call cap, a rep/month cap, an HCP/all-products
cap), a single `Sample_Drop__c` insert can trigger on the order of **10-15 SOQL
queries**, and none of it is batched across the rows in the same DML operation. A call
report with, say, 8-10 sample lines (a plausible single detail visit covering several
products) could push a single transaction to 80-150+ SOQL queries just from eligibility/limit
checking, which is uncomfortably close to (or over) Salesforce's 100-SOQL-query-per-transaction
governor limit — especially once other per-transaction query cost from the CVR
update itself, sharing recalculation, etc. is added in.

**Why it matters for this build:** this is the exact code path the new Sample
Management module will most likely extend (adding new eligibility rules, new limit
scopes, or a lot-picker UI that calls the same service). Any additive change should
either (a) refactor `checkLimits`/`usage` to batch the per-limit aggregate query across
all limits (one query with an `IN` clause instead of N queries), or (b) explicitly cap
how many sample lines a single call report can carry, before adding more logic to a
path that's already close to the query ceiling.

No other DML-in-a-per-record-loop pattern was found in the sample-domain classes read
(`SampleTransactionService.cls`, `SampleLotService.cls`, `SampleAllocationService.cls`,
`SampleExpenditureService.cls` all bulk-collect into maps/sets first, then do a single
`insert`/`update` at the end of the method).

### 1.3 `without sharing` usage

**40 of 72 non-test Apex classes (56%) are declared `without sharing`** — a
strikingly high proportion, confirmed by `grep -l "without sharing class" *.cls`
(excluding `*Test.cls`). Grouped by why:

| Class(es) | Declared reason (from class doc comments) | Sample-relevant? |
|---|---|---|
| `SampleConfig`, `SampleAllocationService`, `SampleEligibilityService`, `SampleExpenditureService`, `SampleAttemptLogService`, `SampleLimitSeeder`, `SampleLimitChecker`, `SampleNotifier`, `SampleTransactionService`, `SampleDropService` | **The entire sample-inventory business-logic layer runs without sharing.** `SampleTransactionService.cls:9` states it explicitly: *"a transfer or receipt changes lots owned by another rep."* | **Yes — this is essentially the whole Sample Management engine today.** |
| `TerritorySharingService`, `PlannedCallTerritorySharingService`, `RCPAAuditTerritorySharingService`, `SupportSharingService` | Deliberate — these classes *are* the Apex-managed-sharing mechanism (§3.2 of the Salesforce inventory), can't grant shares under `with sharing`. | No, but same design pattern reused by Sample*. |
| `DuplicateEngine`, `DuplicateMatchService`, `DuplicateMergeService`, `DuplicateKeyService`, `DuplicateSurvivorship`, `DuplicateAdminController`, `DuplicateScanBatch`/`Queueable`/`Scheduler`, `DuplicateTriggerHandler` | Dedupe engine needs to see/merge records org-wide. | No |
| `Support*` (9 classes) | Support agents need to see every rep's requests. | No |
| `AffiliationSyncService`, `HCOGeocodingQueueable`, `PlannedCallOfficeHoursValidator`, `GlobalAccountSearchController`, `SciagenAccountTerritoryController`, `SciagenAccountController` (inner class) | Each documented individually (e.g. `GlobalAccountSearchController.cls:6`: *"so the search itself can see every account regardless of..."*). | No |

**By contrast, the entry-point/admin controller is `with sharing`:**
`SampleAdminController.cls:7` (`public with sharing class SampleAdminController`) —
i.e. the *only* sharing-respecting layer in the entire sample domain is the one LWC-facing
controller; every service method it calls into, and every trigger-invoked service, runs
without sharing.

**Why it matters for this build — this is the single most relevant finding given the
"strict sharing" requirement for the new module:** the existing pattern is "enforce
sharing at the UI/controller entry point only; every service/trigger method underneath
runs system-wide." That's a defensible, documented design (it has to be — a transfer
between two reps' lots can't work under `with sharing` for the *recipient's* records),
but it means record-level sharing is **not** actually enforced anywhere in the sample
chain except by whatever the entry point (LWC Apex controller, or the mobile REST
layer) chooses to check before calling in. A new REST endpoint or LWC controller added
for Sample Management needs to replicate `SampleAdminController`'s pattern (be
`with sharing` itself, do its own ownership/permission checks before delegating) rather
than assuming the service layer underneath will stop an unauthorized read — because it
won't. This is compounded by the sharing-model finding in `01_inventory_salesforce.md`
§12.2: `Consent__c` (a Private OWD object the sample-eligibility check queries directly,
`SampleEligibilityService.cls:115`) has **no Apex-managed sharing at all**, and the two
broad permission sets already grant `viewAllRecords`/`modifyAllRecords` on it — so in
practice every rep can already see every HCP's consent record org-wide today, which a
"strict sharing" Sample Management module should not assume is fixed by the platform.

### 1.4 Hard-coded Record Type / Salesforce Id literals

**None found.** `grep -noE "'[a-zA-Z0-9]{15,18}'"` across all non-test `.cls` files
returned only coincidental 15-character English words (`'multispeciality'`,
`'territoryFilter'`, `'hasPendingReset'`, `'lastreferenceddate'`) — no actual
Id-shaped literal (`grep` for an assignment-style `= 'xxxxxxxxxxxxxxx'` pattern) exists
anywhere in the classes read. This is a clean, positive finding — no precedent of
hard-coded Ids to avoid perpetuating.

### 1.5 Missing CRUD/FLS enforcement

Org-wide, only **18 of 109 classes** reference `AccessLevel.USER_MODE`/`WITH USER_MODE`
(`grep -rl "USER_MODE" *.cls`), and **zero classes anywhere in the org use
`Security.stripInaccessible` or `WITH SECURITY_ENFORCED`** (`grep -rl` for both returns
nothing). Within the sample domain specifically:

- **None of the core sample business-logic classes' inline `[SELECT ...]` queries use
  `USER_MODE`** — confirmed by reading every `SELECT` in `SampleDropService.cls`,
  `SampleTransactionService.cls`, `SampleEligibilityService.cls`,
  `SampleLimitChecker.cls`, `SampleAllocationService.cls`. These all run in
  system mode by default (consistent with their `without sharing` declaration, §1.3) —
  meaning there is no field-level security check at all on any of these reads, only
  whatever the calling entry point enforces.
- **`SampleAdminController.cls`** (the one `with sharing` sample class, §1.3) is
  **inconsistent internally**: of its 20 `SELECT` statements, only 2 dynamic
  `Database.queryWithBinds(...)` calls pass `AccessLevel.USER_MODE`
  (`SampleAdminController.cls:163` for `Sample_Lot__c`, `:319` for
  `Sample_Transaction__c`); the other 18 plain bracket-SOQL statements
  (e.g. `SampleAdminController.cls:130,132,135,139,140,154,186,240,242,244,388`) have
  no FLS enforcement, relying on `with sharing`'s record-level check only.
- **`UCPMPComplianceController.cls`/`UCPMPComplianceService.cls`** (the compliance
  dashboard, which reads sample expenditure + HCP-identifying data) are **not** in the
  `USER_MODE` class list at all.

**Why it matters for this build:** given the explicit "strict sharing" requirement,
the new module should not follow the existing sample-domain convention of "system mode
everywhere, sharing/FLS enforced only at the very top." Since `Security.stripInaccessible`
is unused anywhere in this org, there's no established idiom to copy for output
scrubbing either — the new module would be introducing that pattern for the first time
if it wants field-level enforcement on read.

### 1.6 Test quality

**Genuinely good — this is a positive finding, not a risk.** Spot-checked 6 sample-domain
test classes plus a broader pass over all 34 `*Test.cls` files for assertion density:

| Test class | Lines | Real assertions (`assertEquals`/`Assert.*`) |
|---|---|---|
| `SampleDropServiceTest.cls` | 260 | 61 |
| `SampleLimitCheckerTest.cls` | 146 | 46 |
| `SampleTransactionServiceTest.cls` | 333 | 56 |
| `SampleAdminControllerTest.cls` | 186 | 53 |
| `SampleEligibilityServiceTest.cls` | 136 | 26 |
| `SampleLotServiceTest.cls` | 99 | 15 |

Reading `SampleLimitCheckerTest.cls:26-40` directly confirms these are real,
value-specific assertions with descriptive failure messages (e.g.
`System.assertEquals('2026-27', SampleLimitChecker.financialYear(...))`,
`System.assertEquals(Date.newInstance(2026, 9, 14), ..., 'weeks start on Monday')`),
not padding. The few `System.assert(true)` occurrences found
(`SampleAdminControllerTest.cls:55,56,167,171`) are legitimate exception-path assertions
(`try { ...; System.assert(false); } catch (AuraHandledException e) { System.assert(true); }`),
not trivial filler.

The org-wide scan found **no test class with zero assertions**; the thinnest are
`RoleHierarchySharingTest.cls` (1 assert in 85 lines — but it's a single focused
sharing-regression test, not padding) and `SavedViewsResourceTest.cls`/
`SyncTrackingPurgeJobTest.cls` (3 asserts each, small classes). None of these are
sample-domain classes.

**One real gap, already flagged in the Salesforce inventory (§10.1) and confirmed here
by directory listing:** `UCPMPComplianceService`, `UCPMPComplianceController`,
`UCPMPDisclosureController`, `SampleLimitGuardService`, `SampleLotExpiryBatch`,
`HcpLicenseExpiryBatch`, `SampleAttemptLogService`, and `SampleExpenditureService` have
**no dedicated `*Test.cls`** (`ls classes/*Test*.cls` has no matching name for any of
them). Given the strong assertion quality everywhere else, this looks like an actual
coverage gap rather than a padding problem — worth closing before the new module builds
further UCPMP/compliance logic on top of untested classes.

---

## 2. Swift (iPadOS client)

### 2.1 Concurrency model

**Sound, and better than a "spot check" expects.** `AccountStore` and `UserDataStore`
are both declared `@MainActor` at the class level
(`Services/AccountStore.swift:12-13`, `Services/UserDataStore.swift:14-15`), so every
method on them — including every `@Published`-mutating one — is compiler-enforced to
run on the main actor; there is no way to accidentally mutate their state off-main from
within the class itself. `SalesforceRestDataService.swift` (116 `async` function
signatures) is deliberately **not** `@MainActor` — correct, since it's pure network
I/O — and its callers are themselves `@MainActor`-isolated methods on `AccountStore`/
`UserDataStore`, so `await service.fetchX()` calls correctly resume back on the main
actor without any explicit hop needed. `Services/CardOCRService.swift:69-76` is the one
place with a raw `DispatchQueue.global(qos: .userInitiated).async` block (wrapping a
Vision framework `perform()` call inside `withCheckedContinuation`); it only resumes a
continuation from the background queue, it does not touch any `@Published`/UI state
directly, and the code includes an explicit comment (`CardOCRService.swift:70-71`)
about avoiding a continuation double-resume — this is a correctly-written pattern, not
a risk. No `Task.detached` calls exist anywhere in `Services/` (`grep` confirmed zero).

**Caveat worth flagging for planning purposes:** the project is `SWIFT_VERSION = 5.0`
(`SciagenCRM.xcodeproj/project.pbxproj`), i.e. **not** built under Swift 6's strict
concurrency checking. The `@MainActor` correctness above holds today because the code
was written carefully, not because the compiler is enforcing it — a future contributor
adding Sample Management sync/concurrency code without the same discipline would not
get a compile-time error for a new data race the way they would under Swift 6 language
mode. Worth deciding whether new Sample Management Swift code should opt into stricter
concurrency checking even if the rest of the app doesn't (yet).

### 2.2 Force unwraps in data-handling paths

**Minimal, and every occurrence found is guarded.** Org-wide: **zero** `try!` and
**zero** `as!` anywhere in the codebase (`grep -rn "try!"` / `grep -rn "as! "` across
all `.swift` files both return nothing). Bare force-unwrap (`!`) occurrences in the
files that actually parse/decode Salesforce responses:

- `Services/UserDataStore.swift:93` — `$0.expirationDate! >= now`, guarded by a
  preceding `$0.expirationDate == nil ||` short-circuit on the same line.
- `Services/UserDataStore.swift:644,648` — `prescriberHCPId!`, guarded by a preceding
  `prescriberHCPId?.isEmpty == false ?` ternary condition (`UserDataStore.swift:643-648`)
  that only reaches the force-unwrap when the optional is confirmed non-nil/non-empty.
- `Services/UserDataStore.swift:653` — `best!.0`, guarded by `best == nil ||` on the
  same line.
- `Services/SalesforceAuthService.swift:403` — `URL(string: "https://\(SalesforceConfig.loginHost)/...")!`,
  an unguarded force-unwrap, but on a URL built from a hardcoded scheme + a
  server-configured host string, the standard (low-risk) pattern for constructing a
  known-shape URL.

No force unwraps at all were found in `Services/SalesforceRestDataService.swift` (the
2800+-line file that actually parses every Salesforce REST/JSON response), `Models/CLMModels.swift`,
or `Models/Models.swift`. **Positive finding** — there is no bad habit here for new
Sample Management parsing code to inherit; the existing convention (guard/ternary
before any force-unwrap) is safe to extend.

### 2.3 Persistence layer threading (`UserDataStore.swift`)

Confirmed consistently `@MainActor` at the class declaration
(`Services/UserDataStore.swift:14-15`, `final class UserDataStore: ObservableObject`),
not method-by-method — so there is no risk of a race between two call sites mutating
the in-memory collections or the `UserDefaults`-backed blob concurrently from different
threads. This matches, and sharpens with a direct citation, what
`02_inventory_ios.md` §2 already established about the persistence mechanism itself
(Codable → JSON → `UserDefaults`).

### 2.4 Error handling in the sync path

**Not silently swallowed — errors are consistently logged into the app's own sync
audit trail.** Every `catch` block in the 36 found in `SciagenCRMApp.swift` either
calls `userData.logSyncFailure(entryId, error: error.localizedDescription)` (e.g.
`SciagenCRMApp.swift:314-316,331-333,347-349,362-364,381-383,394-396,407-409,420-422,439-441,458-460,621-624,686-688,704-706,724-726,768-770,787-789` —
16+ push/pull functions all follow this identical pattern) or logs via `NSLog` with a
tagged prefix for the handful of paths that aren't tied to a specific sync-log entry
(e.g. `SciagenCRMApp.swift:186-188` `"[SCIAGEN-IDENTITY] fetch failed, keeping previous
identity"`, `:505-507` `"[SCIAGEN-SYNC-TRACKING] mirror push failed"`, `:752-754`
`"[SCIAGEN-DCR-PULL] failed"`). No empty `catch {}` block exists anywhere in the app
(`grep` for the literal pattern returns nothing). **Positive finding** — the
`logSyncFailure` path feeds `SyncLogView` (per `02_inventory_ios.md` §3), which the rep
can filter to "Failed" and act on, so a Sample Management sync failure would surface
the same way every other object's does today, not disappear.

### 2.5 Dead/misleading code relevant to Sample Management (cross-referenced from `02_inventory_ios.md`, not re-verified here beyond confirming it's still accurate)

- `Services/SampleData.swift` and `Services/DataService.swift`/`MockDataService.swift`
  are **not** the sample-drug domain and **not** live — `SampleData.swift` is bundled
  demo *account* data, and the mock-data path is dead since
  `SciagenConfig.useLiveSalesforce = true` is hardcoded
  (`SciagenCRMApp.swift:18`, per `02_inventory_ios.md` §1/§5.1). Worth being careful a
  new contributor doesn't assume either file is a starting point for sample-inventory
  data modeling just because of the filename.
- The client's `SampleDrop` model (`Models/CLMModels.swift:272-281`) has **no lot,
  batch, expiry, or serial field**, and the push payload
  (`SalesforceRestDataService.swift:2446-2469`) only ever sends
  `CVR__c`/`Product__c`/`Qty__c` — i.e. **the entire `Sample_Lot__c`/`Sample_Transaction__c`
  ledger concept the Salesforce side already has (§1.5/§1.6 of the Salesforce
  inventory) does not exist on the client at all.** This is the single biggest
  client-side gap for this build, already flagged in `02_inventory_ios.md` (its own
  table row, "Lots / Inventory — none exist"), restated here because it directly
  intersects §1.2's bulkification finding above: any new client UI that lets a rep pick
  a specific lot (instead of trusting server-side FEFO auto-assignment) will need new
  models, new sync fetch/push methods, and a new "Updates"/"Discovery" pull pair
  following the existing per-object convention (`02_inventory_ios.md` §3) — none of
  that scaffolding exists to extend today.

---

## 3. Platform / versioning

### 3.1 API version drift

**Real, and specific.** `sfdx-project.json:8` sets `"sourceApiVersion": "67.0"`, but the
actual deployed metadata is overwhelmingly pinned to an older version:

| apiVersion | Count | Where |
|---|---|---|
| 62.0 | 101 of 109 Apex classes, **all 22 triggers**, sampled LWC `*.js-meta.xml` files | `grep -h apiVersion classes/*.cls-meta.xml \| sort \| uniq -c` |
| 67.0 | 6 classes | `DeviceResetRequestTriggerTest`, `GlobalAccountSearchControllerTest`/`GlobalAccountSearchController`, `SavedViewsResource`/`SavedViewsResourceTest`, `SciagenAccountTerritoryControllerTest` |
| 59.0 | 2 classes | `DeviceResetAdminController`, `SciagenDeviceResetController` |

**None of the `Sample_*`/`UCPMP*` Apex classes are among the newer-API-version files —
every class in the sample domain is pinned at 62.0.** This matters for this build in
two concrete ways: (1) whatever API version new Sample Management Apex/LWC/triggers are
authored at (presumably 67.0+, current at time of writing) will create a third distinct
version tier within the sample domain itself unless someone deliberately re-pins the
existing `Sample_*` classes too; (2) API version governs some security-relevant
defaults (e.g., certain FLS/sharing enforcement behaviors default differently across
API versions), so a mixed-version sample domain means the *existing* `Sample_*` classes
and any *new* ones could subtly behave differently even when calling into each other,
independent of the `without sharing`/CRUD-FLS gaps already flagged in §1.3/§1.5.

### 3.2 Deprecated automation features in active use

**None — this is clean.** `force-app/main/default/workflows/` does not exist as a
directory (no legacy Workflow Rules or Process Builder metadata in source, confirmed by
`ls`). The only file under `force-app/main/default/flows/` is
`sfdc_default_ReportExport_Protection_Flow.flow-meta.xml`, and its own metadata
confirms `<processType>TransactionSecurityFlow</processType>` and
`<status>Draft</status>` — it's the Salesforce-provided default flow, currently
**inert** (Draft), not a custom Process Builder migrated to Flow. All automation in this
org is Apex-trigger/batch/queueable/schedulable (§1.1, §5.5 of the Salesforce
inventory) — there is no Process Builder/Workflow Rule debt to carry into the new
module, and no existing Flow-based pattern to match either (a new module wanting
declarative automation would be introducing Flow to this org for the first time).

### 3.3 Other tech debt specifically affecting the Sample Management build

- **No existing outbound integration pattern (Named Credential) exists anywhere in the
  org** (`01_inventory_salesforce.md` §6.4/§9/§12.5) — the one live outbound callout
  (`HCOGeocodingQueueable.cls` → Google Maps) uses a raw `HttpRequest` with an API key
  in the query string, not a Named Credential. If Sample Management ever needs an
  outbound callout (e.g. a license-verification vendor, an ERP/ERP-adjacent stock feed
  per `Sales_Transaction__c`'s own object description anticipating a future SAP feed),
  it will be establishing this org's first real Named Credential usage from scratch,
  not following a precedent — plan the integration-auth work accordingly rather than
  assuming a pattern to copy.
- **`Sync_Object_Config__mdt`'s 13 configured objects do not include any `Sample_*`
  object** (`01_inventory_salesforce.md` §6.1/§7.2) — the sample-inventory chain is not
  wired into the existing declarative per-object sync-policy table
  (`Sync_Direction__c`/`Conflict_Resolution__c`/`Sync_Window_Days__c`) at all today.
  Combined with §2.5 above (no client-side lot/transaction model exists either), the
  mobile sync design for Sample Management is a genuine blank slate on both sides — not
  a small gap-fill, a first build.
- **No barcode/GS1 scanning capability exists on the client** — confirmed by
  `02_inventory_ios.md` §6 (`VisionKit`, `DataScannerViewController`,
  `AVMetadataObject`, `GS1`, `GTIN` all return zero matches). Camera capture does exist
  (`UIImagePickerController`, legacy API, used for DCR photo-proof only) and on-device
  OCR exists (`CardOCRService.swift`, Vision `VNRecognizeTextRequest`, used for
  business-card prefill only) — neither is a barcode/lot-scanning building block, so if
  Sample Management wants a rep to scan a lot/batch barcode when receiving or
  disbursing stock (a natural feature given `Sample_Lot__c.Lot_Number__c`/
  `Batch_Lot_Id__c` already exist server-side), that is new capability, not an
  extension of an existing one.
- **A real ledger *pattern* does exist and is reusable — just not a barcode/inventory
  one.** `SampleTransactionService.cls` is a well-structured, documented, tested (56
  assertions, §1.6) before/after-split ledger implementation with row-locking
  (`SELECT ... FOR UPDATE`, `SampleTransactionService.cls:353` block) already handling
  concurrent lot updates from transfers between reps. This is a solid pattern for the
  new module's server-side logic to extend directly (it already *is* the Sample
  Management engine, per `01_inventory_salesforce.md`'s framing) — the risk is
  concentrated in §1.2's bulkification finding and §1.3/§1.5's sharing/FLS gaps within
  that same engine, not in the ledger design itself.
- **Swift 5.0 / no Swift 6 strict concurrency** (§2.1) is a minor but relevant platform
  fact: new sync/concurrency code for lots/transactions on the client won't get
  compiler-enforced data-race safety the way it would under a stricter language mode.

---

## Top 5 things to fix before/during Phase 1

1. **Refactor `SampleLimitChecker`'s per-limit `usage()` query (§1.2) before adding any
   new eligibility/limit logic.** `SampleDropService.cls:45` → `SampleEligibilityService.cls:80` →
   `SampleLimitChecker.cls:135/199/269` issues one SOQL aggregate query per applicable
   `Sample_Limit__c`, per `Sample_Drop__c` row, uncached and unbatched across the
   triggering DML operation. A call report with several sample lines is already close
   to the 100-SOQL governor limit from this path alone; any additive Phase 1 work here
   should batch the per-limit usage query (single query with limit ids in an `IN`
   clause) rather than build on top of the current shape.

2. **Decide the sharing/FLS posture explicitly before writing new Sample Management
   Apex, given the "strict sharing" requirement.** 40 of 72 non-test classes (56%) —
   including effectively the entire existing sample engine
   (`SampleDropService`, `SampleTransactionService`, `SampleEligibilityService`,
   `SampleLimitChecker`, `SampleAllocationService`, `SampleExpenditureService`,
   `SampleConfig`, `SampleNotifier`, `SampleAttemptLogService`, `SampleLimitSeeder`) —
   run `without sharing` with zero `Security.stripInaccessible`/`SECURITY_ENFORCED`
   usage anywhere in the org and only partial `AccessLevel.USER_MODE` coverage even
   in the one `with sharing` entry point (`SampleAdminController.cls`, 2 of 20 queries).
   If the new module must enforce record/field-level security more strictly than the
   existing engine does, that enforcement has to be added net-new at whatever entry
   points the module introduces — it will not be inherited from the classes it calls.

3. **Close the test-coverage gap on `UCPMPComplianceService`/`UCPMPComplianceController`/
   `UCPMPDisclosureController`/`SampleLimitGuardService`/`SampleLotExpiryBatch`/
   `HcpLicenseExpiryBatch`/`SampleAttemptLogService`/`SampleExpenditureService`** —
   no dedicated test class exists for any of them today (§1.6), which is a real gap
   given how strong the assertion quality is everywhere else in the sample domain (the
   org clearly has the testing discipline; these classes were just missed).

4. **Design the mobile lot/transaction model and sync contract from scratch — it does
   not exist yet on either the sync-policy or client-model side.** `Sample_*` objects
   are absent from `Sync_Object_Config__mdt`'s 13 configured objects, and the iOS
   client's `SampleDrop` struct has no lot/batch/expiry field at all (§2.5, §3.3). This
   is Phase 1 scope, not a gap-fill, and should follow the existing
   `LastModifiedDate`-based "Updates + Discovery" per-object pull pattern
   (`01_inventory_salesforce.md` §12.7) plus a real transfer/conflict story, since
   `SampleTransactionService`'s row-locking (`FOR UPDATE`, `SampleTransactionService.cls:353`)
   assumes single-writer-at-a-time semantics that a naive "last sync wins" mobile merge
   could violate.

5. **Pick and document the target Apex API version for new Sample Management
   metadata, and note the resulting version split.** `sourceApiVersion` is 67.0 but
   101 of 109 classes (100% of the existing `Sample_*` classes) are pinned to 62.0
   (§3.1); building fresh at whatever the current version is when Phase 1 starts will
   create a third API-version tier inside the sample domain, with version-dependent
   security-default behavior differences between the old and new sample classes unless
   the older ones are deliberately re-pinned alongside the new work.
