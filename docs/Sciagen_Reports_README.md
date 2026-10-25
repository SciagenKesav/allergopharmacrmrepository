# Sciagen Reports (Salesforce) — README

Reproduces the iPad Reports module server-side. Read-only: no DML anywhere.

## Files
- Apex: `ReportsService` (engine, `with sharing`, `WITH USER_MODE` on every query), `ReportsController` (cacheable `@AuraEnabled` facade), `ReportsServiceTest` (97% coverage; covers acceptance tests 1–10).
- LWC: `sciReportsHome` (library, period, search, filters, rep filter), `sciReportView` (renders any report), `sciSalesReports`, `sciReportTable`, `sciKpiCard`, `sciChart`, `sciFilterPanel`, `sciDrillPanel`, `sciReportsUtil` (periods, CSV, sorting).
- Metadata: tab `Sciagen_Reports`, flexipage `Sciagen_Reports`, permission sets `Sciagen_Reports_User` and `Sciagen_Reports_Manager`, custom permission `Sciagen_Reports_Manager`, tab added to the Sciagen CRM app.

## Deliberate differences from the prompt
- One generic `sciReportView` renders every report from the Apex result (KPIs, charts, tables) instead of one LWC per report; all numbers still come from Apex.
- Charts are drawn with inline SVG/CSS (no Chart.js static resource, no CDN, no download needed).

## Field assumptions (names differ from the prompt)
| Prompt | Used |
|---|---|
| `Call_Visit_Report__c.Plan_Call__c` | `Source_Planned_Call__c` (also `Planned_Call__c.Resulting_CVR__c`) |
| Planned-call note | none exists → Missed Calls "Note" shows "—" |
| `Sent_Email__c` sent date | `Sent_At__c`; the server stamps it on delivery, so a still-Queued email has none and falls back to `CreatedDate` |
| `Sent_Email__c` template name | `Template__r.Template_Name__c` (else `Template__r.Name`) |
| `Key_Message__c.Product_Name__c` | `Key_Message__c.Product__c` (a text field holding the product name) |
| Email delivery status | `Status__c`: Sent = delivered, Failed, Queued; blank counts as Sent |

## Other assumptions
- Group calls: child reports (`Parent_Call__c` set) are ignored; the parent report credits its primary HCP and each `CVR_Attendee__c`, once per (HCP, report). Plans have no attendee object, so Planned counts the plan's own HCP only.
- Territory of an HCP: the earliest `Account_Territory__c` row. Hospital: primary affiliation, else the first. City: HCP billing city, else the hospital's.
- Who sees what (enforced in Apex, not just hidden in the UI):
  - KAM (only `Sciagen_Reports_User`): own territories (plus child territories) only; no pickers; any territory/KAM sent in a request is ignored.
  - Manager (+ `Sciagen_Reports_Manager`): Territory picker lists their assigned territories and their child territories (children indented); choosing one lists the KAMs assigned to it or its children; choosing a KAM shows that KAM's reports. A territory outside their scope is refused.
  - Business Admin (+ `Sciagen_Reports_Business_Admin`): every territory and every KAM.
  - Assignments come from `User_Territory__c`; hierarchy from `Territory__c.Parent_Territory__c`. Users who hold the Manager/Business Admin permission sets are not listed as KAMs.
- Dates use the running user's time zone. Missed uses today in that zone.
- Segment = the doctor's **classification** (`Segmentation__c.Classification__c`): V3, V2, V1, and Unclassified for a doctor with no classification or no segmentation record. Tier (Gold/Silver/Bronze) is no longer used by the Reports. The filter chips, the Segment grouping, Segment Analysis, Call Frequency and the Missed Calls "V3 missed" tile all follow this. The iPad Reports still group by Tier / A-B-C, so the iPad and CRM segment views will differ until the app is changed.
- Consent: most recent `Consent__c` by `Captured_At__c`; Expired when captured over 3 years ago (wins over Signed).
- Sales targets: only `Territory__c = null`. Sales view ignores period, search and filters.

## Known gaps (as specified)
- CLM Engagement is not built; `Presentation_Session__c` is not synced from the iPad, so CLM sessions/minutes/slides read 0 (Omnichannel keeps the CLM channel; Product Detailing hides CLM minutes). TODO markers are in `ReportsService`.
- No opens/clicks for approved email. No sample-limit warnings.

## Bi-directional behaviour
Reports store nothing. They recalculate from the live Salesforce data every time (Refresh button), so anything the iPad syncs up (calls, plans, consents, emails, samples) shows up here, and anything changed in Salesforce shows on the iPad after the iPad pulls that object. Accounts/territories sync direction is controlled by `Sync_Object_Config__mdt` and was not changed.
