/**
 * End-to-end tests for `BulkGapFillBatch` against real Net Zero Cloud records.
 *
 * These are the tests the original failure needed: a run that detected gaps,
 * reported `Filled`, and created nothing would pass every assertion in
 * `BulkGapFillBatchTest`, because nothing there asserts records actually land.
 * Every test here reads the energy use records back after the batch finishes.
 *
 * Each test no-ops where Net Zero Cloud is not enabled, so the suite still passes
 * in a scratch org without it — the same property `BulkGapFillServiceTest` has.
 * Where NZC is present they are real assertions.
 *
 * @see BulkGapFillTestData
 */
@IsTest
private class BulkGapFillBatchRunTest {
  private static final Integer YEAR = 2025;
  private static final Date JAN_1 = Date.newInstance(YEAR, 1, 1);
  private static final Date JUN_30 = Date.newInstance(YEAR, 6, 30);
  private static final Date DEC_31 = Date.newInstance(YEAR, 12, 31);

  private static BulkGapFillRequest request(String method) {
    BulkGapFillRequest req = new BulkGapFillRequest();
    req.reportingYear = YEAR;
    req.defaultFillMethod = method;
    req.isDryRun = false;
    return req;
  }

  private static void run(BulkGapFillRequest req, Id jobId) {
    Test.startTest();
    Database.executeBatch(new BulkGapFillBatch(req, jobId), 50);
    Test.stopTest();
  }

  private static BulkGapFillJob__c reload(Id jobId) {
    return [
      SELECT
        Status__c,
        FootprintsProcessed__c,
        GapsFound__c,
        RecordsCreated__c,
        ErrorCount__c,
        ErrorLog__c
      FROM BulkGapFillJob__c
      WHERE Id = :jobId
    ];
  }

  private static List<BulkGapFillJobDetail__c> detailsFor(Id jobId) {
    return [
      SELECT
        Status__c,
        RecordsCreated__c,
        GapsFound__c,
        ErrorMessage__c,
        FuelType__c
      FROM BulkGapFillJobDetail__c
      WHERE BulkGapFillJob__c = :jobId
    ];
  }

  /**
   * The regression test for the original bug. Half a year of measured data leaves
   * half a year of gap; the run must create records that survive the insert, carry
   * the generated flag, and be stamped with the value the org's restricted picklist
   * accepts rather than our internal token.
   */
  @IsTest
  static void currentYearAverageFillsTheGapAndStampsTheMethod() {
    if (!BulkGapFillTestData.isNetZeroCloudAvailable()) {
      return;
    }
    SObject asset = BulkGapFillTestData.asset('HQ');
    SObject footprint = BulkGapFillTestData.footprint(asset.Id, YEAR);
    BulkGapFillTestData.energyUse(
      footprint.Id,
      asset.Id,
      BulkGapFillTestData.FUEL_ELECTRICITY,
      JAN_1,
      JUN_30,
      181000
    );

    BulkGapFillRequest req = request(BulkGapFillConstants.METHOD_CURRENT_YEAR);
    BulkGapFillJob__c job = BulkGapFillTestData.job(req);

    run(req, job.Id);

    List<SObject> generated = BulkGapFillTestData.energyUseUnder(
      footprint.Id,
      true
    );
    Assert.isFalse(
      generated.isEmpty(),
      'The whole point of the run: records must exist afterwards. Job log: ' +
      reload(job.Id).ErrorLog__c
    );

    SObject filled = generated[0];
    Assert.areEqual(
      true,
      filled.get(BulkGapFillConstants.FIELD_ENERGY_USE_IS_SYSTEM_GENERATED),
      'Generated records must be distinguishable from measured ones'
    );
    Assert.areEqual(
      BulkGapFillConstants.gapFillMethodPicklistValue(
        BulkGapFillConstants.METHOD_CURRENT_YEAR
      ),
      filled.get(BulkGapFillConstants.FIELD_ENERGY_USE_FILL_METHOD),
      'Stamped with the org picklist value, not our token'
    );
    Assert.isNotNull(
      filled.get(BulkGapFillConstants.FIELD_ENERGY_USE_ASSET),
      'The asset lookup is required on insert'
    );
    Assert.isNotNull(
      filled.get(BulkGapFillConstants.FIELD_ENERGY_USE_NAME),
      'Name is required on insert'
    );
    // The gap left by the measured half year runs Jul 1 to Dec 31, and the name
    // has to identify the asset, the fill and that period without opening the
    // record.
    Assert.areEqual(
      'HQ Gap Fill ' +
      BulkGapFillTestData.FUEL_ELECTRICITY +
      ' ' +
      String.valueOf(JUN_30.addDays(1)) +
      ' to ' +
      String.valueOf(DEC_31),
      filled.get(BulkGapFillConstants.FIELD_ENERGY_USE_NAME),
      'Generated name carries the asset name, the gap fill marker and the range'
    );

    BulkGapFillJob__c finished = reload(job.Id);
    Assert.areEqual(
      BulkGapFillConstants.JOB_COMPLETED,
      finished.Status__c,
      'No errors expected. Log: ' + finished.ErrorLog__c
    );
    Assert.areEqual(0, finished.ErrorCount__c.intValue());
    Assert.isTrue(finished.RecordsCreated__c.intValue() > 0);
    Assert.areEqual(1, finished.FootprintsProcessed__c.intValue());
  }

  @IsTest
  static void dryRunReportsGapsWithoutCreatingRecords() {
    if (!BulkGapFillTestData.isNetZeroCloudAvailable()) {
      return;
    }
    SObject asset = BulkGapFillTestData.asset('HQ');
    SObject footprint = BulkGapFillTestData.footprint(asset.Id, YEAR);
    BulkGapFillTestData.energyUse(
      footprint.Id,
      asset.Id,
      BulkGapFillTestData.FUEL_ELECTRICITY,
      JAN_1,
      JUN_30,
      181000
    );

    BulkGapFillRequest req = request(BulkGapFillConstants.METHOD_CURRENT_YEAR);
    req.isDryRun = true;
    BulkGapFillJob__c job = BulkGapFillTestData.job(req);

    run(req, job.Id);

    Assert.isTrue(
      BulkGapFillTestData.energyUseUnder(footprint.Id, true).isEmpty(),
      'A dry run must not write anything'
    );
    BulkGapFillJob__c finished = reload(job.Id);
    Assert.areEqual(0, finished.RecordsCreated__c.intValue());
    Assert.isTrue(
      finished.GapsFound__c.intValue() > 0,
      'Gaps are still detected and reported'
    );

    for (BulkGapFillJobDetail__c detail : detailsFor(job.Id)) {
      Assert.areEqual(
        BulkGapFillConstants.DETAIL_PREVIEW,
        detail.Status__c,
        'Dry run rows are previews, not fills'
      );
    }
  }

  @IsTest
  static void fullyCoveredYearCreatesNothing() {
    if (!BulkGapFillTestData.isNetZeroCloudAvailable()) {
      return;
    }
    SObject asset = BulkGapFillTestData.asset('HQ');
    SObject footprint = BulkGapFillTestData.footprint(asset.Id, YEAR);
    BulkGapFillTestData.energyUse(
      footprint.Id,
      asset.Id,
      BulkGapFillTestData.FUEL_ELECTRICITY,
      JAN_1,
      DEC_31,
      365000
    );

    BulkGapFillRequest req = request(BulkGapFillConstants.METHOD_CURRENT_YEAR);
    BulkGapFillJob__c job = BulkGapFillTestData.job(req);

    run(req, job.Id);

    Assert.isTrue(
      BulkGapFillTestData.energyUseUnder(footprint.Id, true).isEmpty(),
      'Nothing to fill when the year is covered end to end'
    );
    Assert.areEqual(0, reload(job.Id).GapsFound__c.intValue());

    List<BulkGapFillJobDetail__c> details = detailsFor(job.Id);
    Assert.areEqual(1, details.size());
    Assert.areEqual(BulkGapFillConstants.DETAIL_NO_GAPS, details[0].Status__c);
  }

  @IsTest
  static void previousYearAverageReadsThePriorYearFootprint() {
    if (!BulkGapFillTestData.isNetZeroCloudAvailable()) {
      return;
    }
    SObject asset = BulkGapFillTestData.asset('HQ');

    SObject priorFootprint = BulkGapFillTestData.footprint(asset.Id, YEAR - 1);
    BulkGapFillTestData.energyUse(
      priorFootprint.Id,
      asset.Id,
      BulkGapFillTestData.FUEL_ELECTRICITY,
      Date.newInstance(YEAR - 1, 1, 1),
      Date.newInstance(YEAR - 1, 12, 31),
      365000
    );

    SObject footprint = BulkGapFillTestData.footprint(asset.Id, YEAR);
    BulkGapFillTestData.energyUse(
      footprint.Id,
      asset.Id,
      BulkGapFillTestData.FUEL_ELECTRICITY,
      JAN_1,
      JUN_30,
      181000
    );

    BulkGapFillRequest req = request(BulkGapFillConstants.METHOD_PREVIOUS_YEAR);
    BulkGapFillJob__c job = BulkGapFillTestData.job(req);

    run(req, job.Id);

    Assert.isFalse(
      BulkGapFillTestData.energyUseUnder(footprint.Id, true).isEmpty(),
      'Prior year data makes the fill viable. Log: ' +
      reload(job.Id).ErrorLog__c
    );
    Assert.areEqual(
      BulkGapFillConstants.gapFillMethodPicklistValue(
        BulkGapFillConstants.METHOD_PREVIOUS_YEAR
      ),
      BulkGapFillTestData.energyUseUnder(footprint.Id, true)[0]
        .get(BulkGapFillConstants.FIELD_ENERGY_USE_FILL_METHOD)
    );
  }

  @IsTest
  static void previousYearAverageWithoutPriorDataIsSkipped() {
    if (!BulkGapFillTestData.isNetZeroCloudAvailable()) {
      return;
    }
    SObject asset = BulkGapFillTestData.asset('HQ');
    SObject footprint = BulkGapFillTestData.footprint(asset.Id, YEAR);
    BulkGapFillTestData.energyUse(
      footprint.Id,
      asset.Id,
      BulkGapFillTestData.FUEL_ELECTRICITY,
      JAN_1,
      JUN_30,
      181000
    );

    BulkGapFillRequest req = request(BulkGapFillConstants.METHOD_PREVIOUS_YEAR);
    BulkGapFillJob__c job = BulkGapFillTestData.job(req);

    run(req, job.Id);

    Assert.isTrue(
      BulkGapFillTestData.energyUseUnder(footprint.Id, true).isEmpty(),
      'No prior year data means no defensible estimate'
    );

    List<BulkGapFillJobDetail__c> details = detailsFor(job.Id);
    Assert.areEqual(1, details.size());
    Assert.areEqual(
      BulkGapFillConstants.DETAIL_SKIPPED,
      details[0].Status__c,
      'Skipped, not errored: the data is absent, nothing went wrong'
    );
    Assert.isNotNull(
      details[0].ErrorMessage__c,
      'The row must say why it was skipped'
    );
  }

  /** Covers loadBenchmarks and beiValueFor, which no other test reaches. */
  @IsTest
  static void regionalBenchmarkFillReadsTheIntensityValue() {
    if (!BulkGapFillTestData.isNetZeroCloudAvailable()) {
      return;
    }
    SObject benchmark = BulkGapFillTestData.benchmark('CBECS Office', true);
    BulkGapFillTestData.benchmarkValue(
      benchmark.Id,
      BulkGapFillTestData.FUEL_ELECTRICITY,
      200
    );

    SObject asset = BulkGapFillTestData.asset('HQ');
    SObject footprint = BulkGapFillTestData.footprint(asset.Id, YEAR);
    footprint.put(BulkGapFillConstants.FIELD_REGIONAL_BEI_LOOKUP, benchmark.Id);
    update footprint;

    BulkGapFillTestData.energyUse(
      footprint.Id,
      asset.Id,
      BulkGapFillTestData.FUEL_ELECTRICITY,
      JAN_1,
      JUN_30,
      181000
    );

    BulkGapFillRequest req = request(BulkGapFillConstants.METHOD_REGIONAL_BEI);
    BulkGapFillJob__c job = BulkGapFillTestData.job(req);

    run(req, job.Id);

    List<SObject> generated = BulkGapFillTestData.energyUseUnder(
      footprint.Id,
      true
    );
    Assert.isFalse(
      generated.isEmpty(),
      'A benchmark with a value for this fuel type makes the fill viable. Log: ' +
      reload(job.Id).ErrorLog__c
    );

    // 200 kWh/m2 over 1,000 m2 is 200,000 kWh a year, or ~547.9 a day.
    Decimal consumption = (Decimal) generated[0]
      .get(BulkGapFillConstants.FIELD_ENERGY_USE_CONSUMPTION);
    Assert.isTrue(
      consumption > 0,
      'The benchmark figure must reach the generated record'
    );
  }

  /**
   * The custom benchmark reads a different lookup on the footprint than the
   * regional one, chosen by a ternary in buildContext. Nothing else exercises
   * that side of it, so a swap of the two lookups would go unnoticed.
   */
  @IsTest
  static void buildingBenchmarkFillUsesTheCustomBeiLookup() {
    if (!BulkGapFillTestData.isNetZeroCloudAvailable()) {
      return;
    }
    SObject benchmark = BulkGapFillTestData.benchmark(
      'BEI Builder Office',
      false
    );
    BulkGapFillTestData.benchmarkValue(
      benchmark.Id,
      BulkGapFillTestData.FUEL_ELECTRICITY,
      180
    );

    SObject asset = BulkGapFillTestData.asset('HQ');
    SObject footprint = BulkGapFillTestData.footprint(asset.Id, YEAR);
    footprint.put(BulkGapFillConstants.FIELD_BEI_LOOKUP, benchmark.Id);
    update footprint;

    BulkGapFillTestData.energyUse(
      footprint.Id,
      asset.Id,
      BulkGapFillTestData.FUEL_ELECTRICITY,
      JAN_1,
      JUN_30,
      181000
    );

    BulkGapFillRequest req = request(BulkGapFillConstants.METHOD_BUILDING_BEI);
    BulkGapFillJob__c job = BulkGapFillTestData.job(req);

    run(req, job.Id);

    List<SObject> generated = BulkGapFillTestData.energyUseUnder(
      footprint.Id,
      true
    );
    Assert.isFalse(
      generated.isEmpty(),
      'The custom benchmark lookup must be read. Log: ' +
      reload(job.Id).ErrorLog__c
    );
    Assert.areEqual(
      BulkGapFillConstants.gapFillMethodPicklistValue(
        BulkGapFillConstants.METHOD_BUILDING_BEI
      ),
      generated[0].get(BulkGapFillConstants.FIELD_ENERGY_USE_FILL_METHOD),
      'BUILDING_BENCHMARK, distinct from the regional stamp'
    );
  }

  @IsTest
  static void benchmarkWithNoValueForTheFuelTypeIsSkipped() {
    if (!BulkGapFillTestData.isNetZeroCloudAvailable()) {
      return;
    }
    // A benchmark that covers gas only, against an asset metered for electricity.
    SObject benchmark = BulkGapFillTestData.benchmark('Gas only', true);
    BulkGapFillTestData.benchmarkValue(
      benchmark.Id,
      BulkGapFillTestData.FUEL_NATURAL_GAS,
      120
    );

    SObject asset = BulkGapFillTestData.asset('HQ');
    SObject footprint = BulkGapFillTestData.footprint(asset.Id, YEAR);
    footprint.put(BulkGapFillConstants.FIELD_REGIONAL_BEI_LOOKUP, benchmark.Id);
    update footprint;

    BulkGapFillTestData.energyUse(
      footprint.Id,
      asset.Id,
      BulkGapFillTestData.FUEL_ELECTRICITY,
      JAN_1,
      JUN_30,
      181000
    );

    BulkGapFillRequest req = request(BulkGapFillConstants.METHOD_REGIONAL_BEI);
    BulkGapFillJob__c job = BulkGapFillTestData.job(req);

    run(req, job.Id);

    Assert.isTrue(
      BulkGapFillTestData.energyUseUnder(footprint.Id, true).isEmpty(),
      'Borrowing another fuel type\'s benchmark would be a wrong number that looks authoritative'
    );
    Assert.areEqual(
      BulkGapFillConstants.DETAIL_SKIPPED,
      detailsFor(job.Id)[0].Status__c
    );
  }

  @IsTest
  static void runIsScopedToTheRequestedYear() {
    if (!BulkGapFillTestData.isNetZeroCloudAvailable()) {
      return;
    }
    SObject asset = BulkGapFillTestData.asset('HQ');
    SObject inScope = BulkGapFillTestData.footprint(asset.Id, YEAR);
    SObject outOfScope = BulkGapFillTestData.footprint(asset.Id, YEAR - 2);

    BulkGapFillTestData.energyUse(
      inScope.Id,
      asset.Id,
      BulkGapFillTestData.FUEL_ELECTRICITY,
      JAN_1,
      JUN_30,
      181000
    );
    BulkGapFillTestData.energyUse(
      outOfScope.Id,
      asset.Id,
      BulkGapFillTestData.FUEL_ELECTRICITY,
      Date.newInstance(YEAR - 2, 1, 1),
      Date.newInstance(YEAR - 2, 6, 30),
      181000
    );

    BulkGapFillRequest req = request(BulkGapFillConstants.METHOD_CURRENT_YEAR);
    BulkGapFillJob__c job = BulkGapFillTestData.job(req);

    run(req, job.Id);

    Assert.areEqual(
      1,
      reload(job.Id).FootprintsProcessed__c.intValue(),
      'Only the requested year is in scope'
    );
    Assert.isTrue(
      BulkGapFillTestData.energyUseUnder(outOfScope.Id, true).isEmpty(),
      'A footprint outside the year must be untouched'
    );
  }

  @IsTest
  static void assetTypeFilterNarrowsScope() {
    if (!BulkGapFillTestData.isNetZeroCloudAvailable()) {
      return;
    }
    SObject office = BulkGapFillTestData.asset('Office', 'Office', 1000, 'm2');
    SObject warehouse = BulkGapFillTestData.asset(
      'Warehouse',
      'Warehouse',
      1000,
      'm2'
    );
    SObject officeFootprint = BulkGapFillTestData.footprint(office.Id, YEAR);
    SObject warehouseFootprint = BulkGapFillTestData.footprint(
      warehouse.Id,
      YEAR
    );
    for (
      SObject fp : new List<SObject>{ officeFootprint, warehouseFootprint }
    ) {
      BulkGapFillTestData.energyUse(
        fp.Id,
        (Id) fp.get(BulkGapFillConstants.FIELD_FOOTPRINT_ASSET),
        BulkGapFillTestData.FUEL_ELECTRICITY,
        JAN_1,
        JUN_30,
        181000
      );
    }

    BulkGapFillRequest req = request(BulkGapFillConstants.METHOD_CURRENT_YEAR);
    req.assetTypes = new List<String>{ 'Warehouse' };
    BulkGapFillJob__c job = BulkGapFillTestData.job(req);

    run(req, job.Id);

    Assert.areEqual(1, reload(job.Id).FootprintsProcessed__c.intValue());
    Assert.isTrue(
      BulkGapFillTestData.energyUseUnder(officeFootprint.Id, true).isEmpty(),
      'The office is outside the asset type filter'
    );
  }

  @IsTest
  static void countFootprintsInScopeMatchesWhatTheRunProcesses() {
    if (!BulkGapFillTestData.isNetZeroCloudAvailable()) {
      return;
    }
    SObject asset = BulkGapFillTestData.asset('HQ');
    BulkGapFillTestData.footprint(asset.Id, YEAR);
    BulkGapFillTestData.footprint(asset.Id, YEAR - 1);

    BulkGapFillRequest req = request(BulkGapFillConstants.METHOD_CURRENT_YEAR);

    Test.startTest();
    Integer count = BulkGapFillController.countFootprintsInScope(
      JSON.serialize(req)
    );
    Test.stopTest();

    Assert.areEqual(1, count, 'One footprint in the requested year');
  }

  @IsTest
  static void launchRunCreatesAJobAndEnqueuesTheBatch() {
    if (!BulkGapFillTestData.isNetZeroCloudAvailable()) {
      return;
    }
    SObject asset = BulkGapFillTestData.asset('HQ');
    BulkGapFillTestData.footprint(asset.Id, YEAR);

    BulkGapFillRequest req = request(BulkGapFillConstants.METHOD_CURRENT_YEAR);

    Test.startTest();
    Id jobId = BulkGapFillController.launchRun(JSON.serialize(req));
    Test.stopTest();

    Assert.isNotNull(jobId);
    BulkGapFillJob__c job = [
      SELECT
        Status__c,
        AsyncApexJobId__c,
        FilterCriteria__c,
        DefaultFillMethod__c
      FROM BulkGapFillJob__c
      WHERE Id = :jobId
    ];
    Assert.areEqual(
      BulkGapFillConstants.METHOD_CURRENT_YEAR,
      job.DefaultFillMethod__c
    );
    Assert.isNotNull(
      job.FilterCriteria__c,
      'The request is captured so the run can be reproduced'
    );
    Assert.isNotNull(
      job.AsyncApexJobId__c,
      'The monitor polls AsyncApexJob through this'
    );
  }

  @IsTest
  static void schedulerLaunchesARunForTheDefaultYear() {
    if (!BulkGapFillTestData.isNetZeroCloudAvailable()) {
      return;
    }
    SObject asset = BulkGapFillTestData.asset('HQ');
    BulkGapFillTestData.footprint(asset.Id, Date.today().year() - 1);

    BulkGapFillRequest req = new BulkGapFillRequest();
    req.defaultFillMethod = BulkGapFillConstants.METHOD_CURRENT_YEAR;
    // Left open on purpose: the scheduler resolves it to last year on each firing.
    req.reportingYear = null;

    Test.startTest();
    new BulkGapFillJobScheduler(req).execute(null);
    Test.stopTest();

    List<BulkGapFillJob__c> jobs = [
      SELECT ReportingYear__c
      FROM BulkGapFillJob__c
    ];
    Assert.areEqual(1, jobs.size(), 'A firing creates exactly one job');
    Assert.areEqual(
      Date.today().year() - 1,
      jobs[0].ReportingYear__c.intValue(),
      'An open year resolves to the previous calendar year'
    );
  }
}
