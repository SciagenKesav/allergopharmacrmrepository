# Sciagen CRM Salesforce Backend — Inventory (Part 1.2)

Read-only discovery pass over the SFDX metadata at
`/Users/kesavamoorthi/Documents/SciagenCRM-Salesforce` (package dir `force-app`,
API v67.0) and read-only SOQL counts against org alias `sciagen-sandbox`
(orgId `00DC1000005MTTVMA4`, instance `allergo-pharma--dev.sandbox.my.salesforce.com`).
No file in the org or the repo was created, modified, or deployed. No `sf apex run test`
was executed. This is pure inventory — no gap analysis, no recommendations.

---

## Coverage & Limitations

- **Apex test coverage percentages: UNVERIFIED.** No stored coverage report was found
  in the repo or in `~/.sf`/`~/.sfdx` local caches. Getting real coverage numbers
  requires running `sf apex run test -o sciagen-sandbox --code-coverage --result-format json --wait 30`
  (or the equivalent "Run All Tests" in Setup), which can insert/roll back data —
  **needs your explicit confirmation before it's run.** Absent that, this report only
  lists which test classes exist and what scenarios their method names/bodies suggest
  they cover, not whether those tests currently pass or what % of lines they hit.
- **Page layouts / record types**: none of the objects below have a
  `recordTypes/` or `layouts/` subfolder *inside their own object directory* — Salesforce
  stores page layout XML flat under `force-app/main/default/layouts/` instead, keyed by
  `Object-Layout Name.layout-meta.xml`. That flat list is what's cited below. No object
  in this metadata (custom or standard-extended) has a custom Record Type defined —
  confirmed by `find force-app/main/default/objects -path "*/recordTypes/*"` returning
  no matches for any sample/product/account/call object. No compact layouts exist either
  (no `compactLayouts/` subfolder under any object checked).
- **Role hierarchy**: no `force-app/main/default/roles/` directory exists in this
  metadata, so the actual role tree (if any) is UNVERIFIED from source — it would need
  to be inspected live in Setup → Roles, or retrieved with
  `sf project retrieve start -m "Role" -o sciagen-sandbox -r /tmp/sciagen-audit-retrieve`
  (a temp folder outside the source tree) if you want it added to this inventory.
- **Sharing rules / restriction rules / permission set groups / named credentials /
  external credentials / remote site settings / custom labels / Experience Cloud
  sites / email templates (standard) / workflows / approval processes / CDC**: all
  confirmed **absent** from this metadata by directory listing (see relevant sections
  below) — not "not checked," but verified not present as source-tracked metadata. It
  is possible some of these exist only as org clicks not yet retrieved into source;
  that possibility is called out per-section.
- **Org data counts** below are `SELECT COUNT(Id)` / `GROUP BY` aggregates only — no
  individual records were read, consistent with the "no PII" instruction. The sandbox
  is very lightly populated (mostly 0–150 records per object), so these counts describe
  a sparse test/demo dataset, not production-representative volumes.
- One transient network blip (`getaddrinfo ENOTFOUND`) occurred on the first batch of
  `sf data query` calls against `sciagen-sandbox`; all affected queries were re-run
  successfully and their results are the ones reported here.
- This report was assembled directly first (not via the parallel sub-agent passes that
  were in flight when it was written), so the main body's depth is concentrated on the
  objects/classes most relevant to Sample Management. Six parallel deep-dive passes
  that had been kicked off in the background completed afterward and returned
  materially more precise evidence (exact line numbers, full REST contracts, and
  several findings not in the main body). Rather than rewrite the whole document, the
  highest-value corrections and additions from those passes are merged in as
  **§12 Supplementary Deep-Dive Findings** at the end — read that section alongside
  the numbered sections above, since it both confirms and sharpens several claims made
  earlier in the document.

---

## 1. Objects

### 1.1 Sciagen_Account__c — the actual "Account" of this system

Evidence: `force-app/main/default/objects/Sciagen_Account__c/Sciagen_Account__c.object-meta.xml`
(`sharingModel = Private`), 68 fields in `.../Sciagen_Account__c/fields/`.

Standard `Account` is **not used** for HCPs/HCOs — `sf data query "SELECT COUNT(Id) FROM Account"`
returned `0`, and `IsPersonAccount` is not a valid field on this org's `Account`
(query errored `No such column 'IsPersonAccount'`), confirming Person Accounts are not
enabled here. `Sciagen_Account__c` is the custom object standing in for both HCP and
HCO records (`Type__c` field distinguishes them — see `HcpLicenseExpiryBatch.cls:9`
querying `WHERE Type__c = 'HCP'`).

Key fields (from `fields/*.field-meta.xml`, all under `Sciagen_Account__c/fields/`):

| Field | Type/notes |
|---|---|
| `Type__c` | picklist, distinguishes HCP vs HCO (used in `HcpLicenseExpiryBatch.cls:9`) |
| `HCP_Type__c`, `HCO_Type__c` | sub-classification picklists |
| `First_Name__c`, `Last_Name__c`, `Prefix__c` | HCP name parts |
| `License_Number__c`, `Licensing_Body__c`, `Licensing_Year__c`, `License_Expiry_Date__c` | HCP licensing |
| `License_Verification_Status__c` | picklist — verified/expired status, flipped to `Expired` by `HcpLicenseExpiryBatch.cls:15-17` when `License_Expiry_Date__c < TODAY` |
| `License_Verified_At__c`, `License_Verified_By__c` | verification audit fields |
| `Controlled_Substance_License__c` | separate licence flag for scheduled-drug sampling |
| `Medical_Council_Reg_Number__c` | registration number |
| `Can_Prescribe__c` | boolean |
| `Sample_Eligible__c` | boolean — gate checked elsewhere for sample eligibility |
| `Billing_Street__c/City__c/State__c/Postal_Code__c/Country__c` | address fields (no separate address child object — address lives flat on the account) |
| `Geolocation__c`, `Plus_Code__c` | geocoding fields |
| `Email__c`, `Phone__c` | contact fields (custom, not standard Account Email/Phone) |
| `Parent_Account__c` | self-lookup (HCO for an HCP, or hierarchy) |
| `Is_Merged__c`, `Merged_Into__c`, `Merged_At__c` | merge/dedupe outcome fields |
| `Dedupe_Name_Key__c`, `Dedupe_Phone_Key__c`, `Dedupe_Email_Key__c`, `Dedupe_Geo_Key__c`, `Dedupe_License_Key__c`, `Dedupe_Sound_Key__c`, `Dedupe_Checked_At__c` | dedupe engine match keys (see `SciagenAccountDedupe.trigger` §4) |
| `Speciality__c` / `Specialty__c` | (both spellings exist as separate fields — likely legacy duplication) |
| `Focus_Area__c`, `Degree_1..5__c`, `Graduation_Year__c`, `Experience_Years__c` | KOL profile fields |
| `Total_Articles__c`, `Total_Citations__c`, `Avg_Citations_Per_Article__c`, `Avg_Coauthors_Per_Article__c`, `Unique_Journal_Count__c`, `Actively_Published_Years__c`, `Guideline_Count__c`, `Emerging_Expert__c` | KOL/publication scoring fields |
| `LinkedIn_URL__c`, `Twitter_URL__c`, `Instagram_URL__c`, `YouTube_URL__c`, `Website__c` | social/web links |
| `External_Ids__c` | text — external system id mapping |
| `Status__c` | lifecycle picklist |
| `Last_Visit__c` | rollup/tracking date |
| `Reach_Flag__c` | boolean |
| `Account_Code__c` | external code |

**Sharing**: `Private` OWD (`Sciagen_Account__c.object-meta.xml`). Visibility is widened
via **Apex managed sharing** driven by territory assignment — see §3.2.

**Layout**: `force-app/main/default/layouts/Sciagen_Account__c-Sciagen Account Layout.layout-meta.xml`.
**Lightning pages**: `flexipages/Sciagen_Account_Record_Page.flexipage-meta.xml` and
`Sciagen_Account_Record_Page1.flexipage-meta.xml` (two variants exist). **Tab**:
`tabs/Sciagen_Account__c.tab-meta.xml`.

**Org data**: `SELECT COUNT(Id) FROM Sciagen_Account__c` → **152**. Of those,
`License_Number__c != null` → **41**; `License_Verification_Status__c` is **null for
all 152** (`GROUP BY License_Verification_Status__c` returned a single `null` bucket
of 152), i.e. license verification is an unused/unpopulated field in this sandbox.

### 1.2 Product__c — the sample/detail product catalogue

Evidence: `force-app/main/default/objects/Product__c/Product__c.object-meta.xml`
(`sharingModel = Read`), 38 fields.

Standard `Product2` exists but is **empty** (`SELECT COUNT(Id) FROM Product2` → `0`)
and its only customization found is the standard page layout
`layouts/Product2-Product Layout.layout-meta.xml` (default, unmodified) — `Product__c`
is the object actually driving samples, catalogues, and eligibility logic.

Fields (all `Product__c/fields/*.field-meta.xml`):

| Field | Type/notes |
|---|---|
| `Level__c` | picklist, **required**, values `Therapy Area / Molecule / Brand / SKU` (default `SKU`) — `Product__c/fields/Level__c.field-meta.xml`. Org data: all 12 current records are `Level__c = SKU`. |
| `Product_Type__c` | text (not a controlled picklist in metadata — despite the free-text type, org data shows 3 values in use: `DP 100%` (4), `DP+DF Mix` (4), `DF 100%` (4)) |
| `Division__c` | picklist, values `Oncology/Diabetes/Cardiology/Respiratory/Immunology` — mirrors the `Division__mdt` CMDT records (§6.1); org data: all 12 Product__c records have this **null** currently |
| `Brand_Name__c`, `Product_Code__c`, `SKU__c`, `SKU_Code__c`, `SKUCode__c` (3 SKU-ish fields — likely redundant) | |
| `Parent_Brand__c`, `Parent_Molecule__c`, `Parent_Therapy__c`, `Parent_Product__c`, `Parent_Detail_Product__c` | self-lookups building the Therapy→Molecule→Brand→SKU hierarchy implied by `Level__c` |
| `Is_Sample_Product__c` | boolean — gates whether a product can be sampled at all (read in `SampleDropService.cls`) |
| `Is_Detail_Product__c` | boolean |
| `Is_Restricted__c`, `Restriction_Reason__c` | restriction flag + free-text reason |
| `Is_Controlled_Substance__c`, `Controlled_Substance_Schedule__c` | drug-schedule flag, read in `SampleDropService.cls:22` and `SampleEligibilityService.cls` for licence checks |
| `Requires_Cold_Chain__c` | boolean, read in `SampleDropService.cls:22` |
| `Requires_Signature__c` | boolean, read in `SampleDropService.cls:22` |
| `Requires_License_Validation__c` | boolean |
| `Requires_Lot_Number__c` | boolean |
| `Sample_Unit_Value_INR__c` | currency/number — per-unit INR value used for UCPMP 2% spend cap calcs (`SampleDropService.cls:22`, `UCPMPComplianceService.cls`) |
| `Pack_Size__c` | number, read in `SampleDropService.cls:22` |
| `Smallest_Market_Pack_Size__c` | number |
| `Max_Packs_Per_HCP_Per_Year__c` | number — "honoured as a regulatory limit" per `SampleLimitChecker.cls:8` |
| `Max_Patients_Per_Pack__c` | number |
| `Min_Sample_Order_Qty__c`, `Max_Sample_Order_Qty__c` | order bounds |
| `Unit_Value_Per_Strip__c` | currency |
| `Valuation_Method__c` | picklist |
| `Active__c` | boolean |
| `Barcode_Format__c` | text |
| `Launch_Date__c`, `Start_Date__c`, `End_Date__c` | dates |
| `Description__c` | text |

**Layout**: `layouts/Product__c-Product Layout.layout-meta.xml`. **Tab**:
`tabs/Product__c.tab-meta.xml`. No dedicated flexipage found beyond the default record
page mechanism.

**Org data**: `SELECT COUNT(Id) FROM Product__c` → **12**.

### 1.3 Product_Master__c

Evidence: `force-app/main/default/objects/Product_Master__c/` (`sharingModel = Read`,
13 fields). Appears to be a separate/possibly legacy master-data list distinct from
`Product__c` — both are populated with SKU-level products (12 vs 12 records; see org
data below), and `Product_Master__c` is granted broadly in the `SciagenCrm` and
`Sciagen_Mobile_App_Access` permission sets alongside `Product__c` (§4.7). Fields were
not read line-by-line in this pass beyond the directory listing (13 field files) —
flagged for deeper review before the Sample Management build reuses either object, since
having two "product" objects is a notable structural fact for that build.
**Layout**: `layouts/Product_Master__c-Product Master Layout.layout-meta.xml`.
**Tab**: `tabs/Product_Master__c.tab-meta.xml`.
**Org data**: `SELECT COUNT(Id) FROM Product_Master__c` → **12**.

### 1.4 Product_Territory_Assignment__c

Evidence: `force-app/main/default/objects/Product_Territory_Assignment__c/`
(`sharingModel = Read`, only 2 custom fields — a thin junction object). Dedicated
permission set `Product_Territory_Assignment_Access.permissionset-meta.xml` grants just
this one object (§4.3), suggesting it's managed as a narrow, separately-assignable
capability (e.g. for a "territory planner" role) rather than bundled into the main
mobile/manager permission sets.
**Org data**: `SELECT COUNT(Id) FROM Product_Territory_Assignment__c` → **216**.

### 1.5 Sample_Lot__c — physical inventory batches

Evidence: `force-app/main/default/objects/Sample_Lot__c/Sample_Lot__c.object-meta.xml`
(`sharingModel = Private`), 21 fields, 4 validation rules
(`Available_Cannot_Be_Negative`, `Expiry_After_Manufacture`, `Expiry_Must_Be_Future_On_Create`,
`Initial_Quantity_Positive` in `Sample_Lot__c/validationRules/`).

Fields (`Sample_Lot__c/fields/*.field-meta.xml`):

| Field | Notes |
|---|---|
| `Product__c` | lookup to `Product__c` |
| `Lot_Number__c`, `Batch_Lot_Id__c` | lot identifiers |
| `Lot_Key__c` | computed per-holder unique key, set in `SampleLotService.beforeSave` (`classes/SampleLotService.cls:16`) |
| `Initial_Quantity__c`, `Available_Quantity__c`, `Allocated_Quantity__c` | stock counters |
| `Manufactured_Date__c`, `Expiry_Date__c`, `Days_To_Expiry__c` | dates; validated by the 3 expiry-related validation rules above |
| `Status__c` | picklist, e.g. `Active`/`Expired` — flipped to `Expired` by `SampleLotExpiryBatch.cls:16-18` when `Expiry_Date__c < TODAY` |
| `Owner_User__c` | lookup to `User` — the rep currently holding the lot; changing it also reassigns the Salesforce `OwnerId` (`SampleLotService.cls:19-20`) so record ownership follows the physical holder |
| `Rep_Territory__c` | denormalized territory name, set from `SampleTerritoryService.namesFor()` (`SampleLotService.cls:11`) |
| `Warehouse__c` | lookup to `Sample_Warehouse__c` |
| `Source_Lot__c` | self-lookup (split/transfer lineage) |
| `Cold_Chain_Required__c`, `Cold_Chain_Status__c`, `Cold_Chain_Tag_Number__c`, `Cold_Chain_Last_Checked__c` | cold-chain tracking |
| `Storage_Conditions__c`, `Notes__c` | free text |

**Trigger**: `SampleLotTrigger.trigger` (before insert/update) → `SampleLotService.beforeSave`
only (2 lines total — `force-app/main/default/triggers/SampleLotTrigger.trigger`).
**Class doc** (`SampleLotService.cls:1-5`): *"Housekeeping for Sample_Lot__c: the
per-holder unique key, ownership that follows the holding rep (so the rep and their
manager can see the lot), and the Active/Depleted flip when the available quantity
crosses zero. Expiry is handled by SampleLotExpiryBatch."*
**Batch job**: `SampleLotExpiryBatch.cls` — `Database.Batchable<SObject>, Schedulable`,
queries lots `WHERE Status__c = 'Active' AND Expiry_Date__c < TODAY` and marks them
`Expired`, runs daily at midnight per its class comment (`classes/SampleLotExpiryBatch.cls:1-3`).
**Layout**: `layouts/Sample_Lot__c-Sample Lot Layout.layout-meta.xml`. **Tab**:
`tabs/Sample_Lot__c.tab-meta.xml`.
**Org data**: `SELECT COUNT(Id) FROM Sample_Lot__c` → **0** (no lots seeded in this sandbox).

### 1.6 Sample_Transaction__c — the sample stock ledger

Evidence: `force-app/main/default/objects/Sample_Transaction__c/` (`sharingModel = Private`),
57 fields, 4 validation rules (`Adjustment_Cannot_Be_Zero`, `Adjustment_Needs_Reason`,
`Only_Adjustments_Can_Be_Negative`, `Return_Needs_Reason`).

Class doc (`classes/SampleTransactionService.cls:1-11`): *"The sample ledger. Every
movement of free samples is a Sample_Transaction__c. beforeSave decides what a
transaction does (validates it, snapshots the product value and the doctor's details,
works out the signed effect on the lot and flags it applied). afterSave then moves the
stock... Without sharing: a transfer or receipt changes lots owned by another rep."*
Transaction type constants (`SampleTransactionService.cls:16-21`): `Receipt`,
`Disbursement`, `Transfer_Out`, `Transfer_In`, `Return`, `Adjustment`.

Representative fields (57 total; key ones from `fields/*.field-meta.xml`):
`Product__c`/lot references (`Destination_Lot__c`), `HCP_Account__c`, `HCP_Name__c`,
`HCP_Registration_Number__c`, `HCP_Specialty__c`, `HCP_Address__c`, `Call_Report__c`
(lookup to `Call_Visit_Report__c`), `From_User__c`, `From_Warehouse__c`,
`Confirmed_Quantity__c`, `Inventory_Applied__c`, `Inventory_Effect__c`,
`Inventory_Shortfall__c`, `Cold_Chain_Status__c`, `Cold_Chain_Tag_Number__c`,
`Cold_Chain_Temperature__c`, `Authorized_Recipient_Name__c`, `Handed_To_Prescriber__c`,
`Marked_Not_For_Sale__c`, `Total_Value__c`, `Adjustment_Reason__c`, `Approved_At__c`,
`Approved_By__c`, `Override_Reason__c`, `Eligibility_Message__c`, `After_Hours__c`,
`Client_Id__c`, `Device_Type__c`, `IP_Address__c` (the last three suggest client/device
metadata captured for audit on each mobile-originated transaction).

**Trigger**: `SampleTransactionTrigger.trigger` (before/after insert & update) →
`SampleTransactionService.beforeSave` / presumably an `afterSave` counterpart (file is 6
lines, `triggers/SampleTransactionTrigger.trigger`).
**Layout**: `layouts/Sample_Transaction__c-Sample Transaction Layout.layout-meta.xml`.
**Tab**: `tabs/Sample_Transaction__c.tab-meta.xml`.
**Org data**: `SELECT COUNT(Id) FROM Sample_Transaction__c` → **0**.

### 1.7 Sample_Drop__c — sample line items on a call report

Evidence: `force-app/main/default/objects/Sample_Drop__c/` (`sharingModel = ControlledByParent`
— inherits sharing from its parent, `Call_Visit_Report__c`), 19 fields.

Fields: `CVR__c` (master/lookup to `Call_Visit_Report__c`), `Product__c`, `Sample_Lot__c`,
`Transaction__c` (lookup to the `Sample_Transaction__c` created once the call is
submitted), `Qty__c`, `Pack_Size__c`, `Unit_Value__c`, `Total_Value__c`, `Lot_Number__c`,
`Expiry_Date__c`, `Eligibility_Status__c`, `Eligibility_Message__c`, `Needs_Signature__c`,
`Requires_Approval__c`, `Limit_Override__c`, `Override_Reason__c`,
`Cold_Chain_Status__c`, `Cold_Chain_Tag_Number__c`, `Custom_Text__c`.

Class doc (`classes/SampleDropService.cls:1-7`): *"Sample lines on a call report.
Before a line is saved it is run through the eligibility rules: the soonest-expiring
lot is assigned (first expiry first out), the value is snapshotted, and a line that
breaks a hard rule is refused. Once the call is submitted, each line becomes a
completed disbursement transaction, which moves the stock (SampleTransactionService)."*
`SampleDropService.beforeInsert` (`SampleDropService.cls:12-27`) queries the parent
`Call_Visit_Report__c` (`OwnerId, HCP__c, Record_Status__c, Signature_Captured__c`) and
the `Product__c` (`Sample_Unit_Value_INR__c, Pack_Size__c, Requires_Signature__c,
Is_Controlled_Substance__c, Requires_Cold_Chain__c`) for every drop, then batches
same-product and same-call quantities for eligibility checking.

**Trigger**: `SampleDropTrigger.trigger` (before/after insert) →
`SampleDropService.beforeInsert` / `afterInsert`.
**Layout**: `layouts/Sample_Drop__c-Sample Drop Layout.layout-meta.xml`.
**Org data**: `SELECT COUNT(Id) FROM Sample_Drop__c` → **0**; and
`Call_Visit_Report__c WHERE Has_Samples__c = true` → **0** (of 26 total CVRs), i.e. no
sample-bearing calls exist yet in this sandbox.

### 1.8 Sample_Limit__c — configurable sampling limits

Evidence: `force-app/main/default/objects/Sample_Limit__c/` (`sharingModel = Read`), 12
fields, 3 validation rules (`Limit_Must_Be_Positive_Or_Zero`,
`Territory_Scope_Needs_Territory`, `Warning_Threshold_In_Range`).

Fields: `Product__c`, `Territory__c`, `Applies_To_User__c`, `Limit_Scope__c` (picklist,
**required**, values: `HCP_Product / HCP_All / Rep_Product / Rep_All /
Territory_Product / Per_Call / Product_Global` —
`Sample_Limit__c/fields/Limit_Scope__c.field-meta.xml`), `Limit_Period__c` (picklist,
**required**, values: `Per_Call / Daily / Weekly / Monthly / Quarterly / Financial_Year
/ Rolling_30 / Rolling_90 / Lifetime` — `fields/Limit_Period__c.field-meta.xml`),
`Limit_Quantity__c`, `Warning_Threshold_Pct__c`, `Hard_Block__c` (boolean),
`Is_Regulatory__c` (boolean), `Regulatory_Reference__c` (text, holds citations like
`SampleLimitChecker.UCPMP_REF = 'UCPMP 2024 Clause 5.1(ii)(b)'` —
`classes/SampleLimitChecker.cls:13`), `Override_Requires_Manager__c` (boolean),
`Is_Active__c` (boolean).

Class doc (`classes/SampleLimitChecker.cls:1-10`): *"Works out whether giving N more
packs of a product to a doctor stays inside every applicable Sample_Limit__c. Usage is
counted from completed disbursements; packs already on the same call are added because
they are not transactions until the call is submitted. Scopes: HCP_Product, HCP_All,
Rep_Product, Rep_All, Territory_Product, Per_Call, Product_Global. Periods: Financial
year runs April to March. A product's own Max_Packs_Per_HCP_Per_Year__c is honoured as
a regulatory limit as well. Overrides apply to company limits only, never to UCPMP
ones."* The `LimitCheck` inner class (`SampleLimitChecker.cls:16-30`) carries
`status` (OK/WARNING/BLOCKED), `hardBlock`, `regulatory`, `requiresManager`,
`needsReason`, `overrideId`/`overrideType`, `message`.

**Trigger**: `SampleLimitGuard.trigger` (before update, before delete) →
`SampleLimitGuardService.beforeLimitUpdate` / `beforeLimitDelete`
(`triggers/SampleLimitGuard.trigger`). `SampleLimitGuardService.cls:32` gates a check
with `FeatureManagement.checkPermission('Manage_Sample_Inventory')`.
**Layout**: `layouts/Sample_Limit__c-Sample Limit Layout.layout-meta.xml`.
**Org data**: `SELECT COUNT(Id) FROM Sample_Limit__c` → **0**.

### 1.9 Sample_Limit_Override__c

Evidence: `force-app/main/default/objects/Sample_Limit_Override__c/`
(`sharingModel = ControlledByParent`), 11 fields, 4 validation rules
(`Increase_Needs_A_Value`, `Override_Needs_A_Target`, `Reason_Is_Required`,
`Valid_To_After_From`).

Fields: `Sample_Limit__c` (parent lookup), `Target_Account__c`, `Target_User__c`,
`Override_Type__c`, `Override_Value__c`, `Reason__c`, `Status__c`, `Approved_By__c`,
`Approved_At__c`, `Valid_From__c`, `Valid_To__c`.
**Trigger**: `SampleLimitOverrideGuard.trigger` (before insert, before update) →
`SampleLimitGuardService.beforeOverrideSave`.
**Layout**: `layouts/Sample_Limit_Override__c-Sample Limit Override Layout.layout-meta.xml`.
**Org data**: `SELECT COUNT(Id) FROM Sample_Limit_Override__c` → **0**.

### 1.10 Sample_Allocation__c — period allocations of stock to a user/territory

Evidence: `force-app/main/default/objects/Sample_Allocation__c/`
(`sharingModel = Private`), 10 fields, 2 validation rules (`Allocation_Needs_A_Recipient`,
`Period_End_After_Start`).

Fields: `Product__c`, `Allocated_To_User__c`, `Allocated_To_Territory__c`,
`Allocation_Quantity__c`, `Used_Quantity__c`, `Remaining_Quantity__c`,
`Utilization_Pct__c`, `Period_Start__c`, `Period_End__c`, `Status__c`. Apex class
`SampleAllocationService.cls` exists (referenced in `Sciagen_Sample_Admin`
permission set §4.9) but was not opened for method-level detail in this pass.
**Layout**: `layouts/Sample_Allocation__c-Sample Allocation Layout.layout-meta.xml`.
**Org data**: `SELECT COUNT(Id) FROM Sample_Allocation__c` → **0**.

### 1.11 Sample_Warehouse__c

Evidence: `force-app/main/default/objects/Sample_Warehouse__c/` (`sharingModel = Read`),
11 fields: `Address__c`, `City__c`, `State__c`, `Country__c`, `Pin_Code__c`,
`Contact_Person__c`, `Contact_Phone__c`, `Has_Cold_Storage__c`, `Is_Active__c`,
`Rep_User__c` (a warehouse can be owned/represented by a specific rep, e.g. a personal
stock point), `Warehouse_Type__c` (picklist).
**Layout**: `layouts/Sample_Warehouse__c-Sample Warehouse Layout.layout-meta.xml`.
**Org data**: `SELECT COUNT(Id) FROM Sample_Warehouse__c` → **0**.

### 1.12 Sample_Blocked_Attempt__c — audit trail of refused sample attempts

Evidence: `force-app/main/default/objects/Sample_Blocked_Attempt__c/`
(`sharingModel = Read`), 8 fields: `Call_Report__c`, `HCP_Account__c`, `Product__c`,
`Rep__c`, `Quantity__c`, `Reason_Type__c`, `Reason__c`, `Attempted_At__c`.
Populated from the `Sample_Attempt__e` platform event pipeline — see §7.2.
**Layout**: `layouts/Sample_Blocked_Attempt__c-Sample Blocked Attempt Layout.layout-meta.xml`.
**Org data**: `SELECT COUNT(Id) FROM Sample_Blocked_Attempt__c` → **0**.

### 1.13 Sample_Expenditure_Tracking__c

Evidence: `force-app/main/default/objects/Sample_Expenditure_Tracking__c/`
(`sharingModel = Read`), 13 fields: `Financial_Year__c`, `HCP_Account__c`,
`HCP_Name__c`, `HCP_Registration__c`, `Product__c`, `Product_Name__c`,
`Total_Packs_Given__c`, `Total_Units_Given__c`, `Total_Value_INR__c`,
`Pack_Limit__c`, `Percent_Of_Limit__c`, `Last_Sample_Date__c`, `Tracking_Key__c`
(dedupe/upsert key, likely one row per HCP+Product+FY). Backing class
`SampleExpenditureService.cls` exists (per `classes/` listing) but its methods were
not read line-by-line in this pass.
**Layout**: `layouts/Sample_Expenditure_Tracking__c-Sample Expenditure Tracking Layout.layout-meta.xml`.
**Org data**: `SELECT COUNT(Id) FROM Sample_Expenditure_Tracking__c` → **0**.

### 1.14 Sample_Attempt__e — platform event (publish/subscribe log of sample attempts)

Evidence: `force-app/main/default/objects/Sample_Attempt__e/`, 7 fields: `Call_Id__c`,
`HCP_Id__c`, `Product_Id__c`, `Rep_Id__c`, `Quantity__c`, `Reason_Type__c`, `Reason__c`.
**Subscriber**: `SampleAttemptEventTrigger.trigger` — *"trigger SampleAttemptEventTrigger
on Sample_Attempt__e (after insert) { SampleAttemptLogService.log(Trigger.new); }"*
(full file, `triggers/SampleAttemptEventTrigger.trigger`). This is a very thin
after-insert trigger that hands the whole batch to `SampleAttemptLogService.log()`,
which (based on the object's field shape and `Sample_Blocked_Attempt__c`'s matching
field shape) most likely persists blocked/attempted sampling events into
`Sample_Blocked_Attempt__c` for audit. **Publisher**: not located in this pass — no
`EventBus.publish` call was found for `Sample_Attempt__e` in the classes read so far;
this needs a targeted grep (`grep -rn "Sample_Attempt__e" force-app/main/default/classes/*.cls`)
before the Sample Management build assumes where publishing happens (possibly only from
the iPad client via the standard REST/Platform Event publish endpoint, not from server
Apex at all — UNVERIFIED, flagged for follow-up).

### 1.15 Consent__c and children — HCP consent/opt-in

Evidence: `force-app/main/default/objects/Consent__c/` (`sharingModel = Private`), 16
fields; `Consent_Channel__c`, `Consent_Email__c`, `Consent_Product__c` (all
`sharingModel = ControlledByParent`, 3 fields each — child detail objects).

`Consent__c` fields: `HCP__c` (lookup), `Consent_Purpose__c` (multi-select picklist —
`SampleEligibilityService.cls:115` queries
`WHERE Consent_Purpose__c INCLUDES ('Sample_Opt_In')`, confirming `Sample_Opt_In` is one
purpose value among possibly others), `Sample_Opt_In_Signature__c`,
`Sample_Opt_In_Valid_Until__c` (expiry — consent isn't permanent),
`Signed__c`, `Signed_At__c`, `Signer_Name__c`, `Signature_Meaning__c`,
`Captured_At__c`, `Mobile_Number__c`, `Mobile_Opt_In__c`, `Mobile_Verified__c`,
`WhatsApp_Number__c`, `WhatsApp_Opt_In__c`, `WhatsApp_Verified__c`, `Email_Verified__c`.

This is the **consent gate for sampling**: `SampleEligibilityService.cls:70-73` —
*"3. sample opt-in ... `String m = 'No valid sample opt-in consent for ' + hcp.Name +
'. Capture it before sampling.'; if (cfg.optInHardBlock) block(r, m); else
r.warnings.add(m);`"* — driven by `SampleConfig.requireOptIn`/`optInHardBlock`, which
load from the `UCPMP_Tenant_Config__c` custom setting (§6.4).

**Layout**: `layouts/Consent__c-HCP Consent Layout.layout-meta.xml`,
`Consent_Channel__c-Consent — Channel Preference Layout.layout-meta.xml`,
`Consent_Email__c-Consent — Email Channel Layout.layout-meta.xml`,
`Consent_Product__c-Consent — Product Preference Layout.layout-meta.xml`. **Tab**:
`tabs/Consent__c.tab-meta.xml` (only the parent has a tab; children are accessed as
related lists).
**Org data**: `Consent__c` → **4**; `Consent_Channel__c` → **12**; `Consent_Email__c` →
**4**; `Consent_Product__c` → **0**.

### 1.16 Call_Visit_Report__c and CVR children — field-rep call logging

Evidence: `force-app/main/default/objects/Call_Visit_Report__c/`
(`sharingModel = Private`), 38 fields; `CVR_Attendee__c`, `CVR_Internal_Attendee__c`
(both `sharingModel = ControlledByParent`, 2 fields each).

Key fields: `Rep__c`, `HCP__c`, `HCO__c`, `Territory__c`, `Call_Type__c`,
`Call_Status__c`, `Record_Status__c`, `Activity_Type__c`, `Visit_Date__c`,
`Start_Time__c`, `End_Time__c`, `Duration_Minutes__c`,
`Check_In_At__c`/`Check_In_Location__c`/`Check_In_Accuracy_M__c` (GPS check-in),
`Pre_Call_Notes__c`, `Discussion_Summary__c`, `Next_Call_Notes__c`,
`Next_Visit_Date__c`, `Plan__c` (lookup to an account plan), `Has_Samples__c` (boolean
gate — read by `SampleDropService`), `Sample_Drop_Count__c`, `Sample_Total_Value__c`
(rollups from `Sample_Drop__c` children), `Signature_Captured__c`,
`Signature_Captured_At__c`, `Signature_Image__c`, `Signature_GPS__c`,
`Signature_Required__c`, `Signature_Required_Count__c`, `Signee_Account__c`,
`Signee_Name__c`, `Unlock_Request__c`, `Unlocked_At__c`, `Unlocked_By__c`,
`Unlock_Count__c` (a submitted/locked call can be reopened via a tracked unlock
workflow — see `SupportUnlockService`/`SupportCallRelockTrigger`, §3.4),
`Linked_Event_Count__c`, `Email_Sent__c`, `Record_Type_Label__c`.

**Triggers**: `SampleCallTrigger.trigger` (before update, after insert/update) →
`SampleDropService.beforeCallUpdate` / `afterCallSubmit` — the point where sample
drop lines become real ledger transactions once a call is submitted;
`SupportCallRelockTrigger.trigger` (after update) → `SupportUnlockService.afterCallSubmit`;
`PlannedCallTerritoryShareSync.trigger` targets the related `Planned_Call__c` object,
not this one directly (§3.2).
**Layout**: `layouts/Call_Visit_Report__c-Call Visit Report Layout.layout-meta.xml`.
**Tab**: `tabs/Call_Visit_Report__c.tab-meta.xml`. **Flexipage**:
`flexipages/Call_Reports_Page.flexipage-meta.xml` / `tabs/Call_Reports_Page.tab-meta.xml`
(a browser-style page, backed by LWC `callVisitReportBrowser` — §8.1).
**Org data**: `SELECT COUNT(Id) FROM Call_Visit_Report__c` → **26** total;
`WHERE Has_Samples__c = true` → **0**.

### 1.17 Planned_Call__c, Call_Backdate_Limit__c, Call_Submission_Restriction__c

`Planned_Call__c` (`sharingModel = Private`, 13 fields) — the scheduled/planned
counterpart to `Call_Visit_Report__c`; shared via Apex managed sharing driven by
territory (`PlannedCallTerritoryShareSync.trigger`, §3.2) and validated against office
hours by `PlannedCallOfficeHoursValidation.trigger` → `PlannedCallOfficeHoursValidator.cls`,
which reads `Office_Hours_Setting__mdt` (§6.1). **Layout**:
`layouts/Planned_Call__c-Planned Call／Event Layout.layout-meta.xml`. **Org data**:
`SELECT COUNT(Id) FROM Planned_Call__c` → **69**.

`Call_Backdate_Limit__c` and `Call_Submission_Restriction__c` are **Hierarchy Custom
Settings** (confirmed via `<customSettingsType>Hierarchy</customSettingsType>` in both
`.object-meta.xml` files), not regular objects — see §6.2. They constrain how far back
a call can be dated and what's required to submit one; not opened field-by-field in
this pass.

### 1.18 Territory__c and related territory objects

`Territory__c` (`sharingModel = Read`, only 3 fields: `Territory_Code__c`, `Type__c`,
`Parent_Territory__c` — a simple self-hierarchical territory tree).
`Account_Territory__c` (`Read`, 2 fields), `User_Territory__c` (`Read`, 3 fields),
`Product_Territory_Assignment__c` (`Read`, 2 fields, §1.4) are junction objects tying
accounts/users/products to territories.

Standard `Territory2` is **not enabled/used**: `SELECT COUNT(Id) FROM Territory2`
returned `sObject type 'Territory2' is not supported`, confirming this org implements
its own custom territory model (`Territory__c` + junctions) instead of Enterprise
Territory Management. **Org data**: `Territory__c` → **18**; `Account_Territory__c` →
**140**; `User_Territory__c` → **11**; `Product_Territory_Assignment__c` → **216**.
Territory-driven record visibility is implemented entirely through Apex managed
sharing — see §3.2.

### 1.19 Sales_Transaction__c

`sharingModel = Read`, 6 fields. Not deeply read in this pass; listed in the
`Sciagen_Mobile_App_Access` permission set (§4.7) alongside `Sales_Target__c`,
suggesting a secondary-sales/claim tracking feature, not directly part of the sample
chain but worth checking during the Sample Management build for any overlap with
UCPMP "domestic sales" figures (`UCPMP_Tenant_Config__c.Domestic_Sales_Revenue_INR__c`
is currently a manually-entered field, not derived from `Sales_Transaction__c` — see
`SampleConfig.cls:22`). **Org data**: `SELECT COUNT(Id) FROM Sales_Transaction__c` → **0**.

### 1.20 UCPMP_Tenant_Config__c — compliance configuration (Custom Setting)

This is a **Hierarchy Custom Setting**, not a plain custom object — confirmed by
`<customSettingsType>Hierarchy</customSettingsType>` and `<visibility>Public</visibility>`
in `force-app/main/default/objects/UCPMP_Tenant_Config__c/UCPMP_Tenant_Config__c.object-meta.xml`.
16 fields: `UCPMP_Compliance_Enabled__c`, `Enforce_Sample_Rules__c`,
`Require_Sample_Opt_In__c`, `Sample_Opt_In_Hard_Block__c`, `Sample_Opt_In_Months__c`,
`Domestic_Sales_Revenue_INR__c`, `Financial_Year__c`, `Company_Name__c`,
`Company_CIN__c`, `Company_PAN__c`, `Company_Address__c`, `Company_Email__c`,
`Signatory_Designation__c`, `Signatory_DIN_or_PAN__c`, `Signatory_Email__c`,
`Signatory_Mobile__c`.

Loaded via `UCPMP_Tenant_Config__c.getOrgDefaults()` in `SampleConfig.load()`
(`classes/SampleConfig.cls:1-27`), whose doc comment explains: *"Reads
UCPMP_Tenant_Config__c with sensible defaults when nothing is saved yet
(getOrgDefaults() returns an empty record, and custom-setting checkbox defaults are not
applied to it, so the defaults live here)"* — i.e. the code-level defaults
(`complianceEnabled = true`, `enforceRules = true`, `requireOptIn = false`,
`optInHardBlock = false`, `optInMonths = 12`) take effect until an admin actually saves
a `UCPMP_Tenant_Config__c` org-default record.
`SampleConfig.twoPercentCap()` (`SampleConfig.cls:29-31`) computes the UCPMP 2%-of-sales
sample-spend ceiling. **Org data**: `SELECT COUNT(Id) FROM UCPMP_Tenant_Config__c` →
**0** (no config record saved in this sandbox — the org-default is unset, so the
hard-coded defaults in `SampleConfig` are what's actually in effect right now).

### 1.21 Data_Change_Request__c / DCR_Comment__c

Not on the primary sample-relevance list but touched because it's automated (§5) and
permissioned distinctly (§4.11). `sharingModel` not captured in this pass — flagged for
follow-up. **Org data**: `SELECT COUNT(Id) FROM Data_Change_Request__c` → **9**.

### 1.22 Standard objects — how they're used

- **Account**: **0 records**, `Person Accounts` not enabled (`IsPersonAccount` invalid
  field). Not the object driving HCP/HCO data — see `Sciagen_Account__c` (§1.1). No
  custom fields were inventoried on `Account` in this pass since it appears unused by
  the sample/account domain.
- **Contact, Lead, Opportunity, Case, User**: present with standard duplicate rules
  defined for Account/Contact/Lead (§4.12); not deep-dived field-by-field in this pass.
  `User` active count: `SELECT COUNT(Id) FROM User WHERE IsActive = true` → **17**.
- **Product2**: standard object present but **0 records**; only artifact found is the
  stock layout `layouts/Product2-Product Layout.layout-meta.xml` — effectively unused,
  `Product__c` is the real product object (§1.2).
- **Territory2**: **not supported in this org** (query error, confirming Enterprise
  Territory Management isn't enabled) — the custom `Territory__c` model is used
  instead (§1.18).
- **Event / Task**: no evidence of direct customization found in the objects checked;
  `Call_Visit_Report__c` and `Planned_Call__c` are the custom analogues actually used
  for visit/activity tracking, not standard `Event`/`Task`. Flagged UNVERIFIED for any
  residual Task/Event usage elsewhere — not exhaustively grepped in this pass.

### 1.23 Other objects with "lot/inventory/warehouse"-adjacent names

A full listing of `force-app/main/default/objects/` (101 entries) was reviewed; besides
the `Sample_*` objects already covered, no additional inventory/lot/warehouse/stock
objects exist. The complete object list (for reference) includes: `Account_Plan__c`,
`Account_Team_Member__c`, `Affiliation__c`, `Alert_Recipient__c`, `Approved_Content__c`,
`Clinical_Trial__c`, `Congress_Event__c`, `Content_Alert__c`, `Custom_List__c` /
`Custom_List_Member__c`, `Daily_Expense__c` / `Daily_Expense_Bill__c`,
`Device_Reset_Request__c`, `Duplicate_Candidate__c`, `Duplicate_Setting__c`,
`Email_Template__c` / `Email_Template_Content__c`, `Expense_Patch__c`, `Influence_Peer__c`,
`Key_Message__c`, `Leave_Request__c`, `Merge_Log__c`, `Monthly_Claim__c` /
`Monthly_Claim_Bill__c`, `Office_Hours_Setting__mdt`, `Office_Window__c`, `POB_Line__c`,
`Plan_Activity__c` / `Plan_Goal__c` / `Plan_Stakeholder__c` / `Plan_Strategy__c`,
`Presentation__c` / `Presentation_Favorite__c` / `Presentation_Session__c`,
`Product_Plan_Template__c`, `Product_Strategy__c`, `Promo_Drop__c`, `Publication__c`,
`RCPA_Audit__c` / `RCPA_Competitor__c` / `RCPA_Line__c` / `RCPA_Target__c`,
`Rep_Preference__c`, `Sales_Target__c`, `Saved_Filter__c`, `Sciagen_Alert__c`,
`Segmentation__c` / `Segmentation_Product__c`, `Sent_Email__c` / `Sent_Email_Attachment__c`,
`Slide__c` / `Slide_Event__c`, `Support_Comment__c` / `Support_Request__c` /
`Support_Setting__c`, `Sync_Tracking__c` (§7.2), `*__mdt` custom metadata types (§6.1),
`Molecule__mdt`, `Division__mdt`, `Geocoding_Config__mdt`, `Expense_Rate_Card__mdt`,
`Holiday__mdt`, `Leave_Entitlement__mdt`, `Sciagen_App_Config__mdt`.
None of these were field-audited in this pass (out of stated scope for this task).

---

## 2. Record Types, Page Layouts, Lightning Record Pages, Compact Layouts

- **Record types**: none exist for any object checked — no `recordTypes/` subfolder
  under any object in `force-app/main/default/objects/` matching sample/product/
  account/call/consent naming (verified with a recursive `find`). UNVERIFIED whether
  any org-only record type exists that wasn't retrieved into source.
- **Compact layouts**: none exist (no `compactLayouts/` subfolder found under any
  object checked).
- **Page layouts**: stored flat under `force-app/main/default/layouts/` (251 files
  total). One layout exists per relevant object, named `<Object>-<Layout Name>.layout-meta.xml`
  — see the per-object citations in §1 above (e.g. `Sample_Lot__c-Sample Lot Layout.layout-meta.xml`).
  Layouts also exist for objects outside the custom package, e.g.
  `AuthorizationFormConsent-Authorization Form Consent Layout.layout-meta.xml`,
  `ContactPointTypeConsent-Contact Point Type Consent Layout.layout-meta.xml`,
  `OpportunityLineItem`, `OrderItem`, `FulfillmentOrderLineItem`,
  `ProductConsumptionSchedule`, `ServiceTerritory`/`ServiceTerritoryMember` — these look
  like default Salesforce layouts pulled in incidentally (e.g. via a metadata retrieve
  that grabbed standard objects touched by installed features/licenses), not evidence
  of active use of Order Management / standard consent objects / Field Service.
  UNVERIFIED whether any of those standard-object layouts are actually assigned/used —
  flagged, not claimed as in-use.
- **Lightning record pages (flexipages)** relevant to this domain:
  `Account_Browser_Page`, `Account_Plan_Browser_Page`, `Account_Plan_Record_Page`,
  `Call_Reports_Page`, `Global_Account_Search_Page`, `Sample_Administration_Page`,
  `Sciagen_Account_Record_Page`, `Sciagen_Account_Record_Page1`,
  `UCPMP_Compliance_Page` — all under `force-app/main/default/flexipages/`.

---

## 3. Sharing

### 3.1 Org-Wide Defaults (sharingModel per object)

From each object's `.object-meta.xml` `<sharingModel>` tag:

| Object | sharingModel |
|---|---|
| Product__c | Read |
| Product_Master__c | Read |
| Product_Territory_Assignment__c | Read |
| Sciagen_Account__c | **Private** |
| Sample_Allocation__c | **Private** |
| Sample_Lot__c | **Private** |
| Sample_Transaction__c | **Private** |
| Sample_Drop__c | ControlledByParent |
| Sample_Limit__c | Read |
| Sample_Limit_Override__c | ControlledByParent |
| Sample_Warehouse__c | Read |
| Sample_Blocked_Attempt__c | Read |
| Sample_Expenditure_Tracking__c | Read |
| Consent__c | **Private** |
| Consent_Channel__c / Consent_Email__c / Consent_Product__c | ControlledByParent |
| Call_Visit_Report__c | **Private** |
| CVR_Attendee__c / CVR_Internal_Attendee__c | ControlledByParent |
| Territory__c | Read |
| Planned_Call__c | **Private** |
| Account_Territory__c | Read |
| User_Territory__c | Read |
| Sales_Transaction__c | Read |

Standard `Account`/`Contact`/`Lead`/`Opportunity`/`Case` OWDs were **not captured** in
this pass (would need a live check or profile/global describe — UNVERIFIED).

### 3.2 Apex Managed Sharing — the real access-control mechanism

**No `sharingRules/` directory exists** in this metadata (`ls sharingRules` → not
found), and **no `restrictionRules/` directory exists** either. Record visibility for
the `Private` objects above is instead implemented entirely through **Apex managed
sharing**, driven by territory assignment, via a family of small trigger+service pairs:

- `AccountTerritoryShareSync.trigger` (`triggers/AccountTerritoryShareSync.trigger`,
  20 lines) — doc comment: *"Keeps Sciagen_Account__Share AND Planned_Call__Share in
  sync whenever an account's territory assignment changes — a Planned_Call__c's own
  visibility..."* — i.e. changing an `Account_Territory__c` assignment cascades share
  rows onto both `Sciagen_Account__Share` and `Planned_Call__Share`.
- `PlannedCallTerritoryShareSync.trigger` (14 lines) — *"Keeps Planned_Call__Share in
  sync whenever a call's HCP__c/HCO__c changes (including on insert, e.g. a rep
  scheduling a new call)."* → calls `PlannedCallTerritorySharingService`.
- `RCPAAuditTerritoryShareSync.trigger` (14 lines) — *"Keeps RCPA_Audit__Share in sync
  whenever an audit's Territory__c changes..."* → `RCPAAuditTerritorySharingService`.
- `UserTerritoryShareSync.trigger` (25 lines) — *"Keeps Sciagen_Account__Share,
  Planned_Call__Share, AND RCPA_Audit__Share in sync whenever a user's territory
  assignment changes."* → likely `TerritorySharingService`/`SampleTerritoryService`
  (class not opened line-by-line in this pass).

This means **`Sciagen_Account__Share` and `Planned_Call__Share` are actively used
Apex-managed-sharing objects**; `RCPA_Audit__Share` also exists for the RCPA (retail
chemist/pharmacy audit?) feature. No `__Share` write for `Sample_Lot__c` or
`Sample_Transaction__c` was found in the trigger set inventoried — those two `Private`
sample objects' visibility model (owner + role hierarchy only, or something else) is
**UNVERIFIED** and should be confirmed before the Sample Management build assumes reps
can see each other's lots/transactions through any specific mechanism. Supporting
service classes referenced: `PlannedCallTerritorySharingService.cls`,
`RCPAAuditTerritorySharingService.cls`, `TerritorySharingService.cls`,
`SampleTerritoryService.cls` (used by `SampleLotService.cls:11`), each with a
matching `*Test.cls`, plus a standalone `RoleHierarchySharingTest.cls` suggesting some
role-hierarchy-based sharing is also tested/expected somewhere in the org.

### 3.3 Role Hierarchy

No `force-app/main/default/roles/` directory exists in this metadata — the role tree
itself is **UNVERIFIED** from source. `RoleHierarchySharingTest.cls` (in `classes/`)
implies role hierarchy is relied on for at least some sharing behavior, but the actual
role structure would need `sf project retrieve start -m "Role" -o sciagen-sandbox -r /tmp/sciagen-audit-retrieve`
(read-only retrieve into a temp folder) to inspect.

### 3.4 Duplicate/Dedupe and Data-Change-Request automation (sharing-adjacent)

- `SciagenAccountDedupe.trigger` (10 lines) — *"Keeps duplicate-detection match keys
  current and queues a background duplicate check for new or materially edited HCP/HCO
  records."* Backed by `DuplicateEngine.cls`, `DuplicateMatchService.cls`,
  `DuplicateMergeService.cls`, `DuplicateSurvivorship.cls`, `DuplicateKeyService.cls`,
  `DuplicateScanBatch.cls`/`DuplicateScanQueueable.cls`/`DuplicateScanScheduler.cls`
  (batch/queueable/scheduled trio for background scanning), gated by the
  `Manage_Duplicates` custom permission (§4.11).
- `DataChangeRequestTrigger.trigger` (4 lines, before update) →
  `DataChangeRequestApprovalHandler.handleApprovals` — a locked/approved-data change
  request workflow (§5.10 below has more detail once read).
- `SupportCallRelockTrigger.trigger` (after update on `Call_Visit_Report__c`) →
  `SupportUnlockService.afterCallSubmit` — re-locks a call after it's been temporarily
  unlocked for correction, gated by the `Support_Unlock_Calls` custom permission (§4.11).

---

## 4. Security

### 4.1 Profiles

`force-app/main/default/profiles/` contains only `Admin.profile-meta.xml` and
`Business Admin.profile-meta.xml`. Neither was diffed field-by-field for FLS on
sample/consent/licensing fields in this pass (large XML files) — flagged for follow-up
if profile-level FLS specifics are needed; access in this org is primarily managed
through the permission sets in §4.2–4.11, which is the more actionable layer for a new
module anyway.

### 4.2 Custom Permissions

`force-app/main/default/customPermissions/`: `Manage_Duplicates`,
`Manage_Sample_Inventory`, `Support_Agent`, `Support_Unlock_Calls`. All four are
**actively checked in Apex** via `FeatureManagement.checkPermission(...)`:

| Custom Permission | Checked in |
|---|---|
| `Manage_Duplicates` | `DuplicateAdminController.cls:20` |
| `Manage_Sample_Inventory` | `SampleAdminController.cls:118,129`; `SampleDropService.cls:165`; `SampleLimitGuardService.cls:32`; `SampleTransactionService.cls:56`; `UCPMPComplianceController.cls:41,48` |
| `Support_Agent` | `SupportRequestService.cls:23` (`isAgent()` helper) |
| `Support_Unlock_Calls` | `SupportConsoleController.cls:63`; `SupportUnlockService.cls:25` (combined with `isAgent()`) |

`Manage_Sample_Inventory` is the single permission gating almost every sample-inventory
write path (stock changes, limit/override edits, UCPMP settings edits) — this is the
key permission the Sample Management module will need to reason about.
`Sciagen_Sample_Admin.permissionset-meta.xml` grants `customPermissions` including this
one (`grep -A1 customPermissions` on that file shows `<enabled>true</enabled>` under a
`Manage_Sample_Inventory` block).

### 4.3–4.10 Permission Sets

`force-app/main/default/permissionsets/` (Salesforce-internal ones —
`sfdcInternalInt__sfdc_chatbot`, `sfdcInternalInt__sfdc_scrt2`,
`sfdc_aiplanner_service_permset` — skipped as out of scope):

| Permission Set | Object grants (sample) | Apex class access (sample) | Purpose (from content) |
|---|---|---|---|
| `SciagenCrm.permissionset-meta.xml` | 56 objects incl. `Sciagen_Account__c`, `Product__c`, `Product_Master__c`, `Sample_Drop__c`, `Consent__c`, `Consent_Channel__c`, `Consent_Email__c`, `Call_Visit_Report__c`, `Planned_Call__c`, `Territory__c` | `SciagenAccountSyncService`, `SciagenScheduleController(+Test)` | Broad general-CRM permission set (~all core objects, not sample-inventory-heavy) |
| `Sciagen_Mobile_App_Access.permissionset-meta.xml` | 78 objects — the broadest set; includes **every** sample object (`Sample_Allocation__c`, `Sample_Blocked_Attempt__c`, `Sample_Drop__c`, `Sample_Expenditure_Tracking__c`, `Sample_Limit__c`, `Sample_Limit_Override__c`, `Sample_Lot__c`, `Sample_Transaction__c`, `Sample_Warehouse__c`), plus `Consent__c`/`Consent_Channel__c`/`Consent_Email__c`/`Consent_Product__c`, `Sync_Tracking__c`, `Sales_Transaction__c`, `Sales_Target__c` | `SciagenAccountSyncService`, `SupportController`, `SupportListService` | This is what the **iPad field rep** gets — the object list matches exactly what a rep needs to run calls, samples, and sync offline |
| `Sciagen_Sample_Admin.permissionset-meta.xml` | 9 objects: `Product__c` + all `Sample_*` inventory objects | `HcpLicenseExpiryBatch`, `SampleAdminController`, `SampleAllocationService`, `SampleAttemptLogService`, `SampleConfig` | Description (verbatim, `<description>` tag): *"Lets a sample administrator manage sample products, lots, warehouses, transactions, limits, allocations and UCPMP reports. Assign only to sample administrators."* Also grants `Manage_Sample_Inventory` custom permission. **This is the sample-admin role of record.** |
| `Sciagen_Manager_Access.permissionset-meta.xml` | `Device_Reset_Request__c` only | `DeviceResetAdminController`, `DeviceResetRequestHandler` | Narrow — device reset approvals for a manager |
| `Sciagen_Zonal_Manager_Access.permissionset-meta.xml` | `Data_Change_Request__c`, `Account_Territory__c`, `DCR_Comment__c` | (none captured) | Zonal-manager-level DCR review/territory access |
| `Sciagen_Support_Agent.permissionset-meta.xml` | `Support_Comment__c`, `Support_Request__c` | `SupportAssignmentService`, `SupportAutoCloseBatch`, `SupportCommentService`, `SupportConfig`, `SupportConsoleController` | Support-desk agent access |
| `Sciagen_LWC_App_Access.permissionset-meta.xml` | `Affiliation__c`, `Congress_Event__c`, `Device_Reset_Request__c`, `Publication__c`, `Sciagen_Account__c` | `AccountPlanController`, `AccountPlanExportPdfController`, `AccountPlanHomeDashboardController`, `GlobalAccountSearchController`, `RCPAController` | General LWC app UI access (account plans, global search, RCPA) — not sample-specific |
| `Product_Territory_Assignment_Access.permissionset-meta.xml` | `Product_Territory_Assignment__c` only | (none) | Narrow, single-object — territory planning capability |
| `CMS_Integration_Access.permissionset-meta.xml` | `Approved_Content__c`, `Presentation__c`, `Product__c`, `Slide__c` | (none) | Content management / CLM-library integration access |
| `Report_Dashboard_Builder_Access.permissionset-meta.xml` | 0 object grants found | (none) | Likely a system-permission-only set for report/dashboard building (not field/object grants) |
| `Experience_Profile_Manager.permissionset-meta.xml` | 0 object grants found | (none) | Likely a system-permission-only set; no evidence of an active Experience Cloud site was found elsewhere (§8.4) |

**No permission set groups exist** (`force-app/main/default/permissionsetgroups/` not
found).

### 4.11 Duplicate Rules

`force-app/main/default/duplicateRules/`: `Account.Standard_Account_Duplicate_Rule`,
`Contact.Standard_Contact_Duplicate_Rule`, `Lead.Standard_Lead_Duplicate_Rule` — these
are the out-of-the-box Salesforce duplicate rules on **standard** objects (which, per
§1.22, hold ~0 of the actual HCP/HCO data). The real dedupe engine for
`Sciagen_Account__c` is the custom Apex one in §3.4
(`DuplicateEngine`/`DuplicateMatchService`/etc.), not these standard rules. Rule
criteria/actions were not opened in this pass (not the primary object family).

---

## 5. Automation

### 5.1 Trigger framework pattern

**No shared `TriggerHandler`/dispatcher base class was found.** Every trigger in
`force-app/main/default/triggers/` (22 files) is a **thin, one-purpose dispatcher**:
it names the object and events directly, and immediately delegates to one or two static
methods on a same-named `*Service`/`*Handler` class. Trigger bodies range from 2 to 46
lines; most are 2–6 lines. This is a "skinny trigger, fat service class" pattern, not a
TDTM- or Handler-interface-based framework. Full inventory (object → events → delegate):

| Trigger | Object | Events | Delegates to |
|---|---|---|---|
| `AccountTerritoryShareSync` | `Account_Territory__c` (implied by name/doc) | (not fully read — doc-commented as territory-change-driven) | share-sync logic, see §3.2 |
| `AffiliationSync` | `Affiliation__c` | after insert/update/delete/undelete | `AffiliationSyncService.enforcePrimaryUniqueness` |
| `DataChangeRequestTrigger` | `Data_Change_Request__c` | before update | `DataChangeRequestApprovalHandler.handleApprovals` |
| `DeviceResetRequestTrigger` | `Device_Reset_Request__c` | before/after insert, before/after update | `DeviceResetRequestHandler` (stamps `Manager__c` before insert for approval routing) |
| `PlannedCallOfficeHoursValidation` | `Planned_Call__c` | (doc: blocks save outside office hours) | `PlannedCallOfficeHoursValidator` + `Office_Hours_Setting__mdt` |
| `PlannedCallTerritoryShareSync` | `Planned_Call__c` | (territory-change-driven) | `PlannedCallTerritorySharingService` |
| `RCPAAuditTerritoryShareSync` | `RCPA_Audit__c` | (territory-change-driven) | `RCPAAuditTerritorySharingService` |
| `SampleAttemptEventTrigger` | `Sample_Attempt__e` | after insert | `SampleAttemptLogService.log` |
| `SampleCallTrigger` | `Call_Visit_Report__c` | before update, after insert/update | `SampleDropService.beforeCallUpdate` / `afterCallSubmit` |
| `SampleDropTrigger` | `Sample_Drop__c` | before/after insert | `SampleDropService.beforeInsert` / `afterInsert` |
| `SampleLimitGuard` | `Sample_Limit__c` | before update, before delete | `SampleLimitGuardService.beforeLimitUpdate` / `beforeLimitDelete` |
| `SampleLimitOverrideGuard` | `Sample_Limit_Override__c` | before insert, before update | `SampleLimitGuardService.beforeOverrideSave` |
| `SampleLotTrigger` | `Sample_Lot__c` | before insert/update | `SampleLotService.beforeSave` |
| `SampleTransactionTrigger` | `Sample_Transaction__c` | before/after insert/update | `SampleTransactionService.beforeSave` (+ presumed `afterSave`) |
| `SciagenAccountAddressSync` | `Sciagen_Account__c` | (doc: keeps address/geolocation consistent both directions) | inline/`SciagenAccountSyncService`-adjacent logic |
| `SciagenAccountDedupe` | `Sciagen_Account__c` | (doc: match keys + queues background dupe check) | `DuplicateEngine`/`DuplicateKeyService`/`DuplicateScanQueueable` |
| `SupportAttachmentTrigger` | `ContentDocumentLink` | before insert, after insert, after delete | `SupportFileService.validateLinks` / `countLinks` |
| `SupportCallRelockTrigger` | `Call_Visit_Report__c` | after update | `SupportUnlockService.afterCallSubmit` |
| `SupportCommentTrigger` | `Support_Comment__c` | before/after insert | `SupportCommentService.beforeInsert` / `afterInsert` |
| `SupportFileTrigger` | `ContentVersion` | before insert | `SupportFileService.validateVersions` |
| `SupportRequestTrigger` | `Support_Request__c` | before insert/update, after insert/update | `SupportRequestService.beforeInsert` / `beforeUpdate` / (after handlers) |
| `UserTerritoryShareSync` | `User_Territory__c` (implied) | (territory-change-driven) | share-sync logic, see §3.2 |

### 5.2 Apex service classes (sample/product/consent/compliance/sync-relevant)

All in `force-app/main/default/classes/` (109 `.cls` files total; full name list
captured in this pass — see §1.23-adjacent listing above for non-sample classes).
Sample/compliance-relevant ones, each with what was actually read:

- **`SampleConfig.cls`** — loads `UCPMP_Tenant_Config__c` org defaults with hard-coded
  fallbacks; `twoPercentCap()` computes the UCPMP 2%-of-sales cap. (Full text read, §1.20.)
- **`SampleLimitChecker.cls`** — evaluates a proposed disbursement against every
  applicable `Sample_Limit__c` scope/period, plus the product's own
  `Max_Packs_Per_HCP_Per_Year__c`; returns `LimitCheck`/`LimitCheckResult` DTOs with
  OK/WARNING/BLOCKED status. (Header + inner classes read, §1.8.)
- **`SampleEligibilityService.cls`** — *"the single answer to 'can this rep give this
  product to this doctor now?'"* Combines product rules, HCP licence, controlled-substance
  licence, sample opt-in consent (queries `Consent__c` for `Sample_Opt_In` purpose),
  lot choice (FEFO — first-expiry-first-out) with stock/expiry/cold-chain, and
  `SampleLimitChecker`. Explicitly noted as mirrored offline: *"The iPad runs the same
  rules offline against its synced copies; this is the authority."* (Header + consent
  check at line 115 read.)
- **`SampleDropService.cls`** — turns call-report sample lines into eligibility-checked,
  value-snapshotted drops, then into ledger transactions on call submission (FEFO lot
  assignment). (Header + `beforeInsert` read, §1.7.)
- **`SampleTransactionService.cls`** — the stock ledger: `beforeSave` validates/snapshots/
  computes signed lot effect, `afterSave` moves stock; transaction types `Receipt`,
  `Disbursement`, `Transfer_Out`, `Transfer_In`, `Return`, `Adjustment`; explicitly
  `without sharing` because "a transfer or receipt changes lots owned by another rep."
  (Header read, §1.6.)
- **`SampleLotService.cls`** — lot housekeeping: per-holder key, ownership-follows-rep,
  Active/Depleted status flip. (Full `beforeSave` opening read, §1.5.)
- **`SampleLotExpiryBatch.cls`** — `Database.Batchable<SObject>, Schedulable`; daily job
  expiring lots past `Expiry_Date__c`. (Full `start`/`execute` opening read, §1.5.)
- **`HcpLicenseExpiryBatch.cls`** — `Database.Batchable<SObject>, Schedulable`; daily
  job flipping `Sciagen_Account__c.License_Verification_Status__c` to `Expired` once
  `License_Expiry_Date__c` passes (note: doesn't stop sampling itself — that's already
  gated by `Sample_Eligible__c`, per its own doc comment — it just keeps the status
  field honest). (Full `start`/`execute` read, §1.1/§1.20.)
- **`SampleLimitGuardService.cls`** — backs the two guard triggers on
  `Sample_Limit__c`/`Sample_Limit_Override__c`; checks `Manage_Sample_Inventory`
  permission at line 32. (Not fully read beyond that grep hit.)
- **`SampleAllocationService.cls`**, **`SampleAttemptLogService.cls`**,
  **`SampleExpenditureService.cls`**, **`SampleAdminController.cls`**,
  **`SampleNotifier.cls`**, **`SampleTerritoryService.cls`** — referenced/used by the
  classes above (e.g. `SampleTerritoryService.namesFor()` called from
  `SampleLotService.cls:11`; `SampleAdminController` gates writes with
  `Manage_Sample_Inventory` at lines 118/129) but not opened method-by-method in this
  pass — flagged for a deeper read before the new module builds on them.
- **`UCPMPComplianceService.cls`** — *"UCPMP 2024 sample compliance: the year's sample
  expenditure against the 2% ceiling, the per-doctor distribution, refused attempts, and
  the annual disclosure form (Annexure to clauses 5.1(g) and 14.4)."* `UCPMPSummary`
  inner DTO includes `financialYear`, `domesticSalesInr`, `capInr`, `spentInr`,
  `percentOfSales`, `percentOfCap`, `status` (Within/Approaching/Exceeding/No sales
  figure), `hcpCount`, `packs`. (Header + DTO fields read, §1.20 note about the 2%
  ceiling.)
- **`UCPMPComplianceController.cls`** — Aura/LWC-facing controller wrapping
  `UCPMPComplianceService`; gates edits with `Manage_Sample_Inventory` (lines 41, 48).
- **`UCPMPDisclosureController.cls`** — Visualforce standard controller for
  `UCPMPDisclosureForm.page` (§8.3); *"Fills the fields of the UCPMP disclosure
  Annexure (clauses 5.1(g) and 14.4) from the company settings and the year's sample
  expenditure. Only the free samples line is produced by Sample Management; education
  programme lines are left for the company to complete."* — **this is a direct,
  explicit statement in the existing code that Sample Management already feeds a
  specific line of the UCPMP disclosure form**, relevant context for the future module.

### 5.3 Flows

`force-app/main/default/flows/` contains **exactly one file**:
`sfdc_default_ReportExport_Protection_Flow.flow-meta.xml` — the Salesforce-provided
default report-export-protection flow. **No custom record-triggered, screen, or
scheduled flows exist in this org's metadata.** All automation is Apex-trigger-driven
(§5.1) or Apex-scheduled/batch (§5.5).

### 5.4 Process Builders / Workflow Rules / Approval Processes

- `force-app/main/default/workflows/` — **does not exist** (no legacy Workflow Rules
  or Process Builder flows in source).
- `force-app/main/default/approvalProcesses/` — **does not exist** as a directory in
  this listing (no approval process metadata found), even though
  `DataChangeRequestApprovalHandler` and `Device_Reset_Request__c`'s "stamp Manager__c
  before save so the Approval Process can route to it" comment
  (`DeviceResetRequestTrigger.trigger`) both *reference* an Approval Process by name.
  This is a notable gap: **the approval process metadata is referenced by Apex but was
  not found in source** — likely configured only via clicks in the org and never
  retrieved. UNVERIFIED; would need
  `sf project retrieve start -m "ApprovalProcess" -o sciagen-sandbox -r /tmp/sciagen-audit-retrieve`
  to confirm what it actually does.

### 5.5 Scheduled / Batch / Queueable Apex

`grep -lE "implements (Database\.)?(Schedulable|Batchable|Queueable)"` over
`classes/*.cls` found:

| Class | Interfaces | Purpose |
|---|---|---|
| `SampleLotExpiryBatch.cls` | `Database.Batchable<SObject>, Schedulable` | daily lot expiry (§1.5) |
| `HcpLicenseExpiryBatch.cls` | `Database.Batchable<SObject>, Schedulable` | daily HCP license status refresh (§1.1) |
| `DuplicateScanBatch.cls` | Batchable (inferred from name/pairing) | background dedupe scan |
| `DuplicateScanQueueable.cls` | Queueable | queued dedupe scan (likely kicked off by `SciagenAccountDedupe.trigger`) |
| `DuplicateScanScheduler.cls` | Schedulable | schedules the dedupe batch |
| `HCOGeocodingQueueable.cls` | Queueable | address→geolocation lookup, ties to `Geocoding_Config__mdt` (§6.1) and `SciagenAccountAddressSync.trigger` |
| `SupportAutoCloseBatch.cls` | Batchable (inferred) | auto-closes stale support requests |
| `SyncTrackingPurgeJob.cls` | (has a `*Test.cls`, implies scheduled/batch) | purges old `Sync_Tracking__c` rows (§7.2) |

### 5.6 Validation Rules (relevant objects)

| Object | Rule | (name only — formula text not extracted in this pass) |
|---|---|---|
| Sciagen_Account__c | `Phone_Must_Be_10_Digits` | |
| Sample_Lot__c | `Available_Cannot_Be_Negative`, `Expiry_After_Manufacture`, `Expiry_Must_Be_Future_On_Create`, `Initial_Quantity_Positive` | |
| Sample_Transaction__c | `Adjustment_Cannot_Be_Zero`, `Adjustment_Needs_Reason`, `Only_Adjustments_Can_Be_Negative`, `Return_Needs_Reason` | |
| Sample_Allocation__c | `Allocation_Needs_A_Recipient`, `Period_End_After_Start` | |
| Sample_Limit__c | `Limit_Must_Be_Positive_Or_Zero`, `Territory_Scope_Needs_Territory`, `Warning_Threshold_In_Range` | |
| Sample_Limit_Override__c | `Increase_Needs_A_Value`, `Override_Needs_A_Target`, `Reason_Is_Required`, `Valid_To_After_From` | |
| Product__c, Sample_Drop__c, Consent__c, Call_Visit_Report__c, Planned_Call__c, Territory__c | none found | no `validationRules/` subfolder present for these objects |

Rule names were enumerated via directory listing
(`force-app/main/default/objects/<Object>/validationRules/*.validationRule-meta.xml`);
formula text and error messages were **not individually opened** in this pass — flagged
as a quick follow-up (17 small XML files total) if exact formula logic is needed.

### 5.7 Platform Events

Covered in §1.14 (`Sample_Attempt__e`). Subscriber confirmed
(`SampleAttemptEventTrigger.trigger` → `SampleAttemptLogService.log`); publisher **not
located** in the Apex classes read so far — UNVERIFIED, needs a targeted
`grep -rn "Sample_Attempt__e" force-app/main/default/classes/*.cls` for
`EventBus.publish` calls.

### 5.8 Change Data Capture

No evidence of CDC found in this pass (no `__ChangeEvent` references encountered while
reading the classes above). Not exhaustively grepped across all 109 classes —
UNVERIFIED as fully absent.

### 5.9 Approval Processes

See §5.4 — referenced by Apex/trigger comments (`Device_Reset_Request__c`,
`DataChangeRequestApprovalHandler`) but no approval process metadata was found in
source. UNVERIFIED/likely org-only configuration.

### 5.10 Data Change Request workflow

`Data_Change_Request__c` + `DCR_Comment__c` + `DataChangeRequestTrigger.trigger` (before
update) → `DataChangeRequestApprovalHandler.handleApprovals`. Backed by
`DCRReviewController.cls` (with `DCRReviewControllerTest.cls`) and the
`Sciagen_Zonal_Manager_Access` permission set (§4.3-4.10). Reads as a workflow for
requesting changes to locked/approved data that needs zonal-manager review — full
approval-criteria logic not read in this pass (the actual Approval Process definition
wasn't found in source per §5.4).

---

## 6. Configuration

### 6.1 Custom Metadata Types (CMDT)

| CMDT | Fields (from field-meta.xml files) | Records |
|---|---|---|
| `Division__mdt` | (not read field-by-field) | `Div_Cardiology`, `Div_Diabetes`, `Div_Immunology`, `Div_Oncology`, `Div_Respiratory` — mirrors `Product__c.Division__c` picklist values exactly |
| `Molecule__mdt` | (not read field-by-field) | `B_Complex`, `Mol_Antifungal_Topical`, `Mol_Insulin_Glargine`, `Mol_Levonadifloxacin`, `Neutraline` |
| `Expense_Rate_Card__mdt` | (not read field-by-field) | `Station_EX`, `Station_HQ`, `Station_OS`, `Travel_2W`, `Travel_4W`, `Travel_Bus`, `Travel_Train` — expense/claim rate configuration, not sample-related |
| `Geocoding_Config__mdt` | (not read field-by-field) | `Default` — backs `HCOGeocodingQueueable.cls` and `SciagenAccountAddressSync.trigger` |
| `Holiday__mdt` | (not read field-by-field) | 10 India public holidays (Diwali, Holi, Christmas, etc.) — likely feeds `PlannedCallOfficeHoursValidator`/scheduling |
| `Leave_Entitlement__mdt` | (not read field-by-field) | `Casual_Leave`, `Compensatory_Off`, `Earned_Privilege`, `Loss_of_Pay`, `Sick_Leave` — HR/leave feature, not sample-related |
| `Office_Hours_Setting__mdt` | (not read field-by-field) | `Default` — read by `PlannedCallOfficeHoursValidator.cls` |
| `Sciagen_App_Config__mdt` | (not read field-by-field) | `Default` — likely a tenant-wide feature-flag config; not opened in this pass |
| `Sync_Object_Config__mdt` | `Conflict_Resolution__c` (picklist, e.g. `Salesforce Wins`), `Is_Active__c` (boolean), `Object_API_Name__c` (text), `Sync_Direction__c` (picklist, e.g. `Bi-Directional`), `Sync_Window_Days__c` (number) — **full field list confirmed by directory listing and one record read in full** | 13 records: `Account_Plans`, `Accounts`, `Call_Visit_Reports`, `Consents`, `Daily_Expenses`, `Data_Change_Requests`, `Leave_Requests`, `Monthly_Claims`, `Office_Windows`, `Planned_Calls`, `RCPA_Audits`, `Sales_Targets`, `Sales_Transactions`, `Segmentation` — this is the **per-object sync configuration table driving the iPad delta sync** (§7.2). Sample record read in full: `Call_Visit_Reports` → `{Conflict_Resolution__c: "Salesforce Wins", Is_Active__c: true, Object_API_Name__c: "Call_Visit_Report__c", Sync_Direction__c: "Bi-Directional", Sync_Window_Days__c: 90.0}` (`force-app/main/default/customMetadata/Sync_Object_Config.Call_Visit_Reports.md-meta.xml`). **Notably, none of the `Sample_*` objects appear in this 13-record CMDT list** — the sample inventory objects (`Sample_Lot__c`, `Sample_Transaction__c`, `Sample_Drop__c`, etc.) are not currently configured for sync via this mechanism, which is directly relevant to the future Sample Management module's mobile sync design. |

### 6.2 Custom Settings

Confirmed via `<customSettingsType>` tag in each object's `.object-meta.xml`:

| Object | Type | Notes |
|---|---|---|
| `UCPMP_Tenant_Config__c` | Hierarchy, `visibility=Public` | compliance config, §1.20 |
| `Call_Backdate_Limit__c` | Hierarchy | not opened field-by-field |
| `Call_Submission_Restriction__c` | Hierarchy | not opened field-by-field |
| `Duplicate_Setting__c` | Hierarchy | dedupe engine tuning, backs `DuplicateEngine.cls` family |
| `Support_Setting__c` | Hierarchy | backs `SupportConfig.cls` |
| `Office_Window__c` | **not** a custom setting — no `<customSettingsType>` tag found; it's a plain custom object | |

### 6.3 Custom Labels

`force-app/main/default/labels/` — **not found** as a directory (no
`CustomLabels.labels-meta.xml`). No custom labels exist in this metadata.

### 6.4 Named Credentials / External Credentials / Remote Site Settings

All three directories (`namedCredentials/`, `externalCredentials/`,
`remoteSiteSettings/`) are **absent** from `force-app/main/default/`. No outbound
callout target configuration exists in source. Consistent with no `HttpRequest`-based
integration classes being found in the sample-relevant classes read (see §9).

### 6.5 Connected Apps (iPad OAuth)

Two connected apps, both fully read:

**`SciagenCRM_iPad_OAuth.connectedApp-meta.xml`** (the newer one — description:
*"Fresh Connected App for the SciagenCRM iPad app (Salesforce Mobile SDK). Public
client — PKCE, no client secret shipped in the app. Created clean to replace
SciagenCRM_Mobile after repeated manual Setup-UI edits made that app's metadata
undeployable via A[PI]"*):
- `callbackUrl`: `com.sciagen.crm://oauth/success`
- `isPkceRequired`: **true**
- `isAdminApproved`: **false**
- `isConsumerSecretOptional`: true (public client, no secret)
- `isRefreshTokenRotationEnabled`: true
- `scopes`: `Api`, `Web`, `RefreshToken`, `OpenID`
- `oauthPolicy.ipRelaxation`: `BYPASS_2FACTOR`
- `oauthPolicy.refreshTokenPolicy`: `specific_inactivity:30:DAYS` (refresh token expires
  after 30 days of inactivity)

**`SciagenCRM_Mobile.connectedApp-meta.xml`** (the older one — description: *"Connected
App for the SciagenCRM iPad app (Salesforce Mobile SDK). Public client — PKCE, no
client secret shipped in the app."*):
- `callbackUrl`: same, `com.sciagen.crm://oauth/success`
- `isPkceRequired`: **true**
- `isAdminApproved`: **true**
- `scopes`: `Api`, `Full`, `RefreshToken`, `SFAP`, `Interaction` (notably broader than
  the newer app — includes `Full` access and `SFAP`/`Interaction`)
- `oauthPolicy.ipRelaxation`: `ENFORCE` (stricter than the new app's `BYPASS_2FACTOR`)
- `oauthPolicy.refreshTokenPolicy`: **`infinite`** (never expires — notably different
  and more permissive than the new app's 30-day inactivity policy)

**Both apps target the same callback URL and both use PKCE with no embedded secret**,
consistent with a native mobile public client. The two apps differ meaningfully in
scope breadth and refresh-token policy, and the newer app's own description states it
was created to replace the older one due to "manual Setup-UI edits" making the old
app's metadata undeployable — **which of the two is the one actually in live use by the
iPad app today is UNVERIFIED from metadata alone** (would need to check the org's
connected-app usage/session data, or ask the iPad team) — flagged clearly since it
matters for any new mobile integration work.

### 6.6 External Service Registrations

`force-app/main/default/externalServiceRegistrations/` — **not found**. No
OpenAPI-based External Services configured.

---

## 7. Mobile APIs

### 7.1 Apex REST (`@RestResource`) classes

`grep -l "@RestResource" classes/*.cls` found 7 classes. All annotation lines and
class-level signatures read:

| Class | `urlMapping` | Sharing | Notes |
|---|---|---|---|
| `SavedViewsResource.cls` | `/sciagen/v1/savedViews` | `with sharing` | reads a `since` param, deserializes it as `Datetime` for delta-style filtering (`Datetime.class` at line 24) — a saved-filter/view sync endpoint |
| `SciagenAccountSyncService.cls` | `/sciagen/v1/accounts/*` | `with sharing` | **the account sync endpoint** — inner classes `AccountSyncRecord`, `SyncDownResult`, `AccountUpsertRequest` (lines 31/43/154) confirm a sync-down (pull changes) + upsert (push changes) pattern for `Sciagen_Account__c` |
| `SciagenAccountTerritoryController.cls` | `/sciagen/v1/account-territory-unassign` | **`without sharing`**, with an explicit code comment at line 127: *"No AccessLevel.USER_MODE here — see class doc comment"* — i.e. this is a deliberate, documented sharing bypass for an unassign operation | inner class `UnassignOutcome` |
| `SciagenDeviceResetController.cls` | `/sciagen/device-reset` | `with sharing` | backs `Device_Reset_Request__c` workflow from the mobile side |
| `CMSContentReceiver.cls` | `/cms/v1/content` | `with sharing` | inner classes `ContentPushRequest`/`ContentPushResult` (lines 28/44) — a **push-in content endpoint** (content pushed *to* Salesforce, e.g. from a CMS), deserializes `req.requestBody` as `ContentPushRequest` |
| `SciagenPicklistService.cls` | `/sciagen/v1/picklists` | `with sharing` | inner class `PicklistOptions` — general picklist metadata endpoint for the mobile app |
| `SciagenBusinessPicklistService.cls` | `/sciagen/v1/business-picklists` | `with sharing` | inner class `BusinessPicklists` — business-specific (vs. standard) picklist values |

None of the 7 classes are annotated `global` at a level suggesting unauthenticated
access — `SavedViewsResource`, `SciagenAccountSyncService`, `SciagenDeviceResetController`,
`CMSContentReceiver`, `SciagenPicklistService`, `SciagenBusinessPicklistService` are all
declared `global with sharing`; `SciagenAccountTerritoryController` is `global without
sharing` with the deliberate-bypass comment noted above. Request/response body shapes
were only spot-read (class/inner-class names, not full field lists) — a full
request/response JSON contract for each endpoint would need a deeper per-class read
before the Sample Management module adds new REST endpoints alongside these (to match
naming/response conventions).

### 7.2 Sync mechanism (iPad delta sync)

Two complementary mechanisms, both confirmed by reading actual metadata/fields:

1. **`Sync_Object_Config__mdt`** (§6.1) — a per-object CMDT table of 13 records
   configuring `Sync_Direction__c` (e.g. `Bi-Directional`), `Conflict_Resolution__c`
   (e.g. `Salesforce Wins`), `Sync_Window_Days__c` (e.g. `90`), and `Is_Active__c` per
   synced object. This looks like the **declarative sync policy layer** — which objects
   sync, in which direction, how conflicts resolve, and how far back. As noted in §6.1,
   the `Sample_*` objects are **not** among the 13 configured objects today.
2. **`Sync_Tracking__c`** — a custom object (not CMDT) with fields
   `Local_Record_Id__c`, `Salesforce_Record_Id__c`, `Record_Type__c`, `Status__c`,
   `Label__c`, `Occurred_At__c`, `Error_Message__c`, `Rep__c` — this is a **per-record,
   per-rep sync log/cursor**, mapping a local (device) record id to its Salesforce id,
   with a status and error message, presumably written each time a record syncs up or
   down. `SyncTrackingPurgeJob.cls` (§5.5) periodically purges old rows from it.
   **Org data**: `SELECT COUNT(Id) FROM Sync_Tracking__c` → **400** rows already present
   in this sandbox — this is clearly an actively-used mechanism, not a stub.

The actual delta-pull query pattern (e.g. `SystemModstamp`-based incremental queries)
was **not confirmed** by a direct grep in this pass — `SciagenAccountSyncService.cls`'s
`SyncDownResult`/`AccountSyncRecord` inner classes strongly imply a modstamp-or-cursor
pull for accounts specifically, but the exact SOQL used was not opened. Flagged as a
quick, high-value follow-up read (`sed -n` on `SciagenAccountSyncService.cls`) before
the Sample Management module designs its own sync contract, since it should probably
match this existing pattern rather than invent a new one.

`Device_Reset_Request__c` + `DeviceResetRequestTrigger.trigger` — before insert stamps
`Manager__c` for approval routing (§5.4); this is the mechanism for a rep requesting
their device/app be reset (likely to force a fresh full sync), backed by
`DeviceResetRequestHandler.cls` and surfaced to reps via `SciagenDeviceResetController`
(§7.1) and to managers/admins via `DeviceResetAdminController.cls` +
`deviceResetAdmin` LWC (§8.1).

### 7.3 Composite / GraphQL / Bulk API

No server-side composite-request helper classes or GraphQL references were found while
reading the classes above. Not exhaustively grepped across all 109 classes for this
specific pass — UNVERIFIED as fully absent, but nothing surfaced incidentally either.

### 7.4 "iPad" references in code comments

Multiple explicit references confirm iPad-app context directly in Apex doc comments:
`SampleEligibilityService.cls` header (*"The iPad runs the same rules offline against
its synced copies; this is the authority"*), and both connected app description fields
(§6.5) explicitly name "the SciagenCRM iPad app (Salesforce Mobile SDK)."

---

## 8. UI

### 8.1 LWC components (52 total)

`force-app/main/default/lwc/` full listing, with sample/product/call/consent/
compliance/sync-relevant ones noted:

- **`sampleAdmin`** — almost certainly the UI for `SampleAdminController.cls`
  (Sciagen_Sample_Admin's primary screen); backs the `Sample_Administration_Page`
  flexipage/tab.
- **`ucpmpComplianceDashboard`** — backs `UCPMPComplianceController.cls`/
  `UCPMPComplianceService.cls`; drives the `UCPMP_Compliance_Page` flexipage/tab.
- **`cvrSampleDrops`** — sample-drop line editor within a Call Visit Report, working
  with `Sample_Drop__c`/`SampleDropService`.
- **`cvrHeaderForm`, `cvrAttendees`, `cvrInternalAttendees`, `cvrKeyMessages`,
  `cvrPresentationSessions`, `cvrPromoDrops`, `cvrViewModal`** — the rest of the Call
  Visit Report editing surface (attendees, key messages, presentations shown, promo
  drops) — `cvrPromoDrops` in particular may be adjacent to but distinct from sample
  drops (worth clarifying scope boundary for Sample Management).
- **`callVisitReportBrowser`, `callVisitReportDetail`** — the call list/detail browser
  backing `Call_Reports_Page`.
- **`associateCallModal`, `scheduleCallForm`, `mySchedule`, `scheduleFilterBar`,
  `scheduleMap`, `scheduleMonthGrid`, `scheduleWeekGrid`** — planned-call scheduling UI
  (backs `SciagenScheduleController.cls`).
- **`accountBrowser`, `accountDetail`, `globalAccountSearch`** — HCP/HCO browsing
  (backs `GlobalAccountSearchController.cls`/`SciagenAccountController.cls`).
- **`deviceResetAdmin`** — admin UI for `DeviceResetAdminController.cls` (§7.2).
- **`duplicateManager`** — admin UI for the dedupe engine (`DuplicateAdminController.cls`).
- **`rcpaAuditForm`, `rcpaBrowser`, `rcpaDetail`, `rcpaDoctorMatrix`,
  `rcpaMasterMatrix`, `rcpaSignaturePad`** — RCPA (retail chemist/pharmacy audit)
  feature UI — not sample-inventory itself, but `rcpaSignaturePad` is notable as
  evidence of an existing **in-app signature capture pattern** that a Sample Management
  build could reuse for sample-receipt signatures (`Call_Visit_Report__c.Signature_*`
  fields already exist, §1.16, but no dedicated `sampleSignaturePad`-named component
  was found — signature capture for samples may currently piggyback on the CVR-level
  signature fields rather than a dedicated component).
- Remaining components (account-plan, dcr-review, support, alert-admin, CLM/presentation
  library, and generic/utility ones), listed by name only (not opened in this pass):
  `accountPlanBrowser`, `accountPlanDashboardTab`, `accountPlanDetailsTab`,
  `accountPlanExportTab`, `accountPlanRelatedTab`, `accountPlanStageStepper`,
  `accountPlanStrategiesTab`, `accountPlanWorkspace`, `alertAdmin`, `clmLibrary`,
  `clmPresentationViewer`, `dcrReviewDetail`, `dcrReviewQueue`, `kamHomeDashboard`,
  `newAccountPlanModal`, `newActionItemModal`, `sciagenColors`, `sciagenLogo`,
  `supportCenter`, `supportConsole`, `supportThread`, `supportUtil`.

### 8.2 Aura components

`force-app/main/default/aura/installSciagenCRM` — name strongly implies an
install/setup utility component; not opened in this pass (single Aura component, out of
primary scope).

### 8.3 Visualforce pages

Both pages fully identified:

- **`AccountPlanExportPdf.page`** — paired with `AccountPlanExportPdfController.cls`;
  renders an account plan as a PDF export. Not sample-related.
- **`UCPMPDisclosureForm.page`** — paired with `UCPMPDisclosureController.cls` (§5.2),
  which populates `fy`, `cin`, `companyName`, `address`, `email`, `pan`, `salesCrore`,
  `samplesCrore`, `hcpCount`, `methodology`, `designation`, `dinOrPan`, `mobile`,
  `signEmail`, `generatedOn` from `UCPMP_Tenant_Config__c` and the year's sample
  expenditure. This **is the compliance disclosure document render surface** — its
  controller's doc comment is explicit that "only the free samples line is produced by
  Sample Management; education programme lines are left for the company to complete,"
  directly confirming this VF page is a downstream consumer of Sample Management data.

### 8.4 Experience Cloud / Sites

**No Experience Cloud/Sites metadata exists** in this repo:
`force-app/main/default/experiences/`, `networks/`, `sites/`, `digitalExperiences/` are
all **absent**. The only "Sites"/"Community" references found are the standard
Lightning app shells `standard__Sites.app-meta.xml` and `standard__Community.app-meta.xml`
under `force-app/main/default/applications/`, which are just Salesforce's built-in app
launcher tiles, not evidence of an actual configured site. **There is currently no
public-facing (guest-user) surface for remote signature or opt-in links** in this
metadata — any "capture consent remotely via a link" capability for Sample Management
would need to be built new, not extended from an existing site. (UNVERIFIED beyond
metadata absence — cannot rule out an org-only site not yet retrieved into source.)

### 8.5 Email templates

No standard Salesforce `email`/`emailTemplates` directory exists. Instead, this org has
a **custom email-template system**: `Email_Template__c`, `Email_Template_Content__c`
objects (for defining templates) and `Sent_Email__c`, `Sent_Email_Attachment__c`
objects (for logging what was actually sent) — both `Email_Template__c` and
`Sent_Email__c` are granted in the `SciagenCrm`/`Sciagen_Mobile_App_Access` permission
sets (§4.3-4.10). Fields were not opened in this pass; flagged for follow-up if the
Sample Management module needs to send disclosure/consent-related emails, since it
looks like it should reuse this custom system rather than standard `EmailTemplate`.

### 8.6 Report Types

`force-app/main/default/reportTypes/`: `Call_Visit_Report.reportType-meta.xml`,
`Consent_Capture_Report.reportType-meta.xml`,
`Coverage_Report_for_Completed_Call_Visits.reportType-meta.xml`,
`RCPA_Report.reportType-meta.xml`. No custom report type exists yet for samples/
inventory/UCPMP — worth noting as a gap-adjacent fact (not a gap analysis, just an
inventory fact) since `UCPMP_Compliance_Page`'s dashboard (`ucpmpComplianceDashboard`
LWC) presumably computes its own aggregates in Apex rather than via a standard report.
No `force-app/main/default/reports/` or `dashboards/` directory exists in this repo
(not source-tracked here).

### 8.7 Tabs

`force-app/main/default/tabs/` (46 files) includes one tab per major custom object
plus several LWC/Aura "page" tabs (`Sample_Administration_Page`, `UCPMP_Compliance_Page`,
`Call_Reports_Page`, `Global_Account_Search_Page`, `My_Schedule_Page`,
`Account_Browser_Page`, `Account_Plan_Browser_Page`, `Alert_Admin_Page`,
`CLM_Library_Page`, `DCR_Review_Page`, `Duplicate_Manager_Page`, `KAM_Dashboard_Page`,
`RCPA_Browser_Page`, `Support_Center_Page`, `Support_Console_Page`). All sample objects
have their own tab (`Sample_Lot__c`, `Sample_Transaction__c`, `Sample_Allocation__c`,
`Sample_Blocked_Attempt__c`, `Sample_Expenditure_Tracking__c`,
`Sample_Limit_Override__c`, `Sample_Limit__c`, `Sample_Warehouse__c`).

### 8.8 Applications

`force-app/main/default/applications/`: one custom app, `Sciagen_CRM.app-meta.xml`
(tabs not enumerated in this pass — flagged for a quick follow-up read), plus ~29
untouched standard Salesforce app shells (`standard__Sales`, `standard__Service`,
`standard__Chatter`, etc.) that appear to be default artifacts of the org's edition/
licenses rather than actively customized apps.

---

## 9. Integrations

- **No Named Credentials, External Credentials, or Remote Site Settings** exist (§6.4)
  — there is **no outbound callout target configured** anywhere in this metadata.
- **No `@future(callout=true)` or `HttpRequest`-based integration class** was
  encountered while reading the sample/compliance/sync classes in this pass. This
  strongly suggests **no live ERP, warehouse, license-vendor, fulfilment, SMS, or
  WhatsApp integration exists server-side today**, despite `Consent__c` having
  `Mobile_Opt_In__c`/`WhatsApp_Opt_In__c`/`WhatsApp_Number__c`/`Mobile_Verified__c`/
  `WhatsApp_Verified__c` fields (§1.15) that clearly anticipate SMS/WhatsApp channels —
  those fields look like they're capturing opt-in preference/verification status for a
  channel that would be operated by some *other* system (or a not-yet-built
  integration), not fields actively populated by a running Apex callout found in this
  pass. This was **not exhaustively grepped** across all 109 classes for `HttpRequest`/
  `Http.send`/`@future(callout=true)` — flagged as the single highest-value quick
  follow-up grep before concluding integrations are fully absent.
- **`CMSContentReceiver.cls`** (§7.1, `/cms/v1/content`) is an **inbound** push
  endpoint — some external CMS pushes content *into* Salesforce, not the reverse. This
  is the one concrete "integration" surface confirmed in this pass, and it's inbound
  REST, not outbound callout.
- No "Integration User" profile or permission set name was encountered among the 2
  profiles or 14 permission sets listed (§4.1, §4.3-4.10) — no dedicated integration
  user identity was found in source. UNVERIFIED whether one exists only as an org user
  record (out of scope for metadata inventory).

---

## 10. Tests

### 10.1 Apex test classes (36 total, `ls classes/*Test*.cls`)

Sample/product/account/call/consent/UCPMP/sync-relevant ones, with what their names and
a light read of method names suggest they cover:

| Test class | Covers |
|---|---|
| `SampleDropServiceTest.cls` | `SampleDropService` (sample line eligibility, FEFO lot assignment, call-submit transaction creation) |
| `SampleLimitCheckerTest.cls` | `SampleLimitChecker` scope/period limit math |
| `SampleEligibilityServiceTest.cls` | `SampleEligibilityService` end-to-end eligibility (product rules, licence, consent, limits) |
| `SampleLotServiceTest.cls` | `SampleLotService` (key generation, ownership-follows-rep, active/depleted flip) |
| `SampleTransactionServiceTest.cls` | `SampleTransactionService` ledger behavior |
| `SampleNotifierTest.cls` | `SampleNotifier` (notification-sending logic, not opened) |
| `SampleAdminControllerTest.cls` | `SampleAdminController` (admin UI backend) |
| `SciagenAccountSyncServiceTest.cls` | the `/sciagen/v1/accounts/*` REST sync endpoint |
| `SciagenAccountControllerTest.cls`, `SciagenAccountTerritoryControllerTest.cls` | account CRUD/territory REST endpoint |
| `SciagenCVRControllerTest.cls` | Call Visit Report controller |
| `SciagenScheduleControllerTest.cls` | planned-call scheduling |
| `SciagenPicklistServiceTest.cls` | `/sciagen/v1/picklists` and business-picklists endpoints |
| `SyncTrackingPurgeJobTest.cls` | `Sync_Tracking__c` purge batch |
| `SavedViewsResourceTest.cls` | `/sciagen/v1/savedViews` endpoint |
| `RoleHierarchySharingTest.cls` | role-hierarchy-driven sharing (confirms role hierarchy matters somewhere, §3.3) |
| `TerritorySharingServiceTest.cls`, `PlannedCallTerritorySharingServiceTest.cls`, `RCPAAuditTerritorySharingServiceTest.cls` | Apex managed sharing (§3.2) |
| `DeviceResetRequestTriggerTest.cls` | device reset trigger/handler |
| `DataChangeRequestApprovalHandlerTest.cls` | DCR approval handling |
| `DuplicateEngineTest.cls`, `DuplicateMatchServiceTest.cls`, `DuplicateMergeServiceTest.cls`, `DuplicateAdminControllerTest.cls` | dedupe engine |
| `GlobalAccountSearchControllerTest.cls`, `AccountPlanControllerTest.cls`, `AccountPlanHomeDashboardControllerTest.cls`, `AlertAdminControllerTest.cls`, `CMSContentReceiverTest.cls`, `DCRReviewControllerTest.cls`, `PlannedCallOfficeHoursValidatorTest.cls`, `RCPAControllerTest.cls`, `RCPAMatrixControllerTest.cls`, `SupportTest.cls` | other feature areas, not opened in this pass |

**Not present**: no test class found named for `UCPMPComplianceService`/
`UCPMPComplianceController`/`UCPMPDisclosureController`, nor for `SampleLimitGuardService`,
`SampleAllocationService`, `SampleLotExpiryBatch`, `HcpLicenseExpiryBatch`,
`SampleAttemptLogService`, or `SampleExpenditureService` — i.e. **several sample/UCPMP
service and batch classes appear to have no dedicated test class**, based on name
matching alone (a class could still be covered incidentally by another test class's
assertions — this wasn't verified either way).

### 10.2 Test data factories

- **`SampleTestData.cls`** — a test data factory for the sample domain (name pattern
  confirms it; contents not opened in this pass).
- **`SampleLimitSeeder.cls`** — referenced in the earlier UCPMP grep (§ intro); a seeder
  specifically for `Sample_Limit__c` test/demo data.
- **`SciagenAccountSeeder.cls`** — HCP/HCO test data factory.

### 10.3 Test coverage

**UNVERIFIED — not measured in this pass**, per the strict no-`sf apex run test` rule.
No stored coverage report was found via `find ~/.sf -iname "*coverage*"` /
`find ~/.sfdx -iname "*coverage*"` / a repo-wide search for `ApexCodeCoverage`. To get
real numbers you would need to approve running:

```
sf apex run test -o sciagen-sandbox --code-coverage --result-format json --wait 30
```

(or equivalent), which can write/roll back data in the sandbox — **requires your
explicit confirmation** per the audit's strict rules, and was correctly not run.

---

## 11. Org Data Sanity (counts only, `sciagen-sandbox`)

All via `sf data query -q "..." -o sciagen-sandbox --json` (`SELECT COUNT(Id)` /
`GROUP BY`, no individual records read):

| Query | Result |
|---|---|
| `Product__c` total | **12** |
| `Product__c GROUP BY Level__c` | `SKU`: 12 (all records) |
| `Product__c GROUP BY Product_Type__c` | `DP 100%`: 4, `DP+DF Mix`: 4, `DF 100%`: 4 |
| `Product__c GROUP BY Division__c` | `null`: 12 (Division not populated on any current record) |
| `Product_Master__c` total | **12** |
| `Product_Territory_Assignment__c` total | **216** |
| `Sample_Lot__c` total | **0** |
| `Sample_Transaction__c` total | **0** |
| `Sample_Allocation__c` total | **0** |
| `Sample_Limit__c` total | **0** |
| `Sample_Limit_Override__c` total | **0** |
| `Sample_Warehouse__c` total | **0** |
| `Sample_Drop__c` total | **0** |
| `Sample_Blocked_Attempt__c` total | **0** |
| `Sample_Expenditure_Tracking__c` total | **0** |
| `Call_Visit_Report__c` total | **26** |
| `Call_Visit_Report__c WHERE Has_Samples__c = true` | **0** |
| `Sciagen_Account__c` total | **152** |
| `Sciagen_Account__c WHERE License_Number__c != null` | **41** |
| `Sciagen_Account__c GROUP BY License_Verification_Status__c` | `null`: 152 (unpopulated for all records) |
| `Consent__c` total | **4** |
| `Consent_Channel__c` total | **12** |
| `Consent_Email__c` total | **4** |
| `Consent_Product__c` total | **0** |
| `UCPMP_Tenant_Config__c` total | **0** (no org-default config saved; code-level defaults in `SampleConfig.cls` are what's in effect) |
| `Territory__c` total | **18** |
| `Account_Territory__c` total | **140** |
| `User_Territory__c` total | **11** |
| `Planned_Call__c` total | **69** |
| `Sales_Transaction__c` total | **0** |
| `Data_Change_Request__c` total | **9** |
| `Sync_Tracking__c` total | **400** |
| `Account` (standard) total | **0** |
| `Account WHERE IsPersonAccount = true` | query error — field doesn't exist (Person Accounts not enabled) |
| `Product2` (standard) total | **0** |
| `Territory2` (standard) | query error — sObject type not supported (Enterprise Territory Management not enabled) |
| `User WHERE IsActive = true` | **17** |

**Reading**: this sandbox has demo/config-level data for accounts (152), territories,
consent, products, and calls, but the **entire sample-inventory chain
(lots/transactions/allocations/limits/drops/warehouses/blocked-attempts/expenditure) is
completely empty (all 0)**, as is `UCPMP_Tenant_Config__c` itself. The Sample Management
module build will effectively be starting from a populated *schema* with no seeded
*data* in this org — useful to know for demo/test-data planning.

---

## 12. Supplementary Deep-Dive Findings

Six parallel background passes over the same metadata (objects/fields, security/
sharing, automation, mobile APIs, UI, config/integrations/tests) completed after the
main body above was written. Their evidence was more granular (exact `file:line`
citations, full REST request/response shapes) than the direct pass that produced §1–11.
This section merges in what's genuinely new or corrects/sharpens an earlier claim —
it does not repeat what's already stated above. All citations below are file paths
under `force-app/main/default/` unless stated otherwise, as reported by those passes.

### 12.1 Objects/fields — corrections and additions

- **`Sciagen_Account__c` has literally zero relationship to standard `Account`** —
  confirmed by a full-codebase grep: no field anywhere has `<referenceTo>Account</referenceTo>`,
  and no `Sciagen_Account__c` field points at `Account` either. This sharpens §1.1/§1.22:
  it's not just "unused," the two object families are entirely disconnected in the schema.
- **`Sciagen_Account__c.Sample_Eligible__c` is a formula field**, not a manually-set
  flag as §1.1 implied it might be: `AND(ISPICKVAL(License_Verification_Status__c,'Verified'),
  NOT(ISBLANK(License_Expiry_Date__c)), License_Expiry_Date__c >= TODAY(), Can_Prescribe__c)`
  (`objects/Sciagen_Account__c/fields/Sample_Eligible__c.field-meta.xml`). Since
  `License_Verification_Status__c` is null for all 152 accounts in this sandbox (§1.1),
  **`Sample_Eligible__c` currently evaluates false for every account in this org** —
  worth knowing before assuming any account is sample-eligible in a demo.
- **Two apparent duplicate-field pairs** worth flagging for the new module to avoid
  perpetuating: `Product__c.SKUCode__c` (formula: `IF(ISBLANK(SKU__c), Name, Name &
  "-" & SKU__c)`) vs. `Product__c.SKU_Code__c` (plain externalId text) — two different
  fields, not a typo; and `Sciagen_Account__c.Speciality__c` (restricted picklist,
  British spelling) vs. `Specialty__c` (unrestricted picklist, American spelling, a
  *different* value set that adds ENT/Paediatrics).
- **`Product_Master__c`** is very likely an **import-staging catalog**, not a parallel
  live object: its own object description reads *"Master catalog of products, imported
  from the Product Master reference file (brand, molecule, therapy area, sampling
  limits, and lifecycle dates)"* — this resolves the open question in §1.3 about why
  two "product" objects exist.
- **`Sales_Transaction__c`'s object description explicitly anticipates a future SAP
  feed**: *"Loaded via flat-file (Data Import Wizard / Bulk API) upserting on
  Sales_Key__c; a future SAP feed can write to the same object/key with no schema
  change. The mobile app only ever reads this object."* (`objects/Sales_Transaction__c/Sales_Transaction__c.object-meta.xml`).
  No SAP integration exists today (§12.4) — this is a documented intent, not a gap.
- **`Sales_Transaction__c.Stockist__c` has a description/enforcement mismatch**: its
  field description references `HCO_Type__c = 'Stockist'`, but the actual enforced
  `lookupFilter` checks `Sciagen_Account__c.Type__c = 'HCO'` (broader than described).
- **Call_Visit_Report__c's sample rollups are real Roll-Up Summary fields**, not just
  formulas referencing children: `Sample_Drop_Count__c` (count of `Sample_Drop__c` via
  `CVR__c`), `Sample_Total_Value__c` (sum of `Sample_Drop__c.Total_Value__c`), and
  `Signature_Required_Count__c` (count filtered to `Needs_Signature__c = True`) are all
  `<type>Summary</type>` roll-ups on the `Sample_Drop__c.CVR__c` master-detail
  relationship — confirming `Sample_Drop__c` really is master-detail (not just lookup)
  to `Call_Visit_Report__c`.
- **`Sample_Transaction__c.Signature_Type__c`** picklist has values `In_Person`,
  `Remote_Link`, `Remote_QR` — the schema already anticipates a **remote signature
  capability** for sample receipts, even though (per §8.4/§12.6 below) no actual remote
  signature UI/page exists yet.
- **No object in the entire org (89 top-level entries checked) has a `recordTypes/` or
  `compactLayouts/` folder**, and **page layouts for every object live in one flat
  shared directory** `force-app/main/default/layouts/` rather than nested per-object —
  an older/`mdapi`-style source layout, not SFDX's usual per-object nesting. This
  confirms and generalizes the finding already in §2.
- **Only `Sciagen_Account__c` has a Lightning Record Page** among the ~27 objects
  checked in depth — and it has **two** near-duplicate flexipages
  (`Sciagen_Account_Record_Page.flexipage-meta.xml` and `...Record_Page1...`), worth a
  quick check for which one is actually assigned before the new module's UI reuses
  either as a pattern.
- Standard `Account`/`Contact`/`Case`/`Lead`/`Opportunity` object-meta.xml files are
  **literally empty `<CustomObject/>` shells** (no sharing/history/activity settings at
  all) carrying only stock Salesforce Developer-Edition demo fields (`SLA__c`,
  GC-prefixed picklists, etc.) — confirms §1.22's "not the object driving HCP/HCO data"
  finding and clarifies these are out-of-the-box cruft, not partially-built Sciagen features.

### 12.2 Sharing — corrections and additions

- **A fifth Apex-managed-sharing pair exists beyond the four in §3.2**:
  `classes/SupportSharingService.cls` (`public without sharing`) manages
  `Support_Request__Share` with `RowCause = 'Manager_CC__c'` — whenever a
  `Support_Request__c`'s `Manager__c` or owner changes, it grants the requester's
  manager an Edit share so they can see/reply, removing the stale share on change.
- **`Consent__c` has Private OWD but *no* Apex managed sharing at all** (zero
  `Consent__Share` references anywhere in `classes/`/`triggers/`) — combined with the
  fact that the two broadly-assigned base permission sets (`SciagenCrm` and
  `Sciagen_Mobile_App_Access`) both grant `viewAllRecords=true`/`modifyAllRecords=true`
  on `Consent__c` (§4.3-4.10), **the Private OWD on this consent/PII object is
  effectively moot for ordinary reps** — every rep can see and edit every HCP's consent
  record org-wide today. This is a materially important fact for the Sample Management
  module to know before it builds anything relying on consent-record confidentiality.
- **Standard `Account`/`Contact`/`Opportunity`/`Case`/`Lead` sharing settings are not
  tracked in this repo at all** (their object-meta.xml files have no `<sharingModel>`
  because they're empty shells, per §12.1) — their real OWD, if it matters, must be
  checked live in the org, not assumed from source.
- The exact territory-sharing algorithm is now confirmed precisely: `TerritorySharingService`
  does an **exact-territory match only** (does not walk `Territory__c.Parent_Territory__c`
  hierarchy) and explicitly excludes users with `Profile.PermissionsViewAllData = true`
  from the share-grant query (Salesforce rejects Manual shares for already-omnipotent
  users) — sharpens §3.2's description of the mechanism.

### 12.3 Security — corrections and additions

- **"Business Admin" is, in practice, a second full System Administrator profile**, not
  the scoped business-user profile its name implies: `profiles/Business Admin.profile-meta.xml`
  has both `ModifyAllData` and `ViewAllData` enabled, plus the standard-admin bundle
  (`ManageUsers`, `ManageSharing`, `ManageProfilesPermissionsets`, `ManageRoles`,
  `ManageIpAddresses`, `AuthorApex`, `ModifyMetadata`, `ViewSetup`, etc.), and **zero**
  field-level-security restrictions anywhere (0 hits for `<editable>false</editable>`
  or `<readable>false</readable>` across all 639 `<fieldPermissions>` blocks) — every
  field on every object, including consent/licensing fields, is fully readable/editable
  for anyone holding this profile. This materially changes how to read §4.1: there is
  effectively no scoped "business admin" tier at the profile level in this org today.
- **The `Manage_Duplicates` custom permission is enforced in Apex
  (`classes/DuplicateAdminController.cls:20`) but granted by no permission set or
  profile anywhere in this source** — a real gap (either assigned to users directly in
  the org outside of tracked metadata, or currently unusable by anyone).
- **`Sciagen_Mobile_App_Access` (the iPad rep permission set) gives `Sample_Lot__c` as
  Read-only** (no Create/Edit/Delete) **while `Sample_Transaction__c` allows
  Create/Read/Edit but not Delete** — i.e., by design, reps transact against lots via
  the ledger but cannot directly edit lot records or delete transactions. Useful
  precedent for how the new module should scope permissions for non-admin reps vs.
  `Sciagen_Sample_Admin` (§4.3-4.10), which gets full CRUD+ViewAll+ModifyAll on every
  sample object.

### 12.4 Automation — corrections and additions

- **`Sample_Attempt__e`'s publisher is now located** (§5.7/§1.14 marked this
  UNVERIFIED): `classes/SampleAttemptLogService.publish()` (`SampleAttemptLogService.cls:8`),
  called from `classes/SampleDropService.cls:67` inside `beforeInsert()` whenever a
  sample line hits a hard-blocked rule, wrapped in `EventBus.publish(...)` inside a
  try/catch. Because the drop line's own save is rolled back
  (`d.addError(...)` right after), **the platform event is deliberately the only
  durable record of the refusal** — its own transaction commits independently of the
  DML rollback. This is a well-designed audit-trail pattern worth preserving/reusing.
- **A real metadata/code mismatch**: `classes/DeviceResetRequestHandler.cls` actively
  calls `Approval.process()`/`Approval.ProcessSubmitRequest` against
  `Device_Reset_Request__c`, and the object's `Manager__c` field is stamped
  specifically "so the Approval Process can route to it" — **but no
  `approvalProcesses/` directory or file exists anywhere in this source tree.** A real
  Salesforce Approval Process is active in the org for this object; its routing/step
  configuration is invisible to source-based review. Needs
  `sf project retrieve start -m "ApprovalProcess" -o sciagen-sandbox -r /tmp/sciagen-audit-retrieve`
  to inspect if that matters for the new module.
- **The Data Change Request "approval" is explicitly *not* a native Approval Process**
  — confirmed: `DCRReviewController.approveDCR()`/`rejectDCR()` just flip `Status__c`
  directly from an LWC action; `DataChangeRequestTrigger` (before update) reacts to
  that flip. This is a custom status-driven workflow, not declarative approval metadata
  — sharpens §5.10/§5.4.
- **`SyncTrackingPurgeJob` has no evidenced production `System.schedule()` call outside
  test code** — worth confirming with the org whether this retention job is actually
  scheduled, since its own doc comment says it was written specifically because
  unpurged `Sync_Tracking__c` rows (2,356 of them) once exhausted the org's 5MB
  Developer Edition storage and blocked all new-record creation org-wide.
- **Exact validation-rule formulas** (§5.6 listed rule names only) are now available,
  e.g. `Sample_Transaction__c.Adjustment_Needs_Reason`:
  `AND(ISPICKVAL(Transaction_Type__c,'Adjustment'), ISPICKVAL(Adjustment_Reason__c,''))`;
  `Sciagen_Account__c.Phone_Must_Be_10_Digits`:
  `AND(NOT(ISBLANK(Phone__c)), NOT(REGEX(SUBSTITUTE(Phone__c," ",""), "(\+?91)?[0-9]{10}")))`.
  Full formula text for all 17 rules is available in the underlying pass output if
  needed for the next audit phase.
- The default `sfdc_default_ReportExport_Protection_Flow` is confirmed to be in
  **`Draft` status** — i.e. currently inert even though it's the only flow in the org.

### 12.5 Configuration — corrections and additions

- **Two Connected Apps target the exact same iPad client (`com.sciagen.crm://oauth/success`)
  with materially different, possibly-simultaneously-active OAuth policies**:
  `SciagenCRM_Mobile` (`isAdminApproved=true`, `refreshTokenPolicy=infinite`,
  `ipRelaxation=ENFORCE`, scopes `Api/Full/RefreshToken/SFAP/Interaction`) vs.
  `SciagenCRM_iPad_OAuth` (`isAdminApproved=false`, `refreshTokenPolicy=specific_inactivity:30:DAYS`,
  `ipRelaxation=BYPASS_2FACTOR`, scopes `Api/Web/RefreshToken/OpenID`). The newer app's
  own description says it was "created clean to replace" the older one after manual
  Setup-UI edits made the old one undeployable — **it's unconfirmed whether the
  migration is complete or both are live in the org today**, which matters for anyone
  adding new mobile OAuth scopes for a Sample Management feature. This sharpens §6.5,
  which already flagged this but without the "possibly both live" framing.
- **`CMS_Integration_Access.permissionset-meta.xml` explicitly references "the
  CMS_Integration Connected App (OAuth 2.0 Client Credentials Flow)" by name, but no
  such Connected App file exists anywhere in this source** — either it was configured
  directly in the org and never retrieved, or the CMS push integration (`CMSContentReceiver.cls`,
  §7.1) is currently unconfigured/broken. Worth a direct check in the org.
- **`Sciagen_App_Config__mdt`'s actual field values are now known** (§6.1 left this
  unread): `Expenses_Module_Enabled__c=true`, `Leave_Module_Enabled__c=true`,
  `Go_Online_URL__c=/lightning/page/home`, `HCP_HCO_Cache_Limit__c=600`,
  `Published_Reports_Folder_Name__c=Mobile_Reports`, `Sync_Log_Retention_Days__c=30`
  (`customMetadata/Sciagen_App_Config.Default.md-meta.xml`) — none of these are
  sample-specific, but the pattern (a single "Default" tenant config record) mirrors
  `UCPMP_Tenant_Config__c` and could be a model for any new Sample Management tenant
  switches.
- **`Geocoding_Config__mdt`'s API-key field is deliberately left blank in source** and
  is, per its own object description, "not granted to any rep-facing permission set —
  only Apex (system mode) ever reads it" — a good precedent for how the new module
  should handle any similarly sensitive config value.
- **The only live outbound third-party callout in the entire codebase** is
  `classes/HCOGeocodingQueueable.cls` → Google Maps Geocoding API — and it's a raw
  `HttpRequest` with the API key appended to the query string, **not** routed through a
  Named Credential (consistent with §6.4/§9's finding that no Named Credentials exist
  at all). If the Sample Management module needs any outbound callout (e.g. to a
  license-verification vendor), it will be establishing the org's first real Named
  Credential usage, not following an existing pattern.
- **WhatsApp/SMS fields exist on `Consent__c` and `Sent_Email__c` (§1.15/§8.5) but no
  WhatsApp Business API/Twilio/SMS-gateway integration code exists anywhere** — these
  are consent/log fields only, confirming §9's "anticipated but not implemented" framing.

### 12.6 UI — corrections and additions

- **`cvrSampleDrops` LWC** (`lwc/cvrSampleDrops/`) is confirmed as the actual in-call
  UI for logging `Sample_Drop__c` records — this is the concrete component the Sample
  Management module would extend or replace for the call-time sampling experience.
- **`rcpaSignaturePad`** (an existing signature-capture component, for the *RCPA*
  chemist-audit feature, not samples) captures a **plain canvas-drawn PNG saved as a
  data URL** (`RCPA_Audit__c.Chemist_Signature__c`) — **not a cryptographic or
  Digital-Signature-Certificate-grade signature**. This is the closest existing
  precedent in the codebase for any "capture a signature" UI the Sample Management
  module might need (e.g. for sample-receipt proof), and it's worth knowing its
  security level is client-side-canvas, not DSC.
- **`UCPMPDisclosureForm.page`'s "Digital Signature Certificate" table cell is left
  empty in the rendered PDF** — no e-signature capture happens on that page at all; the
  form is explicitly meant to be signed externally/offline before manual filing (its
  own footer literally says "Prepared from Sciagen Sample Management ... Review before
  filing"). This sharpens §8.3: the existing UCPMP disclosure output is a **draft
  worksheet for a human to file**, not an automated regulatory submission.
- **The main `Sciagen_CRM` Lightning app's own navigation does *not* include
  `Sample_Administration_Page` or `UCPMP_Compliance_Page`** as tabs (its nav order is
  `Account_Browser_Page, Global_Account_Search_Page, KAM_Dashboard_Page, My_Schedule_Page,
  RCPA_Browser_Page, DCR_Review_Page, CLM_Library_Page, standard-report, Plan_Goal__c,
  User_Territory__c, RCPA_Target__c, Product__c` — `applications/Sciagen_CRM.app-meta.xml`).
  The sample-admin and UCPMP-compliance screens exist as tabs/flexipages but are
  reached via App Launcher or another app not present in this repo, not the primary
  nav bar — worth checking before assuming reps/admins land on them by default.
- **No Apex class anywhere in this repo actually *creates* `Sent_Email__c` records** —
  only reads (Account Detail timeline) and merge-reparenting were found
  (`classes/DuplicateMergeService.cls`). Creation of the custom email-log rows
  apparently happens exclusively via external/mobile sync, not any Salesforce-side send
  logic — relevant if the new module wants to log a sample-related email/notification
  through this existing object.

### 12.7 Mobile APIs / sync — corrections and additions

- **Delta sync is confirmed to be `LastModifiedDate`-based, not `SystemModstamp`-based**
  (§7.2 flagged this as unconfirmed): `classes/SciagenAccountSyncService.cls:85` builds
  its incremental WHERE clause as `LastModifiedDate >= :since`, and a repo-wide grep for
  `SystemModstamp` across all Apex classes returned **zero hits**. `Sync_Tracking__c` is
  confirmed to be a **per-push outcome log, not a cursor/"last synced at" table** — the
  actual "what changed" determination is entirely client-supplied-timestamp-based, with
  no server-held cursor per user/device.
- **None of the 7 `@RestResource` classes check a Custom Permission or explicit
  Profile/role name for endpoint-level authorization** — access instead relies on (a)
  the OAuth/session + Apex class access granted via permission sets, (b) `with
  sharing`/`AccessLevel.USER_MODE` record-level enforcement, and (c) a few hand-rolled
  ownership/role checks inside `SciagenAccountTerritoryController` (deliberately `without
  sharing`, with an explicit code comment that the method itself substitutes for
  object-level CRUD permission) and `SciagenDeviceResetController` (every query scoped
  to `WHERE OwnerId = :userId`). Any new REST endpoint for Sample Management should
  decide explicitly whether to follow this ownership/role-check pattern or add real
  Custom Permission checks, since neither is used consistently today.
- **The account sync-up endpoint deliberately never writes `Sciagen_Account__c`
  directly** — every mobile-submitted create/edit becomes a `Data_Change_Request__c`
  for human review, and `Submitted_By__c` is always stamped server-side from
  `UserInfo.getUserId()` (never trusted from the request body), preventing attribution
  spoofing (`classes/SciagenAccountSyncService.cls`, `syncUp()`). This governance
  pattern (mobile write → DCR → human approval → actual write) is the existing
  convention the Sample Management module should likely follow for any mobile-originated
  writes to master data, as opposed to samples/transactions themselves which write
  directly (§1.6/§1.7) since they're operational, not master-data, records.
- **Device Reset workflow, now fully traced end-to-end**: rep taps "Reset Local Data" →
  inserts `Device_Reset_Request__c` → auto-submitted to the (source-untracked, see
  §12.4) Approval Process → on manager approval, a 6-digit OTP is generated
  (`OTP_Expires__c` = approval + 24h) and emailed to the manager, who relays it to the
  rep out-of-band → rep enters the code in-app → `SciagenDeviceResetController.verifyOTP()`
  (§7.1) validates and marks the request `Verified__c=true`/`Status__c='Used'` → the
  app proceeds with the actual on-device wipe (client-side Swift, outside this repo).

### 12.8 Net effect on this inventory's "UNVERIFIED" items

The deep-dive passes resolved several items this document's main body had marked
UNVERIFIED or flagged for follow-up:
- `Sample_Attempt__e` publisher — **now located** (§12.4).
- Whether sync uses `SystemModstamp` or another delta mechanism — **confirmed
  `LastModifiedDate`, zero `SystemModstamp` usage anywhere** (§12.7).
- Full REST request/response shapes for the 7 `@RestResource` classes — **now fully
  documented** (§12.7 summarizes; full per-field shapes are in the underlying pass
  output and can be pulled into a future revision if needed).

Still genuinely UNVERIFIED after all passes (unchanged from the main body): Apex test
coverage percentages (§10.3 — needs `sf apex run test` with explicit confirmation);
the live role hierarchy structure (§3.3 — needs an org-side metadata retrieve); the
Device_Reset_Request__c Approval Process's actual routing/step configuration (§12.4 —
same); whether both Connected Apps are simultaneously live in the org today (§12.5 —
needs an org-side check, not just metadata); and whether the `CMS_Integration`
Connected App exists only in the org and was never retrieved, or doesn't exist at all
(§12.5 — same).
