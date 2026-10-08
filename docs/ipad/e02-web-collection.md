# E02 bounded web annotation collections

The approved seams are authenticated HTTP, actual web reader UI and delivered artifacts. The dedicated Playwright configuration runs serially after the six main browser journeys in the integrated E02 harness. The fixture creates 1,101 reader-owned private PDF annotations across three pages through canonical public operations, in batches of at most 100. Cleanup searches only its known note prefix and deletes only matching reader-owned annotations in bounded batches. It never creates source PDF ink or edits source bytes; delivered source SHA-256 equality is asserted after cleanup.

Run the fresh, self-contained HTTP and nine-browser acceptance command:

```sh
node scripts/ipad/run-harness.mjs --annotations --web
```

Run against the existing isolated harness only after its runtime owner releases a stable lease:

```sh
IPAD_TEST_RUN=e02-collection-green ./node_modules/.bin/playwright test --config scripts/ipad/annotations-collection.config.mjs
```

The PDF journey scopes its Previous/Next controls to the actual Notes tabpanel. It reaches the eleventh 100-row window and returns to the first while the book remains on PDF page 1. A known yellow highlight must remain visible on the actual rendered page, independently of the sidebar window. A later authenticated native-operation fixture adds a known green highlight to that active page while the sidebar is full; actual delta reception and rendered pixels must converge without removing the older highlight or making earlier note windows unreachable. Screenshots use the existing review helper, preserve meaningful differences, and never accept new baselines automatically.

The pixels come from actual browser screenshots at known PDF coordinates mapped through the visible page element. Expected yellow/green color ranges are independent literals. The test does not inspect private plugin state, query the database or replace persistence/synchronization with mocks. These deterministic protocol inputs are not a physical Pencil or native UI session.

The EPUB journey fills a 100-row sidebar using valid second-paragraph passage anchors. A remote annotation at the earlier first paragraph must be present in the canonical first window, received through the browser's actual delta response and visible in the current sidebar. Its success requires overflow to invalidate/refetch the current ordering instead of silently discarding the new record. The fixture uses reader-owned data and cleans up only its known note prefix.

## Evidence

`e02-collection-red`, 2026-10-08 UTC: the first tracer seeded 1,101 rows and passed in 24.8 seconds. Inspection of its actual screenshot showed the Notes sidebar still offered only `Load more highlights`; the global Previous/Next locators had matched the PDF book-page toolbar. This driver false positive is preserved and withdrawn as collection pagination evidence. It establishes public fixture creation and cleanup only. The screenshot was opened and inspected: the earliest note was visible, the sidebar count was already growing beyond 100 through synchronization, and the PDF render was still loading.

`e02-collection-scoped-red`: **PDF collection failed**, 27.2 seconds, on the fresh real API and old compiled client. The actual Notes tabpanel had no Next-page control after 1,101 owned notes were created. Public cleanup completed and delivered source SHA-256 equality passed. The failure screenshot was opened and inspected at `test-results/ipad/e02-collection-scoped-red/browser/annotations-collection-IPA-16c15-nd-one-thousand-annotations/test-failed-1.png`: the earliest fixture note was visible, the sidebar still offered only Load more highlights, and its buffer count had grown to 120 through synchronization. The reader had resumed a prior page 2. The frozen driver captures and resets public progress before seeding, then uses the actual Current-page input after the reader's progress request. This driver correction does not weaken the scoped missing-pager failure.

`e02-collection-epub-red`: **EPUB overflow failed**, 18.0 seconds. The initial browser request returned exactly 100 rows. The remote earlier-position note appeared in the canonical first window and in the actual browser delta response, but never appeared in the sidebar within 10 seconds. Cleanup completed. Both the initial 100-row image and failure screenshot were opened and inspected under `test-results/ipad/e02-collection-epub-red/browser/annotations-collection-IPA-b16e0--a-full-hundred-row-sidebar/`: the count remained 100, controls and existing notes stayed visible, and the new note was absent. The sidebar overlay partially obscures the book passage; these captures assess the collection, not passage layout.

`e02-collection-green`, final compiled client and API PID 98715: **EPUB passed**, 12.5 seconds. Its earlier-position remote note appeared after the actual delta and sidebar refetch while the collection stayed at 100 rows. Both actual 1024-by-1366 PNGs were opened and inspected under `test-results/ipad/e02-collection-green/browser/annotations-collection-IPA-b16e0--a-full-hundred-row-sidebar/`: the new green Alpha note appeared above First, older rows and retained drawing previews stayed readable, and controls remained reachable. The PDF case failed in 32.8 seconds during setup because its page input raced resumed page 2; this did not establish a collection failure. Its cleanup and source equality checks completed.

`e02-collection-pdf-green`, the single permitted focused PDF rerun: **timed out**, 180-second test budget, approximately 3.3 minutes reported. The public 1,101-row seed consumed about 174 seconds; sequential 100-item create requests took 6.4 to 30.6 seconds. After seeding, the actual reader reached page 1, displayed the earliest note and known yellow highlight, and captured the initial bounded window. The first scoped Next request returned HTTP 200 for sidebar page 2. Cancellation then interrupted first-row visibility and disposed the Playwright request context before `finally` could clean up. Concurrent workspace compute jobs are a possible cause of the slow requests, not a proven server fault. This is a test budget and fixture-isolation failure; the later PDF acceptance steps remain unverified.

The retained trace is `test-results/ipad/e02-collection-pdf-green/browser/annotations-collection-IPA-16c15-nd-one-thousand-annotations/trace.zip`. Its initial screenshot was opened and inspected: PDF page 1 and the earliest fixture note are readable, the yellow highlight is visible, the sidebar filters count 100 rows, and the pager reads Page 1 of 12. The timeout failure screenshot is blank; it is preserved and is not evidence of a stable product rendering defect. No eleventh-window or remote-addition capture was reached.

After the run, independent bounded authenticated public cleanup removed all 1,101 exact-prefix reader-owned rows in 12 batches, about 10 seconds. Public prefix searches for both books returned no rows. The original progress captured in the trace was restored exactly and verified: percentage `66.666664`, page `2`, CFI `null`. Direct API and proxy reads both returned the same fixture row with HTTP 200 in 35 and 76 milliseconds before cleanup, so an annotation-offline read fault was absent. Delivered PDF SHA-256 remains `04b0fd47bc0bc702316827dc7eb73aea3ccf2b36b5fe1b69aae03775dc2268f9`.

Both meaningful RED reports/traces and the EPUB GREEN are preserved. No visual baseline has been approved. The runner and configuration were frozen and handed to the assigned Repairer without another case rerun.

## Final integrated evidence

Candidate `4a75ab220a0647bf1803748c6d25e1af4a1603c5` passed both collection journeys in the fresh `run-41109-1791495583976-collection` phase, 44.0 seconds including fixtures. The PDF browser journey took 16.1 seconds and the EPUB journey 4.4 seconds. The [actual collection report](../../test-results/ipad/run-41109-1791495583976-collection/browser-report/index.html) records zero failures and skips. This phase followed 23 passing authenticated HTTP cases and six passing main browser journeys; the subsequent dense shared-source journey also passed, for 32 passing checks in the single isolated run.

The PDF assertions now reach the eleventh 100-row note window, return to the first, retain the active-page yellow highlight and display the remote green highlight after actual delta reception. The EPUB assertions retain the bounded hundred-row sidebar and reveal the remote earlier-position note after refetch. Source equality and captured progress restoration assertions completed in their independent cleanup contexts. The run proves successful teardown; it does not simulate a timeout to prove every cancellation path.

The preceding fresh run at `c3742ee8`, `run-37427-1791495095780`, passed 23 HTTP cases, six main browser journeys and the EPUB collection. Its PDF collection failed because a strict exact text locator matched multiple `Collection PDF note 0098` elements. The dense source journey was not reached. That 31-check execution is preserved as a failed run. The final candidate selects the unique visible accessible canonical row despite hidden virtual-scroller cache; no product change or relaxed paging/highlight assertion was needed.

The final run's [collection-fix review](../../test-results/ipad/run-41109-1791495583976/reviews/bookorbit-issue-3-collectionfix-code-review.md) is preserved with the evidence. No screenshot baseline has been automatically accepted.

The [independent final report](../../test-results/ipad/run-41109-1791495583976/final-integrated-validation-report.md) includes inspection of all five actual collection captures among the 21 browser states. The PDF images show the initial bounded window, the eleventh window with the active-page highlight preserved, and the remote addition on that page. The EPUB images show the hundred-row window and earlier remote note after refetch. These are functional image observations, with human baseline review still pending. The Tester independently confirmed the integrated harness removed its database, sessions, API/proxy/preview listeners, runner process and temporary content folders.

## Remaining scope

- Injected slow-setup/timeout cancellation and its complete independent cleanup still need a dedicated execution; the final successful run does not establish that fault outcome.
- The dense-page segment controls, many-files spread and broader visual/accessibility profile matrix are separate scale cases. This fixture distributes its notes over three pages.
- Actual native runtime and XCTest performance, narrow native windows, hardware Pencil/Scribble input, human walkthrough and human-reviewed visual baselines remain outside these protocol/browser checks. Human participation is a nonblocking evidence residual.
