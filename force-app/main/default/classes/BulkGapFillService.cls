/**
 * @description Stateless gap detection and fill calculation logic for bulk gap filling.
 *
 * The algorithmic core here deliberately works on plain `DateRange` / `EnergyRecord`
 * wrappers rather than Net Zero Cloud SObjects, so it can be unit tested without
 * NZC data and reused from the batch, the controller preview, and future
 * invocable actions alike. `BulkGapFillBatch` is responsible for querying records
 * and mapping them into these wrappers.
 *
 * **Date convention:** all ranges are inclusive of both endpoints, so a record
 * covering Jan 1 - Jan 31 covers 31 days. The native wizard's published formula
 * uses `EndDate - StartDate` (exclusive, 30 days); the inclusive reading is used
 * here because it leaves no uncovered single days between consecutive bills.
 *
 * @group Bulk Gap Fill
 * @see BulkGapFillBatch
 * @see BulkGapFillConstants
 * @example
 * ```apex
 * // Find the uncovered stretches of a reporting year.
 * List<BulkGapFillService.DateRange> gaps = BulkGapFillService.detectGaps(
 *     Date.newInstance(2025, 1, 1),
 *     Date.newInstance(2025, 12, 31),
 *     covered
 * );
 *
 * // Then price each gap at the method's daily rate.
 * Decimal rate = BulkGapFillService.resolveDailyRate(ctx);
 * for (BulkGapFillService.DateRange gap : gaps) {
 *     Decimal estimated = BulkGapFillService.valueForGap(rate, gap);
 * }
 * ```
 */
public with sharing class BulkGapFillService {
  /**
   * @description Raised when the requested fill method cannot be applied to an
   * asset, for example a BEI method with no benchmark populated. Callers are
   * expected to catch this and record a skipped result rather than abort the run.
   */
  public class FillNotViableException extends Exception {
  }

  // ---- Value types ------------------------------------------------------

  /**
   * @description An inclusive date range. Sorts by start date, then end date.
   */
  public class DateRange implements Comparable {
    @AuraEnabled
    public Date startDate { get; set; }
    @AuraEnabled
    public Date endDate { get; set; }

    public DateRange(Date startDate, Date endDate) {
      this.startDate = startDate;
      this.endDate = endDate;
    }

    /**
     * @description Inclusive day count, so Jan 1 - Jan 31 is 31 days.
     */
    @AuraEnabled
    public Integer days {
      get {
        return startDate.daysBetween(endDate) + 1;
      }
    }

    /**
     * @description Whether this range shares at least one day with another.
     * @param other The range to compare against.
     * @return True when the two ranges intersect.
     */
    public Boolean overlaps(DateRange other) {
      return this.startDate <= other.endDate && other.startDate <= this.endDate;
    }

    /**
     * @description Orders ranges by start date, breaking ties on end date.
     * @param other The `DateRange` to compare against.
     * @return -1, 0, or 1 in the usual `Comparable` sense.
     */
    public Integer compareTo(Object other) {
      DateRange that = (DateRange) other;
      if (this.startDate == that.startDate) {
        return this.endDate < that.endDate
          ? -1
          : (this.endDate == that.endDate ? 0 : 1);
      }
      return this.startDate < that.startDate ? -1 : 1;
    }
  }

  /**
   * @description A single existing energy use record, flattened for the algorithm
   * so gap detection never touches an SObject directly.
   */
  public class EnergyRecord {
    public Id recordId;
    public String fuelType;
    public Date startDate;
    public Date endDate;
    public Decimal consumption;
    public String consumptionUnit;
    public Boolean isGapFilled;

    /**
     * @description Whether this record can take part in gap detection.
     * @return True when both dates are present and not inverted.
     */
    public Boolean hasUsableDates() {
      return startDate != null && endDate != null && startDate <= endDate;
    }

    /**
     * @description Expresses this record's consumption period as a range.
     * @return A `DateRange` spanning `startDate` to `endDate`.
     */
    public DateRange toRange() {
      return new DateRange(startDate, endDate);
    }
  }

  /**
   * @description A data quality problem that blocks or distorts gap detection,
   * surfaced to the user rather than silently worked around.
   */
  public class DateIssue {
    @AuraEnabled
    public Id recordId;
    @AuraEnabled
    public String issueType; // MissingStartDate | MissingEndDate | InvertedRange | Overlap
    @AuraEnabled
    public String message;

    /**
     * @description Creates a date issue.
     * @param recordId The energy use record the issue was found on.
     * @param issueType One of `MissingStartDate`, `MissingEndDate`,
     *        `InvertedRange`, or `Overlap`.
     * @param message Human-readable explanation for the results grid.
     */
    public DateIssue(Id recordId, String issueType, String message) {
      this.recordId = recordId;
      this.issueType = issueType;
      this.message = message;
    }
  }

  /**
   * @description Gap detection outcome for one carbon footprint and one fuel type.
   */
  public class FuelGapSet {
    @AuraEnabled
    public String fuelType;
    @AuraEnabled
    public List<DateRange> gaps = new List<DateRange>();
    @AuraEnabled
    public List<DateIssue> dateIssues = new List<DateIssue>();
    @AuraEnabled
    public String consumptionUnit;

    /**
     * @description Sum of the inclusive day counts of every detected gap.
     */
    @AuraEnabled
    public Integer totalGapDays {
      get {
        Integer total = 0;
        for (DateRange gap : gaps) {
          total += gap.days;
        }
        return total;
      }
    }
  }

  /**
   * @description Inputs needed to derive a daily consumption rate for one fuel
   * type. Only the fields relevant to the chosen `method` need to be populated.
   */
  public class FillContext {
    public String method;
    public String fuelType;

    /** BEI benchmark in kWh per square metre per year. */
    public Decimal beiValue;

    /** Occupied floor area, already normalized to square metres. */
    public Decimal occupiedFloorAreaSqM;

    /** Total consumption recorded in the prior reporting year, same fuel type. */
    public Decimal priorYearTotal;

    /** Total consumption recorded so far this year, same fuel type. */
    public Decimal currentYearTotal;

    /** Days actually covered by current year records, same fuel type. */
    public Integer currentYearDaysWithData;

    /** Operator-supplied daily rate, used when method is Manual. */
    public Decimal manualDailyRate;
  }

  // ---- Gap detection ----------------------------------------------------

  /**
   * @description Collapses overlapping and adjacent ranges into a minimal
   * covering set. Ranges touching end-to-start on consecutive days are merged,
   * since a bill ending Jan 31 and one starting Feb 1 leave no gap between them.
   * @param ranges The ranges to collapse. Null or empty returns an empty list.
   * @return A sorted, non-overlapping covering set.
   */
  public static List<DateRange> mergeRanges(List<DateRange> ranges) {
    List<DateRange> merged = new List<DateRange>();
    if (ranges == null || ranges.isEmpty()) {
      return merged;
    }

    List<DateRange> sorted = ranges.clone();
    sorted.sort();

    DateRange current = new DateRange(sorted[0].startDate, sorted[0].endDate);
    for (Integer i = 1; i < sorted.size(); i++) {
      DateRange next = sorted[i];
      if (next.startDate <= current.endDate.addDays(1)) {
        if (next.endDate > current.endDate) {
          current.endDate = next.endDate;
        }
      } else {
        merged.add(current);
        current = new DateRange(next.startDate, next.endDate);
      }
    }
    merged.add(current);
    return merged;
  }

  /**
   * @description Returns the sub-ranges of the reporting period not covered by
   * any of the supplied ranges. Coverage falling outside the period is clipped
   * rather than counted.
   * @param periodStart First day of the reporting period, inclusive.
   * @param periodEnd Last day of the reporting period, inclusive.
   * @param covered Ranges already covered by existing energy use records.
   * @return The uncovered ranges, in chronological order. Empty when the period
   *         is fully covered or the period itself is invalid.
   */
  public static List<DateRange> detectGaps(
    Date periodStart,
    Date periodEnd,
    List<DateRange> covered
  ) {
    List<DateRange> gaps = new List<DateRange>();
    if (periodStart == null || periodEnd == null || periodStart > periodEnd) {
      return gaps;
    }

    // Clip coverage to the reporting period before merging.
    List<DateRange> clipped = new List<DateRange>();
    if (covered != null) {
      for (DateRange range : covered) {
        if (range == null || range.startDate == null || range.endDate == null) {
          continue;
        }
        if (range.endDate < periodStart || range.startDate > periodEnd) {
          continue;
        }
        clipped.add(
          new DateRange(
            range.startDate < periodStart ? periodStart : range.startDate,
            range.endDate > periodEnd ? periodEnd : range.endDate
          )
        );
      }
    }

    List<DateRange> merged = mergeRanges(clipped);
    if (merged.isEmpty()) {
      gaps.add(new DateRange(periodStart, periodEnd));
      return gaps;
    }

    Date cursor = periodStart;
    for (DateRange range : merged) {
      if (range.startDate > cursor) {
        gaps.add(new DateRange(cursor, range.startDate.addDays(-1)));
      }
      if (range.endDate >= cursor) {
        cursor = range.endDate.addDays(1);
      }
    }
    if (cursor <= periodEnd) {
      gaps.add(new DateRange(cursor, periodEnd));
    }
    return gaps;
  }

  /**
   * @description Flags records that cannot take part in gap detection (missing or
   * inverted dates) and records whose periods overlap another record of the same
   * fuel type. Records of different fuel types may freely share a period.
   * @param records The energy use records to inspect.
   * @return One issue per problem found. Empty when the data is clean.
   */
  public static List<DateIssue> detectDateIssues(List<EnergyRecord> records) {
    List<DateIssue> issues = new List<DateIssue>();
    if (records == null || records.isEmpty()) {
      return issues;
    }

    List<EnergyRecord> usable = new List<EnergyRecord>();
    for (EnergyRecord rec : records) {
      if (rec.startDate == null) {
        issues.add(
          new DateIssue(
            rec.recordId,
            'MissingStartDate',
            'Record has no start date.'
          )
        );
      } else if (rec.endDate == null) {
        issues.add(
          new DateIssue(
            rec.recordId,
            'MissingEndDate',
            'Record has no end date.'
          )
        );
      } else if (rec.startDate > rec.endDate) {
        issues.add(
          new DateIssue(
            rec.recordId,
            'InvertedRange',
            'Start date is after end date.'
          )
        );
      } else {
        usable.add(rec);
      }
    }

    for (Integer i = 0; i < usable.size(); i++) {
      for (Integer j = i + 1; j < usable.size(); j++) {
        EnergyRecord a = usable[i];
        EnergyRecord b = usable[j];
        if (a.fuelType == b.fuelType && a.toRange().overlaps(b.toRange())) {
          issues.add(
            new DateIssue(
              a.recordId,
              'Overlap',
              'Period overlaps record ' +
                b.recordId +
                ' for fuel type ' +
                a.fuelType +
                '.'
            )
          );
        }
      }
    }
    return issues;
  }

  /**
   * @description Full gap detection for one carbon footprint: groups records by
   * fuel type, then detects gaps and date issues within each group.
   * @param periodStart First day of the reporting period, inclusive.
   * @param periodEnd Last day of the reporting period, inclusive.
   * @param records Every energy use record on the footprint, any fuel type.
   * @param fuelTypeFilter When non-empty, restricts output to these fuel types and
   *        guarantees a result even for a fuel type with no records at all — an
   *        entirely unbilled fuel type is a whole-period gap, not an absence of work.
   * @return One `FuelGapSet` per fuel type in scope.
   */
  public static List<FuelGapSet> analyzeFootprint(
    Date periodStart,
    Date periodEnd,
    List<EnergyRecord> records,
    Set<String> fuelTypeFilter
  ) {
    Map<String, List<EnergyRecord>> byFuel = new Map<String, List<EnergyRecord>>();
    if (records != null) {
      for (EnergyRecord rec : records) {
        if (
          fuelTypeFilter != null &&
          !fuelTypeFilter.isEmpty() &&
          !fuelTypeFilter.contains(rec.fuelType)
        ) {
          continue;
        }
        if (!byFuel.containsKey(rec.fuelType)) {
          byFuel.put(rec.fuelType, new List<EnergyRecord>());
        }
        byFuel.get(rec.fuelType).add(rec);
      }
    }

    // An explicitly requested fuel type with zero records is a whole-year gap,
    // not an absence of work.
    if (fuelTypeFilter != null) {
      for (String fuelType : fuelTypeFilter) {
        if (!byFuel.containsKey(fuelType)) {
          byFuel.put(fuelType, new List<EnergyRecord>());
        }
      }
    }

    List<FuelGapSet> results = new List<FuelGapSet>();
    for (String fuelType : byFuel.keySet()) {
      List<EnergyRecord> fuelRecords = byFuel.get(fuelType);

      FuelGapSet gapSet = new FuelGapSet();
      gapSet.fuelType = fuelType;
      gapSet.dateIssues = detectDateIssues(fuelRecords);

      List<DateRange> covered = new List<DateRange>();
      for (EnergyRecord rec : fuelRecords) {
        if (rec.hasUsableDates()) {
          covered.add(rec.toRange());
        }
        if (
          gapSet.consumptionUnit == null &&
          String.isNotBlank(rec.consumptionUnit)
        ) {
          gapSet.consumptionUnit = rec.consumptionUnit;
        }
      }

      gapSet.gaps = detectGaps(periodStart, periodEnd, covered);
      results.add(gapSet);
    }
    return results;
  }

  // ---- Fill calculation -------------------------------------------------

  /**
   * @description Derives the daily consumption rate for a fill method.
   *
   * | Method | Formula |
   * |---|---|
   * | Regional BEI | `(beiValue * occupiedFloorAreaSqM) / 365` |
   * | Building BEI | `(beiValue * occupiedFloorAreaSqM) / 365` |
   * | Previous Year Daily Average | `priorYearTotal / 365` |
   * | Current Year Daily Average | `currentYearTotal / currentYearDaysWithData` |
   * | Manual | `manualDailyRate` |
   *
   * @param ctx The inputs for the chosen method.
   * @return The estimated consumption per day.
   * @throws FillNotViableException When the method's prerequisites are missing, so
   *         the caller can record a skipped row and carry on rather than writing a
   *         silently wrong estimate.
   */
  public static Decimal resolveDailyRate(FillContext ctx) {
    if (ctx == null || String.isBlank(ctx.method)) {
      throw new FillNotViableException('No fill method supplied.');
    }

    if (BulkGapFillConstants.METHOD_MANUAL.equals(ctx.method)) {
      if (ctx.manualDailyRate == null) {
        throw new FillNotViableException(
          'Manual fill selected but no daily rate was provided.'
        );
      }
      return ctx.manualDailyRate;
    }

    if (
      BulkGapFillConstants.METHOD_REGIONAL_BEI.equals(ctx.method) ||
      BulkGapFillConstants.METHOD_BUILDING_BEI.equals(ctx.method)
    ) {
      String label = BulkGapFillConstants.METHOD_REGIONAL_BEI.equals(ctx.method)
        ? 'Regional BEI'
        : 'Building BEI';
      if (ctx.beiValue == null) {
        throw new FillNotViableException(
          label +
          ' fill requires a benchmark on the carbon footprint record, but none is populated.'
        );
      }
      if (ctx.occupiedFloorAreaSqM == null || ctx.occupiedFloorAreaSqM <= 0) {
        throw new FillNotViableException(
          label +
          ' fill requires a positive occupied floor area on the stationary asset.'
        );
      }
      return (ctx.beiValue * ctx.occupiedFloorAreaSqM) /
        BulkGapFillConstants.DAYS_PER_YEAR;
    }

    if (BulkGapFillConstants.METHOD_PREVIOUS_YEAR.equals(ctx.method)) {
      if (ctx.priorYearTotal == null || ctx.priorYearTotal <= 0) {
        throw new FillNotViableException(
          'No prior year consumption found for fuel type ' + ctx.fuelType + '.'
        );
      }
      return ctx.priorYearTotal / BulkGapFillConstants.DAYS_PER_YEAR;
    }

    if (BulkGapFillConstants.METHOD_CURRENT_YEAR.equals(ctx.method)) {
      if (
        ctx.currentYearDaysWithData == null ||
        ctx.currentYearDaysWithData <= 0
      ) {
        throw new FillNotViableException(
          'No current year records with usable dates for fuel type ' +
            ctx.fuelType +
            '.'
        );
      }
      if (ctx.currentYearTotal == null || ctx.currentYearTotal <= 0) {
        throw new FillNotViableException(
          'Current year records for fuel type ' +
            ctx.fuelType +
            ' carry no consumption.'
        );
      }
      return ctx.currentYearTotal / ctx.currentYearDaysWithData;
    }

    throw new FillNotViableException('Unsupported fill method: ' + ctx.method);
  }

  /**
   * @description Estimated consumption for one gap at the given daily rate.
   * @param dailyRate Consumption per day, typically from `resolveDailyRate`.
   * @param gap The uncovered range to price.
   * @return The estimate, rounded to six decimal places, or null if either
   *         argument is null.
   */
  public static Decimal valueForGap(Decimal dailyRate, DateRange gap) {
    if (dailyRate == null || gap == null) {
      return null;
    }
    return (dailyRate * gap.days).setScale(6, System.RoundingMode.HALF_UP);
  }

  /**
   * @description Days covered by the supplied records, counting overlapping
   * periods only once. Records with unusable dates are ignored.
   * @param records The energy use records to measure.
   * @return The number of distinct days with data.
   */
  public static Integer daysWithData(List<EnergyRecord> records) {
    List<DateRange> ranges = new List<DateRange>();
    if (records != null) {
      for (EnergyRecord rec : records) {
        if (rec.hasUsableDates()) {
          ranges.add(rec.toRange());
        }
      }
    }
    Integer total = 0;
    for (DateRange range : mergeRanges(ranges)) {
      total += range.days;
    }
    return total;
  }

  /**
   * @description Sum of consumption across the supplied records, ignoring nulls.
   * @param records The energy use records to total.
   * @return The summed consumption, or zero when there is nothing to add.
   */
  public static Decimal totalConsumption(List<EnergyRecord> records) {
    Decimal total = 0;
    if (records != null) {
      for (EnergyRecord rec : records) {
        if (rec.consumption != null) {
          total += rec.consumption;
        }
      }
    }
    return total;
  }
}
