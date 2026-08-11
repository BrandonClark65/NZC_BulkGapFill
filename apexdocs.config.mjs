import { defineMarkdownConfig } from '@cparra/apexdocs';

/**
 * Configuration for @cparra/apexdocs. Generate with `npm run docs`.
 *
 * Only public and global members are documented; the test classes are @IsTest
 * private and so are excluded by the scope filter rather than by a path rule.
 */
export default defineMarkdownConfig({
    sourceDir: 'force-app/main/default/classes',
    targetDir: 'docs',
    scope: ['public', 'global'],
    defaultGroupName: 'Bulk Gap Fill',
    referenceGuideTitle: 'Bulk Gap Fill Apex Reference',
    sortAlphabetically: true,
    includeMetadata: false,
    linkingStrategy: 'relative'
});
