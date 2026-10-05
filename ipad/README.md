# Private iPad client

Implementation of [issue #2](https://github.com/mooneeb/bookorbit/issues/2) is in progress. This checkout currently provides a native server profile, local/OIDC sign-in, Keychain credentials, refresh/logout, default-password change, bounded library search/sort with list/grid presentation, and book/file details. The complete issue is not finished.

## Build

Use Xcode 27, XcodeGen 2.46, Node 24 or later, and the pnpm version declared in the root package.json. The deployment target is iPadOS 26. The private bundle identity is `com.mooneeb.bookorbit.private`; retain it for future upgrades and signing renewal.

```sh
pnpm install --frozen-lockfile
pnpm ipad:contracts
xcodegen generate --spec ipad/project.yml
xcodebuild build-for-testing \
  -project ipad/BookOrbit.xcodeproj -scheme BookOrbit \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath ipad/DerivedData \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
```

Open the generated `ipad/BookOrbit.xcodeproj` in Xcode to run the app. Enter the server's base URL, including any deployment path prefix. The app appends `/api/v1`. HTTPS is recommended for a server outside localhost; the simulator can use `http://localhost:16482` with the fixture below. HTTP localhost in the simulator reaches the Mac. A physical iPad needs an address reachable from that device.

Credentials are stored as a single Keychain item per server profile, using `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. UserDefaults holds only the server URL. Refreshes are serialized; rotated credentials are persisted before success. Redirects to another origin are rejected by the authenticated HTTP transport. Session restoration validates the account through `/auth/me`.

## OIDC coexistence

Keep the existing native callback configured. Add the private callback to the BookOrbit server environment and register it with each identity provider:

```dotenv
NATIVE_ADDITIONAL_REDIRECT_URIS=bookorbit-private://oauth2-callback
```

The existing `NATIVE_REDIRECT_URI` defaults to `bookorbit://oauth2-callback`. Additional callbacks require exact matches, including scheme and path. No wildcard matching is supported. The app uses ASWebAuthenticationSession, PKCE S256, a random nonce, and callback-state verification. The server still consumes and validates its own state and verifies the provider token.

## Contracts

`scripts/ipad/generate-contracts.mjs` derives Swift Codable models from `packages/types/src/` using the TypeScript type checker. Response projections include fields the entry and library screens currently use. It rejects unsupported type changes rather than silently emitting arbitrary JSON. The generator also derives permission values from the shared enum. Request contracts are implemented by their Nest DTOs, which retain their validation decorators.

```sh
pnpm ipad:contracts
pnpm ipad:contracts:check
```

The audited entry routes are `/auth/login-options`, `/auth/login`, `/auth/refresh`, `/auth/logout`, `/auth/me`, `/auth/change-password`, `/auth/oidc/:slug/state`, and `/auth/oidc/callback`. Browsing uses `/libraries`, `/books/query`, `/libraries/:id/books`, and `/books/:id`. Book query pagination starts at zero. The native client retains one page of 40 books and performs search/sort on the server.

## Isolated integration fixture

Start PostgreSQL and install the browser runtime once:

```sh
pnpm db:up
pnpm exec playwright install chromium --only-shell
pnpm ipad:test:http
pnpm ipad:test:web
```

Each command creates and migrates a unique `bookorbit_ipad_<run>_e2e` localhost database, creates temporary content, starts the real Nest/Fastify application on port 16482, and removes its database after the run. The harness rejects other database names/hosts. It seeds 50,000 books in batches of 500, two accounts, a three-page PDF, and an external OIDC protocol fixture on port 16483. Core controllers, guards, DTO validation, services, and persistence are real. The OIDC fixture is an external-provider substitution with signed tokens and real PKCE validation.

Browser tests build the actual Vue app and serve its production output on port 16484, avoiding development compilation during timed UI assertions. Ports 16482-16484 must be free. Fixture accounts are `ipad-owner` and `ipad-restricted`, with test-only password `IpadFixture123`. To inspect the fixture interactively:

```sh
pnpm ipad:serve:test
BOOKORBIT_API_TARGET=http://localhost:16482 pnpm --filter client exec vite --port 16484
```

Stop the fixture with Ctrl-C. Never point these commands at a home or production database.

For native UI execution, check `xcrun simctl list runtimes` and reuse the installed iOS 26.0 arm64 runtime. If it is missing, install it once:

```sh
xcodebuild -downloadPlatform iOS -buildVersion 26.0 -architectureVariant arm64
```

The runtime asset used here occupies approximately 7.5 GiB; its generated shared cache adds approximately 3.9 GiB, before device data and build output. Create a simulator only if a suitable one is not already available:

```sh
xcrun simctl create 'BookOrbit Test iPad' \
  com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M4-16GB \
  com.apple.CoreSimulator.SimRuntime.iOS-26-0
pnpm ipad:test:ui
```

Use `xcrun simctl list devicetypes` to select an available device type if the identifier differs. `IPAD_TEST_DESTINATION` overrides the Xcode destination. Each run retains evidence under `test-results/ipad/run-<pid>-<timestamp>/`: native attachments in `native.xcresult`, browser screenshots/traces in `browser/`, and the browser report in `browser-report/`. Later runs preserve earlier evidence. No automatic retry or baseline acceptance is enabled.

Native tests run serially on the selected simulator with ad hoc signing. Disabling Xcode signing prevented Keychain access in the tested build. This simulator signature does not require a developer account and does not provide physical-device signing evidence. Verbose system diagnostics are disabled because post-failure `simctl diagnose` stalled on this Mac; test failures, console logs, screenshots, recordings and `.xcresult` reports are retained. After an interrupted simulator boot, consult [verification.md](verification.md) for the current recovery checkpoint before starting another run.

## Current evidence and remaining work

| Named test                          | Boundary                              | Current coverage                                                                                                                                                              |
| ----------------------------------- | ------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| IPAD-E01-A01 HTTP tests             | Authenticated HTTP and delivered file | Native credentials, rotation/revocation, 50,000-book query/search, three-page PDF and byte-range delivery, old/private OIDC callback coexistence, exact callback allowlisting |
| IPAD-E01-A05 HTTP test              | Authenticated HTTP                    | Restricted account cannot list, inspect, or download an inaccessible library                                                                                                  |
| IPAD-E01-A01-web                    | Actual browser                        | Local login, bounded large-library query, search, record reopen/reload, portrait/landscape screenshots                                                                        |
| IPAD-E01-A05-web                    | Actual browser and HTTP               | Restricted navigation and denied file delivery                                                                                                                                |
| IPAD-E01-A01-web-oidc               | Actual browser                        | Controlled provider sign-in and access to the authorized library                                                                                                              |
| IPAD-E01-A03-web                    | Actual browser and HTTP               | Delivered PDF page navigation, saved page 2 and reopen/resume                                                                                                                 |
| testIPADE01A01LocalLoginAndRelaunch | Native XCUITest                       | Passed actual login/search/details/rotation/relaunch, full library accessibility audit, and public-API session revocation/recovery journey                                    |
| testIPADE01A01OIDCLoginAndRelaunch  | Native XCUITest                       | Passed actual system authentication, controlled OIDC, relaunch and sign-out journey                                                                                           |

The implementing agent opened and inspected the final browser library portrait, detail landscape, initial PDF page and resumed PDF page screenshots, and all five final native library/detail/search/expired-session/OIDC captures. Controls and content were reachable; the portrait library title truncates in the compact toolbar while remaining visible in the sidebar. See [verification.md](verification.md) for the test IDs, environment, artifact paths, inspection findings and corrected failures. This review does not establish human-approved visual regression baselines.

Remaining issue #2 deliverables include dashboard/author/series/organization workflows, table/filter/saved-view parity, metadata and cover management, the ebook/PDF/comic/audio readers and their preferences/progress/bookmarks, Read Along/TTS/audio bridging, native engine/CFI/signing proofs, the complete native/browser/artifact acceptance matrix, human-reviewed visual baselines, performance/accessibility budgets and audits, physical-device evidence, AltStore installation/renewal, and the integrated human walkthrough. PDF ink and explicit offline packages remain assigned to issue #3. These requirements have not been waived or represented as passing.

See [the interim two-axis review](review.md) for findings and resolutions against the starting commit.
