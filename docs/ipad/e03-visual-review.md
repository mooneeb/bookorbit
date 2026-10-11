# E03 visual review and comparison gate

Issue: [#4](https://github.com/mooneeb/bookorbit/issues/4). [Acceptance plan](e03-test-plan.md).

The [captured-image gallery](../../test-results/ipad/e03-verification/visual-review/index.html) contains 25 original screenshots opened with `view_image` on 2026-10-11: 20 meaningful browser states, one native restricted-role state and four diagnostic/failure images. Every card links its original and copied actual PNG, test identity, state, configuration, SHA-256 and agent findings. The [machine report](../../test-results/ipad/e03-verification/visual-review/gate-report.json) records the comparisons and individual missing states. [Capture inventory](../../ipad/VisualBaselines/E03/captures.json) preserves the inspection records in source control.

Current visual gate: **blocked**, command exit 1. All 21 meaningful captures lack a human-reviewed baseline; four failure images are evidence only and cannot satisfy required coverage. There are 328 missing states after expanding the authored catalog and representative matrix: 235 portrait-light, 40 landscape-dark, 28 large-text and 25 narrow-dark; 220 native and 108 browser states. These are capture requirements, not 328 executed failures. [Human reviews](../../ipad/VisualBaselines/E03/reviews.json) is empty. No baseline PNG has been created, copied or approved.

## Captured gallery

All browser images use Chromium with a desktop user agent, 1024 x 1366 CSS-pixel viewport and `pro13-portrait-light` settings. Browser viewport evidence does not exercise native Dynamic Type. Exact browser version, web build hash and font hashes were not recorded for these captures, so a reproducible baseline candidate still needs those pins. Runtime fixture: `run-78858-1791630906387`.

| QA/test identity                                                                       | Captured states                                                                    | Agent inspection and limits                                                                                                                                                                                                                                                       |
| -------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `IPAD-E03-A01-upload-web`                                                              | Imported detail and PDF reader                                                     | Wrapped imported title and Read action fit. The reader renders the PDF, but 315% zoom cuts off the right end of its source title. Review fit/zoom before recapture or approval.                                                                                                   |
| `IPAD-E03-A01-scan-web`                                                                | Scanned detail and PDF reader                                                      | Page 2 of 3 and passage 2 are readable. Detail capture still has a Loading reading card and related placeholders; settled detail needs recapture.                                                                                                                                 |
| `IPAD-E03-A02-cross-client`                                                            | Subscribed, unsubscribed, cancelled, source failure, release picker, import review | Request panes, long title, retry and filing controls fit. Toast timing and below-viewport client details need deliberate capture. Filing-failure diagnostic is separately labelled; received-book and readable-PDF states are missing.                                            |
| `IPAD-E03-A04-browser`                                                                 | Selected books 1/2 metadata and reopened PDF/EPUB                                  | Selected publisher/tag fields fit. PDF passage 1 and EPUB Unicode chapter/footer are readable. EPUB toolbar is hidden in its capture. Export-status failure screenshot proves no successful export delivery.                                                                      |
| `IPAD-E03-A05-maintenance-web`                                                         | Repaired detail, PDF open/reopen, reader permission, owner/operator settings       | Private note and reader passage remain visible. Detail reading cards still say Loading, and one sidebar is transiently empty. Owner controls and non-superuser backfill hiding fit. These images do not prove native settings convergence or source ink preservation.             |
| `IPAD-E03-A05-entity-web-pagination`                                                   | Failed genre-directory navigation                                                  | Find Duplicates, bounded rows and pagination are visible; generated names truncate. Duplicate groups, merge preview, mobile return and restoration were not reached. Evidence only.                                                                                               |
| `BulkActionsJourneyTests/testIPADE03A04RestrictedAccountHidesBulkActions`              | Restricted-role main navigation                                                    | Actual 13-inch M4/iOS 26.0 native capture shows 0 books, search, view controls and sidebar without clipping; selected-book bulk control is absent. Functional summary is 1 pass, 0 failures/skips. Other selected-edit/export methods and actual Reduce Motion remain unverified. |
| `AcquisitionJourneyTests/testIPADE03A01NativeFileSelectionDockReviewFinalizeAndReader` | Connection setup diagnostic                                                        | Actual iPad Pro 13-inch M4, iOS 26.0 simulator, full portrait/light, 2064 x 2752 PNG. The recipe set content size Large; the feature/system-profile assertions were not reached. AX snapshot timeout and cancellation occurred before acquisition. Evidence only.                 |

The gallery renders each image and its individual findings. The QA reports retain functional outcomes independently: [A01](../../test-results/ipad/e03-verification/qa1-report.md), [A02](../../test-results/ipad/e03-verification/qa2-report.md), [A03](../../test-results/ipad/e03-verification/qa3-report.md), [A04](../../test-results/ipad/e03-verification/qa4-report.md), [maintenance](../../test-results/ipad/e03-verification/maintenance-report.md), [entities](../../test-results/ipad/e03-verification/entities-report.md). A screenshot from a failing journey is not a passing journey or a visual approval.

## Representative matrix

[The manifest](../../ipad/VisualBaselines/E03/manifest.json) lists authored tests, snapshot names, audit presence and exact matrix states. The default profile covers the complete authored snapshot catalog. Other profiles cover selected review panes, readers, long forms, errors, permission states and bounded lists across A01 through A05. This is a representative matrix, not every Cartesian combination. Migration templates expand to all five provider modes, four media formats and two reader openings; selected-book snapshots expand to IDs 1 and 2.

| Profile                | Size and orientation                   | Window | Theme | Native text size     | Reduce Motion | Current evidence                                                                |
| ---------------------- | -------------------------------------- | ------ | ----- | -------------------- | ------------- | ------------------------------------------------------------------------------- |
| `pro13-portrait-light` | 13-inch Pro, portrait; web 1024 x 1366 | Full   | Light | Default system Large | Off           | 20 browser states; native restricted-role state and connection failure          |
| `pro11-landscape-dark` | 11-inch Pro, landscape; web 1194 x 834 | Full   | Dark  | Default system Large | Off           | Missing E03 captures and comparisons                                            |
| `pro11-portrait-large` | 11-inch Pro, portrait; web 834 x 1194  | Full   | Light | Accessibility XXXL   | On            | Missing E03 captures, actual native text-size/motion assertions and comparisons |
| `pro13-narrow-dark`    | 13-inch Pro, landscape; web 600 x 1024 | Narrow | Dark  | XXXL                 | On            | Missing browser captures and actual native window evidence                      |

The native harness uses `pro13-landscape-dark-large` at 1366 x 1024 as the full-window counterpart for the narrow profile. That run cannot satisfy `pro13-narrow-dark` native coverage. `simctl` cannot size the app window. Narrow native captures require an actual supported window, recorded bounds and system assertions. Browser emulation is not a substitute. State-specific native rotations also need their actual geometry recorded alongside the requested profile.

The E03 comparator now checks actual PNG bounds before accepting a profile label. Browser bounds must equal the requested viewport. Full-window native captures must match the requested orientation and window aspect ratio within 2 percent to allow device pixel scaling. Narrow native captures require `windowBounds` with actual width and height in the capture inventory, with matching image/window aspect ratios. A portrait capture labelled as a landscape profile fails with `failed-profile-geometry` and cannot satisfy matrix coverage. The gallery displays requested and actual orientation separately. These geometry checks do not establish theme, Dynamic Type or Reduce Motion.

The existing catalog is a minimum gate. Browser acquisition file selection/Dock review, new browser administration/configuration panes, and any remaining acceptance interaction without an authored snapshot need implementation and capture; a complete catalog comparison cannot establish those missing behaviors. A03 currently has no browser/native image evidence. The native restricted-role startup proof now has one inspected capture and an actual summary with 1 pass, 0 failures and 0 skips. Native acquisition, requests, migration, selected edit/export, entities and maintenance journey captures remain missing.

## Commands and artifacts

Generate the gallery and evaluate the recorded inventory without starting any app, server, scan or database work:

```sh
node scripts/ipad/e03-visual.mjs
node --test scripts/ipad/e03-visual.test.mjs
```

The first command writes `test-results/ipad/e03-verification/visual-review/index.html`, `gate-report.json` and per-state actual/review files, then returns nonzero while approval or matrix coverage is missing. Rebuilding the gallery never writes `reviews.json` or baseline PNGs. Evidence-only captures do not satisfy the matrix. Changes to a recorded image invalidate its agent inspection checksum.

The seven [isolated comparator checks](../../scripts/ipad/e03-visual.test.mjs) pass: matching pixels, meaningful mismatch, dimension mismatch, approval/budget rejection, baseline checksum change, surface/profile/failure separation and all-provider coverage. Their synthetic PNG/review fixtures are temporary test data, not E03 baseline approvals. [Check output](../../test-results/ipad/e03-verification/visual-review/comparator-checks.tap), [gallery gate](../../test-results/ipad/e03-verification/visual-review/gallery-gate.log), [existing browser gate](../../test-results/ipad/e03-verification/visual-review/existing-web-gate.log) and [existing native gate](../../test-results/ipad/e03-verification/visual-review/existing-native-gate.log) retain the outcomes. Both saved browser/native comparisons return exit 1 specifically for pending human baselines; native functional summary remains passing.

After authorized, serial functional execution, compare existing browser artifacts explicitly:

```sh
node scripts/ipad/e03-visual.mjs \
  --web-artifacts=test-results/ipad/qa1-web-portrait-light \
  --profile=pro13-portrait-light
```

For native captures, the comparator reads existing `native-attachments` or `attachments` directories. If attachments have not been exported, export them first. The comparison itself uses existing artifacts only:

```sh
xcrun xcresulttool export attachments \
  --path test-results/ipad/<run>/native.xcresult \
  --output-path test-results/ipad/<run>/native-attachments
node scripts/ipad/e03-visual.mjs \
  --native-artifacts=test-results/ipad/<run> \
  --profile=pro13-portrait-light
```

Native `IPAD-E03-*` attachments and authored browser PNGs are compared at the existing harness seams after functional success. `pnpm ipad:test:e03:ui` and `pnpm ipad:test:e03:web` therefore fail if meaningful captured states have no approved baseline. Native summary and browser functional reports remain separate from `e03-native-visual-report.json` and `e03-browser-visual-report.json`. The direct frozen-build helper and direct Playwright commands bypass those harness seams, so they require the explicit offline comparison above. The full gallery gate additionally checks missing matrix coverage. No CLI option auto-accepts, updates or quarantines a baseline.

For future browser profile execution, source the private retained runtime first, then use one worker and zero retries:

Prepare and keep a fresh provider holder alive using the explicit sequence in the [E03 test plan](e03-test-plan.md#commands), then source its `native-fixtures.env` before this direct command. For browser-only work, its `--apply` phase supplies the imported HTTP fixture outcomes expected by A03. Historical provider configuration and HTTP-suite artifact directories do not establish live provider readiness.

```sh
IPAD_TEST_RUN=e03-visual-pro11-landscape-dark \
IPAD_E03_PROFILE=pro11-landscape-dark \
pnpm exec playwright test --config scripts/ipad/e03-web.config.mjs
```

The shared harness profile selector is `--profile=<name>`; use it with the E03 UI/web commands only after the runtime/native slot is ready. Record Xcode, iOS runtime/build, simulator model, locale/timezone, exact app/web source/build pins, browser version, installed font hashes, fixture revision/content hashes, actual orientation/window bounds, system content category and Reduce Motion. Keep animation enabled and wait for observable settled state. Reset mutable fixture metadata/IDs and reader zoom before capturing. Do not turn unstable UUID titles, loading cards or unverified configurations into accepted visual noise.

## Human baseline review

A human reviewer must open each actual PNG at full resolution, inspect the layout and accessible controls, resolve or explicitly assess recorded findings, and approve that exact image/configuration. Agent inspection supplies evidence for review; it cannot perform this approval. Human-approved files belong under `ipad/VisualBaselines/E03/`, and their review entries in `reviews.json` must include:

```json
{
  "testId": "IPAD-E03-A01",
  "state": "imported-web-detail",
  "surface": "web",
  "profile": "pro13-portrait-light",
  "file": "approved/IPAD-E03-A01-imported-web-detail.png",
  "sha256": "<approved PNG SHA-256>",
  "reviewType": "human",
  "reviewedBy": "<human reviewer>",
  "reviewedAt": "<UTC ISO timestamp>",
  "pixelThreshold": 16,
  "maxChangedPixelRatio": 0.0005,
  "budgetReason": "<human rationale for this state's tolerance>",
  "masks": []
}
```

This is an unapproved schema example. Its tolerances are proposals, not reviewed E03 budgets. The comparator permits an integer per-channel threshold of 0 through 32 and a changed-pixel ratio of 0 through 0.005; the actual values and rationale require human review for each state. Dimensions must match exactly. Masks require a reason and in-bounds integer `left`, `top`, `width`, `height`; they may exclude only irrelevant dynamic pixels and cannot exclude the whole image. Do not mask text, actions, selected content, ink or meaningful progress/error state.

The gate rejects absent, agent-only, duplicate or incomplete approvals, changed baseline checksums, image dimensions and pixel differences beyond the reviewed budget. Matching approved comparisons retain expected, actual and diff PNGs even when passing. Dimension mismatches retain a union-sized diff; changed/missing pixels are magenta. Review every meaningful expected/actual/diff mismatch and record the resulting inspection with its checksum. Pending approvals have an actual image and a pending report; expected/diff are absent because no trustworthy expected image exists. Previous expected/diff files are cleared before comparison to prevent stale evidence.

## Visible assertions, accessibility and performance

Visible behavior is exercised by the named native methods and real browser tests in the manifest and acceptance plan. A01, A03, A04 and maintenance native methods contain authored accessibility audits; their presence is not an executed audit pass. Audit subsets differ: acquisition reviews hit regions and descriptions, while migration additionally includes contrast. Request list/detail/release, source/client forms, entity directory/rename preview/component-page journeys now contain equivalent authored audits. They remain unexecuted. Reach and audit every required key screen; document failures and remaining coverage instead of treating a screenshot as an audit.

The frozen-build helper can run a single existing method and its authored audit after the serial slot is released:

```sh
bash test-results/ipad/e03-builder-handoff/test-without-building.sh \
  test-results/ipad/run-78858-1791630906387/e03-runtime.env \
  test-results/ipad/e03-a04-audit \
  BookOrbitUITests/BulkActionsJourneyTests/testIPADE03A04SelectedPreviewApplyAndContentExport
```

Do not run this helper while native restoration or another simulator journey owns `/tmp/bookorbit-ipad-xcode.lock`. It sets portrait-light appearance/content size only; it does not establish the other matrix profiles.

Existing XCTest measurements are reusable regression checks, with the following established absolute budgets recorded in [E02 performance evidence](e02-web-acceptance.md#system-profiles-and-performance). Their old results are not E03 results, and E03-specific acquisition, request, migration and bounded maintenance navigation methods are now authored in `E03AcceptancePerformanceTests`, and are discovered by the E03 harness. Native execution and human-reviewed budgets remain pending.

| Existing `AnnotationProfilePerformanceTests` method | Established absolute budget | Measured interval                                          |
| --------------------------------------------------- | --------------------------- | ---------------------------------------------------------- |
| `testIPADE02A01LaunchToUsableLibraryPerformance`    | 8 seconds                   | Launch through hittable library/Hub navigation             |
| `testIPADE02A01BookDetailNavigationPerformance`     | 5 seconds                   | Selected fixture to loaded book detail                     |
| `testIPADE02A02ReaderPageTransitionPerformance`     | 2 seconds                   | Next tap through logical Page 2; restore outside the clock |
| `testIPADE02A07BoundedHubOpenAndSearchPerformance`  | 5 seconds                   | Open/search through correlated bounded empty result        |

The same helper accepts any one of those method identifiers. It uses XCTest clock/launch metrics, one warmup and two measured iterations; timing samples and screenshots are attachments in `.xcresult`. Example for the existing launch check:

```sh
bash test-results/ipad/e03-builder-handoff/test-without-building.sh \
  test-results/ipad/run-78858-1791630906387/e03-runtime.env \
  test-results/ipad/e03-launch-performance \
  BookOrbitUITests/AnnotationProfilePerformanceTests/testIPADE02A01LaunchToUsableLibraryPerformance
```

No performance or native audit command was run for this gallery work. The host load previously exceeded 900 during native startup; measurements there cannot establish useful E03 timing. Record a quiet environment, OS/runtime/device and source pins, actual 50,000-book fixture, clock boundaries and complete sample outcomes. A human must review E03 budgets before those measurements can gate E03 completion. Source-only thresholds and old passing E02 samples cannot supply that approval.

Physical iPad narrow-window behavior, animation feel, VoiceOver, Files providers, live integrations and the integrated A01 through A05 human walkthrough remain pending. The gallery and comparator implementation do not close issue #4.

### Newly authored E03 native checks

`MaintenanceJourneyTests/testIPADE03A05MergePreviewApplyAndReadableFileRepair` now seeds reading data through public APIs, applies merge and repair through native controls, reopens native private notes, passage notes and logical reader progress, and checks the merged source ink overlay. It drives selected native file rename, reopens the renamed PDF, and compares downloaded current PDF bytes. Repaired and renamed ink retain the replacement PDF's exact bytes; the merged ink is also asserted as a native accessibility image and a PDF Ink annotation. These are authored assertions, not executed preservation evidence.

`E03AcceptancePerformanceTests` contains `testIPADE03A01LaunchToUsableLibraryPerformance`, `testIPADE03A01AcquisitionReviewNavigationPerformance`, `testIPADE03A02RequestListNavigationPerformance`, `testIPADE03A03MigrationReviewNavigationPerformance`, and `testIPADE03A05BoundedMaintenancePreviewPerformance`. The proposed budgets are 8 seconds for launch and 5 seconds for each navigation interval. They are **PENDING_HUMAN_REVIEW**, are recorded with OS, processor count, physical memory, profile, native bounds and timing samples, and are not enforced as approved acceptance thresholds. XCTest records clock metrics, launch metrics for launch, one warmup and two measured iterations. These methods measure reachable navigation and a bounded maintenance page; they do not establish full import, migration execution or large-library scan completion performance.

`E03ProfileSupport` selects orientation from the requested E03 profile and checks actual native app and screenshot dimensions before attachment. Acquisition review titles are stable; upload-session, dock and book IDs retain their separate identities. All added methods remain unexecuted while `E03_NATIVE_READY=0`. Human visual approval, integrated walkthrough, physical iPad/Pencil, VoiceOver, dictation, Scribble and simulator-excluded device checks retain their existing explicit boundaries.
