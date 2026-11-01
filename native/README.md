# BookOrbit iPad reader

Implements [issue #57](https://github.com/mooneeb/bookorbit/issues/57), under [the accepted reader specification](https://github.com/mooneeb/bookorbit/issues/24). Base: `f2a7a111881899e7c6cb233a0ec2d8a9c25235c6`. The connected reader from the unmerged #25 branch supplied the initial contained Foliate host.

The owned Swift 6 app targets iPadOS 26.0 and later. Its stable bundle ID is `dev.mooneeb.bookorbit.reader`. SwiftUI owns connection, catalog and book details; UIKit/WebKit owns publication presentation. The checked-in Xcode project builds without XcodeGen. `project.yml` reproduces it with XcodeGen 2.46.0. GRDB is pinned to 7.11.1 in SwiftPM resolution. The frozen Foliate files and bundled notices are listed in [dependencies.json](dependencies.json).

## Build

Use Xcode 27 with Swift 6.4:

```sh
pnpm install --frozen-lockfile
xcodebuild -project native/BookOrbit.xcodeproj -scheme BookOrbit \
  -sdk iphonesimulator -derivedDataPath native/build CODE_SIGNING_ALLOWED=NO build
python3 native/scripts/check-assets.py
```

For physical installation, choose a free Apple Personal Team in Xcode, enable Developer Mode, trust the Mac, and preserve the bundle ID. Apple provisioning access and a free AppID/app slot are prerequisites. Free provisioning lasts at most seven days. Keep Append Team ID unchecked for the accepted SideStore update route. This target has no extensions, push or iCloud requirements. Signing, update continuity and physical accessibility are unpassed until observed on the actual iPad.

## Connection and catalog

Configure an HTTPS origin. The app verifies server identity before and after native sign-in, checks `/auth/me`, and negotiates the versioned reader capabilities before accepting the account. Redirects, cookies and response caching are disabled. Credentials use device-only, after-first-unlock Keychain items scoped by origin, server UUID and account. Refresh is serialized; sign-out invalidates transports and clears credentials while retaining the account's downloaded files.

The existing book-query contract supplies one 50-item native page at a time. Search is bounded to 200 characters. A response above 100 entries is refused. The list contains the current page, with explicit previous/next controls. Backend library/content-filter checks remain authoritative. Download additionally requires `library_download`; capability discovery and catalog browsing remain available without it.

On relaunch, the previously verified account's local catalog opens before reconnecting. Missing credentials, changed capabilities or an unreachable server preserve local reading. Reconnect retries that scope. Different accounts and servers have separate directories and databases.

## Verified offline publications

Download is an explicit book-detail action. A user-adjustable ten-GiB planning budget and one-GiB free-space reserve apply to new transfers. One book download runs at a time per store. Progress and cancellation are exposed. Supported content is ordinary unprotected EPUB 2/3, reflowable or uniformly fixed-layout. Notes, synchronization and saved reading position are unavailable in this slice.

The server prepares an immutable original-byte snapshot plus unmodified archive members. The manifest binds server/account/book, the existing source file UUID, full original SHA-256 and a content-addressed source revision. Preparation checks source changes, normalized paths, entry types, expansion, package/spine declarations and required resource references. Permissions and content filters are checked again when serving each leased resource. Transfer leases expire after thirty idle minutes; snapshots are disposable server caches, not backup records. Multi-replica deployments need lease affinity. Server crashes can leave temporary snapshot files for operator cleanup.

The app downloads to private staging, verifies every byte length and SHA-256, checks package declarations, and flushes files/directories before committing its download record. GRDB uses a serialized DatabaseQueue, versioned migrations, DELETE journal, FULL synchronization and foreign keys. A failed transfer cannot replace the last committed record. Opening rechecks the original and all indexed members. Identifying metadata and bounded local search remain available offline. Stored source bytes are never rewritten into a converted edition. Embedded `data:` resources are explicitly refused before completion; image and font resources must be archive members so native raster bounds apply. The local schema is the extension point for later download/reference/recovery work; this increment does not claim note recovery or sync receipts.

Resource bounds are enforced from the first build: original 512 MiB, expanded members 2 GiB, 20,000 entries, central directory 8 MiB, manifest 256 KiB, consumed text 4 MiB, other buffered members 32 MiB, images 16 million pixels and 8,192 pixels per side, 100,000 nodes per section, ten-second chapter/resource deadline and 128 MiB retained renderer object URLs. Metadata responses are bounded to four MiB. The combined native/WebKit 512 MiB release target still needs representative physical-device pressure measurements.

Only the active package and trusted assets are exposed on loopback, behind an unpredictable session path. The listener bounds headers, connections and concurrent responses. Publication frames receive restrictive CSP; scripts, remote loads, forms, objects and arbitrary navigation are blocked. The WebKit store is nonpersistent. The bridge validates the actual web view, main frame, exact origin, session and bounded message schema. Native tokens and arbitrary file paths never enter publication content. Script/network-dependent content shows partial-reading status; missing resources fail explicitly.

## Isolated QA

The runnable preparation command creates a disposable PostgreSQL container, migrates it, generates controlled EPUBs, seeds 50,000 visible books and 100,000 annotations plus a second owner's private book, and runs authenticated Fastify and native/WebKit scenarios:

```sh
QA_SIMULATOR_ID='<iPad simulator UUID>' native/scripts/qa.sh
```

Requires Docker, pnpm, Xcode, XcodeGen and a previously selected iPad simulator. No production database, books, certificate trust or real account is used. The test-only URLProtocol adapter maps `https://bookorbit-qa.test` requests to the isolated real HTTP listener on `127.0.0.1:55458`. It is compiled only into the test target. The production transport continues to require HTTPS.

The QA database has a four-core/eight-GiB container limit. Node runs on the host; TCP is loopback and PostgreSQL buffers remain warm. Both Fastify and native transport tests record 30 first/next-page repetitions, p50/p95 and failures. These results identify the actual setup and do not certify the complete four-core/eight-GiB server plus conditioned network deployment. `native/build/qa-native.log` and the `.xcresult` bundle contain native results. Review-time results are recorded separately.

The ABeeZee font is an OFL-licensed test fixture, excluded from the app. Its immutable source is google/fonts commit `a8bc01c6dcb2933dca0f37180df6c516e226b346`; see `QAFixtures/OFL.txt`. The image is a generated 96-pixel moon PNG. The EPUB 2 fixture includes its NCX navigation document, which the native test checks through the contained reader. No personal contents or credentials are test evidence. Follow [the physical smoke check](scripts/smoke-check.md) for the remaining device verdict.

### Visible app verification

Run `native/scripts/qa-visible.sh` in one terminal. It serves the generated 50,000-book/100,000-annotation deployment until `native/build/qa-session/stop` exists. `NATIVE_QA_LARGE=0` selects only the format/fault fixtures. `NATIVE_QA_TMPFS=1` places the disposable PostgreSQL data on a bounded one-GiB memory filesystem when investigating low-disk conditions; those runs cannot certify the SSD reference profile.

Build the separate simulator-only verification app with the production screens and model:

```sh
xcodebuild -project native/BookOrbit.xcodeproj -scheme BookOrbitQA \
  -destination 'platform=iOS Simulator,id=<selected simulator UUID>' \
  -derivedDataPath native/build CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- build
```

Install and open `native/build/Build/Products/Debug-iphonesimulator/BookOrbitQA.app` using the device tools. The bundle ID is `dev.mooneeb.bookorbit.reader.qa`, with its own app storage and Keychain identity. Simulator ad-hoc signing is required for Keychain writes. It starts at the isolated origin and uses a QA-target-only URLProtocol adapter to forward it to the real listener on `127.0.0.1:55458`. Other native origins are refused. This is a transport adapter, not a test of TLS certificates. Production builds do not contain that adapter.

Sign in using the generated QA accounts, then drive the issue's connection, search, explicit download and reader controls. For offline reopen, stop the isolated server using `touch native/build/qa-session/stop`, relaunch the QA app and read its downloaded catalog. Do not substitute a DOM-only assertion for the visible workflow. Preserve failed captures and record source identities, versions and actual observations separately.

### Shared server reference profile

`native/scripts/qa-profile.sh` builds and starts an isolated Linux test image with the API and PostgreSQL in one shared four-CPU/eight-GiB cgroup. It requires a clean committed checkout and at least five GiB free on both the host and Docker storage for a build. A cached image whose revision matches the current commit can be reused with a two-GiB startup reserve. The database uses disk-backed container storage. Only the loopback API/probe ports are published; no certificate, production deployment or library is changed. Stop the visible-app deployment first so port 55458 is free.

Once `native/build/qa-profile/ready.json` exists, run:

```sh
node native/scripts/qa-catalog-benchmark.mjs
```

The benchmark refuses an incorrect dataset, memory-backed database or incorrect CPU/memory limit. The fixture session queries actual user-scoped row counts and PostgreSQL's own mount table; the benchmark also checks the served catalog total. It checks three distinct pages and authorized/private search, then records thirty first/next-page requests, raw samples, p50/p95 and every failure. Requests use new HTTP connections without client response caching; database/filesystem buffers remain populated after seed/ANALYZE. A bounded TCP probe measures the client link against the accepted minimum of 100 Mbit/s. A reachable HTTP canary on port 55460 measures unsolicited publication requests after a positive reachability control. Record the host's SSD backing separately. `profile.json` records the source commit, Node/PostgreSQL/kernel identities and actual cgroup limits; `catalog-results.json` records conditions and results. These results cover the catalog increment, not the later note/sync/recovery workload of the parent specification.

The same native adapter tests and visible QA app can use this listener. End the session using `touch native/build/qa-profile/stop`. Physical iPad Air M2 VoiceOver, focus, larger interface text, provisioning and combined native/WebKit memory-pressure acceptance still require the actual device and must retain their independent verdicts.
