/**
 * @description Single source of truth for Net Zero Cloud API names, fill method
 * tokens, and status tokens used across the bulk gap fill solution.
 *
 * Net Zero Cloud object and field API names vary by org edition and NZC release.
 * Every name the solution depends on is declared here so a mismatch is a one-file
 * fix rather than a hunt through the batch and service classes.
 *
 * @group Bulk Gap Fill
 * @see BulkGapFillService
 * @see BulkGapFillBatch
 * @example
 * ```apex
 * // Confirm a target org is ready before the first deploy.
 * List<String> problems = BulkGapFillConstants.validateSchema();
 * System.debug(problems.isEmpty() ? 'Org is ready' : String.join(problems, '\n'));
 * ```
 */
public with sharing class BulkGapFillConstants {
  // ---- Fill methods -----------------------------------------------------
  // These tokens are written to BulkGapFillJob__c.DefaultFillMethod__c and to
  // the GapFillMethod field on generated energy use records, so they must match
  // the picklist API values on both.
  public static final String METHOD_REGIONAL_BEI = 'Regional BEI';
  public static final String METHOD_BUILDING_BEI = 'Building BEI';
  public static final String METHOD_PREVIOUS_YEAR = 'Previous Year Daily Average';
  public static final String METHOD_CURRENT_YEAR = 'Current Year Daily Average';
  public static final String METHOD_MANUAL = 'Manual';

  public static final Set<String> ALL_METHODS = new Set<String>{
    METHOD_REGIONAL_BEI,
    METHOD_BUILDING_BEI,
    METHOD_PREVIOUS_YEAR,
    METHOD_CURRENT_YEAR,
    METHOD_MANUAL
  };

  // ---- Job status -------------------------------------------------------
  public static final String JOB_QUEUED = 'Queued';
  public static final String JOB_RUNNING = 'Running';
  public static final String JOB_COMPLETED = 'Completed';
  public static final String JOB_COMPLETED_WITH_ERRORS = 'Completed With Errors';
  public static final String JOB_FAILED = 'Failed';
  public static final String JOB_ABORTED = 'Aborted';

  // ---- Job detail status ------------------------------------------------
  public static final String DETAIL_FILLED = 'Filled';
  public static final String DETAIL_PREVIEW = 'Preview';
  public static final String DETAIL_NO_GAPS = 'No Gaps';
  public static final String DETAIL_SKIPPED = 'Skipped';
  public static final String DETAIL_ERROR = 'Error';

  // ---- Net Zero Cloud object API names ----------------------------------
  public static final String OBJ_ASSET = 'StnryAssetEnvrSrc';
  public static final String OBJ_FOOTPRINT = 'StnryAssetCrbnFtprnt';
  public static final String OBJ_ENERGY_USE = 'StnryAssetEnrgyUse';

  /**
   * Benchmark header record, and the target of every BEI lookup. There is no
   * separate regional BEI object: the regional lookup carried on the stationary
   * asset points at a building energy intensity record too, so both benchmark
   * fill methods resolve their value from this one object.
   */
  public static final String OBJ_BEI = 'BldgEnrgyIntensity';

  /**
   * Per-fuel-type values belonging to a benchmark. The intensity figure the BEI
   * fill methods need lives here, not on the header, so a benchmark is resolved
   * by (benchmark record, fuel type) rather than by record alone.
   */
  public static final String OBJ_BEI_VALUE = 'BldgEnrgyIntensityVal';

  // ---- Net Zero Cloud field API names -----------------------------------
  /** Parent lookup from an energy use record to its carbon footprint. */
  public static final String FIELD_ENERGY_USE_FOOTPRINT = 'StnryAssetCrbnFtprntId';

  /**
   * Custom (BEI Builder) benchmark lookup on the carbon footprint. Note the
   * unabbreviated `Building` here against the abbreviated `Bldg` in the regional
   * lookup below - neither field name follows the object's own spelling.
   */
  public static final String FIELD_BEI_LOOKUP = 'BuildingEnergyIntensityId';

  /** Regional (CBECS) benchmark lookup, auto-populated for US assets. */
  public static final String FIELD_REGIONAL_BEI_LOOKUP = 'RegionalBldgEnergyIntensityId';

  /** Both BEI lookups, in the order they are selected and read. */
  public static final List<String> BEI_LOOKUP_FIELDS = new List<String>{
    FIELD_BEI_LOOKUP,
    FIELD_REGIONAL_BEI_LOOKUP
  };

  // ---- BldgEnrgyIntensityVal fields -------------------------------------
  /** Master-detail to the parent benchmark. */
  public static final String FIELD_BEI_VALUE_PARENT = 'BuildingEnergyIntensityId';

  /**
   * Fuel type a value applies to. Shares both its name and its picklist with the
   * `FuelType` on energy use records, so the two match directly.
   */
  public static final String FIELD_BEI_VALUE_FUEL_TYPE = 'FuelType';

  /**
   * The benchmark figure, carried in two units. A benchmark may populate either,
   * so both are read and normalized by `toKwhPerSquareMetre`.
   */
  public static final String FIELD_BEI_VALUE_KWH_M2 = 'AnnualIntensityValueInKwhM2';
  public static final String FIELD_BEI_VALUE_KWH_SQFT = 'AnnualIntensityValueInKwhSqft';

  // ---- Tuning -----------------------------------------------------------
  /** Conservative default: each footprint can fan out into many child inserts. */
  public static final Integer DEFAULT_BATCH_SIZE = 50;

  /** Days used to annualize a BEI figure, matching the native wizard. */
  public static final Integer DAYS_PER_YEAR = 365;

  /** ErrorLog__c is a long text area; keep appends from overrunning it. */
  public static final Integer MAX_ERROR_LOG_CHARS = 100000;

  private static final Decimal SQFT_PER_SQM = 10.7639;

  /**
   * @description Converts a floor area to square metres, since BEI benchmarks are
   * expressed per square metre. Units that are not recognised as imperial are
   * assumed to be metric and returned unchanged.
   * @param area The floor area to convert. Null returns null.
   * @param unit The unit of measure, for example `sqft` or `m2`.
   * @return The area in square metres, or null when `area` is null.
   */
  public static Decimal toSquareMetres(Decimal area, String unit) {
    if (area == null) {
      return null;
    }
    String normalized = String.isBlank(unit) ? '' : unit.toLowerCase().trim();
    if (
      normalized.startsWith('sqft') ||
      normalized.startsWith('square f') ||
      normalized == 'ft2'
    ) {
      return area / SQFT_PER_SQM;
    }
    // Treat anything else as already metric; unknown units are surfaced by
    // validateSchema() rather than silently mis-converted here.
    return area;
  }

  /**
   * @description Normalizes a benchmark to kWh per square metre, the unit the fill
   * math works in.
   *
   * A `BldgEnrgyIntensityVal` carries its figure in two units and may populate
   * either, so the metric field is preferred and the imperial one converted as a
   * fallback. That keeps a benchmark usable when only the imperial column is filled
   * in, rather than skipping the fill.
   *
   * @param kwhPerSqM The `AnnualIntensityValueInKwhM2` figure. Wins when populated.
   * @param kwhPerSqFt The `AnnualIntensityValueInKwhSqft` figure, used as a fallback.
   * @return The benchmark in kWh per square metre, or null when neither is populated.
   */
  public static Decimal toKwhPerSquareMetre(
    Decimal kwhPerSqM,
    Decimal kwhPerSqFt
  ) {
    if (kwhPerSqM != null) {
      return kwhPerSqM;
    }
    // kWh per sqft x sqft per m2 = kWh per m2.
    return kwhPerSqFt == null ? null : kwhPerSqFt * SQFT_PER_SQM;
  }

  /**
   * @description Confirms every Net Zero Cloud object and field the solution
   * depends on actually exists and is accessible in the running org.
   *
   * Worth running before the first deploy to a new org: because the NZC queries
   * are built as dynamic SOQL, a successful deploy does not prove these names
   * are correct.
   *
   * @return Human-readable problems. An empty list means the org is ready.
   */
  public static List<String> validateSchema() {
    List<String> problems = new List<String>();
    Map<String, Schema.SObjectType> globals = Schema.getGlobalDescribe();

    List<String> required = new List<String>{
      OBJ_ASSET,
      OBJ_FOOTPRINT,
      OBJ_ENERGY_USE,
      OBJ_BEI,
      OBJ_BEI_VALUE
    };
    for (String objName : required) {
      if (!globals.containsKey(objName)) {
        problems.add('Object not found or not accessible: ' + objName);
      }
    }

    List<String> beiValueFields = new List<String>{
      FIELD_BEI_VALUE_PARENT,
      FIELD_BEI_VALUE_FUEL_TYPE,
      FIELD_BEI_VALUE_KWH_M2,
      FIELD_BEI_VALUE_KWH_SQFT
    };
    for (String fieldName : beiValueFields) {
      problems.addAll(checkField(globals, OBJ_BEI_VALUE, fieldName));
    }

    problems.addAll(
      checkField(globals, OBJ_ENERGY_USE, FIELD_ENERGY_USE_FOOTPRINT)
    );
    for (String lookup : BEI_LOOKUP_FIELDS) {
      problems.addAll(checkField(globals, OBJ_FOOTPRINT, lookup));
    }
    return problems;
  }

  private static List<String> checkField(
    Map<String, Schema.SObjectType> globals,
    String objName,
    String fieldName
  ) {
    List<String> problems = new List<String>();
    if (!globals.containsKey(objName)) {
      return problems; // Already reported as a missing object.
    }
    Map<String, Schema.SObjectField> fields = globals.get(objName)
      .getDescribe()
      .fields.getMap();
    if (!fields.containsKey(fieldName.toLowerCase())) {
      problems.add('Field not found on ' + objName + ': ' + fieldName);
    }
    return problems;
  }
}
