# E02 bounded web annotation collections

The approved seams are authenticated HTTP, actual web reader UI and delivered artifacts. The standalone Playwright configuration leaves the existing E02 runner/configuration untouched. The fixture creates 1,101 reader-owned private PDF annotations across three pages through canonical public operations, in batches of at most 100. Cleanup searches only its known note prefix and deletes only matching reader-owned annotations in bounded batches. It never creates source PDF ink or edits source bytes; delivered source SHA-256 equality is asserted after cleanup.

Run against the existing isolated harness only after its runtime owner releases a stable lease:

```sh
IPAD_TEST_RUN=e02-collection-green ./node_modules/.bin/playwright test --config scripts/ipad/annotations-collection.config.mjs
```

The PDF journey scopes its Previous/Next controls to the actual Notes tabpanel. It reaches the eleventh 100-row window and returns to the first while the book remains on PDF page 1. A known yellow highlight must remain visible on the actual rendered page, independently of the sidebar window. A later authenticated native-operation fixture adds a known green highlight to that active page while the sidebar is full; actual delta reception and rendered pixels must converge without removing the older highlight or making earlier note windows unreachable. Screenshots use the existing review helper, preserve meaningful differences, and never accept new baselines automatically.

The pixels come from actual browser screenshots at known PDF coordinates mapped through the visible page element. Expected yellow/green color ranges are independent literals. The test does not inspect private plugin state, query the database or replace persistence/synchronization with mocks. These deterministic protocol inputs are not a physical Pencil or native UI session.

The EPUB journey fills a 100-row sidebar using valid second-paragraph passage anchors. A remote annotation at the earlier first paragraph must be present in the canonical first window, received through the browser's actual delta response and visible in the current sidebar. Its success requires overflow to invalidate/refetch the current ordering instead of silently discarding the new record. The fixture uses reader-owned data and cleans up only its known note prefix.

## Evidence

`e02-collection-red`, 2026-10-08 UTC: the first tracer seeded 1,101 rows and passed in 24.8 seconds. Inspection of its actual screenshot showed the Notes sidebar still offered only `Load more highlights`; the global Previous/Next locators had matched the PDF book-page toolbar. This driver false positive is preserved and withdrawn as collection pagination evidence. It establishes public fixture creation and cleanup only. The screenshot was opened and inspected: the earliest note was visible, the sidebar count was already growing beyond 100 through synchronization, and the PDF render was still loading.

`e02-collection-scoped-red`: **PDF collection failed**, 27.2 seconds, on the fresh real API and old compiled client. The actual Notes tabpanel had no Next-page control after 1,101 owned notes were created. Public cleanup completed and delivered source SHA-256 equality passed. The failure screenshot was opened and inspected at `test-results/ipad/e02-collection-scoped-red/browser/annotations-collection-IPA-16c15-nd-one-thousand-annotations/test-failed-1.png`: the earliest fixture note was visible, the sidebar still offered only Load more highlights, and its buffer count had grown to 120 through synchronization. The reader had resumed a prior page 2; the final driver now uses the actual Current-page input after its progress request to select page 1 before its pixel assertions. This driver correction does not weaken the scoped missing-pager failure.

`e02-collection-epub-red`: **EPUB overflow failed**, 18.0 seconds. The initial browser request returned exactly 100 rows. The remote earlier-position note appeared in the canonical first window and in the actual browser delta response, but never appeared in the sidebar within 10 seconds. Cleanup completed. Both the initial 100-row image and failure screenshot were opened and inspected under `test-results/ipad/e02-collection-epub-red/browser/annotations-collection-IPA-b16e0--a-full-hundred-row-sidebar/`: the count remained 100, controls and existing notes stayed visible, and the new note was absent. The sidebar overlay partially obscures the book passage; these captures assess the collection, not passage layout.

Both functional RED reports/traces are preserved. The final GREEN will be recorded after the client build and explicit stable runtime handoff. No visual baseline has been approved.

## Remaining scope

- Both collection journeys await the final client build and live GREEN verification.
- The dense-page segment controls, many-files spread and broader visual/accessibility profile matrix are separate scale cases. This fixture distributes its notes over three pages.
- Actual native sessions, hardware input and human-reviewed visual baselines remain outside these protocol/browser checks.
