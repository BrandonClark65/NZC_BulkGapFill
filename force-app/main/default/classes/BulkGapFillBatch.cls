/**
 * @description Runs bulk gap filling across every `StnryAssetCrbnFtprnt` matching
 * the request's filters, replacing the native one-asset-at-a-time wizard.
 *
 * Queries are built as dynamic SOQL against the object and field names declared in
 * `BulkGapFillConstants`. That is deliberate: Net Zero Cloud API names vary across
 * org editions and NZC releases, and dynamic SOQL turns a name mismatch into a
 * clear runtime error captured on the job record rather than a deploy failure that
 * blocks the whole package. The trade-off is that a successful deploy does not
 * prove the NZC names are right — run `BulkGapFillConstants.validateSchema()` for that.
 *
 * All DML uses partial-success semantics so one malformed asset cannot abort the run.
 *
 * @group Bulk Gap Fill
 * @see BulkGapFillService
 * @see BulkGapFillRequest
 * @see BulkGapFillJobScheduler
 * @example
 * ```apex
 * BulkGapFillRequest req = new BulkGapFillRequest();
 * req.reportingYear = 2025;
 * req.defaultFillMethod = BulkGapFillConstants.METHOD_CURRENT_YEAR;
 *
 * BulkGapFillJob__c job = new BulkGapFillJob__c(
 *     Status__c = BulkGapFillConstants.JOB_QUEUED,
 *     ReportingYear__c = req.reportingYear,
 *     DefaultFillMethod__c = req.defaultFillMethod
 * );
 * insert job;
 *
 * Database.executeBatch(new BulkGapFillBatch(req, job.Id), BulkGapFillConstants.DEFAULT_BATCH_SIZE);
 * ```
 */
public with sharing class BulkGapFillBatch implements Database.Batchable<SObject>, Database.Stateful {
  private final BulkGapFillRequest request;
  private final Id jobId;

  // Stateful roll-ups carried across chunks into finish().
  private Integer footprintsProcessed = 0;
  private Integer gapsFound = 0;
  private Integer recordsCreated = 0;
  private Integer recordsAssociated = 0;
  private Integer errorCount = 0;
  private List<String> errorLog = new List<String>();

  /**
   * @description Creates the batch for one run.
   * @param request The validated run configuration.
   * @param jobId The `BulkGapFillJob__c` this run reports progress and results to.
   */
  public BulkGapFillBatch(BulkGapFillRequest request, Id jobId) {
    this.request = request;
    this.jobId = jobId;

    this.scopeFootprintIds = request.carbonFootprintIds;
    this.scopeAssetIds = request.stationaryAssetIds;
    this.scopeAssetTypes = request.assetTypes;
    this.scopeYear = BulkGapFillConstants.reportingYearBind(
      request.reportingYear
    );
  }

  // ---- start ------------------------------------------------------------

  /**
   * @description Marks the job as running and returns the carbon footprint records
   * in scope.
   * @param bc The batch context, whose job id is stamped onto the job record so the
   *        monitor UI can poll `AsyncApexJob`.
   * @return A locator over the matching `StnryAssetCrbnFtprnt` records.
   */
  public Database.QueryLocator start(Database.BatchableContext bc) {
    markJobRunning(bc);
    return Database.getQueryLocator(buildFootprintQuery());
  }

  /**
   * Builds the scope query. Explicit footprint Ids win outright; otherwise the
   * reporting year plus any asset filters apply.
   */
  @TestVisible
  private String buildFootprintQuery() {
    List<String> wheres = new List<String>();

    if (
      request.carbonFootprintIds != null &&
      !request.carbonFootprintIds.isEmpty()
    ) {
      wheres.add('Id IN :scopeFootprintIds');
    } else {
      wheres.add(BulkGapFillConstants.FIELD_FOOTPRINT_YEAR + ' = :scopeYear');

      if (
        request.stationaryAssetIds != null &&
        !request.stationaryAssetIds.isEmpty()
      ) {
        wheres.add(
          BulkGapFillConstants.FIELD_FOOTPRINT_ASSET + ' IN :scopeAssetIds'
        );
      }
      if (request.assetTypes != null && !request.assetTypes.isEmpty()) {
        wheres.add(
          assetField(BulkGapFillConstants.FIELD_ASSET_TYPE) +
          ' IN :scopeAssetTypes'
        );
      }
    }

    List<String> selects = new List<String>{ 'Id' };
    selects.addAll(BulkGapFillConstants.FOOTPRINT_FIELDS);
    for (String assetFieldName : BulkGapFillConstants.ASSET_FIELDS) {
      selects.add(assetField(assetFieldName));
    }

    return 'SELECT ' +
      String.join(selects, ', ') +
      ' FROM ' +
      BulkGapFillConstants.OBJ_FOOTPRINT +
      ' WHERE ' +
      String.join(wheres, ' AND ') +
      ' ORDER BY ' +
      BulkGapFillConstants.FIELD_FOOTPRINT_ASSET;
  }

  /** Qualifies an asset field for traversal from the footprint. */
  private static String assetField(String fieldName) {
    return BulkGapFillConstants.REL_FOOTPRINT_ASSET + '.' + fieldName;
  }

  // Bind variables referenced by the dynamic query above. These are plain fields
  // rather than properties because SOQL bind resolution does not see properties.
  private List<Id> scopeFootprintIds;
  private List<Id> scopeAssetIds;
  private List<String> scopeAssetTypes;
  // Text, not Integer: ReportingYear is a string column on the NZC objects.
  private String scopeYear;

  // ---- execute ----------------------------------------------------------

  /**
   * @description Detects gaps for each footprint in the chunk, inserts the
   * gap-filled energy use records unless this is a dry run, and writes one
   * `BulkGapFillJobDetail__c` per footprint per fuel type.
   * @param bc The batch context.
   * @param scope The carbon footprint records in this chunk.
   */
  public void execute(Database.BatchableContext bc, List<SObject> scope) {
    List<StagedFill> staged = new List<StagedFill>();
    List<BulkGapFillJobDetail__c> details = new List<BulkGapFillJobDetail__c>();

    try {
      Map<Id, SObject> footprintsById = new Map<Id, SObject>(scope);
      Map<Id, List<BulkGapFillService.EnergyRecord>> currentByFootprint = loadEnergyRecords(
        footprintsById.keySet()
      );
      Map<Id, List<BulkGapFillService.EnergyRecord>> priorByFootprint = loadPriorYearRecords(
        footprintsById.values()
      );
      loadBenchmarks(scope);

      for (SObject footprint : scope) {
        footprintsProcessed++;
        try {
          processFootprint(
            footprint,
            currentByFootprint.get((Id) footprint.get('Id')),
            priorByFootprint.get((Id) footprint.get('Id')),
            staged,
            details
          );
        } catch (Exception e) {
          errorCount++;
          details.add(errorDetail(footprint, e.getMessage()));
        }
      }

      if (!request.isDryRun && !staged.isEmpty()) {
        recordsCreated += commitEnergyUse(staged);
      }
    } catch (Exception e) {
      // A chunk-level failure (bad query, missing field) applies to every
      // record in scope, so log once rather than per footprint.
      errorCount += scope.size();
      logError(
        'Chunk failed: ' + e.getMessage() + ' | ' + e.getStackTraceString()
      );
    }

    if (!details.isEmpty()) {
      Database.insert(details, false);
    }
  }

  /** Detects gaps for one footprint and stages the records that would fill them. */
  private void processFootprint(
    SObject footprint,
    List<BulkGapFillService.EnergyRecord> currentRecords,
    List<BulkGapFillService.EnergyRecord> priorRecords,
    List<StagedFill> staged,
    List<BulkGapFillJobDetail__c> details
  ) {
    Id footprintId = (Id) footprint.get('Id');
    Id assetId = (Id) footprint.get(BulkGapFillConstants.FIELD_FOOTPRINT_ASSET);
    // Read once here rather than per gap: the asset name goes into the name of
    // every record generated for this footprint.
    SObject asset = footprint.getSObject(
      BulkGapFillConstants.REL_FOOTPRINT_ASSET
    );
    String assetName = asset == null
      ? null
      : asText(asset.get(BulkGapFillConstants.FIELD_ASSET_NAME));
    String method = request.methodFor(footprintId);

    Set<String> fuelFilter = request.fuelTypes == null
      ? new Set<String>()
      : new Set<String>(request.fuelTypes);

    List<BulkGapFillService.FuelGapSet> gapSets = BulkGapFillService.analyzeFootprint(
      request.effectivePeriodStart(),
      request.effectivePeriodEnd(),
      currentRecords,
      fuelFilter
    );

    for (BulkGapFillService.FuelGapSet gapSet : gapSets) {
      BulkGapFillJobDetail__c detail = baseDetail(footprint);
      detail.FuelType__c = gapSet.fuelType;
      detail.FillMethodUsed__c = method;
      detail.GapsFound__c = gapSet.gaps.size();
      detail.GapDays__c = gapSet.totalGapDays;
      detail.EnergyFilledUnit__c = gapSet.consumptionUnit;

      if (gapSet.gaps.isEmpty()) {
        detail.Status__c = BulkGapFillConstants.DETAIL_NO_GAPS;
        details.add(detail);
        continue;
      }
      gapsFound += gapSet.gaps.size();

      Decimal dailyRate;
      try {
        dailyRate = BulkGapFillService.resolveDailyRate(
          buildContext(
            footprint,
            gapSet.fuelType,
            method,
            currentRecords,
            priorRecords
          )
        );
      } catch (BulkGapFillService.FillNotViableException e) {
        detail.Status__c = BulkGapFillConstants.DETAIL_SKIPPED;
        detail.ErrorMessage__c = e.getMessage();
        details.add(detail);
        continue;
      }

      Decimal energyFilled = 0;
      for (BulkGapFillService.DateRange gap : gapSet.gaps) {
        Decimal value = BulkGapFillService.valueForGap(dailyRate, gap);
        energyFilled += value;
        if (!request.isDryRun) {
          staged.add(
            new StagedFill(
              buildEnergyUse(
                footprintId,
                assetId,
                assetName,
                gapSet,
                gap,
                value,
                method
              ),
              detail,
              value
            )
          );
        }
      }

      detail.EnergyFilled__c = energyFilled.setScale(
        4,
        System.RoundingMode.HALF_UP
      );
      detail.RecordsCreated__c = request.isDryRun ? 0 : gapSet.gaps.size();
      detail.Status__c = request.isDryRun
        ? BulkGapFillConstants.DETAIL_PREVIEW
        : BulkGapFillConstants.DETAIL_FILLED;

      if (!gapSet.dateIssues.isEmpty()) {
        detail.ErrorMessage__c = describeIssues(gapSet.dateIssues);
      }
      details.add(detail);
    }
  }

  /** Assembles the inputs each fill method needs for this footprint and fuel type. */
  private BulkGapFillService.FillContext buildContext(
    SObject footprint,
    String fuelType,
    String method,
    List<BulkGapFillService.EnergyRecord> currentRecords,
    List<BulkGapFillService.EnergyRecord> priorRecords
  ) {
    BulkGapFillService.FillContext ctx = new BulkGapFillService.FillContext();
    ctx.method = method;
    ctx.fuelType = fuelType;
    ctx.manualDailyRate = request.manualDailyRate;

    SObject asset = footprint.getSObject(
      BulkGapFillConstants.REL_FOOTPRINT_ASSET
    );
    if (asset != null) {
      ctx.occupiedFloorAreaSqM = BulkGapFillConstants.toSquareMetres(
        (Decimal) asset.get(BulkGapFillConstants.FIELD_ASSET_FLOOR_AREA),
        (String) asset.get(BulkGapFillConstants.FIELD_ASSET_FLOOR_AREA_UNIT)
      );
    }

    // BEI lookups gate the two benchmark methods. Both point at a
    // BldgEnrgyIntensity record, whose per-energy-type values loadBenchmarks()
    // has already read off the child value records.
    Id beiId = BulkGapFillConstants.METHOD_REGIONAL_BEI.equals(method)
      ? (Id) footprint.get(BulkGapFillConstants.FIELD_REGIONAL_BEI_LOOKUP)
      : (Id) footprint.get(BulkGapFillConstants.FIELD_BEI_LOOKUP);
    ctx.beiValue = beiValueFor(beiId, fuelType);

    List<BulkGapFillService.EnergyRecord> currentForFuel = filterByFuel(
      currentRecords,
      fuelType
    );
    ctx.currentYearTotal = BulkGapFillService.totalConsumption(currentForFuel);
    ctx.currentYearDaysWithData = BulkGapFillService.daysWithData(
      currentForFuel
    );
    ctx.priorYearTotal = BulkGapFillService.totalConsumption(
      filterByFuel(priorRecords, fuelType)
    );

    return ctx;
  }

  private static List<BulkGapFillService.EnergyRecord> filterByFuel(
    List<BulkGapFillService.EnergyRecord> records,
    String fuelType
  ) {
    List<BulkGapFillService.EnergyRecord> matched = new List<BulkGapFillService.EnergyRecord>();
    if (records != null) {
      for (BulkGapFillService.EnergyRecord rec : records) {
        if (rec.fuelType == fuelType) {
          matched.add(rec);
        }
      }
    }
    return matched;
  }

  // ---- Queries ----------------------------------------------------------

  /**
   * Annual intensity values for this chunk in kWh per square metre, keyed by
   * benchmark record Id and then by fuel type. Two levels because a benchmark holds
   * one value per fuel type on its child BldgEnrgyIntensityVal records.
   */
  private Map<Id, Map<String, Decimal>> benchmarkValues = new Map<Id, Map<String, Decimal>>();

  /**
   * Loads the intensity values behind every BEI lookup in this chunk. Both the
   * custom (BEI Builder) and regional (CBECS) lookups are collected, since the fill
   * method can be overridden per footprint, and both resolve against the same
   * BldgEnrgyIntensity object — so one query over its value records covers them.
   */
  private void loadBenchmarks(List<SObject> footprints) {
    benchmarkValues.clear();

    Set<Id> beiIds = new Set<Id>();
    for (SObject footprint : footprints) {
      for (String lookup : BulkGapFillConstants.BEI_LOOKUP_FIELDS) {
        Id beiId = (Id) footprint.get(lookup);
        if (beiId != null) {
          beiIds.add(beiId);
        }
      }
    }
    if (beiIds.isEmpty()) {
      return;
    }

    String parentField = BulkGapFillConstants.FIELD_BEI_VALUE_PARENT;
    String fuelTypeField = BulkGapFillConstants.FIELD_BEI_VALUE_FUEL_TYPE;
    String metricField = BulkGapFillConstants.FIELD_BEI_VALUE_KWH_M2;
    String imperialField = BulkGapFillConstants.FIELD_BEI_VALUE_KWH_SQFT;

    String soql =
      'SELECT ' +
      parentField +
      ', ' +
      fuelTypeField +
      ', ' +
      metricField +
      ', ' +
      imperialField +
      ' FROM ' +
      BulkGapFillConstants.OBJ_BEI_VALUE +
      ' WHERE ' +
      parentField +
      ' IN :beiIds';

    for (SObject row : Database.query(soql)) {
      // Normalize on read so everything downstream is in kWh per square metre.
      Decimal value = BulkGapFillConstants.toKwhPerSquareMetre(
        (Decimal) row.get(metricField),
        (Decimal) row.get(imperialField)
      );
      if (value == null) {
        continue;
      }
      Id beiId = (Id) row.get(parentField);
      if (!benchmarkValues.containsKey(beiId)) {
        benchmarkValues.put(beiId, new Map<String, Decimal>());
      }
      benchmarkValues.get(beiId).put((String) row.get(fuelTypeField), value);
    }
  }

  /**
   * Looks up the annual intensity value for one benchmark and fuel type.
   *
   * Returns null when the benchmark carries no value for this fuel type, which
   * `resolveDailyRate` turns into a Skipped detail row. That is deliberate: the
   * alternative would be borrowing another fuel type's benchmark and writing an
   * estimate that looks authoritative and is wrong.
   */
  private Decimal beiValueFor(Id beiId, String fuelType) {
    if (beiId == null) {
      return null;
    }
    Map<String, Decimal> byFuelType = benchmarkValues.get(beiId);
    return byFuelType == null ? null : byFuelType.get(fuelType);
  }

  /** The SELECT..FROM shared by both energy use queries; callers append a WHERE. */
  private static String energyUseSelect() {
    List<String> selects = new List<String>{ 'Id' };
    selects.addAll(BulkGapFillConstants.ENERGY_USE_FIELDS);
    return 'SELECT ' +
      String.join(selects, ', ') +
      ' FROM ' +
      BulkGapFillConstants.OBJ_ENERGY_USE;
  }

  private Map<Id, List<BulkGapFillService.EnergyRecord>> loadEnergyRecords(
    Set<Id> footprintIds
  ) {
    Map<Id, List<BulkGapFillService.EnergyRecord>> byFootprint = new Map<Id, List<BulkGapFillService.EnergyRecord>>();
    if (footprintIds.isEmpty()) {
      return byFootprint;
    }

    String parentField = BulkGapFillConstants.FIELD_ENERGY_USE_FOOTPRINT;
    String soql =
      energyUseSelect() +
      ' WHERE ' +
      parentField +
      ' IN :footprintIds';

    for (SObject row : Database.query(soql)) {
      Id parentId = (Id) row.get(parentField);
      if (!byFootprint.containsKey(parentId)) {
        byFootprint.put(parentId, new List<BulkGapFillService.EnergyRecord>());
      }
      byFootprint.get(parentId).add(toEnergyRecord(row));
    }
    return byFootprint;
  }

  /**
   * Loads prior year records, keyed by the *current* year footprint Id so the
   * Previous Year Daily Average method can look them up directly.
   */
  private Map<Id, List<BulkGapFillService.EnergyRecord>> loadPriorYearRecords(
    List<SObject> footprints
  ) {
    Map<Id, List<BulkGapFillService.EnergyRecord>> byCurrentFootprint = new Map<Id, List<BulkGapFillService.EnergyRecord>>();

    String assetIdField = BulkGapFillConstants.FIELD_FOOTPRINT_ASSET;

    Map<Id, Id> currentFootprintByAsset = new Map<Id, Id>();
    for (SObject footprint : footprints) {
      Id assetId = (Id) footprint.get(assetIdField);
      if (assetId != null) {
        currentFootprintByAsset.put(assetId, (Id) footprint.get('Id'));
      }
    }
    if (currentFootprintByAsset.isEmpty()) {
      return byCurrentFootprint;
    }

    Set<Id> assetIds = currentFootprintByAsset.keySet();
    String priorYear = BulkGapFillConstants.reportingYearBind(
      request.reportingYear - 1
    );

    Map<Id, Id> priorFootprintToCurrent = new Map<Id, Id>();
    String footprintSoql =
      'SELECT Id, ' +
      assetIdField +
      ' FROM ' +
      BulkGapFillConstants.OBJ_FOOTPRINT +
      ' WHERE ' +
      BulkGapFillConstants.FIELD_FOOTPRINT_YEAR +
      ' = :priorYear AND ' +
      assetIdField +
      ' IN :assetIds';
    for (SObject prior : Database.query(footprintSoql)) {
      Id assetId = (Id) prior.get(assetIdField);
      priorFootprintToCurrent.put(
        (Id) prior.get('Id'),
        currentFootprintByAsset.get(assetId)
      );
    }
    if (priorFootprintToCurrent.isEmpty()) {
      return byCurrentFootprint;
    }

    Set<Id> priorFootprintIds = priorFootprintToCurrent.keySet();
    String parentField = BulkGapFillConstants.FIELD_ENERGY_USE_FOOTPRINT;
    String useSoql =
      energyUseSelect() +
      ' WHERE ' +
      parentField +
      ' IN :priorFootprintIds';

    for (SObject row : Database.query(useSoql)) {
      Id currentId = priorFootprintToCurrent.get((Id) row.get(parentField));
      if (currentId == null) {
        continue;
      }
      if (!byCurrentFootprint.containsKey(currentId)) {
        byCurrentFootprint.put(
          currentId,
          new List<BulkGapFillService.EnergyRecord>()
        );
      }
      byCurrentFootprint.get(currentId).add(toEnergyRecord(row));
    }
    return byCurrentFootprint;
  }

  private static BulkGapFillService.EnergyRecord toEnergyRecord(SObject row) {
    BulkGapFillService.EnergyRecord rec = new BulkGapFillService.EnergyRecord();
    rec.recordId = (Id) row.get('Id');
    rec.fuelType = (String) row.get(
      BulkGapFillConstants.FIELD_ENERGY_USE_FUEL_TYPE
    );
    rec.startDate = (Date) row.get(BulkGapFillConstants.FIELD_ENERGY_USE_START);
    rec.endDate = (Date) row.get(BulkGapFillConstants.FIELD_ENERGY_USE_END);
    rec.consumption = (Decimal) row.get(
      BulkGapFillConstants.FIELD_ENERGY_USE_CONSUMPTION
    );
    rec.consumptionUnit = (String) row.get(
      BulkGapFillConstants.FIELD_ENERGY_USE_CONSUMPTION_UNIT
    );
    // The same flag the native gap fill process sets, so records generated by
    // either route are recognised here.
    Boolean systemGenerated = (Boolean) row.get(
      BulkGapFillConstants.FIELD_ENERGY_USE_IS_SYSTEM_GENERATED
    );
    rec.isGapFilled = systemGenerated == true;
    return rec;
  }

  // ---- Record construction ----------------------------------------------

  /** ErrorMessage__c is a 32,768 character long text area. */
  private static final Integer MAX_DETAIL_ERROR_CHARS = 32000;

  /** Standard Name fields cap at 80 characters. */
  private static final Integer MAX_ENERGY_USE_NAME_CHARS = 80;

  /**
   * One staged energy use record, tied to the detail row that reports it and the
   * value it contributed, so a failed insert can be undone from both.
   */
  @TestVisible
  private class StagedFill {
    public SObject record;
    public BulkGapFillJobDetail__c detail;
    public Decimal value;

    public StagedFill(
      SObject record,
      BulkGapFillJobDetail__c detail,
      Decimal value
    ) {
      this.record = record;
      this.detail = detail;
      this.value = value;
    }
  }

  /**
   * Names a generated record so it is identifiable in a list view without opening
   * it: the stationary asset it belongs to, that it was gap filled, the fuel type
   * and the period covered. ISO dates rather than Date.format(), which is locale
   * dependent and would make the name vary by whoever ran the batch.
   *
   * Over the 80 character limit the asset name is what gives, not the tail: two
   * generated records under one asset are told apart by fuel type and date range,
   * so those have to survive.
   */
  private static String generatedName(
    String assetName,
    String fuelType,
    BulkGapFillService.DateRange gap
  ) {
    String suffix =
      'Gap Fill ' +
      fuelType +
      ' ' +
      String.valueOf(gap.startDate) +
      ' to ' +
      String.valueOf(gap.endDate);

    String prefix = assetName == null ? null : assetName.trim();
    if (String.isBlank(prefix)) {
      return truncateName(suffix);
    }

    // One character held back for the space between the two halves.
    Integer room = MAX_ENERGY_USE_NAME_CHARS - suffix.length() - 1;
    if (room <= 0) {
      return truncateName(suffix);
    }
    if (prefix.length() > room) {
      prefix = prefix.substring(0, room).trim();
      if (String.isBlank(prefix)) {
        return truncateName(suffix);
      }
    }
    return prefix + ' ' + suffix;
  }

  private static String truncateName(String value) {
    return value.length() > MAX_ENERGY_USE_NAME_CHARS
      ? value.substring(0, MAX_ENERGY_USE_NAME_CHARS)
      : value;
  }

  private SObject buildEnergyUse(
    Id footprintId,
    Id assetId,
    String assetName,
    BulkGapFillService.FuelGapSet gapSet,
    BulkGapFillService.DateRange gap,
    Decimal value,
    String method
  ) {
    SObject rec = Schema.getGlobalDescribe()
      .get(BulkGapFillConstants.OBJ_ENERGY_USE)
      .newSObject();

    // Name and the asset lookup are both required on insert. The footprint lookup
    // alone is not enough: an energy use record hangs off the asset as well, and
    // leaving either out fails the record with REQUIRED_FIELD_MISSING.
    rec.put(
      BulkGapFillConstants.FIELD_ENERGY_USE_NAME,
      generatedName(assetName, gapSet.fuelType, gap)
    );
    rec.put(BulkGapFillConstants.FIELD_ENERGY_USE_ASSET, assetId);
    rec.put(BulkGapFillConstants.FIELD_ENERGY_USE_FOOTPRINT, footprintId);
    rec.put(BulkGapFillConstants.FIELD_ENERGY_USE_FUEL_TYPE, gapSet.fuelType);
    rec.put(BulkGapFillConstants.FIELD_ENERGY_USE_START, gap.startDate);
    rec.put(BulkGapFillConstants.FIELD_ENERGY_USE_END, gap.endDate);
    rec.put(BulkGapFillConstants.FIELD_ENERGY_USE_CONSUMPTION, value);
    rec.put(
      BulkGapFillConstants.FIELD_ENERGY_USE_CONSUMPTION_UNIT,
      gapSet.consumptionUnit
    );
    // Match what the native process stamps: the generated flag marks the record as
    // an estimate, the method name records how it was derived.
    rec.put(BulkGapFillConstants.FIELD_ENERGY_USE_IS_SYSTEM_GENERATED, true);

    // The method name is a standard restricted picklist, so it takes the org's
    // value rather than our token. When nothing maps, leave it unset: an estimate
    // that is stamped as generated but not attributed is still correct and still
    // inserts, whereas an unaccepted value fails the whole record. The method is
    // preserved either way on the detail row's FillMethodUsed__c, and
    // validateSchema warns about the mismatch up front.
    String stamp = BulkGapFillConstants.gapFillMethodPicklistValue(method);
    if (stamp != null) {
      rec.put(BulkGapFillConstants.FIELD_ENERGY_USE_FILL_METHOD, stamp);
    }
    return rec;
  }

  /**
   * Inserts staged records with partial success, logging each failure and
   * correcting the detail row that reported it.
   *
   * The detail rows are written optimistically during gap detection, before any
   * DML has happened, so a failure here has to be reflected back onto them —
   * otherwise the per-asset audit trail claims records were created that do not
   * exist, and the only evidence of the failure is the job-level error log.
   */
  private Integer commitEnergyUse(List<StagedFill> staged) {
    List<SObject> records = new List<SObject>();
    for (StagedFill fill : staged) {
      records.add(fill.record);
    }

    Integer inserted = 0;
    List<Database.SaveResult> results = Database.insert(records, false);
    for (Integer i = 0; i < results.size(); i++) {
      if (results[i].isSuccess()) {
        inserted++;
        continue;
      }
      errorCount++;
      // Every error, not just the first: a record can fail validation on several
      // counts at once, and reporting one of them sends the reader after a single
      // cause when there are more.
      List<String> reasons = new List<String>();
      for (Database.Error err : results[i].getErrors()) {
        reasons.add(err.getMessage());
      }
      String message = String.join(reasons, ' | ');
      logError(
        'Energy use insert failed for footprint ' +
          records[i].get(BulkGapFillConstants.FIELD_ENERGY_USE_FOOTPRINT) +
          ': ' +
          message
      );
      recordFailure(staged[i], message);
    }

    demoteEmptyDetails(staged);
    return inserted;
  }

  /**
   * Turns a detail row that lost every record it staged into an error, whatever it
   * said a moment ago. A row that kept even one insert is still a partial fill.
   */
  @TestVisible
  private static void demoteEmptyDetails(List<StagedFill> staged) {
    for (StagedFill fill : staged) {
      if (
        fill.detail.Status__c == BulkGapFillConstants.DETAIL_FILLED &&
        fill.detail.RecordsCreated__c == 0
      ) {
        fill.detail.Status__c = BulkGapFillConstants.DETAIL_ERROR;
      }
    }
  }

  /** Backs one failed insert out of the detail row that counted it. */
  @TestVisible
  private static void recordFailure(StagedFill fill, String message) {
    BulkGapFillJobDetail__c detail = fill.detail;

    if (detail.RecordsCreated__c != null && detail.RecordsCreated__c > 0) {
      detail.RecordsCreated__c -= 1;
    }
    if (detail.EnergyFilled__c != null && fill.value != null) {
      Decimal remaining = detail.EnergyFilled__c - fill.value;
      detail.EnergyFilled__c = remaining <= 0
        ? 0
        : remaining.setScale(4, System.RoundingMode.HALF_UP);
    }
    appendDetailError(detail, message);
  }

  /**
   * Appends a message to a detail row. Every gap in a fuel set usually fails for
   * the same reason, so repeats are dropped rather than printed once per record.
   */
  private static void appendDetailError(
    BulkGapFillJobDetail__c detail,
    String message
  ) {
    if (String.isBlank(detail.ErrorMessage__c)) {
      detail.ErrorMessage__c = message;
      return;
    }
    if (detail.ErrorMessage__c.contains(message)) {
      return;
    }
    String combined = detail.ErrorMessage__c + '\n' + message;
    detail.ErrorMessage__c = combined.length() > MAX_DETAIL_ERROR_CHARS
      ? combined.substring(0, MAX_DETAIL_ERROR_CHARS)
      : combined;
  }

  private BulkGapFillJobDetail__c baseDetail(SObject footprint) {
    SObject asset = footprint.getSObject(
      BulkGapFillConstants.REL_FOOTPRINT_ASSET
    );
    return new BulkGapFillJobDetail__c(
      BulkGapFillJob__c = jobId,
      CarbonFootprintId__c = asText(footprint.get('Id')),
      StationaryAssetId__c = asText(
        footprint.get(BulkGapFillConstants.FIELD_FOOTPRINT_ASSET)
      ),
      StationaryAssetName__c = asset == null
        ? null
        : asText(asset.get(BulkGapFillConstants.FIELD_ASSET_NAME))
    );
  }

  /**
   * Null-safe Object to String. A plain cast throws when the value holds an Id,
   * and String.valueOf(null) returns the literal text 'null'.
   */
  private static String asText(Object value) {
    return value == null ? null : String.valueOf(value);
  }

  private BulkGapFillJobDetail__c errorDetail(
    SObject footprint,
    String message
  ) {
    BulkGapFillJobDetail__c detail = baseDetail(footprint);
    detail.Status__c = BulkGapFillConstants.DETAIL_ERROR;
    detail.ErrorMessage__c = message;
    return detail;
  }

  private static String describeIssues(
    List<BulkGapFillService.DateIssue> issues
  ) {
    List<String> lines = new List<String>();
    for (BulkGapFillService.DateIssue issue : issues) {
      lines.add(issue.issueType + ': ' + issue.message);
    }
    return String.join(lines, '\n');
  }

  private void logError(String message) {
    errorLog.add(message);
  }

  // ---- finish -----------------------------------------------------------

  /**
   * @description Writes the final counts and terminal status onto the job record.
   * A run that saw any error finishes as Completed With Errors rather than Failed,
   * since the successful footprints were still filled.
   * @param bc The batch context.
   */
  public void finish(Database.BatchableContext bc) {
    BulkGapFillJob__c job = new BulkGapFillJob__c(
      Id = jobId,
      FootprintsProcessed__c = footprintsProcessed,
      GapsFound__c = gapsFound,
      RecordsCreated__c = recordsCreated,
      RecordsAssociated__c = recordsAssociated,
      ErrorCount__c = errorCount,
      CompletedAt__c = System.now(),
      Status__c = errorCount > 0
        ? BulkGapFillConstants.JOB_COMPLETED_WITH_ERRORS
        : BulkGapFillConstants.JOB_COMPLETED
    );

    if (!errorLog.isEmpty()) {
      String log = String.join(errorLog, '\n');
      job.ErrorLog__c = log.length() > BulkGapFillConstants.MAX_ERROR_LOG_CHARS
        ? log.substring(0, BulkGapFillConstants.MAX_ERROR_LOG_CHARS)
        : log;
    }

    Database.update(job, false);
  }

  private void markJobRunning(Database.BatchableContext bc) {
    Database.update(
      new BulkGapFillJob__c(
        Id = jobId,
        Status__c = BulkGapFillConstants.JOB_RUNNING,
        StartedAt__c = System.now(),
        AsyncApexJobId__c = bc == null ? null : String.valueOf(bc.getJobId())
      ),
      false
    );
  }
}
