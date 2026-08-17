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
  // DataGapFillingMethodName on generated energy use records, so they must match
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

  /**
   * Maps each internal fill method token onto the `DataGapFillingMethodName`
   * values that mean the same thing, most authoritative first.
   *
   * That field is a standard restricted picklist owned by Net Zero Cloud, so the
   * values it accepts are Salesforce's and do not match the tokens above — writing
   * a token straight into it fails the insert with "bad value for restricted
   * picklist field". The API value is listed first because it is stable: labels
   * are translated for the running user's language and can be renamed in Setup,
   * so matching one is a fallback rather than the plan.
   *
   * Add a spelling here rather than editing the tokens, which are also stored in
   * `BulkGapFillJob__c.DefaultFillMethod__c` and would break existing job records.
   */
  private static final Map<String, List<String>> METHOD_PICKLIST_ALIASES = new Map<String, List<String>>{
    METHOD_REGIONAL_BEI => new List<String>{
      'REGIONAL_BENCHMARK',
      'Regional Building Energy Intensity'
    },
    METHOD_BUILDING_BEI => new List<String>{
      'BUILDING_BENCHMARK',
      'Building Energy Intensity'
    },
    METHOD_PREVIOUS_YEAR => new List<String>{
      'DAILY_AVERAGE_LAST_YEAR',
      'Previous Year Daily Average'
    },
    METHOD_CURRENT_YEAR => new List<String>{
      'DAILY_AVERAGE_CURRENT_YEAR',
      'Current Year Daily Average'
    },
    METHOD_MANUAL => new List<String>{ 'MANUAL' }
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

  // ---- StnryAssetCrbnFtprnt fields --------------------------------------
  /** Parent asset lookup. */
  public static final String FIELD_FOOTPRINT_ASSET = 'StnryAssetEnvrSrcId';

  /** Reporting year, the primary scope filter for a run. */
  public static final String FIELD_FOOTPRINT_YEAR = 'ReportingYear';

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

  /** Relationship name for traversing a footprint to its stationary asset. */
  public static final String REL_FOOTPRINT_ASSET = 'StnryAssetEnvrSrc';

  /** Footprint fields the batch selects, beyond `Id`. */
  public static final List<String> FOOTPRINT_FIELDS = new List<String>{
    FIELD_FOOTPRINT_ASSET,
    FIELD_FOOTPRINT_YEAR,
    FIELD_BEI_LOOKUP,
    FIELD_REGIONAL_BEI_LOOKUP
  };

  // ---- StnryAssetEnvrSrc fields -----------------------------------------
  public static final String FIELD_ASSET_NAME = 'Name';
  public static final String FIELD_ASSET_TYPE = 'StationaryAssetType';
  public static final String FIELD_ASSET_FLOOR_AREA = 'OccupiedFloorArea';
  public static final String FIELD_ASSET_FLOOR_AREA_UNIT = 'OccupiedFloorAreaUnit';

  /** Asset fields the batch selects through `REL_FOOTPRINT_ASSET`. */
  public static final List<String> ASSET_FIELDS = new List<String>{
    FIELD_ASSET_NAME,
    FIELD_ASSET_TYPE,
    FIELD_ASSET_FLOOR_AREA,
    FIELD_ASSET_FLOOR_AREA_UNIT
  };

  // ---- StnryAssetEnrgyUse fields ----------------------------------------
  /** Parent lookup from an energy use record to its carbon footprint. */
  public static final String FIELD_ENERGY_USE_FOOTPRINT = 'StnryAssetCrbnFtprntId';

  /**
   * Lookup straight to the stationary asset. Required on insert alongside the
   * footprint lookup: an energy use record hangs off both, and omitting this one
   * fails the record with REQUIRED_FIELD_MISSING rather than orphaning it.
   */
  public static final String FIELD_ENERGY_USE_ASSET = 'StnryAssetEnvrSrcId';

  /** Also required on insert; generated records get a descriptive name. */
  public static final String FIELD_ENERGY_USE_NAME = 'Name';

  public static final String FIELD_ENERGY_USE_FUEL_TYPE = 'FuelType';
  public static final String FIELD_ENERGY_USE_START = 'StartDate';
  public static final String FIELD_ENERGY_USE_END = 'EndDate';
  public static final String FIELD_ENERGY_USE_CONSUMPTION = 'FuelConsumption';
  public static final String FIELD_ENERGY_USE_CONSUMPTION_UNIT = 'FuelConsumptionUnit';

  /**
   * Marks a record as generated rather than measured. This is what the native gap
   * fill process sets, so the batch sets it too and reads it to tell estimates from
   * actuals — there is no gap-filled boolean of its own on the object.
   */
  public static final String FIELD_ENERGY_USE_IS_SYSTEM_GENERATED = 'IsSystemGeneratedRecord';

  /** Which fill method produced a record, for the audit trail. */
  public static final String FIELD_ENERGY_USE_FILL_METHOD = 'DataGapFillingMethodName';

  /** Energy use fields the batch selects, beyond `Id`. */
  public static final List<String> ENERGY_USE_FIELDS = new List<String>{
    FIELD_ENERGY_USE_NAME,
    FIELD_ENERGY_USE_FOOTPRINT,
    FIELD_ENERGY_USE_ASSET,
    FIELD_ENERGY_USE_FUEL_TYPE,
    FIELD_ENERGY_USE_START,
    FIELD_ENERGY_USE_END,
    FIELD_ENERGY_USE_CONSUMPTION,
    FIELD_ENERGY_USE_CONSUMPTION_UNIT,
    FIELD_ENERGY_USE_IS_SYSTEM_GENERATED,
    FIELD_ENERGY_USE_FILL_METHOD
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
   * @description Converts a reporting year for use as a SOQL bind.
   *
   * `ReportingYear` is a **text** column on the Net Zero Cloud objects, so binding
   * the Integer the request carries fails at runtime with "invalid bind expression
   * type of Integer for column of type String". Every NZC query filtering on the
   * year goes through here; `BulkGapFillJob__c.ReportingYear__c` is our own Number
   * field and is unaffected.
   *
   * @param year The reporting year, or null.
   * @return The year as text, or null when `year` is null.
   */
  public static String reportingYearBind(Integer year) {
    return year == null ? null : String.valueOf(year);
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

  // ---- Fill method picklist resolution ----------------------------------

  /** Resolved once per transaction; describe calls are not free. */
  private static Map<String, String> methodPicklistCache;

  /**
   * @description Maps an internal fill method token onto the value this org's
   * `DataGapFillingMethodName` picklist will actually accept.
   *
   * The field is a standard restricted picklist, so its values belong to Net Zero
   * Cloud rather than to us and vary by release. Resolving against a live describe
   * keeps that difference in one place instead of hardcoding a literal that fails
   * the same way the token did.
   *
   * @param method An internal token, for example `METHOD_CURRENT_YEAR`.
   * @return The value to write: the org's matching picklist value, `method`
   *         unchanged when the field is not a picklist in this org, or null when
   *         nothing matches. Callers must treat null as "leave the field unset"
   *         rather than write it, or the insert fails.
   */
  public static String gapFillMethodPicklistValue(String method) {
    if (String.isBlank(method)) {
      return null;
    }
    if (methodPicklistCache == null) {
      methodPicklistCache = buildMethodPicklistMap();
    }
    return methodPicklistCache.get(method);
  }

  /**
   * @description The active values this org's `DataGapFillingMethodName` picklist
   * accepts, for surfacing in schema warnings.
   * @return The active picklist values, or an empty list when the field is absent
   *         or is not a picklist here.
   */
  public static List<String> gapFillMethodPicklistOptions() {
    List<String> values = new List<String>();
    Schema.DescribeFieldResult field = describeFillMethodField();
    if (field == null) {
      return values;
    }
    for (Schema.PicklistEntry entry : field.getPicklistValues()) {
      if (entry.isActive()) {
        values.add(entry.getValue());
      }
    }
    return values;
  }

  private static Map<String, String> buildMethodPicklistMap() {
    Map<String, String> resolved = new Map<String, String>();

    Schema.DescribeFieldResult field = describeFillMethodField();
    if (field == null) {
      return resolved; // Missing field; validateSchema reports it separately.
    }

    List<Schema.PicklistEntry> entries = field.getPicklistValues();
    if (entries.isEmpty()) {
      // Not a picklist in this org, so there is nothing to restrict the value and
      // the token can be written through unchanged.
      for (String method : ALL_METHODS) {
        resolved.put(method, method);
      }
      return resolved;
    }

    // Match on value and on label: orgs differ in which one carries the wording
    // an admin would recognise.
    Map<String, String> byNormalized = new Map<String, String>();
    for (Schema.PicklistEntry entry : entries) {
      if (!entry.isActive()) {
        continue;
      }
      byNormalized.put(normalizeToken(entry.getValue()), entry.getValue());
      byNormalized.put(normalizeToken(entry.getLabel()), entry.getValue());
    }

    for (String method : ALL_METHODS) {
      String match = null;
      if (METHOD_PICKLIST_ALIASES.containsKey(method)) {
        for (String alias : METHOD_PICKLIST_ALIASES.get(method)) {
          match = byNormalized.get(normalizeToken(alias));
          if (match != null) {
            break;
          }
        }
      }
      // The token is the last resort: it is our wording, not the org's, and it
      // only lands when it happens to coincide with a label.
      if (match == null) {
        match = byNormalized.get(normalizeToken(method));
      }
      if (match != null) {
        resolved.put(method, match);
      }
    }
    return resolved;
  }

  private static Schema.DescribeFieldResult describeFillMethodField() {
    Schema.SObjectType energyUse = Schema.getGlobalDescribe().get(OBJ_ENERGY_USE);
    if (energyUse == null) {
      return null;
    }
    Schema.SObjectField field = energyUse.getDescribe()
      .fields.getMap()
      .get(FIELD_ENERGY_USE_FILL_METHOD.toLowerCase());
    return field == null ? null : field.getDescribe();
  }

  /**
   * Reduces a value to letters and digits so wording differences that do not
   * change meaning — case, spaces, punctuation — still match.
   */
  private static String normalizeToken(String value) {
    return value == null ? '' : value.toLowerCase().replaceAll('[^a-z0-9]', '');
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

    // OBJ_BEI carries no fields of its own here — it is only a lookup target —
    // so it is checked for existence and nothing else.
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

    // Every field the batch reads or writes. These are the same lists the dynamic
    // SOQL is built from, so validation cannot drift from what actually runs.
    Map<String, List<String>> fieldsByObject = new Map<String, List<String>>{
      OBJ_ASSET => ASSET_FIELDS,
      OBJ_FOOTPRINT => FOOTPRINT_FIELDS,
      OBJ_ENERGY_USE => ENERGY_USE_FIELDS,
      OBJ_BEI_VALUE => new List<String>{
        FIELD_BEI_VALUE_PARENT,
        FIELD_BEI_VALUE_FUEL_TYPE,
        FIELD_BEI_VALUE_KWH_M2,
        FIELD_BEI_VALUE_KWH_SQFT
      }
    };

    for (String objName : fieldsByObject.keySet()) {
      for (String fieldName : fieldsByObject.get(objName)) {
        problems.addAll(checkField(globals, objName, fieldName));
      }
    }

    problems.addAll(checkFillMethodPicklist());
    return problems;
  }

  /**
   * Reports fill methods this org's `DataGapFillingMethodName` picklist will not
   * accept, and names the values it does. Checked here so the Configure page warns
   * before a run rather than after every insert in that run has already failed.
   */
  private static List<String> checkFillMethodPicklist() {
    List<String> problems = new List<String>();

    List<String> options = gapFillMethodPicklistOptions();
    if (options.isEmpty()) {
      // Either the field is absent, already reported above, or it is not a
      // picklist here — in which case there is nothing to violate.
      return problems;
    }

    List<String> unmapped = new List<String>();
    for (String method : ALL_METHODS) {
      if (gapFillMethodPicklistValue(method) == null) {
        unmapped.add(method);
      }
    }
    if (unmapped.isEmpty()) {
      return problems;
    }
    unmapped.sort();

    problems.add(
      'No value in ' +
        FIELD_ENERGY_USE_FILL_METHOD +
        ' on ' +
        OBJ_ENERGY_USE +
        ' matches these fill methods: ' +
        String.join(unmapped, ', ') +
        '. Records will still be created and flagged as system generated, but ' +
        'without a method stamp. Values this org accepts: ' +
        String.join(options, ', ') +
        '. Add the right spelling to METHOD_PICKLIST_ALIASES in ' +
        'BulkGapFillConstants to close the gap.'
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
