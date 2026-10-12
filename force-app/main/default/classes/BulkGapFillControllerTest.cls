/**
 * Tests for the LWC-facing controller.
 *
 * These cover the paths that touch only custom objects: config options, request
 * validation, job status, details, and abort. End-to-end launch coverage requires
 * Net Zero Cloud data and lives in BulkGapFillBatchTest.
 *
 * getJobStatus, getJobDetails, getRecentJobs, and abortRun query with WITH
 * USER_MODE / AccessLevel.USER_MODE, so they only succeed for a user holding
 * field-level security on BulkGapFillJob__c/BulkGapFillJobDetail__c — granted by
 * the Bulk_Gap_Fill_Admin permission set. Running these tests as whichever user
 * triggers the deployment would make them depend on that permission set already
 * being assigned to that user, which cannot be true on a first deploy: the
 * permission set is deployed in the very same transaction that runs these tests,
 * before anyone has had a chance to assign it. Each such test instead runs as a
 * dedicated user this class assigns the permission set to in @testSetup, so the
 * tests pass regardless of what the deploying/running user has.
 */
@IsTest
private class BulkGapFillControllerTest {
  @testSetup
  static void setupPermissions() {
    Id standardUserProfileId = [
      SELECT Id
      FROM Profile
      WHERE Name = 'Standard User'
      LIMIT 1
    ]
    .Id;
    User runAsUser = new User(
      FirstName = 'Bulk Gap Fill',
      LastName = 'Controller Test User',
      Alias = 'bgfctu',
      Email = 'bulk.gap.fill.controller.test@example.com.invalid',
      Username = 'bulk.gap.fill.controller.test.' +
        Crypto.getRandomInteger() +
        '@example.com.invalid',
      TimeZoneSidKey = 'America/Los_Angeles',
      LocaleSidKey = 'en_US',
      EmailEncodingKey = 'UTF-8',
      LanguageLocaleKey = 'en_US',
      ProfileId = standardUserProfileId
    );
    insert runAsUser;

    Id permissionSetId = [
      SELECT Id
      FROM PermissionSet
      WHERE Name = 'Bulk_Gap_Fill_Admin'
      LIMIT 1
    ]
    .Id;
    insert new PermissionSetAssignment(
      AssigneeId = runAsUser.Id,
      PermissionSetId = permissionSetId
    );
  }

  /** The user @testSetup granted Bulk_Gap_Fill_Admin to. */
  private static User runAsUser() {
    return [
      SELECT Id
      FROM User
      WHERE LastName = 'Controller Test User' AND Alias = 'bgfctu'
      LIMIT 1
    ];
  }

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

    BulkGapFillController.JobStatus status;
    System.runAs(runAsUser()) {
      Test.startTest();
      status = BulkGapFillController.getJobStatus(job.Id);
      Test.stopTest();
    }

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

    BulkGapFillController.JobStatus status;
    System.runAs(runAsUser()) {
      status = BulkGapFillController.getJobStatus(job.Id);
    }

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

    List<BulkGapFillJobDetail__c> all;
    List<BulkGapFillJobDetail__c> skipped;
    System.runAs(runAsUser()) {
      all = BulkGapFillController.getJobDetails(job.Id, null, 200, 0);
      skipped = BulkGapFillController.getJobDetails(
        job.Id,
        BulkGapFillConstants.DETAIL_SKIPPED,
        200,
        0
      );
    }

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

    System.runAs(runAsUser()) {
      Assert.areEqual(
        2,
        BulkGapFillController.getJobDetails(job.Id, null, 2, 0).size()
      );
      Assert.areEqual(
        3,
        BulkGapFillController.getJobDetails(job.Id, null, 10, 2).size()
      );
    }
  }

  @IsTest
  static void recentJobsAreNewestFirst() {
    BulkGapFillJob__c older = insertJob();
    BulkGapFillJob__c newer = insertJob();

    // Everything inserted in one transaction shares a CreatedDate, so the dates
    // have to be moved apart for this to be a test of ordering by date at all.
    Test.setCreatedDate(older.Id, System.now().addDays(-2));
    Test.setCreatedDate(newer.Id, System.now().addDays(-1));

    List<BulkGapFillJob__c> jobs;
    System.runAs(runAsUser()) {
      jobs = BulkGapFillController.getRecentJobs(10);
    }

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

    List<BulkGapFillJob__c> jobs;
    System.runAs(runAsUser()) {
      jobs = BulkGapFillController.getRecentJobs(10);
    }

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

    System.runAs(runAsUser()) {
      Test.startTest();
      BulkGapFillController.abortRun(job.Id);
      Test.stopTest();
    }

    BulkGapFillJob__c reloaded = [
      SELECT Status__c, CompletedAt__c
      FROM BulkGapFillJob__c
      WHERE Id = :job.Id
    ];
    Assert.areEqual(BulkGapFillConstants.JOB_ABORTED, reloaded.Status__c);
    Assert.isNotNull(reloaded.CompletedAt__c);
  }
}
