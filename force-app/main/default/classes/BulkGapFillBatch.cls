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
    this.scopeYear = request.reportingYear;
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
      wheres.add('ReportingYear = :scopeYear');

      if (
        request.stationaryAssetIds != null &&
        !request.stationaryAssetIds.isEmpty()
      ) {
        wheres.add('StnryAssetEnvrSrcId IN :scopeAssetIds');
      }
      if (request.assetTypes != null && !request.assetTypes.isEmpty()) {
        wheres.add('StnryAssetEnvrSrc.StationaryAssetType IN :scopeAssetTypes');
      }
    }

    return 'SELECT Id, StnryAssetEnvrSrcId, ReportingYear, ' +
      String.join(BulkGapFillConstants.BEI_LOOKUP_FIELDS, ', ') +
      ', ' +
      'StnryAssetEnvrSrc.Name, StnryAssetEnvrSrc.StationaryAssetType, ' +
      'StnryAssetEnvrSrc.OccupiedFloorArea, StnryAssetEnvrSrc.OccupiedFloorAreaUnit ' +
      'FROM ' +
      BulkGapFillConstants.OBJ_FOOTPRINT +
      ' ' +
      'WHERE ' +
      String.join(wheres, ' AND ') +
      ' ' +
      'ORDER BY StnryAssetEnvrSrcId';
  }

  // Bind variables referenced by the dynamic query above. These are plain fields
  // rather than properties because SOQL bind resolution does not see properties.
  private List<Id> scopeFootprintIds;
  private List<Id> scopeAssetIds;
  private List<String> scopeAssetTypes;
  private Integer scopeYear;

  // ---- execute ----------------------------------------------------------

  /**
   * @description Detects gaps for each footprint in the chunk, inserts the
   * gap-filled energy use records unless this is a dry run, and writes one
   * `BulkGapFillJobDetail__c` per footprint per fuel type.
   * @param bc The batch context.
   * @param scope The carbon footprint records in this chunk.
   */
  public void execute(Database.BatchableContext bc, List<SObject> scope) {
    List<SObject> energyUseToInsert = new List<SObject>();
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
            energyUseToInsert,
            details
          );
        } catch (Exception e) {
          errorCount++;
          details.add(errorDetail(footprint, e.getMessage()));
        }
      }

      if (!request.isDryRun && !energyUseToInsert.isEmpty()) {
        recordsCreated += commitEnergyUse(energyUseToInsert, details);
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
    List<SObject> energyUseToInsert,
    List<BulkGapFillJobDetail__c> details
  ) {
    Id footprintId = (Id) footprint.get('Id');
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
          energyUseToInsert.add(
            buildEnergyUse(footprintId, gapSet, gap, value, method)
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

    SObject asset = footprint.getSObject('StnryAssetEnvrSrc');
    if (asset != null) {
      ctx.occupiedFloorAreaSqM = BulkGapFillConstants.toSquareMetres(
        (Decimal) asset.get('OccupiedFloorArea'),
        (String) asset.get('OccupiedFloorAreaUnit')
      );
    }

    // BEI lookups gate the two benchmark methods. Both point at a
    // BldgEnrgyIntensity record, whose value is resolved in loadBenchmarks().
    Id beiId = BulkGapFillConstants.METHOD_REGIONAL_BEI.equals(method)
      ? (Id) footprint.get(BulkGapFillConstants.FIELD_REGIONAL_BEI_LOOKUP)
      : (Id) footprint.get(BulkGapFillConstants.FIELD_BEI_LOOKUP);
    ctx.beiValue = beiId == null ? null : benchmarkValues.get(beiId);

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

  /** BEI benchmark values keyed by benchmark record Id, populated per chunk. */
  private Map<Id, Decimal> benchmarkValues = new Map<Id, Decimal>();

  /**
   * Resolves the intensity value behind every BEI lookup in this chunk. Both the
   * custom (BEI Builder) and regional (CBECS) lookups are collected, since the fill
   * method can be overridden per footprint, and both resolve against the same
   * BldgEnrgyIntensity object — so one query covers them.
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

    String valueField = BulkGapFillConstants.FIELD_BEI_VALUE;
    String soql =
      'SELECT Id, ' +
      valueField +
      ' FROM ' +
      BulkGapFillConstants.OBJ_BEI +
      ' WHERE Id IN :beiIds';
    for (SObject row : Database.query(soql)) {
      benchmarkValues.put((Id) row.get('Id'), (Decimal) row.get(valueField));
    }
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
      'SELECT Id, ' +
      parentField +
      ', FuelType, StartDate, EndDate, ' +
      'EnergyConsumption, EnergyConsumptionUnit, IsGapFilled ' +
      'FROM ' +
      BulkGapFillConstants.OBJ_ENERGY_USE +
      ' ' +
      'WHERE ' +
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

    Map<Id, Id> currentFootprintByAsset = new Map<Id, Id>();
    for (SObject footprint : footprints) {
      Id assetId = (Id) footprint.get('StnryAssetEnvrSrcId');
      if (assetId != null) {
        currentFootprintByAsset.put(assetId, (Id) footprint.get('Id'));
      }
    }
    if (currentFootprintByAsset.isEmpty()) {
      return byCurrentFootprint;
    }

    Set<Id> assetIds = currentFootprintByAsset.keySet();
    Integer priorYear = request.reportingYear - 1;

    Map<Id, Id> priorFootprintToCurrent = new Map<Id, Id>();
    String footprintSoql =
      'SELECT Id, StnryAssetEnvrSrcId FROM ' +
      BulkGapFillConstants.OBJ_FOOTPRINT +
      ' WHERE ReportingYear = :priorYear AND StnryAssetEnvrSrcId IN :assetIds';
    for (SObject prior : Database.query(footprintSoql)) {
      Id assetId = (Id) prior.get('StnryAssetEnvrSrcId');
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
      'SELECT Id, ' +
      parentField +
      ', FuelType, StartDate, EndDate, ' +
      'EnergyConsumption, EnergyConsumptionUnit, IsGapFilled ' +
      'FROM ' +
      BulkGapFillConstants.OBJ_ENERGY_USE +
      ' ' +
      'WHERE ' +
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
    rec.fuelType = (String) row.get('FuelType');
    rec.startDate = (Date) row.get('StartDate');
    rec.endDate = (Date) row.get('EndDate');
    rec.consumption = (Decimal) row.get('EnergyConsumption');
    rec.consumptionUnit = (String) row.get('EnergyConsumptionUnit');
    rec.isGapFilled = (Boolean) row.get('IsGapFilled');
    return rec;
  }

  // ---- Record construction ----------------------------------------------

  private SObject buildEnergyUse(
    Id footprintId,
    BulkGapFillService.FuelGapSet gapSet,
    BulkGapFillService.DateRange gap,
    Decimal value,
    String method
  ) {
    SObject rec = Schema.getGlobalDescribe()
      .get(BulkGapFillConstants.OBJ_ENERGY_USE)
      .newSObject();

    rec.put(BulkGapFillConstants.FIELD_ENERGY_USE_FOOTPRINT, footprintId);
    rec.put('FuelType', gapSet.fuelType);
    rec.put('StartDate', gap.startDate);
    rec.put('EndDate', gap.endDate);
    rec.put('EnergyConsumption', value);
    rec.put('EnergyConsumptionUnit', gapSet.consumptionUnit);
    rec.put('IsGapFilled', true);
    rec.put('GapFillMethod', method);
    return rec;
  }

  /** Inserts staged records with partial success, logging each failure. */
  private Integer commitEnergyUse(
    List<SObject> records,
    List<BulkGapFillJobDetail__c> details
  ) {
    Integer inserted = 0;
    List<Database.SaveResult> results = Database.insert(records, false);
    for (Integer i = 0; i < results.size(); i++) {
      if (results[i].isSuccess()) {
        inserted++;
      } else {
        errorCount++;
        logError(
          'Energy use insert failed for footprint ' +
            records[i].get(BulkGapFillConstants.FIELD_ENERGY_USE_FOOTPRINT) +
            ': ' +
            results[i].getErrors()[0].getMessage()
        );
      }
    }
    return inserted;
  }

  private BulkGapFillJobDetail__c baseDetail(SObject footprint) {
    SObject asset = footprint.getSObject('StnryAssetEnvrSrc');
    return new BulkGapFillJobDetail__c(
      BulkGapFillJob__c = jobId,
      CarbonFootprintId__c = asText(footprint.get('Id')),
      StationaryAssetId__c = asText(footprint.get('StnryAssetEnvrSrcId')),
      StationaryAssetName__c = asset == null ? null : asText(asset.get('Name'))
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
