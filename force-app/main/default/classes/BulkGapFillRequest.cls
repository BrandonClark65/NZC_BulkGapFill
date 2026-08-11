/**
 * @description Configuration for one bulk gap fill run, built on the Configure page
 * of the LWC wizard and passed straight through to `BulkGapFillBatch`.
 *
 * Serialized onto `BulkGapFillJob__c.FilterCriteria__c` at launch so any run can be
 * reproduced or audited later.
 *
 * @group Bulk Gap Fill
 * @see BulkGapFillBatch
 * @see BulkGapFillController
 * @example
 * ```apex
 * BulkGapFillRequest req = new BulkGapFillRequest();
 * req.reportingYear = 2025;
 * req.defaultFillMethod = BulkGapFillConstants.METHOD_PREVIOUS_YEAR;
 * req.isDryRun = true;
 *
 * List<String> problems = req.validate();
 * if (problems.isEmpty()) {
 *     Id jobId = BulkGapFillController.launchRun(JSON.serialize(req));
 * }
 * ```
 */
public with sharing class BulkGapFillRequest {
  /** Reporting year to gap fill. Required. */
  @AuraEnabled
  public Integer reportingYear { get; set; }

  /**
   * Reporting period bounds. Left null for a calendar year, in which case the
   * service derives Jan 1 - Dec 31 of reportingYear. Set both for a fiscal year.
   */
  @AuraEnabled
  public Date periodStart { get; set; }

  @AuraEnabled
  public Date periodEnd { get; set; }

  /** One of BulkGapFillConstants.ALL_METHODS. Required. */
  @AuraEnabled
  public String defaultFillMethod { get; set; }

  /** Per-footprint override of defaultFillMethod, keyed by carbon footprint Id. */
  @AuraEnabled
  public Map<Id, String> methodOverrides { get; set; }

  /** Value used when defaultFillMethod is Manual. Interpreted as a daily rate. */
  @AuraEnabled
  public Decimal manualDailyRate { get; set; }

  /** Detect and report gaps without inserting any energy use records. */
  @AuraEnabled
  public Boolean isDryRun { get; set; }

  // ---- Scope filters ----------------------------------------------------
  /** Explicit footprint Ids. When populated, the other filters are ignored. */
  @AuraEnabled
  public List<Id> carbonFootprintIds { get; set; }

  /** Explicit asset Ids. Narrows scope to footprints under these assets. */
  @AuraEnabled
  public List<Id> stationaryAssetIds { get; set; }

  /** StnryAssetEnvrSrc.StationaryAssetType values to include. Empty means all. */
  @AuraEnabled
  public List<String> assetTypes { get; set; }

  /** Fuel types to gap fill. Empty means every fuel type present on the asset. */
  @AuraEnabled
  public List<String> fuelTypes { get; set; }

  /** Link orphan energy use records to their footprint before detecting gaps. */
  @AuraEnabled
  public Boolean associateOrphans { get; set; }

  /** Skip footprints that already have gap-filled records for the same period. */
  @AuraEnabled
  public Boolean skipAlreadyFilled { get; set; }

  /** Chunk size handed to Database.executeBatch. */
  @AuraEnabled
  public Integer batchSize { get; set; }

  /**
   * @description Creates a request with empty filters and safe defaults: live run,
   * orphan association off, already-filled footprints skipped, and the conservative
   * default batch size.
   */
  public BulkGapFillRequest() {
    this.methodOverrides = new Map<Id, String>();
    this.carbonFootprintIds = new List<Id>();
    this.stationaryAssetIds = new List<Id>();
    this.assetTypes = new List<String>();
    this.fuelTypes = new List<String>();
    this.isDryRun = false;
    this.associateOrphans = false;
    this.skipAlreadyFilled = true;
    this.batchSize = BulkGapFillConstants.DEFAULT_BATCH_SIZE;
  }

  /**
   * @description Effective first day of the reporting period.
   * @return `periodStart` when set, otherwise January 1 of `reportingYear`.
   */
  public Date effectivePeriodStart() {
    return periodStart != null
      ? periodStart
      : Date.newInstance(reportingYear, 1, 1);
  }

  /**
   * @description Effective last day of the reporting period, inclusive.
   * @return `periodEnd` when set, otherwise December 31 of `reportingYear`.
   */
  public Date effectivePeriodEnd() {
    return periodEnd != null
      ? periodEnd
      : Date.newInstance(reportingYear, 12, 31);
  }

  /**
   * @description Fill method for a specific footprint, honouring any per-asset
   * override recorded in `methodOverrides`.
   * @param footprintId The carbon footprint being processed.
   * @return The override when one exists, otherwise `defaultFillMethod`.
   */
  public String methodFor(Id footprintId) {
    if (methodOverrides != null && methodOverrides.containsKey(footprintId)) {
      return methodOverrides.get(footprintId);
    }
    return defaultFillMethod;
  }

  /**
   * @description Validates the request before a batch is enqueued, checking the
   * reporting year, fill method, manual rate, period ordering, overrides, and
   * batch size.
   * @return Human-readable problems. An empty list means the request is launchable.
   */
  public List<String> validate() {
    List<String> problems = new List<String>();

    if (reportingYear == null) {
      problems.add('Reporting year is required.');
    } else if (reportingYear < 1900 || reportingYear > 2200) {
      problems.add('Reporting year ' + reportingYear + ' is out of range.');
    }

    if (String.isBlank(defaultFillMethod)) {
      problems.add('A default fill method is required.');
    } else if (!BulkGapFillConstants.ALL_METHODS.contains(defaultFillMethod)) {
      problems.add('Unknown fill method: ' + defaultFillMethod);
    }

    if (BulkGapFillConstants.METHOD_MANUAL.equals(defaultFillMethod)) {
      if (manualDailyRate == null) {
        problems.add(
          'A manual daily rate is required when the fill method is Manual.'
        );
      } else if (manualDailyRate < 0) {
        problems.add('Manual daily rate cannot be negative.');
      }
    }

    if (periodStart != null && periodEnd != null && periodStart > periodEnd) {
      problems.add('Period start must be on or before period end.');
    }

    if (methodOverrides != null) {
      for (String method : methodOverrides.values()) {
        if (!BulkGapFillConstants.ALL_METHODS.contains(method)) {
          problems.add('Unknown fill method in overrides: ' + method);
        }
      }
    }

    if (batchSize != null && (batchSize < 1 || batchSize > 2000)) {
      problems.add('Batch size must be between 1 and 2000.');
    }

    return problems;
  }
}
