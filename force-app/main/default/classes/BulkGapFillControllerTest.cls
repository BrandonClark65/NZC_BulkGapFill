/**
 * Tests for the LWC-facing controller.
 *
 * These cover the paths that touch only custom objects: config options, request
 * validation, job status, details, and abort. End-to-end launch coverage requires
 * Net Zero Cloud data and lives in BulkGapFillBatchTest.
 */
@IsTest
private class BulkGapFillControllerTest {
  private static BulkGapFillJob__c insertJob() {
    BulkGapFillJob__c job = new BulkGapFillJob__c(
      Status__c = BulkGapFillConstants.JOB_RUNNING,
      ReportingYear__c = 2025,
      DefaultFillMethod__c = BulkGapFillConstants.METHOD_PREVIOUS_YEAR,
      IsDryRun__c = false,
      FootprintsInScope__c = 10,
      FootprintsProcessed__c = 4,
      GapsFound__c = 7,
      RecordsCreated__c = 7,
      ErrorCount__c = 1
    );
    insert job;
    return job;
  }

  @IsTest
  static void configOptionsExposeAllFiveFillMethods() {
    Test.startTest();
    BulkGapFillController.ConfigOptions options = BulkGapFillController.getConfigOptions();
    Test.stopTest();

    Assert.areEqual(5, options.fillMethods.size());
    Assert.areEqual(
      7,
      options.reportingYears.size(),
      'Current year plus six prior'
    );
    Assert.areEqual(Date.today().year() - 1, options.defaultReportingYear);
    Assert.areEqual(
      BulkGapFillConstants.DEFAULT_BATCH_SIZE,
      options.defaultBatchSize
    );

    Set<String> values = new Set<String>();
    for (BulkGapFillController.Option option : options.fillMethods) {
      values.add(option.value);
    }
    Assert.areEqual(BulkGapFillConstants.ALL_METHODS, values);
  }

  @IsTest
  static void launchRejectsAnInvalidRequest() {
    BulkGapFillRequest req = new BulkGapFillRequest();
    req.defaultFillMethod = 'Guesswork'; // and no reporting year

    try {
      BulkGapFillController.launchRun(JSON.serialize(req));
      Assert.fail('Expected the request to be rejected');
    } catch (AuraHandledException e) {
      Assert.isNotNull(e.getMessage());
    }

    Assert.areEqual(
      0,
      [SELECT COUNT() FROM BulkGapFillJob__c],
      'No job row for a rejected request'
    );
  }

  @IsTest
  static void launchRejectsBlankConfiguration() {
    try {
      BulkGapFillController.launchRun(null);
      Assert.fail('Expected blank configuration to be rejected');
    } catch (AuraHandledException e) {
      Assert.isNotNull(e.getMessage());
    }
  }

  @IsTest
  static void launchRejectsMalformedJson() {
    try {
      BulkGapFillController.launchRun('{not valid json');
      Assert.fail('Expected malformed JSON to be rejected');
    } catch (AuraHandledException e) {
      Assert.isNotNull(e.getMessage());
    }
  }

  @IsTest
  static void jobStatusFallsBackWhenThereIsNoApexJobYet() {
    BulkGapFillJob__c job = insertJob();

    Test.startTest();
    BulkGapFillController.JobStatus status = BulkGapFillController.getJobStatus(
      job.Id
    );
    Test.stopTest();

    Assert.areEqual(job.Id, status.job.Id);
    Assert.isFalse(status.isComplete, 'No CompletedAt means still running');
    Assert.areEqual(0, status.percentComplete);
    Assert.areEqual(7, status.job.GapsFound__c);
  }

  @IsTest
  static void jobStatusReportsCompleteOnceFinished() {
    BulkGapFillJob__c job = insertJob();
    job.Status__c = BulkGapFillConstants.JOB_COMPLETED;
    job.CompletedAt__c = System.now();
    update job;

    BulkGapFillController.JobStatus status = BulkGapFillController.getJobStatus(
      job.Id
    );

    Assert.isTrue(status.isComplete);
    Assert.areEqual(100, status.percentComplete);
  }

  @IsTest
  static void jobDetailsCanBeFilteredByStatus() {
    BulkGapFillJob__c job = insertJob();
    insert new List<BulkGapFillJobDetail__c>{
      new BulkGapFillJobDetail__c(
        BulkGapFillJob__c = job.Id,
        StationaryAssetName__c = 'HQ',
        FuelType__c = 'Electricity',
        Status__c = BulkGapFillConstants.DETAIL_FILLED,
        GapsFound__c = 2,
        RecordsCreated__c = 2
      ),
      new BulkGapFillJobDetail__c(
        BulkGapFillJob__c = job.Id,
        StationaryAssetName__c = 'Warehouse',
        FuelType__c = 'Natural Gas',
        Status__c = BulkGapFillConstants.DETAIL_SKIPPED,
        GapsFound__c = 1,
        ErrorMessage__c = 'No prior year data.'
      )
    };

    List<BulkGapFillJobDetail__c> all = BulkGapFillController.getJobDetails(
      job.Id,
      null,
      200,
      0
    );
    List<BulkGapFillJobDetail__c> skipped = BulkGapFillController.getJobDetails(
      job.Id,
      BulkGapFillConstants.DETAIL_SKIPPED,
      200,
      0
    );

    Assert.areEqual(2, all.size());
    Assert.areEqual(1, skipped.size());
    Assert.areEqual('Warehouse', skipped[0].StationaryAssetName__c);
  }

  @IsTest
  static void jobDetailsPaginate() {
    BulkGapFillJob__c job = insertJob();
    List<BulkGapFillJobDetail__c> details = new List<BulkGapFillJobDetail__c>();
    for (Integer i = 0; i < 5; i++) {
      details.add(
        new BulkGapFillJobDetail__c(
          BulkGapFillJob__c = job.Id,
          StationaryAssetName__c = 'Asset ' + i,
          Status__c = BulkGapFillConstants.DETAIL_FILLED
        )
      );
    }
    insert details;

    Assert.areEqual(
      2,
      BulkGapFillController.getJobDetails(job.Id, null, 2, 0).size()
    );
    Assert.areEqual(
      3,
      BulkGapFillController.getJobDetails(job.Id, null, 10, 2).size()
    );
  }

  @IsTest
  static void recentJobsAreNewestFirst() {
    BulkGapFillJob__c older = insertJob();
    BulkGapFillJob__c newer = insertJob();

    // Everything inserted in one transaction shares a CreatedDate, so the dates
    // have to be moved apart for this to be a test of ordering by date at all.
    Test.setCreatedDate(older.Id, System.now().addDays(-2));
    Test.setCreatedDate(newer.Id, System.now().addDays(-1));

    List<BulkGapFillJob__c> jobs = BulkGapFillController.getRecentJobs(10);

    Assert.areEqual(2, jobs.size());
    Assert.areEqual(
      newer.Id,
      jobs[0].Id,
      'Most recently created job comes first'
    );
  }

  @IsTest
  static void recentJobsOrderIsStableWhenCreatedDatesTie() {
    // Two runs launched in the same second, which is the common case when a
    // scheduled job and a manual one land together. CreatedDate cannot separate
    // them, so the query falls back to Id and the order stays put across
    // refreshes rather than flipping.
    BulkGapFillJob__c first = insertJob();
    BulkGapFillJob__c second = insertJob();
    Id higherId = first.Id > second.Id ? first.Id : second.Id;

    List<BulkGapFillJob__c> jobs = BulkGapFillController.getRecentJobs(10);

    Assert.areEqual(2, jobs.size());
    Assert.areEqual(
      higherId,
      jobs[0].Id,
      'A CreatedDate tie is broken by Id, descending'
    );
  }

  @IsTest
  static void abortMarksTheJobAborted() {
    BulkGapFillJob__c job = insertJob();

    Test.startTest();
    BulkGapFillController.abortRun(job.Id);
    Test.stopTest();

    BulkGapFillJob__c reloaded = [
      SELECT Status__c, CompletedAt__c
      FROM BulkGapFillJob__c
      WHERE Id = :job.Id
    ];
    Assert.areEqual(BulkGapFillConstants.JOB_ABORTED, reloaded.Status__c);
    Assert.isNotNull(reloaded.CompletedAt__c);
  }
}
