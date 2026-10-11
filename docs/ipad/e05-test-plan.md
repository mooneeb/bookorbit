# E05 focused acceptance harness

Issue: https://github.com/mooneeb/bookorbit/issues/6

This extends the existing real BookOrbit HTTP/PostgreSQL and XCUITest harness. It is a focused acceptance slice. It does not close the complete E05 inventory or its integrated human walkthrough. See [e05-inventory.md](e05-inventory.md) for the remaining enabled actions and stories.

## Environment and independent setup

Node >=24, pnpm >=9, migrated localhost PostgreSQL, Xcode with iOS 26, XcodeGen, and an available iPad Pro simulator are required. No paid signing or testing service is used. E05 uses ten books because the new smoke paths operate on settings and account ownership, while earlier large-library tests retain their 50,000-book fixture.

```sh
node scripts/ipad/run-harness.mjs --e05 --serve --web
```

The harness owns a newly named `bookorbit_ipad_<pid>_e2e` database and temporary content root. It runs the actual server on 16486 and actual compiled web app on 16588, leaving the existing journey ports untouched. It writes `test-results/ipad/<run>/environment.json`, `e05-fixture.json`, `e05-runtime.env`, command logs, and `server.log`. Interrupt the owning harness to clean up its fixtures. Use `--skip-build` only for retained fixture setup immediately after compiling the same working tree.

The E05 fixture grants existing `ipad-editor` only `manage_app_settings` through the authenticated public permissions route. Fixture setup receives the E05 API URL explicitly. The reader has no administration grants. All proof assertions use visible UI, public authenticated HTTP, or actual returned content; fixture setup does not assert private database state.

## Named tests

| Criteria / QA | Named test                                                               | Exact scope                                                                                                       |
| ------------- | ------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------- |
| A01 / QA1     | `IPAD-E05-A01-http-profile-scope`                                        | Profile name, timezone, locale persistence and account scope; DTO extra-field and anonymous rejection             |
| A01 / QA1     | `testIPADE05A01ProfilePersistsAcrossRelaunch`                            | Visible native profile save and reload, screenshot states, accessibility audit                                    |
| A01 / QA1     | `IPAD-E05-A01-web-profile-cross-client`                                  | Actual browser profile matches authenticated account; with `IPAD_E05_EXPECT_NATIVE=1`, requires native saved name |
| A02 / QA2     | `IPAD-E05-A02-http-session-revocation`                                   | Session ownership and refresh rejection after revocation                                                          |
| A02 / QA2     | `IPAD-E05-A02-native-magic-link`                                         | Native magic-link token transport, no browser cookie, session ownership, refresh and link revocation              |
| A02 / QA2     | `testIPADE05A02AccountSwitchDoesNotExposePreviousIdentity`               | Visible account switch and session identity isolation; does not prove offline queue isolation                     |
| A03 / QA3     | `IPAD-E05-A03-http-admin-setting-roundtrip`                              | Non-superuser settings grant edits validated upload limit and owner sees persisted value                          |
| A03 / QA3     | `IPAD-E05-A03-library-creator`                                           | Non-superuser library creator gets ownership and can read, change and remove their library                        |
| A03 / QA3     | `testIPADE05A03AuthorizedSettingsAdmin`                                  | Permission-scoped native menu and actual authentication-policy toggle, save and reload                            |
| A04 / QA4     | `IPAD-E05-A04-http-specific-permission-denials`                          | Reader and settings administrator cannot access user/magic-link/superuser work outside their grants               |
| A04 / QA4     | `IPAD-E05-A04-library-scope`                                             | Unassigned library metadata and access changes are rejected; superuser-only actions remain rejected               |
| A04 / QA4     | `testIPADE05A04ReaderCannotOpenAdministration`                           | Native reader settings screen does not expose administration                                                      |
| A04 / QA4     | `IPAD-E05-A04-web-permission-settings`, `IPAD-E05-A04-web-reader-denied` | Actual browser settings subset and public configuration denial                                                    |
| A05 / QA5     | `testIPADE05A05RenewalGuidancePreservesIdentity`                         | Visible renewal guidance and same-session app relaunch only                                                       |
| A06 / QA6     | Existing E01-E04 suites and inventory                                    | Not replaced by these smoke tests; integrated five-journey evidence remains required                              |

`IPAD-E05-A03-web-authentication-policy` additionally checks the actual web users form against the registration policy returned by authenticated HTTP after the native save.

The `native-magic-link` name denotes native HTTP transport. It is an authenticated server test, not evidence of a native UI login gesture.

## Run retained surfaces

```sh
source test-results/ipad/<run>/e05-runtime.env
node scripts/ipad/e05-runner.mjs
export IPAD_E05_DEVICE_ID='<available iPad Pro UDID>'
node scripts/ipad/e05-native-runner.mjs --build-only
node scripts/ipad/e05-native-runner.mjs --reuse-build
IPAD_E05_EXPECT_NATIVE=1 pnpm exec playwright test --config scripts/ipad/e05-web.config.mjs
```

The native build and test runner holds `/tmp/bookorbit-ipad-xcode.lock`, disables parallel simulator testing, and uses the existing `ipad/DerivedData` cache. Only one agent or runner may own Xcode. `--build-only` prepares the actual app and UI test bundle without performing feature validation. `--reuse-build` is valid only after that same working tree has successfully built.

For a focused smoke set, set comma-separated fully qualified `IPAD_TEST_ONLY` values: `BookOrbitUITests/E05AcceptanceJourneyTests/testIPADE05A01ProfilePersistsAcrossRelaunch`, `.../testIPADE05A03AuthorizedSettingsAdmin`, and `.../testIPADE05A04ReaderCannotOpenAdministration`. A targeted rerun uses a fresh `IPAD_TEST_ARTIFACTS` subdirectory to preserve the original `.xcresult` and attachments. Do not silently retry failed tests.

The native runner exports `native.xcresult`, `native-summary.json`, `native-attachments/`, profile metadata and command logs even for test failures where the result bundle exists. Browser tests retain failure screenshots, trace and HTML report in `e05-browser/` and `e05-browser-report/`. The runner rejects skipped or expected-failure native tests.

## Visual gate and inspection

```sh
source test-results/ipad/<run>/e05-runtime.env
node --input-type=module -e 'const {compareE05Captures}=await import("./scripts/ipad/e05-visual.mjs"); await compareE05Captures(process.env.IPAD_TEST_ARTIFACTS, process.env.IPAD_E05_PROFILE, "web");'
```

`e05-visual.mjs` preserves actual images and compares against `ipad/VisualBaselines/E05/reviews.json`. A baseline entry must explicitly record human review, reviewer, valid date, checksum, pixel threshold, changed-pixel budget and its rationale. There is no baseline creation or acceptance command. Missing baselines remain `pending-human-baseline` and fail the gate. Passing UI assertions or agent image inspection do not change that status.

The default smoke profile is an actual 13-inch iPad Pro, portrait, light appearance, default Dynamic Type and animations enabled. Earlier shared representative profiles provide 11-inch, landscape, dark, large type and narrow browser viewports. Full matrix execution, native narrow-window bounds and verified Reduce Motion remain open until actual configuration evidence is recorded. Captures check requested geometry; unsupported native narrow-window geometry fails. E05 screenshots currently have no masks. Open actual and any expected/diff images and record test ID, state, configuration, artifact path and findings in the evidence document. T3 collaborative browser preview is used for agent inspection; actual native screenshots come from the local XCUITest/simulator harness.

## Remaining proof

Profile/avatar/privacy/preferences, custom icons, supported locale layouts, onboarding, release and notification destinations are not completely covered by profile-name smoke. Controlled OIDC/recovery/magic-link UI, offline cached books and queued edits across account switching, all administration families, ingestion/reading after configuration, and audit output need additional real joined evidence. A05 guidance/relaunch does not establish a same-identity binary update, offline annotation preservation, dispatch after reconnect or signing renewal.

Physical residuals include Home Screen icon and notification behavior, production identity/email integration, real home-server paths/provider credentials, actual TTS/font appearance and audio, Pencil and Scribble behavior in the integrated earlier journeys, and real AltStore/AltServer free signing, background/Shortcuts conditions and expiry recovery without deleting app data. Human-reviewed visual baselines, the complete representative matrix, performance budgets and the full five-journey human walkthrough remain gates before issue closure.
