# E05 run evidence

This record distinguishes implementation, executed assertions, visual inspection and unresolved gates. It must not be treated as complete acceptance of issue 6.

## Current isolated run

- Run: `run-56722-1791745741757`, started October 11 2026 at approximately 19:09 UTC.
- Actual API: `http://localhost:16486/api/v1`; actual web: `http://localhost:16588`.
- Database: `bookorbit_ipad_56722_e2e`, independently migrated PostgreSQL; ten-book fixture and temporary content root.
- Native simulator: `91D39F27-170D-47B7-962A-6966925F667F`, BookOrbit E05 Isolated iPad, iPad Pro 13-inch M5, iOS 26.0.
- Environment and detailed server/command logs: `test-results/ipad/run-56722-1791745741757/`.
- Canonical shared contract check and server TypeScript compilation passed during setup; actual client build completed.

## Findings and repairs before handoff

The first fixture attempt failed because `shellQuote` was scoped to E03. A retained setup then found that port 16488 was already used, so E05 web uses 16588. A tester identified that E05 fixture HTTP setup had inherited the earlier 16482 API URL at module import; explicit E05 base URL delivery corrected the target and the settings administrator now has only `manage_app_settings`. The settings test was corrected to use the canonical `AuthUser.permissions` field.

The initial serialized `build-for-testing` caught native production integration errors: the profile file-import completion type, missing generated authentication and configurable-library properties, and optional library folders. Feature owners received exact compiler locations; the failed build output is retained as `e05-build-output.log`. No failure was converted to a passing result or an accepted visual baseline.

The final actual app and UI test bundle `build-for-testing` succeeded. Its successful output is retained as `e05-test-rebuild-output.log`. A later test-run path guard exposed duplicate slashes in the runtime artifact path; the tester normalized that path before running, and the runner now normalizes paths itself.

## Authenticated HTTP results

The independent HTTP tester reports 19 unique checks passed, zero failed and zero skipped against the real isolated API on 16486. This includes the seven named harness cases, native token DTO/transport validation, refresh rotation and retry grace, revoked/expired session rejection, browser cookie transport, logout and a fresh non-superuser permission snapshot. Original and corrected tester outputs remain in the same artifact directory. The original five passing cases and two harness setup/contract failures were followed by a targeted two-case passing repair run; failures were preserved rather than silently retried.

Exact report: [e05-http-tester-report.json](../../test-results/ipad/run-56722-1791745741757/e05-http-tester-report.json). Passing HTTP checks do not prove native queued offline dispatch, native UI identity isolation or the complete administration journey.

## Native run and controlled offline repair

The original native session 87612 selected A01 profile persistence, A03 authorized settings and A04 reader denial. It remained blocked during launch/initialization of the fresh iOS 26 simulator with zero of three tests started. The parent explicitly terminated the original session once at 19:21:08 UTC. No retry, simulator erase, product failure or native UI pass is claimed.

The original `native-smoke-tester.log`, installation/test-manager/process diagnostic logs, partial `native.xcresult` and `native-inprogress-1917.png` are retained. Summary export failed with status 64 after the interruption. The tester opened and inspected the actual image: it shows SpringBoard and the grey UI test runner icon, with no product settings screen. Product clipping, controls, navigation and accessibility therefore remain unassessed. Exact report: [native-tester-report.md](../../test-results/ipad/run-56722-1791745741757/native-tester-report.md).

The tester reproduced an offline local appearance defect using the unchanged actual `NativeAppearanceModel` and a controlled URLSession connection refusal. Saving dark/grid with sync disabled originally restored system/list after model recreation. After the repair, three checks passed on the updated actual source: `E05-OFFLINE01` local dark/grid survives recreation; `E05-OFFLINE02` local success and an account warning coexist; `E05-OFFLINE03` another user retains defaults. Source and RED/GREEN outputs are retained as `native-offline-appearance-repro.swift/log` and `native-offline-appearance-retest.swift/log`. These are actual model and controlled transport-failure checks, not native screen evidence.

## Full regression results

The root `pnpm test` command ran once and exited 1. Charts passed 35 tests and PR policy passed 19. Server results were 15,543 passed, eight failed and 13 skipped. The root command chain stopped at the server failure, so its remaining client stage was executed once separately; that command exited 0 with 7,267 tests passed. The aggregate is 22,864 passed, eight failed and 13 skipped. This is not a fully passing regression result.

The six failing server test files and their directly involved production paths are byte-identical to baseline commit `7270aacb4bb51c49da4fc2a9addf2f94cb23b275`. They are unchanged failure candidates. The baseline was not separately executed, so byte equality does not establish reproduced baseline failures. The report lists the architecture allowlist, cover mock argument, scanner module imports, bulk rename fixture, upload module exports and publisher transaction fixtures, with proposed repair checks.

Original full report: `/tmp/bookorbit-e05-full-test-report.json`; root log: `/tmp/bookorbit-e05-full-test.log`; client supplement log: `/tmp/bookorbit-e05-client-test.log`. Copies are retained in the isolated artifact directory as `e05-full-test-report.json`, `e05-full-test.log` and `e05-client-test.log`. No additional regression loop was run for this documentation update.

## Pending evidence

The final browser run executed the existing `IPAD-E05-A03-web-authentication-policy` check: one test passed in 4.6 seconds. The owner-visible registration policy matched authenticated API state. Its actual PNG was opened and inspected: [IPAD-E05-A03-web-registration-policy.png](../../test-results/ipad/run-56722-1791745741757/e05-browser/e05-web-IPAD-E05-A03-web-a-03819-rsisted-registration-policy/IPAD-E05-A03-web-registration-policy.png). This limited browser check does not establish a native configuration write or the complete cross-client journey.

Final native/browser end-to-end acceptance remains incomplete. The initial native run produced no executed acceptance tests or product screenshots. A02/A05 additional native slices are implemented but no run is claimed here. HTTP execution selections A05 and A06 now fail explicitly before requests because their coverage is not implemented; inventory listing retains their pending status. All E05 screenshots lack human-reviewed baselines. No expected/actual/diff product comparison passed, and the visual gate remains unresolved.

The complete enabled action/story inventory, full E05 scope, representative visual/accessibility/performance matrix, offline annotation/account-switch/update proof, integrated human walkthrough and documented physical device/live integration/signing checks remain open. A successful build, 19 passing HTTP checks and controlled offline model checks do not close those gates.

See [e05-test-plan.md](e05-test-plan.md) and [e05-inventory.md](e05-inventory.md) for exact scope, runnable commands and remaining physical/integrated checks.
