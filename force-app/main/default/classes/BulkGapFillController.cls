/**
 * @description Apex surface for the bulk gap fill LWC wizard: configure, launch,
 * monitor, review.
 *
 * Every method converts internal failures into `AuraHandledException` so the UI gets
 * a readable message instead of a raw stack trace.
 *
 * @group Bulk Gap Fill
 * @see BulkGapFillRequest
 * @see BulkGapFillBatch
 */
public with sharing class BulkGapFillController {
  /**
   * @description Picklist and default data for the Configure page, including any
   * Net Zero Cloud schema problems worth warning the user about up front.
   */
  public class ConfigOptions {
    @AuraEnabled
    public List<Option> fillMethods = new List<Option>();
    @AuraEnabled
    public List<Option> assetTypes = new List<Option>();
    @AuraEnabled
    public List<Integer> reportingYears = new List<Integer>();
    @AuraEnabled
    public Integer defaultReportingYear;
    @AuraEnabled
    public Integer defaultBatchSize;
    @AuraEnabled
    public List<String> schemaProblems = new List<String>();
  }

  /**
   * @description A label/value pair for a combobox or dual listbox in the UI.
   */
  public class Option {
    @AuraEnabled
    public String label;
    @AuraEnabled
    public String value;

    /**
     * @description Creates an option.
     * @param label Text shown to the user.
     * @param value Value submitted back to Apex.
     */
    public Option(String label, String value) {
      this.label = label;
      this.value = value;
    }
  }

  /**
   * @description Combined job record plus live `AsyncApexJob` progress for the
   * Monitor page. Falls back to the job's own timestamps when the platform job row
   * is not available.
   */
  public class JobStatus {
    @AuraEnabled
    public BulkGapFillJob__c job;
    @AuraEnabled
    public String apexJobStatus;
    @AuraEnabled
    public Integer totalBatches;
    @AuraEnabled
    public Integer processedBatches;
    @AuraEnabled
    public Integer batchErrors;
    @AuraEnabled
    public Decimal percentComplete;
    @AuraEnabled
    public Boolean isComplete;
  }

  // ---- Configure --------------------------------------------------------

  /**
   * @description Supplies the Configure page with fill methods, selectable asset
   * types, recent reporting years, and sensible defaults.
   * @return The options and defaults for the configuration form.
   */
  @AuraEnabled(cacheable=true)
  public static ConfigOptions getConfigOptions() {
    try {
      ConfigOptions options = new ConfigOptions();

      options.fillMethods.add(
        new Option(
          'Regional Building Energy Intensity',
          BulkGapFillConstants.METHOD_REGIONAL_BEI
        )
      );
      options.fillMethods.add(
        new Option(
          'Building Energy Intensity',
          BulkGapFillConstants.METHOD_BUILDING_BEI
        )
      );
      options.fillMethods.add(
        new Option(
          'Previous Year Daily Average',
          BulkGapFillConstants.METHOD_PREVIOUS_YEAR
        )
      );
      options.fillMethods.add(
        new Option(
          'Current Year Daily Average',
          BulkGapFillConstants.METHOD_CURRENT_YEAR
        )
      );
      options.fillMethods.add(
        new Option('Manual', BulkGapFillConstants.METHOD_MANUAL)
      );

      Integer thisYear = Date.today().year();
      options.defaultReportingYear = thisYear - 1;
      options.defaultBatchSize = BulkGapFillConstants.DEFAULT_BATCH_SIZE;
      for (Integer year = thisYear; year >= thisYear - 6; year--) {
        options.reportingYears.add(year);
      }

      options.assetTypes = describePicklist(
        BulkGapFillConstants.OBJ_ASSET,
        BulkGapFillConstants.FIELD_ASSET_TYPE
      );
      options.schemaProblems = BulkGapFillConstants.validateSchema();
      return options;
    } catch (Exception e) {
      throw asAuraException(e);
    }
  }

  /**
   * @description Counts the carbon footprints a request would touch, so the user
   * can sanity check scope before launching.
   * @param requestJson A serialized `BulkGapFillRequest`.
   * @return The number of footprint records the filters match.
   */
  @AuraEnabled
  public static Integer countFootprintsInScope(String requestJson) {
    try {
      BulkGapFillRequest request = parseRequest(requestJson);

      if (
        request.carbonFootprintIds != null &&
        !request.carbonFootprintIds.isEmpty()
      ) {
        return request.carbonFootprintIds.size();
      }

      String scopeYear = BulkGapFillConstants.reportingYearBind(
        request.reportingYear
      );
      List<Id> scopeAssetIds = request.stationaryAssetIds;
      List<String> scopeAssetTypes = request.assetTypes;

      List<String> wheres = new List<String>{
        BulkGapFillConstants.FIELD_FOOTPRINT_YEAR + ' = :scopeYear'
      };
      if (scopeAssetIds != null && !scopeAssetIds.isEmpty()) {
        wheres.add(
          BulkGapFillConstants.FIELD_FOOTPRINT_ASSET + ' IN :scopeAssetIds'
        );
      }
      if (scopeAssetTypes != null && !scopeAssetTypes.isEmpty()) {
        wheres.add(
          BulkGapFillConstants.REL_FOOTPRINT_ASSET +
            '.' +
            BulkGapFillConstants.FIELD_ASSET_TYPE +
            ' IN :scopeAssetTypes'
        );
      }

      String soql =
        'SELECT COUNT() FROM ' +
        BulkGapFillConstants.OBJ_FOOTPRINT +
        ' WHERE ' +
        String.join(wheres, ' AND ');
      return Database.countQuery(soql);
    } catch (Exception e) {
      throw asAuraException(e);
    }
  }

  // ---- Launch -----------------------------------------------------------

  /**
   * @description Validates the request, creates the job record, and enqueues the
   * batch. If the launch fails after the job row exists, the row is marked Failed
   * rather than left stuck at Queued.
   * @param requestJson A serialized `BulkGapFillRequest`.
   * @return Id of the new `BulkGapFillJob__c`, which the Monitor page then polls.
   * @throws AuraHandledException When the request is invalid or the batch cannot
   *         be enqueued.
   */
  @AuraEnabled
  public static Id launchRun(String requestJson) {
    BulkGapFillRequest request = parseRequest(requestJson);

    List<String> problems = request.validate();
    if (!problems.isEmpty()) {
      throw new AuraHandledException(String.join(problems, ' '));
    }

    BulkGapFillJob__c job = new BulkGapFillJob__c(
      Status__c = BulkGapFillConstants.JOB_QUEUED,
      ReportingYear__c = request.reportingYear,
      DefaultFillMethod__c = request.defaultFillMethod,
      IsDryRun__c = request.isDryRun,
      FilterCriteria__c = requestJson,
      FootprintsProcessed__c = 0,
      GapsFound__c = 0,
      RecordsCreated__c = 0,
      RecordsAssociated__c = 0,
      ErrorCount__c = 0
    );

    try {
      insert job;
      job.FootprintsInScope__c = countFootprintsInScope(requestJson);

      Integer chunkSize = request.batchSize == null
        ? BulkGapFillConstants.DEFAULT_BATCH_SIZE
        : request.batchSize;
      job.AsyncApexJobId__c = String.valueOf(
        Database.executeBatch(new BulkGapFillBatch(request, job.Id), chunkSize)
      );
      update job;
      return job.Id;
    } catch (Exception e) {
      // The job row is the user's only record that a launch was attempted,
      // so mark it Failed rather than leaving it stuck at Queued.
      if (job.Id != null) {
        Database.update(
          new BulkGapFillJob__c(
            Id = job.Id,
            Status__c = BulkGapFillConstants.JOB_FAILED,
            ErrorLog__c = e.getMessage(),
            CompletedAt__c = System.now()
          ),
          false
        );
      }
      throw asAuraException(e);
    }
  }

  // ---- Monitor ----------------------------------------------------------

  /**
   * @description Reads current progress for a run, combining the job record with
   * live `AsyncApexJob` batch counts.
   * @param jobId The `BulkGapFillJob__c` to inspect.
   * @return The job and its progress.
   */
  @AuraEnabled
  public static JobStatus getJobStatus(Id jobId) {
    try {
      JobStatus status = new JobStatus();
      status.job = [
        SELECT
          Id,
          Name,
          Status__c,
          ReportingYear__c,
          DefaultFillMethod__c,
          IsDryRun__c,
          AsyncApexJobId__c,
          FootprintsInScope__c,
          FootprintsProcessed__c,
          GapsFound__c,
          RecordsCreated__c,
          RecordsAssociated__c,
          ErrorCount__c,
          ErrorLog__c,
          StartedAt__c,
          CompletedAt__c,
          CreatedDate,
          CreatedBy.Name
        FROM BulkGapFillJob__c
        WHERE Id = :jobId
        WITH USER_MODE
        LIMIT 1
      ];

      if (String.isNotBlank(status.job.AsyncApexJobId__c)) {
        List<AsyncApexJob> apexJobs = [
          SELECT
            Id,
            Status,
            JobItemsProcessed,
            TotalJobItems,
            NumberOfErrors,
            ExtendedStatus
          FROM AsyncApexJob
          WHERE Id = :status.job.AsyncApexJobId__c
          LIMIT 1
        ];
        if (!apexJobs.isEmpty()) {
          AsyncApexJob apexJob = apexJobs[0];
          status.apexJobStatus = apexJob.Status;
          status.totalBatches = apexJob.TotalJobItems;
          status.processedBatches = apexJob.JobItemsProcessed;
          status.batchErrors = apexJob.NumberOfErrors;
          status.percentComplete = apexJob.TotalJobItems == 0
            ? 0
            : (Decimal.valueOf(apexJob.JobItemsProcessed) /
                apexJob.TotalJobItems *
                100)
                .setScale(0, System.RoundingMode.DOWN);
          status.isComplete = new Set<String>{
              'Completed',
              'Failed',
              'Aborted'
            }
            .contains(apexJob.Status);
        }
      }

      if (status.isComplete == null) {
        status.isComplete = status.job.CompletedAt__c != null;
        status.percentComplete = status.isComplete ? 100 : 0;
      }
      return status;
    } catch (Exception e) {
      throw asAuraException(e);
    }
  }

  /**
   * @description Aborts the underlying batch and marks the job Aborted. Energy use
   * records already inserted by completed chunks are **not** rolled back.
   * @param jobId The `BulkGapFillJob__c` to abort.
   */
  @AuraEnabled
  public static void abortRun(Id jobId) {
    try {
      BulkGapFillJob__c job = [
        SELECT Id, AsyncApexJobId__c
        FROM BulkGapFillJob__c
        WHERE Id = :jobId
        WITH USER_MODE
        LIMIT 1
      ];
      if (String.isNotBlank(job.AsyncApexJobId__c)) {
        System.abortJob(job.AsyncApexJobId__c);
      }
      update new BulkGapFillJob__c(
        Id = jobId,
        Status__c = BulkGapFillConstants.JOB_ABORTED,
        CompletedAt__c = System.now()
      );
    } catch (Exception e) {
      throw asAuraException(e);
    }
  }

  // ---- Review -----------------------------------------------------------

  /**
   * @description Returns the per-asset audit rows for a run, optionally filtered by
   * outcome and paged for large portfolios.
   * @param jobId The `BulkGapFillJob__c` to read details for.
   * @param statusFilter A detail status such as `Filled` or `Skipped`. Blank or null
   *        returns every row.
   * @param pageSize Rows per page. Defaults to 200, capped at 2000.
   * @param pageOffset Rows to skip. Defaults to 0.
   * @return The matching detail rows, errors and skips first.
   */
  @AuraEnabled
  public static List<BulkGapFillJobDetail__c> getJobDetails(
    Id jobId,
    String statusFilter,
    Integer pageSize,
    Integer pageOffset
  ) {
    try {
      Integer limitSize = pageSize == null ||
        pageSize <= 0
        ? 200
        : Math.min(pageSize, 2000);
      Integer offsetSize = pageOffset == null ||
        pageOffset < 0
        ? 0
        : pageOffset;
      Boolean filtered = String.isNotBlank(statusFilter);

      return Database.query(
        'SELECT Id, Name, StationaryAssetName__c, StationaryAssetId__c, CarbonFootprintId__c, ' +
          'FuelType__c, FillMethodUsed__c, GapsFound__c, GapDays__c, RecordsCreated__c, ' +
          'EnergyFilled__c, EnergyFilledUnit__c, Status__c, ErrorMessage__c ' +
          'FROM BulkGapFillJobDetail__c ' +
          'WHERE BulkGapFillJob__c = :jobId ' +
          (filtered ? 'AND Status__c = :statusFilter ' : '') +
          'ORDER BY Status__c, StationaryAssetName__c NULLS LAST ' +
          'LIMIT :limitSize OFFSET :offsetSize',
        AccessLevel.USER_MODE
      );
    } catch (Exception e) {
      throw asAuraException(e);
    }
  }

  /**
   * @description Lists recent runs, newest first, for a run-history view.
   * @param recordLimit Maximum runs to return. Defaults to 10, capped at 200.
   * @return The most recent `BulkGapFillJob__c` records.
   */
  @AuraEnabled(cacheable=true)
  public static List<BulkGapFillJob__c> getRecentJobs(Integer recordLimit) {
    try {
      Integer limitSize = recordLimit == null ||
        recordLimit <= 0
        ? 10
        : Math.min(recordLimit, 200);
      return [
        SELECT
          Id,
          Name,
          Status__c,
          ReportingYear__c,
          DefaultFillMethod__c,
          IsDryRun__c,
          FootprintsInScope__c,
          FootprintsProcessed__c,
          GapsFound__c,
          RecordsCreated__c,
          ErrorCount__c,
          StartedAt__c,
          CompletedAt__c,
          CreatedDate,
          CreatedBy.Name
        FROM BulkGapFillJob__c
        WITH USER_MODE
        ORDER BY CreatedDate DESC
        LIMIT :limitSize
      ];
    } catch (Exception e) {
      throw asAuraException(e);
    }
  }

  // ---- Helpers ----------------------------------------------------------

  private static BulkGapFillRequest parseRequest(String requestJson) {
    if (String.isBlank(requestJson)) {
      throw new AuraHandledException('No gap fill configuration was supplied.');
    }
    try {
      return (BulkGapFillRequest) JSON.deserialize(
        requestJson,
        BulkGapFillRequest.class
      );
    } catch (Exception e) {
      throw new AuraHandledException(
        'Could not read the gap fill configuration: ' + e.getMessage()
      );
    }
  }

  private static List<Option> describePicklist(
    String objectName,
    String fieldName
  ) {
    List<Option> options = new List<Option>();
    Schema.SObjectType sobjType = Schema.getGlobalDescribe().get(objectName);
    if (sobjType == null) {
      return options;
    }
    Map<String, Schema.SObjectField> fields = sobjType.getDescribe()
      .fields.getMap();
    Schema.SObjectField field = fields.get(fieldName.toLowerCase());
    if (field == null) {
      return options;
    }
    for (Schema.PicklistEntry entry : field.getDescribe().getPicklistValues()) {
      if (entry.isActive()) {
        options.add(new Option(entry.getLabel(), entry.getValue()));
      }
    }
    return options;
  }

  private static AuraHandledException asAuraException(Exception e) {
    if (e instanceof AuraHandledException) {
      return (AuraHandledException) e;
    }
    AuraHandledException wrapped = new AuraHandledException(e.getMessage());
    // Without this the UI shows the useless default "Script-thrown exception".
    wrapped.setMessage(e.getMessage());
    return wrapped;
  }
}
