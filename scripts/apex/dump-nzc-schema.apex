/**
 * Dumps everything a test fixture builder needs to know about the Net Zero Cloud
 * objects this project writes to.
 *
 * Run with:  sf apex run --file scripts/apex/dump-nzc-schema.apex
 * Then paste the debug output back.
 */
List<String> objectNames = new List<String>{
  'StnryAssetEnvrSrc',
  'StnryAssetCrbnFtprnt',
  'StnryAssetEnrgyUse',
  'BldgEnrgyIntensity',
  'BldgEnrgyIntensityVal'
};

// Fields whose allowed values decide what a fixture can put in them.
Map<String, List<String>> picklistsToDump = new Map<String, List<String>>{
  'StnryAssetEnvrSrc' => new List<String>{
    'StationaryAssetType',
    'OccupiedFloorAreaUnit'
  },
  'StnryAssetEnrgyUse' => new List<String>{
    'FuelType',
    'FuelConsumptionUnit',
    'DataGapFillingMethodName'
  },
  'BldgEnrgyIntensityVal' => new List<String>{ 'FuelType' }
};

for (String objectName : objectNames) {
  Schema.SObjectType sobjType = Schema.getGlobalDescribe().get(objectName);
  if (sobjType == null) {
    System.debug('### ' + objectName + ' :: NOT PRESENT IN THIS ORG');
    continue;
  }

  Schema.DescribeSObjectResult described = sobjType.getDescribe();
  System.debug(
    '### ' + objectName +
    ' | createable=' + described.isCreateable() +
    ' | accessible=' + described.isAccessible()
  );

  for (Schema.RecordTypeInfo rt : described.getRecordTypeInfos()) {
    if (!rt.isAvailable()) {
      continue;
    }
    System.debug(
      '    RECORDTYPE: ' + rt.getName() +
      ' | ' + rt.getRecordTypeId() +
      ' | default=' + rt.isDefaultRecordTypeMapping()
    );
  }

  // Anything createable that must be supplied: this is the minimum fixture.
  for (Schema.SObjectField field : described.fields.getMap().values()) {
    Schema.DescribeFieldResult f = field.getDescribe();
    if (!f.isCreateable()) {
      continue;
    }
    if (!f.isNillable() && !f.isDefaultedOnCreate()) {
      System.debug(
        '    REQUIRED: ' + f.getName() +
        ' (' + f.getType() + ')' +
        (f.getReferenceTo().isEmpty()
          ? ''
          : ' -> ' + f.getReferenceTo()[0].getDescribe().getName())
      );
    }
  }

  for (String fieldName : picklistsToDump.get(objectName) == null
    ? new List<String>()
    : picklistsToDump.get(objectName)) {
    Schema.SObjectField field = described.fields.getMap().get(fieldName.toLowerCase());
    if (field == null) {
      System.debug('    PICKLIST ' + fieldName + ' :: FIELD NOT FOUND');
      continue;
    }
    List<String> values = new List<String>();
    for (Schema.PicklistEntry entry : field.getDescribe().getPicklistValues()) {
      if (entry.isActive()) {
        values.add(entry.getValue() + ' (' + entry.getLabel() + ')');
      }
    }
    System.debug('    PICKLIST ' + fieldName + ': ' + String.join(values, ' | '));
  }
}
