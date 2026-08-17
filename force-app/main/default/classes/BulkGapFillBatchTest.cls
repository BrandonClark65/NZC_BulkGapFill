/**
 * Tests for the batch's fill method stamping and its per-asset audit trail.
 *
 * Two areas, both regression cover for a live run that reported success while
 * creating nothing:
 *
 * 1. `DataGapFillingMethodName` is a standard restricted picklist, so a value we
 *    invent is rejected and takes every generated record down with it. The tests
 *    assert the resolver only ever produces a value the running org accepts.
 * 2. Detail rows are written optimistically during gap detection, before any DML.
 *    The tests assert a failed insert is backed out of the row that counted it.
 *
 * The reconciliation tests operate on in-memory `BulkGapFillJobDetail__c` records
 * and need no Net Zero Cloud data, so they hold in any org. The picklist tests
 * describe whatever the running org actually has: where NZC is not enabled the
 * field does not exist, there is nothing to violate, and they no-op rather than
 * assert against a schema that isn't there.
 *
 * A full `execute()` pass over real Net Zero Cloud records lives in
 * `BulkGapFillBatchRunTest`, which needs fixtures this class deliberately avoids.
 */
@IsTest
private class BulkGapFillBatchTest {
  /** The values Net Zero Cloud ships for DataGapFillingMethodName. */
  private static final Map<String, String> EXPECTED_PICKLIST_VALUES = new Map<String, String>{
    BulkGapFillConstants.METHOD_REGIONAL_BEI => 'REGIONAL_BENCHMARK',
    BulkGapFillConstants.METHOD_BUILDING_BEI => 'BUILDING_BENCHMARK',
    BulkGapFillConstants.METHOD_PREVIOUS_YEAR => 'DAILY_AVERAGE_LAST_YEAR',
    BulkGapFillConstants.METHOD_CURRENT_YEAR => 'DAILY_AVERAGE_CURRENT_YEAR',
    BulkGapFillConstants.METHOD_MANUAL => 'MANUAL'
  };

  // ---- Fill method picklist resolution ----------------------------------

  /**
   * The bug this guards: our own token was written straight into the picklist and
   * every insert failed with "bad value for restricted picklist field".
   */
  @IsTest
  static void everyMethodResolvesToAValueThePicklistAccepts() {
    List<String> options = BulkGapFillConstants.gapFillMethodPicklistOptions();
    if (options.isEmpty()) {
      return; // Not a picklist in this org, so nothing constrains the value.
    }
    Set<String> accepted = new Set<String>(options);

    for (String method : BulkGapFillConstants.ALL_METHODS) {
      String resolved = BulkGapFillConstants.gapFillMethodPicklistValue(method);
      Assert.isNotNull(
        resolved,
        method +
          ' resolved to nothing. Add its spelling to METHOD_PICKLIST_ALIASES. ' +
          'This org accepts: ' +
          String.join(options, ', ')
      );
      Assert.isTrue(
        accepted.contains(resolved),
        method +
          ' resolved to "' +
          resolved +
          '", which this org will reject. Accepted: ' +
          String.join(options, ', ')
      );
    }
  }

  @IsTest
  static void knownNetZeroCloudValuesMapToTheRightMethod() {
    Set<String> accepted = new Set<String>(
      BulkGapFillConstants.gapFillMethodPicklistOptions()
    );

    for (String method : EXPECTED_PICKLIST_VALUES.keySet()) {
      String expected = EXPECTED_PICKLIST_VALUES.get(method);
      if (!accepted.contains(expected)) {
        // A different NZC release, or NZC is not enabled. The invariant that the
        // value must be one the org accepts is asserted by the test above.
        continue;
      }
      Assert.areEqual(
        expected,
        BulkGapFillConstants.gapFillMethodPicklistValue(method),
        method + ' must resolve to the API value, not a translated label'
      );
    }
  }

  @IsTest
  static void anUnknownMethodResolvesToNothing() {
    Assert.isNull(
      BulkGapFillConstants.gapFillMethodPicklistValue('Guesswork'),
      'An unrecognised method must not be stamped onto a record'
    );
    Assert.isNull(BulkGapFillConstants.gapFillMethodPicklistValue(null));
    Assert.isNull(BulkGapFillConstants.gapFillMethodPicklistValue(''));
  }

  @IsTest
  static void schemaValidationReportsRatherThanThrows() {
    // Returns problems in an org without NZC and an empty list in one with it;
    // either way it must not blow up, since the Configure page calls it on load.
    Assert.isNotNull(BulkGapFillConstants.validateSchema());
  }

  // ---- Detail reconciliation --------------------------------------------

  private static BulkGapFillJobDetail__c filledDetail(
    Integer records,
    Decimal energy
  ) {
    return new BulkGapFillJobDetail__c(
      StationaryAssetName__c = 'HQ',
      FuelType__c = 'Electricity',
      Status__c = BulkGapFillConstants.DETAIL_FILLED,
      GapsFound__c = records,
      RecordsCreated__c = records,
      EnergyFilled__c = energy
    );
  }

  /** `record` is never dereferenced by the reconciliation, so it stays null here. */
  private static BulkGapFillBatch.StagedFill staged(
    BulkGapFillJobDetail__c detail,
    Decimal value
  ) {
    return new BulkGapFillBatch.StagedFill((SObject) null, detail, value);
  }

  @IsTest
  static void failedInsertIsBackedOutOfItsDetailRow() {
    BulkGapFillJobDetail__c detail = filledDetail(2, 1000);

    BulkGapFillBatch.recordFailure(staged(detail, 400), 'insert exploded');

    Assert.areEqual(
      1,
      detail.RecordsCreated__c.intValue(),
      'One of two records survived'
    );
    Assert.areEqual(
      600,
      detail.EnergyFilled__c.intValue(),
      'Failed energy is subtracted'
    );
    Assert.areEqual('insert exploded', detail.ErrorMessage__c);
    Assert.areEqual(
      BulkGapFillConstants.DETAIL_FILLED,
      detail.Status__c,
      'A partial fill is still a fill'
    );
  }

  @IsTest
  static void detailLosingEveryRecordBecomesAnError() {
    BulkGapFillJobDetail__c detail = filledDetail(2, 1000);
    List<BulkGapFillBatch.StagedFill> fills = new List<BulkGapFillBatch.StagedFill>{
      staged(detail, 500),
      staged(detail, 500)
    };

    for (BulkGapFillBatch.StagedFill fill : fills) {
      BulkGapFillBatch.recordFailure(fill, 'bad value for restricted picklist');
    }
    BulkGapFillBatch.demoteEmptyDetails(fills);

    Assert.areEqual(
      BulkGapFillConstants.DETAIL_ERROR,
      detail.Status__c,
      'Reporting Filled with nothing created is what hid the original bug'
    );
    Assert.areEqual(0, detail.RecordsCreated__c.intValue());
    Assert.areEqual(0, detail.EnergyFilled__c.intValue());
    Assert.isTrue(detail.ErrorMessage__c.contains('restricted picklist'));
  }

  @IsTest
  static void detailKeepingOneRecordStaysFilled() {
    BulkGapFillJobDetail__c detail = filledDetail(3, 900);
    List<BulkGapFillBatch.StagedFill> fills = new List<BulkGapFillBatch.StagedFill>{
      staged(detail, 300),
      staged(detail, 300)
    };

    for (BulkGapFillBatch.StagedFill fill : fills) {
      BulkGapFillBatch.recordFailure(fill, 'insert exploded');
    }
    BulkGapFillBatch.demoteEmptyDetails(fills);

    Assert.areEqual(BulkGapFillConstants.DETAIL_FILLED, detail.Status__c);
    Assert.areEqual(1, detail.RecordsCreated__c.intValue());
    Assert.areEqual(300, detail.EnergyFilled__c.intValue());
  }

  @IsTest
  static void identicalFailuresAreRecordedOnce() {
    BulkGapFillJobDetail__c detail = filledDetail(3, 900);
    String message = 'bad value for restricted picklist field';

    for (Integer i = 0; i < 3; i++) {
      BulkGapFillBatch.recordFailure(staged(detail, 300), message);
    }

    Assert.areEqual(
      message,
      detail.ErrorMessage__c,
      'Every gap in a fuel set fails the same way; say it once'
    );
    Assert.areEqual(
      0,
      detail.RecordsCreated__c.intValue(),
      'All three still counted'
    );
  }

  @IsTest
  static void distinctFailuresAreBothKept() {
    BulkGapFillJobDetail__c detail = filledDetail(2, 800);

    BulkGapFillBatch.recordFailure(staged(detail, 400), 'first problem');
    BulkGapFillBatch.recordFailure(staged(detail, 400), 'second problem');

    Assert.isTrue(detail.ErrorMessage__c.contains('first problem'));
    Assert.isTrue(detail.ErrorMessage__c.contains('second problem'));
  }

  @IsTest
  static void failureMessageKeepsExistingDateIssueText() {
    BulkGapFillJobDetail__c detail = filledDetail(1, 500);
    detail.ErrorMessage__c = 'Overlap: two records cover 2025-03-01';

    BulkGapFillBatch.recordFailure(staged(detail, 500), 'insert exploded');

    Assert.isTrue(
      detail.ErrorMessage__c.contains('Overlap'),
      'Date issues detected earlier must survive'
    );
    Assert.isTrue(detail.ErrorMessage__c.contains('insert exploded'));
  }

  @IsTest
  static void energyFilledNeverGoesNegative() {
    // Rounding can leave the per-gap values summing to slightly over the total.
    BulkGapFillJobDetail__c detail = filledDetail(1, 100);

    BulkGapFillBatch.recordFailure(staged(detail, 250), 'insert exploded');

    Assert.areEqual(0, detail.EnergyFilled__c.intValue());
  }

  // ---- finish -----------------------------------------------------------

  @IsTest
  static void finishStampsCompletionOntoTheJob() {
    BulkGapFillJob__c job = new BulkGapFillJob__c(
      Status__c = BulkGapFillConstants.JOB_RUNNING,
      ReportingYear__c = 2025,
      DefaultFillMethod__c = BulkGapFillConstants.METHOD_CURRENT_YEAR
    );
    insert job;

    BulkGapFillRequest request = new BulkGapFillRequest();
    request.reportingYear = 2025;
    request.defaultFillMethod = BulkGapFillConstants.METHOD_CURRENT_YEAR;

    Test.startTest();
    new BulkGapFillBatch(request, job.Id).finish(null);
    Test.stopTest();

    BulkGapFillJob__c reloaded = [
      SELECT Status__c, CompletedAt__c, RecordsCreated__c, ErrorCount__c
      FROM BulkGapFillJob__c
      WHERE Id = :job.Id
    ];
    Assert.areEqual(BulkGapFillConstants.JOB_COMPLETED, reloaded.Status__c);
    Assert.isNotNull(reloaded.CompletedAt__c);
    Assert.areEqual(0, reloaded.RecordsCreated__c.intValue());
    Assert.areEqual(0, reloaded.ErrorCount__c.intValue());
  }
}
