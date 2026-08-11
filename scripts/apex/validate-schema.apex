// Confirms the Net Zero Cloud objects and fields this solution depends on exist and
// are accessible in the target org.
//
// Worth running before the first deploy to a new org: the NZC queries in
// BulkGapFillBatch are built as dynamic SOQL, so a successful deploy does NOT prove
// the API names in BulkGapFillConstants are correct. This does.
//
//   sf apex run --target-org <your-org> --file scripts/apex/validate-schema.apex

List<String> problems = BulkGapFillConstants.validateSchema();

if (problems.isEmpty()) {
    System.debug('Schema OK — every required Net Zero Cloud object and field was found.');
} else {
    System.debug('Found ' + problems.size() + ' schema problem(s):');
    for (String problem : problems) {
        System.debug('  - ' + problem);
    }
    System.debug('Correct these names in BulkGapFillConstants before running a gap fill.');
}
