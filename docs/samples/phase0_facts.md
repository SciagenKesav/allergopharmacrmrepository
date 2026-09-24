# Phase 0 Step 9 — facts the build depends on

Read-only investigation against `sciagen-sandbox`, run 24 Sep 2026. No metadata or data
was changed by any of the commands below (see the queries themselves for exact
reproduction).

## Role hierarchy

Retrieved via `SELECT Id, Name, DeveloperName, ParentRoleId FROM UserRole` (the
`sf project retrieve start -m Role` metadata retrieve reported success but wrote no
files to disk — a local SFDX/CLI quirk, not an org issue; SOQL against `UserRole` is the
reliable source here and is what the table below reflects).

4 roles, one straight chain, no branching:

| Role | Developer Name | Parent |
|---|---|---|
| Business Unit Head | `Business_Unit_Head` | *(top level)* |
| Zonal Manager | `Zonal_Manager` | Business Unit Head |
| Key Account Manager | `Key_Account_Manager` | Zonal Manager |
| Sales Representative | `Sales_Representative` | Key Account Manager |

Relevant to `SampleLimitChecker`'s `Territory_Product` scope and
`SampleNotifier.managersOf()` (walks `User.ManagerId`, not the role hierarchy directly —
worth knowing these don't automatically move together) and to any future
role-hierarchy-based sharing rule for Sample Management records.

## Approval processes

**None exist.** Confirmed two ways:
- `sf project retrieve start -m ApprovalProcess` returned success with zero
  `ApprovalProcess` entries in `fileProperties` (only the 4 `Role` entries above and
  `package.xml`).
- `sf org list metadata -m ApprovalProcess` returned an empty list.

Relevant to the build plan's Phase 2 note: *"Adjustments over a set size need approval.
Build that as an Apex status workflow like DCR, not a native Approval Process"* — this is
already the only viable path; there is no existing native Approval Process to extend or
collide with, in this org or in general (0 exist for any object).

## Connected app the iPad actually uses

**Neither of the two tracked Connected Apps.** This is the most consequential finding
here:

- `force-app/main/default/connectedApps/SciagenCRM_iPad_OAuth.connectedApp-meta.xml`
  and `SciagenCRM_Mobile.connectedApp-meta.xml` exist in this repo's source, each with
  its own `consumerKey`.
- Neither key matches the consumer key actually compiled into the iPad app
  (`SciagenCRM/Services/SalesforceAuthService.swift:26`,
  `3MVG9gl7ph1Px3Yb9Mi7Su5UI9TYcJTz...`).
- Retrieving both named Connected Apps from `sciagen-sandbox`
  (`sf project retrieve start -m "ConnectedApp:SciagenCRM_iPad_OAuth" -m "ConnectedApp:SciagenCRM_Mobile"`)
  returned **zero** file properties for either — **neither Connected App exists in the
  live sandbox at all**, despite being present in this repo's tracked source. They were
  either never deployed, or deleted from the org after being retrieved into source at
  some point.
- The `ConnectedApplication` standard object lists exactly one classic Connected App in
  this org — `OIQ_Integration` — unrelated to the iPad.
- The `ExternalClientApplication` Tooling API object (Salesforce's newer app-registration
  model, separate from classic Connected Apps and from what `-m ConnectedApp` metadata
  retrieval surfaces) lists two entries:
  - `Sciagen_CRM` — "Created for CMS and APP integration"
  - **`IPAD_APP_Access`** — "Crearted for APP integration" *(sic)*

  `IPAD_APP_Access` is, by name and stated purpose, almost certainly the app the iPad
  actually authenticates through. I could not pull its OAuth consumer key via SOQL/Tooling
  API to confirm the exact match byte-for-byte (External Client App OAuth settings
  aren't exposed through a queryable object the way classic Connected App fields
  sometimes are) — **this needs a quick manual check in Setup → App Manager → External
  Client Apps → IPAD_APP_Access → OAuth Settings** to confirm the consumer key equals
  `3MVG9gl7ph1Px3Yb9Mi7Su5UI9TYcJTz_1IyXkTmndtjx0RcRLVgwbmbEutl_ehap0UGofD7u04maDzMd0611`.

**Practical implication:** `SciagenCRM_iPad_OAuth.connectedApp-meta.xml` and
`SciagenCRM_Mobile.connectedApp-meta.xml` in this repo are currently dead source — they
describe something that doesn't exist in the org the iPad actually talks to. Any future
change to OAuth scopes, callback URL, or token policy for the iPad app needs to happen
on `IPAD_APP_Access` (via Setup UI, or by retrieving it into source first, since it isn't
tracked here), not on either of the two files currently in this repo. Worth a follow-up
to either delete the two stale local files or reconcile them with reality — flagging
rather than changing them here, since this is a read-only fact-finding step.

## `SyncTrackingPurgeJob` — is it scheduled?

**No.** `SyncTrackingPurgeJob.cls` exists in source (with a test class,
`SyncTrackingPurgeJobTest.cls`), but `SELECT Id, CronJobDetail.Name, State, NextFireTime
FROM CronTrigger` shows exactly one scheduled job in this org — an unrelated "Metalytics
Data Loader Job" — and no entry for `SyncTrackingPurgeJob`. Its `.schedule()`-style entry
point (if one exists on the class) has never been invoked against this org, or was
invoked and later aborted.

## Not covered here

`Sync_Object_Config__mdt` seeding for the new Sample_* objects, real device/APNs
questions (D13), and the Address-object design decision (Open Question #1, gates
~20 licensing IDs) are Phase 1+ concerns per `05_revised_build_plan.md` and D1 — not
re-investigated in this pass.
