/**
 * @description Builds the Net Zero Cloud records the batch tests run against.
 *
 * Records are created through `Schema.getGlobalDescribe()` rather than with static
 * types, for the same reason `BulkGapFillBatch` queries dynamically: the package has
 * to compile in an org where Net Zero Cloud is not enabled. A static
 * `new StnryAssetEnvrSrc()` here would break that for the whole package.
 *
 * Every field set below is either required on insert or read by the batch. The
 * required ones — `Name` on each object, plus `StnryAssetEnvrSrcId` and `FuelType`
 * on energy use, and the benchmark lookup on an intensity value — come from
 * describing the objects, not from guesswork.
 *
 * @group Bulk Gap Fill
 * @see BulkGapFillBatchTest
 */
@IsTest
public class BulkGapFillTestData {
  /** An API value from the org's FuelType picklist, not the label "Electricity". */
  public static final String FUEL_ELECTRICITY = 'Electricity';
  public static final String FUEL_NATURAL_GAS = 'NaturalGas';
  public static final String UNIT_KWH = 'kWh';

  /**
   * @description Whether this org carries the Net Zero Cloud objects at all.
   * Tests that need fixtures skip themselves when it returns false, so the suite
   * stays green in a scratch org without NZC.
   * @return True when every object the fixtures touch is present.
   */
  public static Boolean isNetZeroCloudAvailable() {
    for (
      String objectName : new List<String>{
        BulkGapFillConstants.OBJ_ASSET,
        BulkGapFillConstants.OBJ_FOOTPRINT,
        BulkGapFillConstants.OBJ_ENERGY_USE,
        BulkGapFillConstants.OBJ_BEI,
        BulkGapFillConstants.OBJ_BEI_VALUE
      }
    ) {
      if (Schema.getGlobalDescribe().get(objectName) == null) {
        return false;
      }
    }
    return true;
  }

  private static SObject blank(String objectName) {
    return Schema.getGlobalDescribe().get(objectName).newSObject();
  }

  /**
   * Resolves a record type by name, returning null when the object has no such
   * type. Null is a valid RecordTypeId — it falls back to the default.
   */
  private static Id recordTypeId(String objectName, String recordTypeName) {
    Schema.SObjectType sobjType = Schema.getGlobalDescribe().get(objectName);
    if (sobjType == null) {
      return null;
    }
    Schema.RecordTypeInfo info = sobjType.getDescribe()
      .getRecordTypeInfosByName()
      .get(recordTypeName);
    return info == null || !info.isAvailable() ? null : info.getRecordTypeId();
  }

  /**
   * @description Inserts a stationary asset.
   * @param name Asset name.
   * @param assetType A `StationaryAssetType` picklist value, or null.
   * @param floorArea Occupied floor area, or null.
   * @param floorAreaUnit `m2` or `sqft`, or null.
   * @return The inserted asset.
   */
  public static SObject asset(
    String name,
    String assetType,
    Decimal floorArea,
    String floorAreaUnit
  ) {
    SObject rec = blank(BulkGapFillConstants.OBJ_ASSET);
    rec.put(BulkGapFillConstants.FIELD_ASSET_NAME, name);
    if (assetType != null) {
      rec.put(BulkGapFillConstants.FIELD_ASSET_TYPE, assetType);
    }
    if (floorArea != null) {
      rec.put(BulkGapFillConstants.FIELD_ASSET_FLOOR_AREA, floorArea);
      rec.put(BulkGapFillConstants.FIELD_ASSET_FLOOR_AREA_UNIT, floorAreaUnit);
    }
    Id commercialBuilding = recordTypeId(
      BulkGapFillConstants.OBJ_ASSET,
      'Commercial Building'
    );
    if (commercialBuilding != null) {
      rec.put('RecordTypeId', commercialBuilding);
    }
    insert rec;
    return rec;
  }

  /** @description A Commercial Building office with 1,000 m2 of occupied floor area. */
  public static SObject asset(String name) {
    return asset(name, 'Office', 1000, 'm2');
  }

  /**
   * @description Inserts a carbon footprint for an asset and year.
   * @param assetId Parent stationary asset.
   * @param reportingYear The year. Bound as text, since `ReportingYear` is a string
   *        column on the Net Zero Cloud objects.
   * @return The inserted footprint.
   */
  public static SObject footprint(Id assetId, Integer reportingYear) {
    SObject rec = blank(BulkGapFillConstants.OBJ_FOOTPRINT);
    rec.put('Name', 'CFP ' + reportingYear + ' ' + assetId);
    rec.put(BulkGapFillConstants.FIELD_FOOTPRINT_ASSET, assetId);
    rec.put(
      BulkGapFillConstants.FIELD_FOOTPRINT_YEAR,
      BulkGapFillConstants.reportingYearBind(reportingYear)
    );
    insert rec;
    return rec;
  }

  /**
   * @description Inserts a measured energy use record covering one period.
   * @param footprintId Parent carbon footprint.
   * @param assetId Parent stationary asset. Required on insert.
   * @param fuelType A `FuelType` API value. Required on insert.
   * @param startDate Period start.
   * @param endDate Period end.
   * @param consumption Fuel consumed over the period.
   * @return The inserted energy use record.
   */
  public static SObject energyUse(
    Id footprintId,
    Id assetId,
    String fuelType,
    Date startDate,
    Date endDate,
    Decimal consumption
  ) {
    SObject rec = blank(BulkGapFillConstants.OBJ_ENERGY_USE);
    rec.put(
      BulkGapFillConstants.FIELD_ENERGY_USE_NAME,
      'Measured ' + fuelType + ' ' + startDate
    );
    rec.put(BulkGapFillConstants.FIELD_ENERGY_USE_ASSET, assetId);
    rec.put(BulkGapFillConstants.FIELD_ENERGY_USE_FOOTPRINT, footprintId);
    rec.put(BulkGapFillConstants.FIELD_ENERGY_USE_FUEL_TYPE, fuelType);
    rec.put(BulkGapFillConstants.FIELD_ENERGY_USE_START, startDate);
    rec.put(BulkGapFillConstants.FIELD_ENERGY_USE_END, endDate);
    rec.put(BulkGapFillConstants.FIELD_ENERGY_USE_CONSUMPTION, consumption);
    rec.put(BulkGapFillConstants.FIELD_ENERGY_USE_CONSUMPTION_UNIT, UNIT_KWH);
    insert rec;
    return rec;
  }

  /**
   * @description Inserts a benchmark header.
   * @param name Benchmark name.
   * @param regional True for the Regional record type, false for the custom one.
   * @return The inserted benchmark.
   */
  public static SObject benchmark(String name, Boolean regional) {
    SObject rec = blank(BulkGapFillConstants.OBJ_BEI);
    rec.put('Name', name);
    Id rtId = recordTypeId(
      BulkGapFillConstants.OBJ_BEI,
      regional
        ? 'Regional Building Energy Intensity'
        : 'Building Energy Intensity'
    );
    if (rtId != null) {
      rec.put('RecordTypeId', rtId);
    }
    insert rec;
    return rec;
  }

  /**
   * @description Inserts the per-fuel-type intensity figure a benchmark fill reads.
   * @param benchmarkId Parent benchmark.
   * @param fuelType Fuel type the figure applies to.
   * @param kwhPerSqM Annual intensity in kWh per square metre.
   * @return The inserted intensity value.
   */
  public static SObject benchmarkValue(
    Id benchmarkId,
    String fuelType,
    Decimal kwhPerSqM
  ) {
    SObject rec = blank(BulkGapFillConstants.OBJ_BEI_VALUE);
    rec.put(BulkGapFillConstants.FIELD_BEI_VALUE_PARENT, benchmarkId);
    rec.put(BulkGapFillConstants.FIELD_BEI_VALUE_FUEL_TYPE, fuelType);
    rec.put(BulkGapFillConstants.FIELD_BEI_VALUE_KWH_M2, kwhPerSqM);
    insert rec;
    return rec;
  }

  /**
   * @description Inserts a queued job row for a request, as `launchRun` would.
   * @param request The run configuration.
   * @return The inserted job.
   */
  public static BulkGapFillJob__c job(BulkGapFillRequest request) {
    BulkGapFillJob__c rec = new BulkGapFillJob__c(
      Status__c = BulkGapFillConstants.JOB_QUEUED,
      ReportingYear__c = request.reportingYear,
      DefaultFillMethod__c = request.defaultFillMethod,
      IsDryRun__c = request.isDryRun == true
    );
    insert rec;
    return rec;
  }

  /**
   * @description Reads back the energy use records under a footprint.
   * @param footprintId The parent footprint.
   * @param generatedOnly True to return only system generated (gap filled) records.
   * @return Matching energy use records, with the fields the batch writes.
   */
  public static List<SObject> energyUseUnder(
    Id footprintId,
    Boolean generatedOnly
  ) {
    List<String> selects = new List<String>{ 'Id' };
    selects.addAll(BulkGapFillConstants.ENERGY_USE_FIELDS);

    String soql =
      'SELECT ' +
      String.join(selects, ', ') +
      ' FROM ' +
      BulkGapFillConstants.OBJ_ENERGY_USE +
      ' WHERE ' +
      BulkGapFillConstants.FIELD_ENERGY_USE_FOOTPRINT +
      ' = :footprintId';
    if (generatedOnly == true) {
      soql +=
        ' AND ' +
        BulkGapFillConstants.FIELD_ENERGY_USE_IS_SYSTEM_GENERATED +
        ' = true';
    }
    return Database.query(
      soql + ' ORDER BY ' + BulkGapFillConstants.FIELD_ENERGY_USE_START
    );
  }
}
