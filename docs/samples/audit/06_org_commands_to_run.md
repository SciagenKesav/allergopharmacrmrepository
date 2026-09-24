# Org Commands Needed To Complete Verification

Org access was **not** missing for this audit — `sciagen-sandbox` was connected and authenticated throughout, and every check in `01_inventory_salesforce.md` and the four gap-analysis passes that needed live org data (record counts, `sf sobject describe`, SELECT-only `sf data query`) was run directly. This file exists only because one specific, named check was explicitly excluded by the audit's own strict rules and needs your explicit go-ahead to complete.

## The one blocked check: Apex test coverage percentages

**Why it's blocked:** the audit's rule #2 permits `sf apex run test` "only if I confirm," because running tests can insert/roll back data in the org. No test run was performed anywhere in this audit.

**What's missing without it:** `03_gap_matrix.csv` and `03_code_quality.md` both document *which* test classes exist and, by reading their contents directly, how strong their assertions are (this was verified by reading test file contents, not by running them) — but neither can state actual **pass/fail status** or **% line coverage** for any class, because that requires execution.

**Exact command to run, if you approve:**

```bash
sf apex run test -o sciagen-sandbox --code-coverage --result-format json --wait 30 --synchronous
```

Notes on this command:
- `--synchronous` runs tests one at a time in the current context rather than queuing async — slower but simpler to review the output of in one pass. Drop it (and add `--wait 30` alone) for the org's normal async parallel test execution if you'd rather it finish faster.
- This **will** create and roll back test data inside the org's test-execution sandboxed transaction, as any Apex test run does — it does not persist data, but it does count against the org's daily test-run limits and will take several minutes given 34+ test classes.
- Once run, re-open `sf apex run test -o sciagen-sandbox --code-coverage --result-format json` or check **Setup → Apex Test Execution** for the code-coverage report, and I can fold the actual percentages into an updated `03_code_quality.md` if you'd like.

## What this does *not* block

Nothing else in the six deliverables (`01_inventory_salesforce.md`, `02_inventory_ios.md`, `03_gap_matrix.csv`, `04_gap_report.md`, `05_revised_build_plan.md`, this file) is waiting on org access — the gap analysis, the 238-ID coverage verification, the high-risk-area findings, and the revised build plan are all already complete without it.

## Supplementary evidence files (not part of the 6 official deliverables, but kept for traceability)

The four parallel gap-analysis sub-agents each wrote a CSV slice and a notes file before being merged into `03_gap_matrix.csv`/`04_gap_report.md`. These are left in place in `docs/samples/audit/` as more granular per-ID evidence trails, in case you want to trace a specific finding back to its original agent's full reasoning:
- `gap_matrix_part1.csv` / `gap_notes_part1.md` — Foundation, Data Model, Config, Setup Flow, Transactions (88 IDs)
- `gap_matrix_part2.csv` / `gap_notes_part2.md` — Licensing, Mid-Level Practitioners, Controlled Substances (37 IDs)
- `gap_matrix_part3.csv` / `gap_notes_part3.md` — Call Sampling, Barcode, Signature, Opt-In, Cold Chain, Inventory Counts (76 IDs)
- `gap_matrix_part4.csv` / `gap_notes_part4.md` — Security, Audit Trail, UCPMP Rules, Disclosure, iOS Architecture (37 IDs)
