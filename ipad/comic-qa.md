# Autonomous comic feature verification

This review covers the separate CBZ reader proof and actual web handoff from commit `8f548c03`. It does not establish production comic integration, general comic-format support, measured physical performance, or issue #2 completion. The tester uses an isolated Git worktree, real migrated PostgreSQL/BookOrbit server, delivered files, public authenticated HTTP, actual XCUITest simulator UI and the maintained browser journey. No physical iPad, external credentials, simulator/runtime downloads or user intervention are needed for these checks.

Run the comic feature gate:

```sh
IPAD_TEST_DESTINATION='platform=iOS Simulator,id=2D308564-4246-4C75-B67B-DCFC2AD4BE7B' \
  pnpm exec node scripts/ipad/run-harness.mjs --ui --reader-proof --web --comic-proof
```

The normal comic gate also runs `scripts/ipad/comic-http.test.mjs` against its fresh server before starting native UI tests. The HTTP journey independently reads the delivered CBZ through `books/files/:id/serve`, extracts its entries with `unzipper`, compares each page's exact bytes with the correct archive entry and decodes the page with `sharp`. It does not call production archive helpers or inspect private database state. Controlled native faults affect HTTP delivery through the existing localhost fault proxy; core authorization, progress writes and file serving remain real.

| Test ID                                                         | Required observable behavior                                                                                                                                                                    |
| --------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| IPAD-E01-A04/A05-comic-http                                     | Three genuine decoded pages follow natural filename order despite shuffled ZIP entries; primed owner access does not allow anonymous/restricted access; malformed and out-of-range indices fail |
| IPAD-E01-A05-comic-cache                                        | Authenticated book pixels have `private, no-store` cache policy                                                                                                                                 |
| IPAD-E01-A03/A04/A05-comic-progress                             | Accepted legacy text companions are cleared by a new page; concurrent narration remains independent; another authorized user has separate progress; unauthorized writes fail                    |
| testIPADE01A03ComicCloseWaitsForLatestPageAndPreservesNarration | Native turns coalesce while a public save is held; Close waits for the latest acknowledged page; concurrent narration survives; immediate reopen displays the actual last page                  |
| testIPADE01A04ComicCurlRotationAndResume                        | Actual native image pixels, horizontal curl, rotation, public saved page, relaunch and full accessibility audits                                                                                |
| testIPADE01A05ComicOpenFailureCanRetry                          | A failed page-count request exposes accessible error/retry; recovery displays actual first-page pixels                                                                                          |
| testIPADE01A05ComicPageFailureCanRetry                          | Failed image delivery has an accessible Retry page action; recovery paints actual pages and permits a real turn                                                                                 |
| testIPADE01A05ComicFailedSaveCanRetryOrDiscard                  | Failed save retains page and Retry; recovered save persists; confirmed discard resumes at the earlier acknowledged page                                                                         |
| IPAD-E01-A04-comic-web                                          | Actual web Read/reopen/reload renders the page saved by native, independently checked with screenshot OCR                                                                                       |

## First public-boundary execution

The isolated harness `run-95241-1791318999405` used Node 25.7.0, the cached dependencies and a newly migrated 50,000-book PostgreSQL fixture on `localhost:16482`. Its database/server cleanup returned exit 0. Worktree dependency reuse required a temporary PATH wrapper that passes `--config.verifyDepsBeforeRun=false` to the installed pnpm; no package install succeeded or was needed. The initial attempted run rejected the test's incorrect `koboPercentRead` field with a genuine DTO 400. The tester corrected the fixture to the canonical `koboContentSourceProgressPercent` and recorded a fresh execution.

The corrected execution finished in 917 ms with **2 passing HTTP journeys, 1 failing cache-policy journey, no skipped or cancelled tests**. The actual response was `200 image/png` with `Cache-Control: public, max-age=31536000, immutable`. This is a confirmed private-content caching defect in `CbzController.getPage`, reported immediately to the coordinating agent for a separate repair agent. The minimal expected correction is `private, no-store`. Anonymous/restricted requests still returned 401/403 after priming; natural order, exact artifact bytes, all page dimensions, malformed index handling and progress independence passed.

Artifacts are retained in the QA worktree under `test-results/ipad/run-95241-179132-comic-http-cache-red/comic-http/`: `run.log`, `server.log`, `delivered.cbz`, `natural-order.json`, `cache-policy.json`, `progress-before.json`, `progress-after.json` and `natural-page-1.png` through `natural-page-3.png`. The earlier fixture-error run remains under `run-95241-179132-comic-http-red/comic-http/` and is not a passing gate.

The tester opened all six decoded PNGs from both executions. Each is 600 by 800 pixels with complete black panel borders and a visible literal `Orbit comic: page 1`, `2` or `3`; there is no clipping or substituted page. The archive entries arrived in `page-10.png`, `page-2.png`, `page-1.png` order and were served in `page-1.png`, `page-2.png`, `page-10.png` order. The tester read both natural-order/hash reports and both cache-policy reports, plus the corrected before/after public progress. The before record retained the seeded CFI/Kobo/KOReader fields; the after record has all six old text companions null, page 2, approximately 66.6667 percent, narration 9 seconds, second fragment and 20 percent narration. These artifact images do not count as native/browser screenshots or human-approved visual baselines.

The expanded native fault journeys are prepared and await their serialized simulator run. Their execution and correction evidence will be appended here before claiming that the implemented proof's autonomous feature gates pass.
