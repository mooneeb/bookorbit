# Interim verification for issue #2

Date: 2026-10-05. These results cover the implemented entry/browsing foundation and the web PDF journey. They do not establish completion of issue #2.

## Environment

macOS 27.0 (26A428), Xcode 27.0 (27A266a), Node 25.7.0, pnpm 11.22.0, Playwright 1.63.0 with its Chromium headless shell, and the local PostgreSQL dev container. Native deployment targets iPadOS 26. The iOS 26.0 arm64 simulator runtime (23A343) was installed, but native execution remains blocked by the simulator recovery described below.

The real BookOrbit server uses `http://localhost:16482`; the production Vue build uses `http://localhost:16484`. OIDC is enabled with the external protocol fixture displayed as `Test identity provider`. Each run migrates and seeds a separate temporary database with 50,000 books. The public HTTP API, actual browser/native UI, and delivered files are the agreed test boundaries. No assertion queries private database state.

## Results

- `pnpm ipad:test:web`: 4 authenticated HTTP/artifact tests and 4 real-browser tests passed without retries. Run `run-11644-1791219645293`; browser duration 42.4 seconds while the regression suite was also running. The PDF journey reaches page 2 visibly and leaves before awaiting its save response, checking the exit save as well as reopening. The temporary database and listeners were removed after the run.
- `pnpm typecheck`: passed.
- `pnpm ipad:contracts:check`: passed, including in the final harness run.
- `pnpm --filter server exec eslint .`: passed after the review fixes.
- `xcrun swift-format lint --strict` on both changed session files: passed.
- `xcodebuild build-for-testing`: passed for the app and two XCUITest journeys with signing disabled. This is compilation evidence only. Native UI execution and its accessibility audit remain unverified.
- The first full regression run passed 14,692 server tests but failed two existing config expectations after adding the callback setting. Both expectations were updated; all 25 config tests then passed. The separately executed full client suite passed 7,163 tests. The complete regression rerun passed 14,693 server tests but failed the existing real-filesystem watcher pause/resume timing test; it stopped before the client stage. All 39 watcher tests passed in an isolated diagnostic run, which does not erase the full-run failure. The six existing skips are the opt-in qBittorrent daemon reproduction (five tests) and the podcast-disabled configuration case while that feature is enabled (one test). No new issue #2 test is skipped.

## Screenshot inspection

The implementing agent opened and inspected the actual PNGs below. All browser captures use English, UTC, light theme, default text size, and animation enabled. Fixture added dates are fixed to 2026-01-01. This inspection does not provide human-reviewed visual baselines or deterministic expected/actual/diff comparisons.

Artifact root: `test-results/ipad/run-11644-1791219645293/browser/`. The harness log is `run.log` beside that directory; the full regression log is `test-results/ipad/full-regression.log`.

| Test ID          | State and viewport                           | Artifact beneath the root                                                                        | Inspection                                                                                                                                                                                                          |
| ---------------- | -------------------------------------------- | ------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| IPAD-E01-A01-web | Library, 1024 x 1366 portrait                | `web-IPAD-E01-A01-web-searc-e5b16-brary-and-reopen-its-record/IPAD-E01-A01-library-portrait.png` | Covers, search, sort, view controls, sidebar and count are legible and reachable. The compact title truncates to `Larg...`; the full name remains in the sidebar. Lower rows continue below the scrolling viewport. |
| IPAD-E01-A01-web | Reopened record, 1366 x 1024 landscape       | `web-IPAD-E01-A01-web-searc-e5b16-brary-and-reopen-its-record/IPAD-E01-A01-detail-landscape.png` | Title, tabs, cover, reader action and file facts are visible without overlap.                                                                                                                                       |
| IPAD-E01-A03-web | PDF page 1, 1024 x 1366 portrait             | `web-IPAD-E01-A03-web-read--30704-F-and-resume-its-saved-page/IPAD-E01-A03-pdf-page-one.png`     | Passage 1 is visible on the page; the counter reads 1 of 3. Toolbar and navigation controls remain reachable.                                                                                                       |
| IPAD-E01-A03-web | PDF reopened at page 2, 1024 x 1366 portrait | `web-IPAD-E01-A03-web-read--30704-F-and-resume-its-saved-page/IPAD-E01-A03-pdf-resumed.png`      | Passage 2 is visible, counter 2 of 3. Page placement and toolbar are intact; the following page begins below the viewport.                                                                                          |

## Failures and corrections

### Native simulator recovery

The initial native run passed all four HTTP tests, then stalled in Xcode preflight without starting either native test. When the disk filled, that attempt was stopped. Task-generated build output and browser runtime caches were removed; source changes, dependency installations, user files and captured evidence were preserved. The installed simulator asset occupies approximately 7.5 GiB. Its removal was interrupted before the user authorized resuming after freeing space.

The resumed attempt used the cached runtime, restarted the local PostgreSQL container and disabled parallel native testing to avoid creating multiple active test devices. Run `run-32399-1791221842979` passed all four HTTP tests without retries. Xcode again stalled before test execution. A one-second process sample shows its simulator profile queue blocked in the kernel `stat` call while loading a runtime profile. Simulator boot and cache creation were also blocked. Stopping orphaned processes from the task-created simulator released substantial swap allocation; free disk space stabilized at approximately 44 GiB. These measurements do not attribute all system storage or memory use to this task.

Service restarts and runtime unmount/remount attempts did not restore booting. The system-owned `simdiskimaged` service remained blocked; a noninteractive administrator restart was unavailable because macOS requires a password. No password was requested. A Mac restart is the next recovery step before native UI work can resume. The harness was stopped, with its temporary database and server processes cleaned up. This is an interrupted environment attempt, not a native test pass or an assertion failure.

The run directory preserves `run.log`, `xcode-stall.sample` and `core-simulator-recovery.log`. No native screenshots, accessibility result or valid native test report were produced. The prior compiled tests still require actual execution.

### Browser and regression checks

Cold Vite development compilation exceeded the initial navigation assertion deadline. The harness now builds and serves production output before timed UI assertions. A search assertion counted a hidden tooltip from an old card; the corrected test verifies the authorized response and visible results. The PDF record route legitimately retains a details query parameter; its assertion now accepts that route.

The first web OIDC test failed because the external provider fixture accepted only native callbacks. Its exact allowed callback list now includes the local web callback, and the harness explicitly configures the matching app URL. The final journey signs in through the actual provider button and callback routes.

Run `run-1025-1791219144297` exposed the PDF test leaving after an optimistic counter change, before the save completed. Its `test-failed-1.png` and `trace.zip` remain in that run's PDF artifact directory. The agent opened the failure image: counter 2 was visible while passage 1 remained on screen. The corrected test awaits the public page-2 save response, page-2 viewport placement, and the destination UI before checking persisted progress and reopening. The final run passed with passage 2 visible. No fixed sleep, automatic retry, or failure quarantine was introduced.

The required native matrix, human-reviewed baseline comparisons, measured native performance budgets, controlled native failures, actual device installation/network/audio/VoiceOver proofs and full integrated human walkthrough remain outstanding. See [README.md](README.md) for the remaining implementation scope and [review.md](review.md) for the separate Standards and Spec findings.
