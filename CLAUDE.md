# Net Zero Cloud — Bulk Gap Fill Project

## Project Goal

Build a custom Salesforce solution that enables **bulk gap filling** for all Stationary Asset Environmental Source records (`StnryAssetEnvrSrc`) simultaneously. Salesforce's native gap fill wizard only supports one stationary asset at a time. This project replicates and extends that wizard's logic via:

- A **Batch Apex** class that processes gap filling across an entire portfolio of stationary assets
- A **custom Lightning Web Component (LWC) UI** that lets users configure, trigger, monitor, and review bulk gap fill runs — replacing the native one-at-a-time wizard experience

---

## Domain Background: Salesforce Net Zero Cloud Gap Filling

### What Gap Filling Does

When energy use data is missing for a stationary asset (e.g., a utility bill wasn't received), the carbon footprint record for that asset will have gaps. Gap filling estimates those missing values so emissions calculations remain complete and auditable.

The native wizard walks through three steps for a **single** `StnryAssetCrbnFtprnt` record:

1. **Associate orphan records** — links unmatched `EnergyUse` records to the carbon footprint record
2. **Fix date issues** — corrects overlapping periods, missing start/end dates
3. **Fill missing data** — generates new `EnergyUse` records for gaps using one of five methods

### Key Limitation of Native Feature

- Only works on the **Commercial Building** record type of `StnryAssetEnvrSrc`
- Wizard is scoped to **one carbon footprint record at a time** — no portfolio-level processing
- No API, invocable action, or Flow action is exposed for bulk automation
- Salesforce has indicated bulk gap fill is on the roadmap but has not shipped it publicly as of August 2026

---

## Data Model

### Core Objects

| Object                                | API Name                | Purpose                                                                 |
| ------------------------------------- | ----------------------- | ----------------------------------------------------------------------- |
| Stationary Asset Environmental Source | `StnryAssetEnvrSrc`     | Represents a physical stationary asset (building, warehouse, etc.)      |
| Stationary Asset Carbon Footprint     | `StnryAssetCrbnFtprnt`  | Annual carbon footprint record per asset per reporting year             |
| Stationary Asset Energy Use           | `StnryAssetEnrgyUse`    | Individual energy consumption records (fuel type, date range, quantity) |
| Building Energy Intensity             | `BldgEnrgyIntensity`    | BEI benchmark header; target of every BEI lookup                        |
| Building Energy Intensity Value       | `BldgEnrgyIntensityVal` | Per-energy-type values belonging to a benchmark                         |

There is **no** regional building energy intensity object. The regional lookup on the
stationary asset points at a `BldgEnrgyIntensity` record like the custom one does, so
both benchmark fill methods resolve against the same object.

### Key Fields on `StnryAssetEnvrSrc`

- `RegionalBldgEnergyIntensityId` — auto-populated for US locations; gates Regional BEI fill method. Points to a `BldgEnrgyIntensity` record
- `OccupiedFloorArea` + `OccupiedFloorAreaUnit` (sqft or m²) — used in BEI calculations
- `TotalFloorArea` + `TotalFloorAreaUnit`
- `StationaryAssetType` — Office, Factory, Warehouse, Data Center, etc.
- `RecordTypeId` — must be **Commercial Building** for native gap fill; our solution should handle all types

### Key Fields on `StnryAssetCrbnFtprnt`

- `StnryAssetEnvrSrcId` — parent asset lookup
- `ReportingYear` — fiscal/calendar year being reported
- `BuildingEnergyIntensityId` — lookup to custom BEI (gates Building BEI fill method)
- `RegionalBldgEnergyIntensityId` — lookup to the CBECS benchmark
- Scope 1, 2, 3 rollup fields (auto-calculated from child energy use records)

Both BEI lookups point at a `BldgEnrgyIntensity` record. The two field names spell
`Building` differently — unabbreviated on the custom lookup, `Bldg` on the regional
one — and neither matches the object's own `BldgEnrgy` spelling.

### Key Fields on `StnryAssetEnrgyUse`

- `StnryAssetCrbnFtprntId` — parent footprint record
- `FuelType` — electricity, natural gas, diesel, etc.
- `StartDate` / `EndDate` — consumption period
- `EnergyConsumption` + `EnergyConsumptionUnit`
- `IsGapFilled` (Boolean) — flag to distinguish estimated vs. actual records
- `GapFillMethod` — which method was used (for audit trail)

---

## The Five Fill Methods

All methods produce a daily consumption rate, then multiply by gap duration in days.

### 1. Regional Building Energy Intensity (BEI)

Uses CBECS benchmarks loaded on the asset.

```
DailyRate = (RegionalBEI_kWh_per_m2 × OccupiedFloorArea_m2) / 365
GapFillValue = DailyRate × GapDays
```

**Requires**: `RegionalBldgEnergyIntensityId` populated on the carbon footprint record.

### 2. Building Energy Intensity (Custom BEI)

Uses organization-defined benchmarks from BEI Builder.

```
DailyRate = (CustomBEI_kWh_per_m2 × OccupiedFloorArea_m2) / 365
GapFillValue = DailyRate × GapDays
```

**Requires**: `BuildingEnergyIntensityId` populated on the carbon footprint record.

### 3. Previous Year Daily Average

Extrapolates from prior year actual data for the same fuel type.

```
PriorYearTotal = SUM(EnergyConsumption) WHERE ReportingYear = CurrentYear - 1 AND FuelType = X
DailyRate = PriorYearTotal / 365
GapFillValue = DailyRate × GapDays
```

**Requires**: Energy use records exist for the prior year for the same fuel type.

### 4. Current Year Daily Average

Extrapolates from existing year-to-date records.

```
CurrentYearDaysWithData = SUM(EndDate - StartDate) across existing records for this fuel type
CurrentYearTotal = SUM(EnergyConsumption) for this fuel type this year
DailyRate = CurrentYearTotal / CurrentYearDaysWithData
GapFillValue = DailyRate × GapDays
```

**Requires**: At least one existing energy use record for the current year and fuel type.

### 5. Manual

User provides a direct value. No formula — captured as input in the UI.

---

## Gap Detection Logic

For each `StnryAssetCrbnFtprnt` record in scope:

1. Determine the full reporting period (Jan 1 – Dec 31, or fiscal equivalent)
2. For each fuel type associated with that asset, collect all `StnryAssetEnrgyUse` records
3. Sort by `StartDate`
4. Identify any periods within the reporting year not covered by an energy use record — these are gaps
5. Identify orphan energy use records (no `StnryAssetCrbnFtprntId`) that fall within the reporting period — offer to associate them
6. Identify date issues: overlapping records, records with null start/end dates

---

## Solution Architecture

### Batch Apex

- **`BulkGapFillBatch`** — implements `Database.Batchable<SObject>`, `Database.Stateful`
  - `start()`: queries all `StnryAssetCrbnFtprnt` records matching user-selected filters (year, asset type, specific assets, etc.)
  - `execute()`: for each record, runs gap detection, applies chosen fill method, inserts new `StnryAssetEnrgyUse` records with `IsGapFilled = true` and `GapFillMethod` stamped
  - `finish()`: updates a custom `BulkGapFillJob__c` record with status, counts, and any errors
- **`BulkGapFillService`** — stateless service class with the gap detection and fill calculation logic (called by batch; also callable from unit tests independently)
- **`BulkGapFillJobScheduler`** — optional `Schedulable` wrapper to allow scheduled runs

### Custom Objects

- **`BulkGapFillJob__c`** — tracks each bulk run: status, reporting year, fill method used, assets processed, records created, errors, run by, timestamps
- **`BulkGapFillJobDetail__c`** — child records per asset within a run, for per-asset audit trail

### Lightning Web Component UI

A custom LWC (or small set of LWCs) that provides a portfolio-level gap fill experience:

**Page 1 — Configure Run**

- Select reporting year
- Filter assets: all, by type, by region, by specific list
- Choose default fill method (can be overridden per asset)
- Option to dry run (preview gaps without creating records)
- Launch button triggers the batch

**Page 2 — Monitor Run**

- Live status of the running batch job (polling `AsyncApexJob`)
- Progress: X of Y assets processed
- Running counts: gaps found, records created, errors

**Page 3 — Review Results**

- Per-asset breakdown: gaps found, method used, records created
- Ability to drill into a specific asset and see the generated energy use records
- Flag any assets with errors for manual follow-up
- Export summary to CSV

**Deployment target**: Custom tab or embedded on the Net Zero Cloud app page.

---

## Development Constraints & Notes

- Salesforce API version: target **v62.0+** (Net Zero Cloud objects stable from v54.0)
- All Net Zero Cloud objects (`StnryAssetEnvrSrc`, `StnryAssetCrbnFtprnt`, `StnryAssetEnrgyUse`, etc.) are fully queryable and writable via Apex — no managed package restrictions on CRUD
- The native gap fill wizard is in a managed package; do not try to extend or call it — build independently
- Gap-filled records should be clearly tagged (`IsGapFilled__c` or the standard field if available) so they can be excluded from actuals-only reporting views
- Batch size: start with 50 records per chunk; each chunk may generate many child inserts, so stay conservative to avoid governor limits
- All DML should use `Database.insert(records, false)` with partial success handling so one bad asset doesn't abort the entire batch

---

## Reference URLs

- [Data Gap Filling — Net Zero Cloud Developer Guide](https://developer.salesforce.com/docs/atlas.en-us.netzero_cloud_dev_guide.meta/netzero_cloud_dev_guide/netzero_calc_data_gap_filling.htm)
- [StnryAssetEnvrSrc Object Reference](https://developer.salesforce.com/docs/atlas.en-us.netzero_cloud_dev_guide.meta/netzero_cloud_dev_guide/sforce_api_objects_stnryassetenvrsrc.htm)
- [Stationary Asset Energy Use — Developer Guide](https://developer.salesforce.com/docs/atlas.en-us.netzero_cloud_dev_guide.meta/netzero_cloud_dev_guide/netzero_calc_eur_commercial_building.htm)
- [Benchmark BEI and Fill Gaps — Trailhead](https://trailhead.salesforce.com/content/learn/modules/carbon-accounting-for-assets-with-net-zero-cloud/benchmark-building-energy-intensity-and-fill-gaps-in-the-carbon-footprint-data)
- [Manage Carbon Footprint Records — Trailhead](https://trailhead.salesforce.com/content/learn/modules/carbon-accounting-for-assets-with-net-zero-cloud/manage-carbon-footprint-records-for-stationary-assets)
