/**
 * @description Schedulable wrapper so a bulk gap fill run can be cron-scheduled
 * instead of launched from the wizard.
 *
 * The stored request is reused verbatim on every firing, except that a null
 * `reportingYear` is resolved at run time to the prior calendar year — which is what
 * a recurring "fill last year's gaps" schedule actually wants.
 *
 * @group Bulk Gap Fill
 * @see BulkGapFillRequest
 * @see BulkGapFillBatch
 * @example
 * ```apex
 * BulkGapFillRequest req = new BulkGapFillRequest();
 * req.defaultFillMethod = BulkGapFillConstants.METHOD_PREVIOUS_YEAR;
 * // reportingYear left null so each firing targets the prior year.
 *
 * System.schedule('Nightly Bulk Gap Fill', '0 0 2 * * ?', new BulkGapFillJobScheduler(req));
 * ```
 */
public with sharing class BulkGapFillJobScheduler implements Schedulable {
  private final BulkGapFillRequest request;

  /**
   * @description Creates the scheduled wrapper around a run configuration.
   * @param request The configuration to reuse on every firing.
   */
  public BulkGapFillJobScheduler(BulkGapFillRequest request) {
    this.request = request;
  }

  /**
   * @description Resolves the reporting year if it was left open, then launches the
   * run. The stored request is deep-copied so one firing cannot mutate the next.
   * @param sc The schedulable context.
   */
  public void execute(SchedulableContext sc) {
    BulkGapFillRequest runRequest = (BulkGapFillRequest) JSON.deserialize(
      JSON.serialize(request),
      BulkGapFillRequest.class
    );
    if (runRequest.reportingYear == null) {
      runRequest.reportingYear = Date.today().year() - 1;
    }

    BulkGapFillController.launchRun(JSON.serialize(runRequest));
  }
}
