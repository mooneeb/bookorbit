# E05 code review

Reviewed October 11, 2026 against fixed base `7270aacb4bb51c49da4fc2a9addf2f94cb23b275` using `git diff 7270aacb4bb51c49da4fc2a9addf2f94cb23b275...HEAD`. The frozen review HEAD was `aae6e62328bbcd7611ad0b9367fa245c7a5c7429`. The final narrow follow-up reviewed the original working tree's runner fix and updated run evidence.

The code-review skill ran separate Standards and Spec agents. Sources were AGENTS.md, project contribution and commit guidance, E05 documentation, and the supplied exact issue 6 and parent issue 1 records. The review covered changed production code, shared/generated contracts, generator, harness, every E05 script, native acceptance tests, and E05 documents. Inherited inventory mappings and artifact contents were not all independently verified. No tests, screenshot approvals, or human walkthroughs were performed by this review. Missing issue-tracker setup recommendation: run `/setup-matt-pocock-skills`.

## Standards

No confirmed Critical/P0 or High/P1 production defect was found.

- **Open, Medium/P2:** `ipad/Sources/Settings/NativeAppearanceModel.swift:79` always sends the theme-storage-mode update, including demo-restricted users whose backend rejects it. Save remains enabled and reports an account warning. AGENTS.md requires rejected actions to be hidden or disabled. Pass the restriction into the model and omit prohibited account writes while preserving local appearance saves.
- **Resolved, Medium/P2:** `scripts/ipad/e05-runner.mjs:13` previously accepted A05/A06 execution with no suites and exited successfully. The final patch rejects unsupported execution selections before HTTP requests and permits empty suites only for explicit inventory listing. Default and A01-A04 selection remain unchanged; the harness forwards inventory mode only for listing. Read-only follow-up found no new bug in this patch.

Optional duplication cleanup is omitted from the required follow-up work.

## Spec

- **Open, High/P1 acceptance gap:** `docs/ipad/e05-test-plan.md:67` lists missing joined native/browser, offline-account, administration-effect, and update evidence; `docs/ipad/e05-inventory.md:5` leaves 112 stories and 412 actions open. The spec requires passing native, browser, HTTP/artifact, and visual coverage for every repeatable acceptance behavior. Complete automation, human-reviewed baselines, integrated walkthrough, and justified physical residuals before closing issue 6. This is an acceptance blocker, not a confirmed production defect.
- **Open, Medium/P2:** `ipad/Sources/Settings/PersonalSettingsView.swift:165` documents English fallback. The spec requires localization to retain baseline behavior. Add native translations and supported-locale layout coverage.
- **Open, Medium/P2:** `ipad/Sources/Administration/AdministrationAuthenticationView.swift:48` explains magic links without management controls. The spec includes magic-link/account policies. Implement permitted creation, activation, expiration, and revocation workflows.
- **Open, Medium/P2:** `ipad/Sources/Administration/AdministrationMetadataView.swift:69` exposes enablement without provider credentials or connection tests. The spec requires configuring providers and verifying ingestion/reading effects. Expose baseline configuration and verify those effects.
- **Open, Medium/P2:** `scripts/ipad/e05-visual.mjs:112` requires only one discovered screenshot and validates only discovered captures. The spec requires screenshots for every repeatable acceptance behavior. Enforce required states for the selected journey/profile while retaining human baseline approval.
- **Resolved, Medium/P2:** Unsupported A05/A06 HTTP execution now fails explicitly instead of producing a successful empty run. This does not implement their missing coverage.

The updated run evidence accurately scopes 19 HTTP passes, zero executed native acceptance tests, three controlled offline model checks, one browser policy check passed in 4.6 seconds with its actual screenshot inspected, and aggregate regression results of 22,864 passed, eight failed, and 13 skipped. The browser check establishes owner-visible policy against API state; it does not establish a native configuration write. Unchanged failure paths are correctly described as candidates, without claiming reproduced baseline failures. Native, integrated, visual, and physical acceptance remain open; no baseline approval or issue completion is claimed.

Standards: one open Medium finding and one resolved finding. Spec: five open findings, worst High acceptance gap, and one resolved finding.
