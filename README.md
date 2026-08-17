# Net Zero Cloud — Bulk Gap Fill

Portfolio-level gap filling for Salesforce Net Zero Cloud stationary assets.

Salesforce's native gap fill wizard works on **one** `StnryAssetCrbnFtprnt`
record at a time, only on the Commercial Building record type, and exposes no API,
invocable action, or Flow action for automation. This project replicates that
wizard's logic as Batch Apex and puts a portfolio-level LWC in front of it, so an
entire estate can be gap filled in a single run.

New to the codebase? [`PROCESS_MAP.html`](PROCESS_MAP.html) is a diagrammed
walkthrough of how the pieces fit together — the tier boundaries, one run end to
end, what happens inside a single batch chunk, the gap detection algorithm, and
the fill method routing. Open it in a browser.

---

## What gap filling does

When energy use data is missing for a stationary asset — a utility bill never
arrived, say — the asset's carbon footprint record has gaps, and its emissions
totals are understated. Gap filling estimates the missing consumption so the
footprint is complete and auditable. Generated records are flagged so they can be
excluded from actuals-only reporting.

---

## Architecture

### Apex

| Class                     | Role                                                                 |
| ------------------------- | -------------------------------------------------------------------- |
| `BulkGapFillService`      | Gap detection and fill calculation. Pure logic, no SObjects.         |
| `BulkGapFillBatch`        | `Database.Batchable` + `Database.Stateful` run across the portfolio. |
| `BulkGapFillRequest`      | Run configuration DTO, with `validate()`.                            |
| `BulkGapFillConstants`    | All Net Zero Cloud API names, method and status tokens.              |
| `BulkGapFillController`   | `@AuraEnabled` surface for the LWC wizard.                           |
| `BulkGapFillJobScheduler` | `Schedulable` wrapper for recurring runs.                            |

Two design decisions worth knowing before you read the code:

**The service core takes no SObjects.** Gap detection works on plain `DateRange` and
`EnergyRecord` wrappers, so it is unit testable in any org — including one without
Net Zero Cloud installed — and reusable from the batch, a preview, or a future
invocable action. The batch owns all querying and mapping.

**The batch queries via dynamic SOQL.** NZC object and field API names vary by org
edition and release. Dynamic SOQL turns a name mismatch into a clear runtime error
recorded on the job record, instead of a deploy failure that blocks the entire
package. The trade-off is that a successful deploy proves nothing about those names
— see [Verify the org first](#verify-the-org-first).

### Custom objects

- **`BulkGapFillJob__c`** — one row per run: status, reporting year, method, dry-run
  flag, the serialized request, `AsyncApexJobId__c` for progress polling, roll-up
  counts, error log, timestamps.
- **`BulkGapFillJobDetail__c`** — master-detail child, one row per footprint per fuel
  type: gaps found, gap days, method actually used, records created, energy filled,
  outcome, and any error. This is the audit trail.

### LWC

`bulkGapFillWizard` is the container and the only exposed component; it owns step
state and delegates to three children:

1. **`bulkGapFillConfigure`** — pick year, method, and filters; check scope; launch.
2. **`bulkGapFillMonitor`** — polls `AsyncApexJob` for live progress; supports abort.
3. **`bulkGapFillResults`** — per-asset grid with status filtering and CSV export.

Deployed to a `Bulk Gap Fill` tab via the `Bulk_Gap_Fill` FlexiPage.

---

## The five fill methods

Each derives a daily consumption rate, then multiplies by the gap's inclusive day count.

| Method                      | Daily rate                        | Requires                                           |
| --------------------------- | --------------------------------- | -------------------------------------------------- |
| Regional BEI                | `(BEI × floorAreaSqM) / 365`      | `RegionalBldgEnergyIntensityId` on the footprint   |
| Building BEI                | `(BEI × floorAreaSqM) / 365`      | `BuildingEnergyIntensityId` on the footprint       |
| Previous Year Daily Average | `priorYearTotal / 365`            | Prior-year records for the same fuel type          |
| Current Year Daily Average  | `currentYearTotal / daysWithData` | At least one current-year record for the fuel type |
| Manual                      | operator-supplied                 | A daily rate on the request                        |

When a method's prerequisites are missing, the service throws `FillNotViableException`
and the batch records a **Skipped** detail row with the reason. It does not silently
substitute another method or write a wrong estimate.

### Date convention

All ranges are **inclusive of both endpoints**: Jan 1 – Jan 31 is 31 days, and a bill
ending Jan 31 followed by one starting Feb 1 leaves no gap. The native wizard's
published formula uses `EndDate - StartDate` (exclusive, 30 days). The inclusive
reading is used here because the exclusive one leaves phantom single-day gaps between
consecutive bills — **confirm which convention your org's audit expects before trusting
the totals.**

---

## Getting started

### Prerequisites

- [Salesforce CLI](https://developer.salesforce.com/tools/salesforcecli)
- Node.js 20+ and npm
- An org with **Net Zero Cloud enabled**

### Install and deploy

```bash
npm install
```

```bash
sf project deploy start --source-dir force-app --target-org <your-org>
```

Then assign the permission set:

```bash
sf org assign permset --name Bulk_Gap_Fill_Admin --target-org <your-org>
```

The `Bulk Gap Fill` tab is then available from the App Launcher.

### Verify the org first

Because the NZC queries are dynamic, deployment does **not** validate that the object
and field names in `BulkGapFillConstants` match your org. Check them explicitly:

```bash
sf apex run --target-org <your-org> --file scripts/apex/validate-schema.apex
```

An empty result means the org is ready. Anything listed is a name to correct in
`BulkGapFillConstants` before the first real run.

### First run

Start with **Dry run** checked. It performs full gap detection and writes the complete
per-asset audit trail without creating a single energy use record, which is the cheapest
way to confirm the detected gaps and estimated values look right for your data.

---

## Development

```bash
npm run lint
```

```bash
npm run docs
```

`npm test` runs the LWC Jest suite: 33 specs across the four components, covering
step transitions, the request payload the Configure page builds, the monitor's
polling and auto-advance behaviour, and the Results CSV escaping.

`npm run docs` generates the Apex reference into `docs/` with
[apexdocs](https://github.com/cesarParra/apexdocs). That directory is gitignored —
regenerate it locally rather than committing it. The post-processing step
(`scripts/fix-doc-links.mjs`) normalizes path separators in the generated links,
which apexdocs otherwise emits as backslashes on Windows.

Apex tests:

```bash
sf apex run test --target-org <your-org> --code-coverage --result-format human
```

| Class                       | Covers                                                             | Needs NZC? |
| --------------------------- | ------------------------------------------------------------------ | ---------- |
| `BulkGapFillServiceTest`    | Gap detection and the five fill formulas, over plain wrappers      | No         |
| `BulkGapFillRequestTest`    | Request validation, period defaults, JSON round trip               | No         |
| `BulkGapFillControllerTest` | Controller paths touching only the custom objects                  | No         |
| `BulkGapFillBatchTest`      | Fill method picklist resolution, detail reconciliation, `finish()` | No         |
| `BulkGapFillBatchRunTest`   | The batch run end to end, against real NZC records                 | Yes        |
| `BulkGapFillTestData`       | Fixture builder for the five NZC objects (not a test class)        | Yes        |

`BulkGapFillBatchRunTest` runs the batch and then reads the generated energy use
records back — the assertion that matters, since a run can report `Filled` while
creating nothing. Each of its tests no-ops where Net Zero Cloud is absent, so the
suite stays green in a scratch org without it.

Coverage as of the last full-org run: 91% org-wide, comfortably past the 75%
deploy gate. Per class — `BulkGapFillJobScheduler` 100%, `BulkGapFillRequest` 97%,
`BulkGapFillService` 94%, `BulkGapFillBatch` 89%, `BulkGapFillConstants` 86%,
`BulkGapFillController` 70%. The controller is the thinnest: its uncovered lines
are mostly `catch` blocks that rethrow as `AuraHandledException`.

---

## Deployment note

`Bulk_Gap_Fill_Admin` carries the field-level security for both custom objects.
Custom fields deploy with FLS off, so a user assigned only the object permissions
gets "fields being inaccessible on SObject BulkGapFillJob__c" the moment a run is
launched. Assign the permission set — do not rely on object access alone.

---

## Current limitations

Known gaps in this implementation, so nobody discovers them the hard way:

- **NZC API names are verified, for one org.** `BulkGapFillBatchRunTest` reads and
  writes every object and field in `BulkGapFillConstants` against a real Net Zero
  Cloud org, and dynamic SOQL fails loudly on a bad name, so the names are no longer
  taken on trust. That is evidence from one org on one NZC release, not a guarantee:
  run `validateSchema()` against any new target org before the first deploy. One
  branch remains unexercised end to end — a benchmark that populates only
  `AnnualIntensityValueInKwhSqft` and not the metric column, so the imperial
  conversion in `toKwhPerSquareMetre` is covered by unit test only.
- **A benchmark missing the fuel type is skipped, quietly.** Intensity values are keyed
  by fuel type on the child `BldgEnrgyIntensityVal` records. When a benchmark has no row
  for the fuel type being filled, the fill resolves to a **Skipped** detail row rather
  than borrowing another fuel type's figure — safe, but easy to miss across a large run.
  Dry-run first and check the detail rows.
- **Orphan association is not implemented.** `associateOrphans` is accepted on the
  request and surfaced in the UI, but no matching logic runs; `RecordsAssociated__c`
  stays at zero. The matching rule is org-specific.
- **`skipAlreadyFilled` is not enforced.** It is carried on the request but not yet
  applied in `execute()`, so re-running against the same period will create duplicate
  gap-filled records. Use dry run and check the detail rows before a repeat run.
  `EnergyRecord.isGapFilled` is already populated for when it is implemented, from
  `IsSystemGeneratedRecord` — the flag the native process sets, so records filled by
  either route count.
- **Two failure paths are deliberately untested.** The chunk-level `catch` in
  `execute()` and the partial-failure branch of `Database.insert` both need DML to
  fail against real NZC objects. Forcing that would distort the fixtures more than
  the coverage is worth, so they are left uncovered knowingly rather than missed.
- **Abort does not roll back.** Aborting a run stops further chunks; records already
  inserted by completed chunks remain.
- **CSV export covers loaded rows only.** The Results grid pages at 200 rows; page
  through before exporting a large run.

---

## Reference

- [Data Gap Filling — Net Zero Cloud Developer Guide](https://developer.salesforce.com/docs/atlas.en-us.netzero_cloud_dev_guide.meta/netzero_cloud_dev_guide/netzero_calc_data_gap_filling.htm)
- [StnryAssetEnvrSrc Object Reference](https://developer.salesforce.com/docs/atlas.en-us.netzero_cloud_dev_guide.meta/netzero_cloud_dev_guide/sforce_api_objects_stnryassetenvrsrc.htm)
- [Stationary Asset Energy Use](https://developer.salesforce.com/docs/atlas.en-us.netzero_cloud_dev_guide.meta/netzero_cloud_dev_guide/netzero_calc_eur_commercial_building.htm)
- [Benchmark BEI and Fill Gaps — Trailhead](https://trailhead.salesforce.com/content/learn/modules/carbon-accounting-for-assets-with-net-zero-cloud/benchmark-building-energy-intensity-and-fill-gaps-in-the-carbon-footprint-data)
