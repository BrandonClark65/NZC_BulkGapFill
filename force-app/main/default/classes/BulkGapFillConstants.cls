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
  public static final String OBJ_FOOTPRINT = 'StationaryAssetCarbonFootprint';
  public static final String OBJ_ENERGY_USE = 'StationaryAssetEnergyUse';
  public static final String OBJ_BUILDING_BEI = 'BldgEnergyIntensityValue';
  public static final String OBJ_REGIONAL_BEI = 'RegionalBldgEnergyIntensity';

  // Field holding the benchmark itself, in kWh per square metre per year.
  // TODO: verify against the target org - the BEI objects expose several
  // intensity fields and the correct one depends on how BEI Builder was configured.
  public static final String FIELD_BUILDING_BEI_VALUE = 'EnergyIntensityValue';
  public static final String FIELD_REGIONAL_BEI_VALUE = 'EnergyIntensityValue';

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
      OBJ_BUILDING_BEI,
      OBJ_REGIONAL_BEI
    };
    for (String objName : required) {
      if (!globals.containsKey(objName)) {
        problems.add('Object not found or not accessible: ' + objName);
      }
    }

    problems.addAll(
      checkField(globals, OBJ_BUILDING_BEI, FIELD_BUILDING_BEI_VALUE)
    );
    problems.addAll(
      checkField(globals, OBJ_REGIONAL_BEI, FIELD_REGIONAL_BEI_VALUE)
    );
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
