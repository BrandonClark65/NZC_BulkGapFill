/**
 * Unit tests for the gap detection and fill calculation core.
 *
 * These run against plain wrappers, so they need no Net Zero Cloud data and stay
 * green in any org — including a scratch org without NZC enabled.
 */
@IsTest
private class BulkGapFillServiceTest {
  private static final Date YEAR_START = Date.newInstance(2025, 1, 1);
  private static final Date YEAR_END = Date.newInstance(2025, 12, 31);

  private static BulkGapFillService.EnergyRecord rec(
    String fuelType,
    Date startDate,
    Date endDate,
    Decimal consumption
  ) {
    BulkGapFillService.EnergyRecord r = new BulkGapFillService.EnergyRecord();
    r.fuelType = fuelType;
    r.startDate = startDate;
    r.endDate = endDate;
    r.consumption = consumption;
    r.consumptionUnit = 'kWh';
    r.isGapFilled = false;
    return r;
  }

  private static BulkGapFillService.DateRange range(
    Date startDate,
    Date endDate
  ) {
    return new BulkGapFillService.DateRange(startDate, endDate);
  }

  // ---- Gap detection ----------------------------------------------------

  @IsTest
  static void noCoverageYieldsWholePeriodAsOneGap() {
    List<BulkGapFillService.DateRange> gaps = BulkGapFillService.detectGaps(
      YEAR_START,
      YEAR_END,
      new List<BulkGapFillService.DateRange>()
    );

    Assert.areEqual(1, gaps.size(), 'An uncovered year is a single gap');
    Assert.areEqual(YEAR_START, gaps[0].startDate);
    Assert.areEqual(YEAR_END, gaps[0].endDate);
    Assert.areEqual(365, gaps[0].days, '2025 is not a leap year');
  }

  @IsTest
  static void fullCoverageYieldsNoGaps() {
    List<BulkGapFillService.DateRange> gaps = BulkGapFillService.detectGaps(
      YEAR_START,
      YEAR_END,
      new List<BulkGapFillService.DateRange>{ range(YEAR_START, YEAR_END) }
    );

    Assert.areEqual(0, gaps.size(), 'A fully covered year has no gaps');
  }

  @IsTest
  static void detectsGapBetweenTwoCoveredPeriods() {
    List<BulkGapFillService.DateRange> covered = new List<BulkGapFillService.DateRange>{
      range(YEAR_START, Date.newInstance(2025, 3, 31)),
      range(Date.newInstance(2025, 7, 1), YEAR_END)
    };

    List<BulkGapFillService.DateRange> gaps = BulkGapFillService.detectGaps(
      YEAR_START,
      YEAR_END,
      covered
    );

    Assert.areEqual(1, gaps.size());
    Assert.areEqual(Date.newInstance(2025, 4, 1), gaps[0].startDate);
    Assert.areEqual(Date.newInstance(2025, 6, 30), gaps[0].endDate);
    Assert.areEqual(91, gaps[0].days, 'April through June inclusive');
  }

  @IsTest
  static void detectsLeadingAndTrailingGaps() {
    List<BulkGapFillService.DateRange> covered = new List<BulkGapFillService.DateRange>{
      range(Date.newInstance(2025, 2, 1), Date.newInstance(2025, 11, 30))
    };

    List<BulkGapFillService.DateRange> gaps = BulkGapFillService.detectGaps(
      YEAR_START,
      YEAR_END,
      covered
    );

    Assert.areEqual(2, gaps.size());
    Assert.areEqual(YEAR_START, gaps[0].startDate);
    Assert.areEqual(Date.newInstance(2025, 1, 31), gaps[0].endDate);
    Assert.areEqual(Date.newInstance(2025, 12, 1), gaps[1].startDate);
    Assert.areEqual(YEAR_END, gaps[1].endDate);
  }

  @IsTest
  static void adjacentPeriodsLeaveNoGap() {
    // A bill ending Jan 31 and one starting Feb 1 are contiguous, not a 0-day gap.
    List<BulkGapFillService.DateRange> covered = new List<BulkGapFillService.DateRange>{
      range(YEAR_START, Date.newInstance(2025, 1, 31)),
      range(Date.newInstance(2025, 2, 1), YEAR_END)
    };

    Assert.areEqual(
      0,
      BulkGapFillService.detectGaps(YEAR_START, YEAR_END, covered).size()
    );
  }

  @IsTest
  static void overlappingCoverageIsMergedNotDoubleCounted() {
    List<BulkGapFillService.DateRange> covered = new List<BulkGapFillService.DateRange>{
      range(YEAR_START, Date.newInstance(2025, 6, 30)),
      range(Date.newInstance(2025, 5, 1), Date.newInstance(2025, 8, 31))
    };

    List<BulkGapFillService.DateRange> gaps = BulkGapFillService.detectGaps(
      YEAR_START,
      YEAR_END,
      covered
    );

    Assert.areEqual(1, gaps.size());
    Assert.areEqual(Date.newInstance(2025, 9, 1), gaps[0].startDate);
    Assert.areEqual(YEAR_END, gaps[0].endDate);
  }

  @IsTest
  static void coverageOutsideThePeriodIsClipped() {
    List<BulkGapFillService.DateRange> covered = new List<BulkGapFillService.DateRange>{
      range(Date.newInstance(2024, 6, 1), Date.newInstance(2025, 1, 15)),
      range(Date.newInstance(2025, 12, 20), Date.newInstance(2026, 3, 1))
    };

    List<BulkGapFillService.DateRange> gaps = BulkGapFillService.detectGaps(
      YEAR_START,
      YEAR_END,
      covered
    );

    Assert.areEqual(1, gaps.size());
    Assert.areEqual(Date.newInstance(2025, 1, 16), gaps[0].startDate);
    Assert.areEqual(Date.newInstance(2025, 12, 19), gaps[0].endDate);
  }

  @IsTest
  static void invertedPeriodReturnsNoGaps() {
    Assert.areEqual(
      0,
      BulkGapFillService.detectGaps(YEAR_END, YEAR_START, null).size(),
      'An inverted period is not gap fillable'
    );
  }

  // ---- Date issues ------------------------------------------------------

  @IsTest
  static void flagsMissingAndInvertedDates() {
    List<BulkGapFillService.EnergyRecord> records = new List<BulkGapFillService.EnergyRecord>{
      rec('Electricity', null, Date.newInstance(2025, 1, 31), 100),
      rec('Electricity', Date.newInstance(2025, 2, 1), null, 100),
      rec(
        'Electricity',
        Date.newInstance(2025, 3, 31),
        Date.newInstance(2025, 3, 1),
        100
      )
    };

    List<BulkGapFillService.DateIssue> issues = BulkGapFillService.detectDateIssues(
      records
    );

    Assert.areEqual(3, issues.size());
    Set<String> types = new Set<String>();
    for (BulkGapFillService.DateIssue issue : issues) {
      types.add(issue.issueType);
    }
    Assert.isTrue(types.contains('MissingStartDate'));
    Assert.isTrue(types.contains('MissingEndDate'));
    Assert.isTrue(types.contains('InvertedRange'));
  }

  @IsTest
  static void flagsOverlapsOnlyWithinTheSameFuelType() {
    List<BulkGapFillService.EnergyRecord> records = new List<BulkGapFillService.EnergyRecord>{
      rec('Electricity', YEAR_START, Date.newInstance(2025, 6, 30), 100),
      rec(
        'Electricity',
        Date.newInstance(2025, 5, 1),
        Date.newInstance(2025, 9, 30),
        100
      ),
      rec(
        'Natural Gas',
        Date.newInstance(2025, 5, 1),
        Date.newInstance(2025, 9, 30),
        50
      )
    };

    List<BulkGapFillService.DateIssue> issues = BulkGapFillService.detectDateIssues(
      records
    );

    Assert.areEqual(
      1,
      issues.size(),
      'Different fuel types may share a period'
    );
    Assert.areEqual('Overlap', issues[0].issueType);
  }

  // ---- Footprint analysis -----------------------------------------------

  @IsTest
  static void analyzesEachFuelTypeIndependently() {
    List<BulkGapFillService.EnergyRecord> records = new List<BulkGapFillService.EnergyRecord>{
      rec('Electricity', YEAR_START, YEAR_END, 12000),
      rec('Natural Gas', YEAR_START, Date.newInstance(2025, 3, 31), 900)
    };

    List<BulkGapFillService.FuelGapSet> sets = BulkGapFillService.analyzeFootprint(
      YEAR_START,
      YEAR_END,
      records,
      new Set<String>()
    );

    Assert.areEqual(2, sets.size());
    for (BulkGapFillService.FuelGapSet gapSet : sets) {
      if (gapSet.fuelType == 'Electricity') {
        Assert.areEqual(0, gapSet.gaps.size(), 'Electricity is fully covered');
      } else {
        Assert.areEqual(1, gapSet.gaps.size());
        Assert.areEqual(275, gapSet.totalGapDays, 'April 1 through Dec 31');
      }
    }
  }

  @IsTest
  static void requestedFuelTypeWithNoRecordsIsAWholeYearGap() {
    List<BulkGapFillService.FuelGapSet> sets = BulkGapFillService.analyzeFootprint(
      YEAR_START,
      YEAR_END,
      new List<BulkGapFillService.EnergyRecord>(),
      new Set<String>{ 'Diesel' }
    );

    Assert.areEqual(1, sets.size());
    Assert.areEqual('Diesel', sets[0].fuelType);
    Assert.areEqual(365, sets[0].totalGapDays);
  }

  @IsTest
  static void fuelTypeFilterExcludesOtherFuels() {
    List<BulkGapFillService.EnergyRecord> records = new List<BulkGapFillService.EnergyRecord>{
      rec('Electricity', YEAR_START, Date.newInstance(2025, 6, 30), 6000),
      rec('Natural Gas', YEAR_START, Date.newInstance(2025, 6, 30), 500)
    };

    List<BulkGapFillService.FuelGapSet> sets = BulkGapFillService.analyzeFootprint(
      YEAR_START,
      YEAR_END,
      records,
      new Set<String>{ 'Electricity' }
    );

    Assert.areEqual(1, sets.size());
    Assert.areEqual('Electricity', sets[0].fuelType);
  }

  // ---- Fill rate resolution ---------------------------------------------

  @IsTest
  static void beiMethodsAnnualizeOverFloorArea() {
    BulkGapFillService.FillContext ctx = new BulkGapFillService.FillContext();
    ctx.method = BulkGapFillConstants.METHOD_REGIONAL_BEI;
    ctx.beiValue = 200; // kWh per m2 per year
    ctx.occupiedFloorAreaSqM = 1825; // m2

    Decimal rate = BulkGapFillService.resolveDailyRate(ctx);

    Assert.areEqual(1000, rate, '200 * 1825 / 365');
  }

  @IsTest
  static void beiMethodIsNotViableWithoutABenchmark() {
    BulkGapFillService.FillContext ctx = new BulkGapFillService.FillContext();
    ctx.method = BulkGapFillConstants.METHOD_BUILDING_BEI;
    ctx.occupiedFloorAreaSqM = 1000;

    try {
      BulkGapFillService.resolveDailyRate(ctx);
      Assert.fail('Expected FillNotViableException');
    } catch (BulkGapFillService.FillNotViableException e) {
      Assert.isTrue(e.getMessage().contains('benchmark'), e.getMessage());
    }
  }

  @IsTest
  static void beiMethodIsNotViableWithoutFloorArea() {
    BulkGapFillService.FillContext ctx = new BulkGapFillService.FillContext();
    ctx.method = BulkGapFillConstants.METHOD_REGIONAL_BEI;
    ctx.beiValue = 200;
    ctx.occupiedFloorAreaSqM = 0;

    try {
      BulkGapFillService.resolveDailyRate(ctx);
      Assert.fail('Expected FillNotViableException');
    } catch (BulkGapFillService.FillNotViableException e) {
      Assert.isTrue(e.getMessage().contains('floor area'), e.getMessage());
    }
  }

  @IsTest
  static void previousYearMethodDividesByCalendarDays() {
    BulkGapFillService.FillContext ctx = new BulkGapFillService.FillContext();
    ctx.method = BulkGapFillConstants.METHOD_PREVIOUS_YEAR;
    ctx.priorYearTotal = 36500;

    Assert.areEqual(100, BulkGapFillService.resolveDailyRate(ctx));
  }

  @IsTest
  static void previousYearMethodIsNotViableWithoutPriorData() {
    BulkGapFillService.FillContext ctx = new BulkGapFillService.FillContext();
    ctx.method = BulkGapFillConstants.METHOD_PREVIOUS_YEAR;
    ctx.fuelType = 'Electricity';
    ctx.priorYearTotal = 0;

    try {
      BulkGapFillService.resolveDailyRate(ctx);
      Assert.fail('Expected FillNotViableException');
    } catch (BulkGapFillService.FillNotViableException e) {
      Assert.isTrue(e.getMessage().contains('Electricity'), e.getMessage());
    }
  }

  @IsTest
  static void currentYearMethodDividesByDaysActuallyCovered() {
    BulkGapFillService.FillContext ctx = new BulkGapFillService.FillContext();
    ctx.method = BulkGapFillConstants.METHOD_CURRENT_YEAR;
    ctx.currentYearTotal = 9000;
    ctx.currentYearDaysWithData = 90;

    Assert.areEqual(100, BulkGapFillService.resolveDailyRate(ctx));
  }

  @IsTest
  static void currentYearMethodIsNotViableWithoutCoveredDays() {
    BulkGapFillService.FillContext ctx = new BulkGapFillService.FillContext();
    ctx.method = BulkGapFillConstants.METHOD_CURRENT_YEAR;
    ctx.fuelType = 'Natural Gas';
    ctx.currentYearTotal = 500;
    ctx.currentYearDaysWithData = 0;

    try {
      BulkGapFillService.resolveDailyRate(ctx);
      Assert.fail('Expected FillNotViableException');
    } catch (BulkGapFillService.FillNotViableException e) {
      Assert.isTrue(e.getMessage().contains('Natural Gas'), e.getMessage());
    }
  }

  @IsTest
  static void manualMethodUsesTheSuppliedRate() {
    BulkGapFillService.FillContext ctx = new BulkGapFillService.FillContext();
    ctx.method = BulkGapFillConstants.METHOD_MANUAL;
    ctx.manualDailyRate = 42.5;

    Assert.areEqual(42.5, BulkGapFillService.resolveDailyRate(ctx));
  }

  @IsTest
  static void unknownMethodIsRejected() {
    BulkGapFillService.FillContext ctx = new BulkGapFillService.FillContext();
    ctx.method = 'Telepathy';

    try {
      BulkGapFillService.resolveDailyRate(ctx);
      Assert.fail('Expected FillNotViableException');
    } catch (BulkGapFillService.FillNotViableException e) {
      Assert.isTrue(e.getMessage().contains('Telepathy'), e.getMessage());
    }
  }

  // ---- Aggregation helpers ----------------------------------------------

  @IsTest
  static void valueForGapScalesByDayCount() {
    Decimal value = BulkGapFillService.valueForGap(
      100,
      range(Date.newInstance(2025, 4, 1), Date.newInstance(2025, 4, 30))
    );

    Assert.areEqual(3000, value, '100 per day over 30 inclusive days');
  }

  @IsTest
  static void daysWithDataCountsOverlapOnce() {
    List<BulkGapFillService.EnergyRecord> records = new List<BulkGapFillService.EnergyRecord>{
      rec('Electricity', YEAR_START, Date.newInstance(2025, 1, 31), 100),
      rec(
        'Electricity',
        Date.newInstance(2025, 1, 15),
        Date.newInstance(2025, 2, 14),
        100
      ),
      rec('Electricity', null, null, 100)
    };

    Assert.areEqual(
      45,
      BulkGapFillService.daysWithData(records),
      'Jan 1 through Feb 14'
    );
  }

  @IsTest
  static void totalConsumptionIgnoresNulls() {
    List<BulkGapFillService.EnergyRecord> records = new List<BulkGapFillService.EnergyRecord>{
      rec('Electricity', YEAR_START, YEAR_END, 100),
      rec('Electricity', YEAR_START, YEAR_END, null),
      rec('Electricity', YEAR_START, YEAR_END, 50)
    };

    Assert.areEqual(150, BulkGapFillService.totalConsumption(records));
  }

  @IsTest
  static void floorAreaConvertsFromSquareFeet() {
    Decimal sqm = BulkGapFillConstants.toSquareMetres(10763.9, 'sqft');

    Assert.areEqual(1000, sqm.setScale(0), '10763.9 sqft is about 1000 m2');
    Assert.areEqual(
      1000,
      BulkGapFillConstants.toSquareMetres(1000, 'm2'),
      'Metric passes through'
    );
    Assert.isNull(BulkGapFillConstants.toSquareMetres(null, 'sqft'));
  }

  @IsTest
  static void benchmarkNormalizesToKwhPerSquareMetre() {
    Assert.areEqual(
      200,
      BulkGapFillConstants.toKwhPerSquareMetre(200, 18.58),
      'The metric figure wins when both are populated'
    );

    Decimal converted = BulkGapFillConstants.toKwhPerSquareMetre(null, 10);
    Assert.areEqual(107.639, converted, '10 kWh/sqft is 107.639 kWh/m2');

    Assert.isNull(
      BulkGapFillConstants.toKwhPerSquareMetre(null, null),
      'Neither unit populated leaves the benchmark unresolved'
    );
  }
}
