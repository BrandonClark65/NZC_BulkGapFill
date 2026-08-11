/**
 * Normalizes backslashes to forward slashes inside markdown link targets.
 *
 * apexdocs builds its cross-reference links with the host path separator, so on
 * Windows the generated index contains `](bulk-gap-fill\Foo.md)`. That renders as
 * a broken link on GitHub and most markdown viewers, which treat the backslash as
 * an escape rather than a path separator. Runs as part of `npm run docs`, and is a
 * no-op on macOS and Linux.
 */
import { readdirSync, readFileSync, writeFileSync, statSync } from 'node:fs';
import { join } from 'node:path';

const DOCS_DIR = 'docs';

function markdownFilesIn(dir) {
    return readdirSync(dir).flatMap((entry) => {
        const full = join(dir, entry);
        if (statSync(full).isDirectory()) {
            return markdownFilesIn(full);
        }
        return full.endsWith('.md') ? [full] : [];
    });
}

let fixedFiles = 0;
for (const file of markdownFilesIn(DOCS_DIR)) {
    const original = readFileSync(file, 'utf8');
    // Only rewrite inside the (...) target of a markdown link, never body text.
    const updated = original.replace(/\]\(([^)]+)\)/g, (match, target) =>
        target.includes('\\') ? `](${target.replace(/\\/g, '/')})` : match
    );

    if (updated !== original) {
        writeFileSync(file, updated, 'utf8');
        fixedFiles++;
    }
}

console.log(
    fixedFiles === 0
        ? 'Doc links already use forward slashes.'
        : `Normalized link separators in ${fixedFiles} file(s).`
);
