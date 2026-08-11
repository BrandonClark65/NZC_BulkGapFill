/**
 * Unit tests for request validation and period/method resolution.
 */
@IsTest
private class BulkGapFillRequestTest {
  private static BulkGapFillRequest validRequest() {
    BulkGapFillRequest req = new BulkGapFillRequest();
    req.reportingYear = 2025;
    req.defaultFillMethod = BulkGapFillConstants.METHOD_PREVIOUS_YEAR;
    return req;
  }

  @IsTest
  static void validRequestHasNoProblems() {
    Assert.areEqual(0, validRequest().validate().size());
  }

  @IsTest
  static void reportingYearIsRequired() {
    BulkGapFillRequest req = validRequest();
    req.reportingYear = null;

    List<String> problems = req.validate();

    Assert.areEqual(1, problems.size());
    Assert.isTrue(problems[0].contains('Reporting year'), problems[0]);
  }

  @IsTest
  static void fillMethodMustBeKnown() {
    BulkGapFillRequest req = validRequest();
    req.defaultFillMethod = 'Guesswork';

    List<String> problems = req.validate();

    Assert.areEqual(1, problems.size());
    Assert.isTrue(problems[0].contains('Guesswork'), problems[0]);
  }

  @IsTest
  static void manualMethodRequiresARate() {
    BulkGapFillRequest req = validRequest();
    req.defaultFillMethod = BulkGapFillConstants.METHOD_MANUAL;

    List<String> problems = req.validate();

    Assert.areEqual(1, problems.size());
    Assert.isTrue(problems[0].contains('manual daily rate'), problems[0]);

    req.manualDailyRate = -5;
    Assert.isTrue(req.validate()[0].contains('negative'));

    req.manualDailyRate = 10;
    Assert.areEqual(0, req.validate().size());
  }

  @IsTest
  static void invertedPeriodIsRejected() {
    BulkGapFillRequest req = validRequest();
    req.periodStart = Date.newInstance(2025, 12, 31);
    req.periodEnd = Date.newInstance(2025, 1, 1);

    Assert.isTrue(req.validate()[0].contains('on or before'));
  }

  @IsTest
  static void overrideMethodsAreValidated() {
    BulkGapFillRequest req = validRequest();
    req.methodOverrides.put('a0100000000000AAAA', 'Nonsense');

    Assert.isTrue(req.validate()[0].contains('Nonsense'));
  }

  @IsTest
  static void batchSizeIsBounded() {
    BulkGapFillRequest req = validRequest();
    req.batchSize = 5000;

    Assert.isTrue(req.validate()[0].contains('Batch size'));
  }

  @IsTest
  static void periodDefaultsToTheCalendarYear() {
    BulkGapFillRequest req = validRequest();

    Assert.areEqual(Date.newInstance(2025, 1, 1), req.effectivePeriodStart());
    Assert.areEqual(Date.newInstance(2025, 12, 31), req.effectivePeriodEnd());
  }

  @IsTest
  static void explicitFiscalPeriodOverridesTheCalendarYear() {
    BulkGapFillRequest req = validRequest();
    req.periodStart = Date.newInstance(2025, 7, 1);
    req.periodEnd = Date.newInstance(2026, 6, 30);

    Assert.areEqual(Date.newInstance(2025, 7, 1), req.effectivePeriodStart());
    Assert.areEqual(Date.newInstance(2026, 6, 30), req.effectivePeriodEnd());
  }

  @IsTest
  static void methodForHonoursOverrides() {
    BulkGapFillRequest req = validRequest();
    Id overridden = 'a0100000000000AAAA';
    Id notOverridden = 'a0100000000000BAAA';
    req.methodOverrides.put(overridden, BulkGapFillConstants.METHOD_MANUAL);

    Assert.areEqual(
      BulkGapFillConstants.METHOD_MANUAL,
      req.methodFor(overridden)
    );
    Assert.areEqual(
      BulkGapFillConstants.METHOD_PREVIOUS_YEAR,
      req.methodFor(notOverridden)
    );
  }

  @IsTest
  static void roundTripsThroughJson() {
    BulkGapFillRequest req = validRequest();
    req.isDryRun = true;
    req.fuelTypes = new List<String>{ 'Electricity' };

    BulkGapFillRequest restored = (BulkGapFillRequest) JSON.deserialize(
      JSON.serialize(req),
      BulkGapFillRequest.class
    );

    Assert.areEqual(2025, restored.reportingYear);
    Assert.isTrue(restored.isDryRun);
    Assert.areEqual(1, restored.fuelTypes.size());
    Assert.areEqual(
      BulkGapFillConstants.METHOD_PREVIOUS_YEAR,
      restored.defaultFillMethod
    );
  }
}
