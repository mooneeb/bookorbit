# Private iPad client

Implementation of [issue #2](https://github.com/mooneeb/bookorbit/issues/2) is in progress. This checkout provides a native server profile, local/OIDC sign-in, Keychain credentials, refresh/logout, default-password change, bounded library search/sort with list/grid/basic table presentation, book/file details, collection creation/membership, text and bibliographic metadata editing/clearing/locks, ebook/audio cover upload/revert, and production PDF reading with native page curl, direct page navigation, contents, text search and cross-client resume. The complete issue is not finished.

Native author and series browsing is implemented and its independent test handoff is in progress. The authenticated sidebar opens forty-result directories with server search, sorting/direction and accessible-library filtering. Author filters cover photo, sort name, multiple books and recent additions; series filters cover reading/completion/gaps and author name. Profiles expose authorized book pages, biography/series information and the existing permission-aware book details/PDF entry. Query parameter names and sort values follow the existing owning controllers' DTOs, and response models derive from the canonical author/series contracts. No full-library client processing is introduced.

Native Home shelves are implemented and awaiting independent acceptance testing. The owning dashboard batch route supplies enabled book shelves with at most eight shelves and fifty books per shelf. Native controls edit labels, enabled state, order, row/limit and wide/two-column layout, with user/server-scoped local persistence or the existing web shelf synchronization route. Existing synced smart-scope shelves render; the new scope workflow adds a paged picker for named shelves. Podcast configurations are preserved. Actual ebook/audio cover previews use the authenticated image transport, off-main-actor ImageIO thumbnails, three active transfers, at most thirty-two waiting requests and a twenty-four-image cache. Book selection uses the existing authorized details/PDF entry. The generated dashboard settings response projects canonical AuthUser settings separately, preserving the existing stored credential model.

Native scope creation, sharing, editing, deletion, Kobo opt-in and authorized library queries are implemented and awaiting independent acceptance. The new owning `smart-scopes/page` route bounds native directories, while existing scope book queries return forty-result pages. Library filtering supports nested All/Any conditions, canonical field/operator/value choices and up to five sort fields, with explicit Apply/Cancel and stable random paging. [smart-scope-implementation.md](smart-scope-implementation.md) records the passing compilation checks and remaining acceptance work.

The current workflow completes feature implementation, then hands autonomous local API/native/browser/file testing to a separate agent while the implementing agent builds the next feature. Each confirmed defect receives a separate repair agent, and the tester verifies the resulting correction. Isolated checkouts preserve the tested source, existing dependencies/runtimes are reused, and heavy checks are serialized to avoid exhausting this Mac. Physical-device and human-reviewed baseline requirements remain explicit residual gates; unattended simulator testing does not satisfy them.

Native custom metadata values are implemented for all five canonical types, including explicit clears and nullable booleans. The existing authorized book response supplies only enabled fields, and the existing combined metadata save route persists changed values. [custom-metadata-implementation.md](custom-metadata-implementation.md) records the implementation checks and pending independent acceptance.

Native provider matching, identifier lookup and field comparison are implemented, alongside extended provider/series/rating/audio/comic metadata controls and ebook/audio cover search. Choices are staged until Save and existing locks and server permissions apply. Metadata and cover writes acknowledge separately with useful partial-failure feedback. [metadata-match-implementation.md](metadata-match-implementation.md) records bounded transport/image handling, implementation checks and the independent acceptance handoff.

The author/series handoff now has a focused autonomous QA command and public/native/web test mapping in [organization-verification.md](organization-verification.md). Its initial eleven HTTP checks pass, while four full native accessibility audits expose concrete font-scaling and contrast defects that remain gates. The focused reader handoff and browser journeys execute after those native gates pass.

Production comic entry and native page navigation are implemented and awaiting their independent acceptance handoff. The production and proof apps share the bounded page-curl engine and acknowledged progress model. Actual CBZ proof tests passed; the new production path, direct navigation and genuine CBR/CB7 delivery remain acceptance work. [comic-reader-implementation.md](comic-reader-implementation.md) records the boundary and remaining reader controls.

Native saved views and table-column controls are implemented and awaiting independent acceptance. Snapshots preserve the active query, search, presentation and column visibility/order/width, scoped to the server, user and library location. The bounded catalog supports rename, duplicate, favorites and confirmed deletion. Native table rows remain paged and virtualized while wide configured columns scroll horizontally. The web saved-view type now comes from the same canonical shared contract. [saved-view-implementation.md](saved-view-implementation.md) records checks and limitations.

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

Collection navigation uses `/collections/page` with bounded 40-item pages, server search, ownership/public visibility and viewer-scoped book counts. Personal creation and book membership use the existing `/collections` and `/collections/:id/books` routes. Metadata editing uses `/books/:id/metadata-and-locks`, retaining the server's metadata permission and library access checks. Optional generated `FieldUpdate` values omit unchanged fields, encode `.clear` as JSON null, and encode `.set` as the new value. The editor preserves locks outside the currently displayed text fields. It covers bibliographic fields, provider identifiers, series memberships, ratings, custom values, audio and comic metadata. Date and year share the canonical publication lock. Scalar Clear actions encode null, list clears encode empty arrays, and names use one line per entry so commas remain part of a name. Provider matching and cover search stage selected changes before saving. Automatic and embedded metadata preview workflows remain pending.

## Isolated integration fixture

Start PostgreSQL and install the browser runtime once:

```sh
pnpm db:up
pnpm exec playwright install chromium --only-shell
pnpm ipad:test:http
pnpm ipad:test:progress
pnpm ipad:test:web
pnpm ipad:test:cross-client
```

Each command creates and migrates a unique `bookorbit_ipad_<run>_e2e` localhost database, creates temporary content, starts the real Nest/Fastify application on port 16482, and removes its database after the run. The harness rejects other database names/hosts. It seeds 50,000 books in batches of 500, owner/inaccessible-reader/viewer/permitted-editor accounts, a three-page PDF, and an external OIDC protocol fixture on port 16483. Core controllers, guards, DTO validation, services, and persistence are real. The OIDC fixture is an external-provider substitution with signed tokens and real PKCE validation.

Browser tests build the actual Vue app and serve its production output on port 16484, avoiding development compilation during timed UI assertions. Ports 16482-16484 must be free. Fixture accounts are `ipad-owner`, `ipad-restricted` (no library access), `ipad-reader` (library viewer), and `ipad-editor` (permitted non-superuser editor), with test-only password `IpadFixture123`. To inspect the fixture interactively:

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

Use `xcrun simctl list devicetypes` to select an available device type if the identifier differs. `IPAD_TEST_DESTINATION` overrides the Xcode destination. `IPAD_TEST_ONLY=BookOrbitUITests/EntryJourneyTests/testIPADE01A02CreateCollectionAndReopen` selects the collection journey during development. Each run retains evidence under `test-results/ipad/run-<pid>-<timestamp>/`: native results in `native.xcresult`, exported screenshots/recordings and their manifest in `native-attachments/`, `native-summary.json`, browser screenshots/traces in `browser/`, and the browser report in `browser-report/`. Later runs preserve earlier evidence. No automatic retry or baseline acceptance is enabled. The cross-client command runs native UI before browser verification while retaining the same isolated server and database.

`IPAD_TEST_ONLY` also accepts comma-separated classes or methods within the selected scheme, allowing related focused journeys to share one isolated fixture. Filtering is recorded in the run log. A focused pass does not replace the complete native/web gate, and excluded failed journeys remain unresolved. Text-replacement helpers use public keyboard input; single-line fields retain exact blank/replacement assertions after deletion. This substitutes keyboard input and does not prove a physical keyboard.

Focused metadata journeys reuse the selected cached simulator and the same real HTTP/web fixture:

```sh
IPAD_TEST_ONLY=BookOrbitUITests/EntryJourneyTests/testIPADE01A02EditBibliographicMetadataAndReopen \
  pnpm exec node scripts/ipad/run-harness.mjs --ui --web --metadata-proof
IPAD_TEST_ONLY=BookOrbitUITests/EntryJourneyTests/testIPADE01A02ClearBibliographicMetadataAndReopen \
  pnpm exec node scripts/ipad/run-harness.mjs --ui --web --metadata-clears-proof
IPAD_TEST_ONLY=BookOrbitUITests/CoverJourneyTests \
  pnpm exec node scripts/ipad/run-harness.mjs --ui --web --cover-proof
```

Set `IPAD_TEST_DESTINATION` to the installed simulator's `platform=iOS Simulator,id=<UUID>` when it is not named BookOrbit Test iPad. `--inspect-web` retains the successful native result and its isolated server for interactive browser inspection. Stop that exact harness with Ctrl-C when done. The maintained browser tests can run against that retained server with `IPAD_METADATA_PROOF=1`, `IPAD_METADATA_CLEARS_PROOF=1` or `IPAD_COVER_PROOF=1` and a distinct `IPAD_TEST_RUN` artifact identifier. This inspection mode does not run the maintained browser suite automatically.

Cover fixtures are generated locally. The harness adds the two selected PNGs to the chosen simulator's Photos library as a hardware-input substitution, then tests use the actual system picker. Pinned 2030/2031 photo dates distinguish the 640-by-960 image and the 2,400-by-3,600 transparent image across repeated imports. Existing Photos and simulator data are preserved. This proves the repeatable picker/save workflow and delivered image state, not physical camera or Photos input. The focused cover class prepares both the native-reverted originals and the native-uploaded custom image for the browser checks. Individual methods can run with `--ui` during development; a single method does not prepare every cross-client fixture.

Native fault journeys use a localhost proxy on port 16485. It forwards to the same real server, can hold an actual old cover response, and can make selected upload or lock-refresh requests unavailable. Tests release or recover these controlled failures through local controls and verify persistence through the authenticated server on 16482. Core authorization and writes remain real. These cases cover stale previews, retained selections after upload failure, concurrent cover locks, and blocking writes until unavailable lock information can be refreshed.

Native tests run serially on the selected simulator with ad hoc signing. Disabling Xcode signing prevented Keychain access in the tested build. This simulator signature does not require a developer account and does not provide physical-device signing evidence. Verbose system diagnostics are disabled because post-failure `simctl diagnose` stalled on this Mac; test failures, console logs, screenshots, recordings and `.xcresult` reports are retained. After an interrupted simulator boot, consult [verification.md](verification.md) for the current recovery checkpoint before starting another run.

## Current evidence and remaining work

The focused `ipad:test:progress` command uses a separate migrated fixture on localhost port 16487 and runs the independent narration HTTP regression. It can run alongside the standard fixture. Normal HTTP/native/web commands include that regression as well. The focused command does not execute entry, OIDC, native or browser coverage.

For a physical reader proof, the isolated localhost fixture can be exposed on this Mac's private IPv4 interface:

```sh
IPAD_PHYSICAL_HOST=192.168.0.109 node scripts/ipad/physical-proxy.mjs
```

Replace the address with the Mac's current private IPv4 address. The proxy listens on that address at port 16486, forwards only `/api/v1/` to the isolated localhost server, and exposes no fault-control routes. Stop it with Ctrl-C when the check is finished. The iPad enters `http://<Mac-private-address>:16486` through the ordinary server-profile UI. The test helper can receive the same URL through `TEST_RUNNER_IPAD_PROOF_SERVER_URL`; Xcode passes `TEST_RUNNER_` variables to the runner with that prefix removed. [Apple environment-variable reference](https://developer.apple.com/documentation/xcode/environment-variable-reference).

The proof build can temporarily use the task's existing private bundle slot with `BOOKORBIT_READER_PROOF_BUNDLE_IDENTIFIER=com.mooneeb.bookorbit.private`. Restore the normal signed `BookOrbit` build in that slot after inspection. The connected Air currently has three free-profile apps installed: the additional proof app and its physical UI test runner were rejected by Apple's free-signing limit. Reusing the private slot installs the proof without deleting an app, but it does not make room for the additional UI test runner. Physical launch/reader inspection, Pro performance, AltStore renewal and the integrated walkthrough remain unproved. [verification.md](verification.md) records the exact attempts.

| Named test                                                             | Boundary                                                               | Current coverage                                                                                                                                                                         |
| ---------------------------------------------------------------------- | ---------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| IPAD-E01-A01 HTTP tests                                                | Authenticated HTTP and delivered file                                  | Native credentials, rotation/revocation, 50,000-book query/search, three-page PDF and byte-range delivery, old/private OIDC callback coexistence, exact callback allowlisting            |
| IPAD-E01-A05 HTTP test                                                 | Authenticated HTTP                                                     | Restricted account cannot list, inspect, or download an inaccessible library                                                                                                             |
| IPAD-E01-A01-web                                                       | Actual browser                                                         | Local login, bounded large-library query, search, record reopen/reload, portrait/landscape screenshots                                                                                   |
| IPAD-E01-A05-web                                                       | Actual browser and HTTP                                                | Restricted navigation and denied file delivery                                                                                                                                           |
| IPAD-E01-A01-web-oidc                                                  | Actual browser                                                         | Controlled provider sign-in and access to the authorized library                                                                                                                         |
| IPAD-E01-A03-web                                                       | Actual browser and HTTP                                                | Delivered PDF page navigation, saved page 2 and reopen/resume                                                                                                                            |
| testIPADE01A03ProductionPDFCurlAndResume                               | Native XCUITest, authenticated HTTP and delivered PDF                  | Production Read action, literal page text, genuine curl, rotation, acknowledged save, relaunch and full accessibility audits                                                             |
| testIPADE01A03PDFPageNavigationAndResume                               | Native XCUITest, controlled HTTP delay and delivered PDF               | Invalid page constraints, direct page three, Cancel while saving, real acknowledgement, relaunch, subsequent curl and full accessibility audits                                          |
| testIPADE01A04PDFSearchAndResume                                       | Native XCUITest, authenticated HTTP, delivered PDF and rendered pixels | No-match/case-insensitive search, actual highlighted match, saved page, curl clearing, relaunch and full accessibility audits; corrected helper execution passed                         |
| testIPADE01A04PDFContentsAndResume                                     | Native XCUITest, authenticated HTTP and delivered PDF                  | Nested outline, Back, actual passage, acknowledged progress, relaunch, curl and unfiltered audits; focused execution passed                                                              |
| testIPADE01A01LocalLoginAndRelaunch                                    | Native XCUITest                                                        | Passed actual login/search/details/rotation/relaunch, full library accessibility audit, and public-API session revocation/recovery journey                                               |
| testIPADE01A01TableBrowseSearchAndOpen                                 | Native XCUITest and authenticated HTTP                                 | Bounded forty-row table, exact paging/back/search records, full portrait/search/landscape audits and correct PDF book/file details; focused execution passed                             |
| testIPADE01A01OIDCLoginAndRelaunch                                     | Native XCUITest                                                        | Passed actual system authentication, controlled OIDC, relaunch and sign-out journey                                                                                                      |
| IPAD-E01-A02/A05 collection HTTP                                       | Authenticated HTTP                                                     | Bounded collection pages, ownership, public visibility, scoped book counts, query validation and denied membership writes                                                                |
| testIPADE01A02CreateCollectionAndReopen                                | Native XCUITest                                                        | Collection creation, duplicate-name correction, membership, visible title placement and relaunch                                                                                         |
| IPAD-E01-A02-web                                                       | Actual browser and HTTP                                                | Reopen native-created collection and membership, reload, and inspect completed book details                                                                                              |
| IPAD-E01-A02/A05 metadata HTTP                                         | Authenticated HTTP                                                     | Permitted non-superuser changes, denied viewer edits, explicit null clears, omitted-field preservation, public reopen, Unicode storage limits and DTO validation                         |
| testIPADE01A02EditMetadataAndReopen                                    | Native XCUITest                                                        | Edit title/subtitle/description, clear only subtitle, preserve description, save and reopen                                                                                              |
| testIPADE01A02MetadataLocksAndReopen                                   | Native XCUITest                                                        | Enable title lock, save and confirm disabled title after app relaunch                                                                                                                    |
| testIPADE01A05PermittedEditorMetadataControls                          | Native XCUITest                                                        | Specific metadata permission allows a non-superuser to open the editor                                                                                                                   |
| testIPADE01A05ReadOnlyMetadataControls                                 | Native XCUITest                                                        | Library viewer can inspect the record and has no metadata edit action                                                                                                                    |
| testIPADE01A05MetadataUnicodeValidation                                | Native XCUITest                                                        | Rejects combining-mark/presentation-selector inputs beyond storage limits, accepts astral emoji, discards canceled drafts and passes an unfiltered invalid-state accessibility audit     |
| testIPADE01A02EditBibliographicMetadataAndReopen                       | Native XCUITest and authenticated HTTP                                 | Publication, identifiers, comma-preserving names, canonical date/year lock, Save and exact values after termination/relaunch                                                             |
| IPAD-E01-A02 bibliographic web                                         | Actual browser and authenticated HTTP                                  | Exact native-saved publication/identifier/relation values and lock state in the web editor before and after reload                                                                       |
| testIPADE01A05MetadataRelationNameValidation                           | Native XCUITest and authenticated HTTP                                 | Unicode scalar name limits, invalid/exact-limit inputs, cancellation and an unfiltered accessibility audit                                                                               |
| testIPADE01A02ClearBibliographicMetadataAndReopen                      | Native XCUITest and authenticated HTTP                                 | Explicit Clear controls, seven null scalars, three empty lists, unchanged title, termination/relaunch and an unfiltered audit                                                            |
| IPAD-E01-A02 cleared metadata web                                      | Actual browser and authenticated HTTP                                  | Native-cleared values remain empty in the public record and actual editor after web reload                                                                                               |
| testIPADE01A02UploadReopenAndRevertEbookCover                          | Native XCUITest, HTTP and delivered images                             | Actual Photos selection, staging without persistence, versioned upload, exact dimensions/pixels, relaunch, exact original restoration, unchanged audio slot and full accessibility audit |
| IPAD-E01-A02 reverted covers web                                       | Actual browser, HTTP and delivered images                              | Native-reverted ebook/audio images decode and render with the original dimensions/pixels before and after web reload                                                                     |
| IPAD-E01-A02/A05 cover permissions and locks HTTP                      | Authenticated HTTP and delivered images                                | Denied viewer/restricted/anonymous writes, invalid requests, independent medium locks, unchanged denied artifacts and exact revert bytes                                                 |
| testIPADE01A05CoverLocksAndReadOnlyControls                            | Native XCUITest and authenticated HTTP                                 | Hidden viewer editing, independent metadata cover locks, staging/Save/relaunch, unchanged artwork and unfiltered metadata/cover audits                                                   |
| testIPADE01A02UploadPreservesOriginalResolutionAndTransparency         | Native XCUITest, HTTP and delivered images                             | Original 2,400-by-3,600 PNG dimensions and transparency survive Save/relaunch, audio remains unchanged, and full accessibility audit passes                                              |
| IPAD-E01-A02 original custom cover web                                 | Actual browser, HTTP and delivered images                              | Native custom PNG retains dimensions, decoded/rendered alpha and known pixels before and after web reload                                                                                |
| testIPADE01A02ConcurrentCoverLockRetainsSelectionAndReloadsLocks       | Native XCUITest, HTTP and delivered images                             | A real second session locks the cover; denied Save retains the selection, refreshes locks and blocks edits until unlock/reload; unchanged denied bytes and successful recovery           |
| testIPADE01A02DelayedOldCoverCannotReplaceSavedPreview                 | Native XCUITest, controlled HTTP delay and delivered images            | Releases a captured old image after Save and verifies that the actual rendered preview and delivered file retain the new known pixels                                                    |
| testIPADE01A02CoverFailuresRetainSelectionAndRequireAuthoritativeLocks | Native XCUITest, controlled HTTP failures and delivered images         | Upload retry retains selection; failed conflict refresh blocks writes until successful reload; independent audio remains unchanged; full error-state accessibility audit                 |

The earlier combined collection/initial-metadata run passed all 6 HTTP tests, all 8 native journeys and both cross-client browser tests. The second browser test reopens the corrected native text, verifies the null subtitle and preserved description, reloads and confirms the disabled locked title. The implementing agent opened all 20 native and all 4 browser PNGs from that run. The full expanded production run passed nine HTTP journeys and 18 of 21 native journeys, with three failures; browser execution was gated. All 79 actual native PNGs were inspected. A corrected focused run subsequently passed cover resolution/transparency and collection conflict recovery/membership/relaunch, with all seven PNGs inspected. The narrowed relation-editor contrast correction and Unicode input regression subsequently passed in focused native journeys. The new table journey has a genuine missing-control RED and a focused GREEN alongside sign-in/relaunch/expiry: both native journeys passed, including bounded paging/search, portrait/search/landscape full audits and correct PDF details. All nine actual PNGs were inspected. A new complete aggregate pass remains required. See [verification.md](verification.md) for test IDs, configuration, exact artifact paths, inspection findings and corrected failures. This review does not establish human-approved visual regression baselines.

Remaining issue #2 deliverables include dashboard/author/series/scope/sharing workflows, remaining table/filter/saved-view parity, metadata matching/custom fields and cover search/version controls, integrated EPUB/comic/audio readers, reader preferences/bookmarks, broader PDF contents/search coverage, Read Along/TTS/audio bridging, unresolved EPUB accessibility and physical engine proofs, the complete native/browser/artifact acceptance matrix, human-reviewed visual baselines, measured performance, physical-device evidence, AltStore installation/renewal, and the integrated human walkthrough. PDF ink and explicit offline packages remain assigned to issue #3. These requirements have not been waived or represented as passing.

See [the interim two-axis review](review.md) for findings and resolutions against the starting commit.

## Reader feasibility target

`BookOrbitReaderProof` is a separate native app target with its own bundle identity. It reuses the existing authenticated connection and bounded library browser. PDF and comic reader sources are shared with the production app; the new production comic entry awaits independent acceptance. The EPUB experiment remains separate pending its accessibility, security and performance gates.

```sh
pnpm ipad:test:reader-proof
```

This command uses the cached simulator runtime, the real isolated server and delivered PDF. The first native tracer is `testIPADE01A03PDFCurlAndResume`, covering actual delivered page text, a horizontal turn, public persisted page position, rotation and relaunch. The isolated PDF tracer passed curl, rotation, acknowledged-save relaunch and full first/resumed-page accessibility audits. A second native tracer holds a real progress request to verify closing during a pending save. Run `pnpm ipad:test:reader-cross-client` to run both native tracers and the actual web PDF handoff against the same fixture. Both native PDF tracers and the actual pixel-verified browser handoff passed together. The persistent-save-failure Retry/discard tracer also passed independently. Additional reader engines, measured performance, deterministic visual comparisons and physical-device checks remain required for issue completion.

### Native comic experiment

```sh
pnpm exec node scripts/ipad/run-harness.mjs --ui --reader-proof --web --comic-proof
```

The separate proof target reads actual authenticated CBZ page images through a native horizontal curl. A generated three-image archive has intentionally shuffled entries to verify natural page ordering with independent literal image OCR. Streamed image delivery is capped at 20 MiB; ImageIO decodes off the main actor with a 3,072-pixel maximum dimension, retaining only the current/adjacent page window. Completed turns save the canonical one-based text page and clear obsolete text companions, leaving narration independent. Closing waits for acknowledgement and exposes retry or confirmed discard after a failed save.

`testIPADE01A04ComicCurlRotationAndResume` verifies actual image pixels, curl, rotation, public progress, relaunch and full unfiltered audits. `IPAD-E01-A04-comic-web` opens the actual web Read action and recognizes the native-saved page before and after reopening/reload. The missing-Read, accepted stale-locator and visible web Back control REDs are retained in [verification.md](verification.md). The focused native journey and subsequent browser handoff passed against the same native-saved fixture; the existing PDF curl/resume regression also passed. This is CBZ feasibility; general comic formats, controlled failures, measured performance, physical evidence and production integration remain required.

### Local EPUB anchor experiment

```sh
IPAD_TEST_ONLY=BookOrbitReaderProofUITests/EPUBReaderProofTests pnpm ipad:test:epub-proof
```

The command creates the small two-chapter EPUB with decoded 24-second recorded AAC using the already installed Fred voice and ffmpeg. It seeds that file alongside the existing PDF in the same isolated 50,000-book server fixture. The native inspector opens actual chapter text through bundled Foliate modules, resolves an entered range CFI and displays its observed text and generated round-trip anchor. The known test range includes an astral emoji and a combining mark. Loading, range resolution, fresh resolution after rotation and actual selected-passage painting passed. Acknowledged native save/reopen/relaunch passed; saving a new CFI clears obsolete device text locations while preserving independent narration. The actual web Read action and reload resume the saved second chapter, verified by exact OCR of captured pixels. The separate unfiltered content accessibility test fails on the first paragraph's reported hit region, including after all script touch/pointer handlers are removed. Security and narration playback checks remain pending. Normal PDF proof commands select only the PDF class; the EPUB command without a filter runs both proof classes.

The current experiment bounds publication resources to 8 MB and four simultaneous native requests. Audio, hostile-content tests, interrupted/concurrent saves, genuine EPUB curl and measured engine performance remain required; no engine selection or production integration is claimed.

A separate native chapter diagnostic reads the first linear delivered XHTML resource into a genuine selectable TextKit 2 UITextView. Its plain-paragraph parser accepts at most 64 KiB and 32,768 UTF-16 units, with explicit paragraph/depth limits and external entities disabled. It preserves Unicode characters without normalization and does not apply publication CSS. The public native journey passed exact Unicode, independent screenshot OCR and unfiltered portrait/landscape audits, alongside the PDF launch/curl/resume regression. This supplies a native text accessibility feasibility result; CFI mapping, native selection, rich publications, pagination, progress, security/configuration/performance coverage and physical acceptance remain required before integration. The original WebKit audit failures remain recorded.

```sh
IPAD_TEST_ONLY=BookOrbitReaderProofUITests/EPUBReaderProofTests/testIPADE01A05NativeDeliveredChapterAccessibility pnpm ipad:test:epub-proof
```

```sh
IPAD_TEST_ONLY=BookOrbitReaderProofUITests/EPUBReaderProofTests/testIPADE01A03EPUBSaveReplacesDevicePositionsAndPreservesNarration pnpm exec node scripts/ipad/run-harness.mjs --ui --reader-proof --epub-proof --web
```

### Production PDF reader

```sh
pnpm ipad:test:pdf-reader
```

The focused command drives the production BookOrbit app through local sign-in, file details, Read, known PDF text, horizontal native curl, rotation, acknowledged position save and app relaunch. It then opens the actual web app and independently verifies the rendered second-page passage before and after reload. `testIPADE01A03ProductionPDFCurlAndResume` and `IPAD-E01-A03-web` are the named journeys. The full `ipad:test:cross-client` gate includes this handoff. Native and browser assertion failures remain gates; this command does not substitute for bookmarks, contents/search, alternative modes, appearance/performance coverage or the integrated human walkthrough.

To include the direct-page-navigation and controlled-save-delay journey:

```sh
IPAD_TEST_ONLY='BookOrbitUITests/EntryJourneyTests/testIPADE01A03PDFPageNavigationAndResume,BookOrbitUITests/EntryJourneyTests/testIPADE01A03ProductionPDFCurlAndResume' pnpm ipad:test:pdf-reader
```

The final focused navigation run passed nine HTTP journeys, both selected native journeys and the actual-browser handoff/reopen. All twelve native and both browser PNGs, both public progress records and both OCR outputs were opened and inspected. [verification.md](verification.md) records exact artifacts and the remaining complete 19-native/7-browser production aggregate. The load-guard source concern was removed; the before-guard controlled-delay run passed from an unset saved page and does not establish a reproduced lifecycle failure.

### Production PDF text search

```sh
IPAD_TEST_ONLY=BookOrbitUITests/EntryJourneyTests/testIPADE01A04PDFSearchAndResume pnpm ipad:test:pdf-reader
```

Search reads the already delivered local PDF with native asynchronous PDFKit search. It shows the first 100 matches, offers refinement feedback and opens the actual page with a transient native highlight. Clear search resets the query and results; page turns and closing clear the highlight. The named public native journey verifies the literal delivered passage, public saved position, relaunch and actual browser handoff. Rendered-pixel assertions recognize the literal source line independently and require localized highlight fill, then its absence after curl away/back and relaunch. A painting-disabled sensitivity run failed the new assertion as intended. The restored three-PDF-journey/web regression passed, and fresh native search passed with the corrected screenshot buffer; engine-scale, cancellation/failure/configuration coverage and the complete expanded 20-native/7-browser gate remain pending. See [verification.md](verification.md) for exact runs and limitations.

### Production PDF contents

```sh
IPAD_TEST_ONLY=BookOrbitUITests/EntryJourneyTests/testIPADE01A04PDFContentsAndResume \
  pnpm ipad:test:pdf-reader
```

Contents reads the outline from the actual delivered local PDF, presents one level at a time with bounded sibling pages, and follows valid local page destinations. Back restores the parent contents position; selecting a page uses the existing acknowledged save path. `testIPADE01A04PDFContentsAndResume` verifies actual root/nested titles, Back, passage three, public progress, relaunch, subsequent native curl and full accessibility audits. Its combined cover/PDF-search/curl run and actual browser handoff passed. All twenty native and both browser screenshots were opened and inspected. Outline pagination, malformed/no-outline files, engine-scale/configuration/physical evidence and the complete expanded 21-native/7-browser aggregate remain pending. [verification.md](verification.md) records RED, GREEN and exact artifacts.
