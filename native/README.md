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

The app downloads to private staging, verifies every byte length and SHA-256, checks package declarations, and flushes files/directories before committing its download record. GRDB uses a serialized DatabaseQueue, versioned migrations, DELETE journal, FULL synchronization and foreign keys. A failed transfer cannot replace the last committed record. Opening rechecks the original and all indexed members. Identifying metadata and bounded local search remain available offline. Stored source bytes are never rewritten into a converted edition. The local schema is the extension point for later download/reference/recovery work; this increment does not claim note recovery or sync receipts.

Resource bounds are enforced from the first build: original 512 MiB, expanded members 2 GiB, 20,000 entries, central directory 8 MiB, manifest 256 KiB, consumed text 4 MiB, other buffered members 32 MiB, images 16 million pixels and 8,192 pixels per side, 100,000 nodes per section, ten-second chapter/resource deadline and 128 MiB retained renderer object URLs. Metadata responses are bounded to four MiB. The combined native/WebKit 512 MiB release target still needs representative physical-device pressure measurements.

Only the active package and trusted assets are exposed on loopback, behind an unpredictable session path. The listener bounds headers, connections and concurrent responses. Publication frames receive restrictive CSP; scripts, remote loads, forms, objects and arbitrary navigation are blocked. The WebKit store is nonpersistent. The bridge validates the actual web view, main frame, exact origin, session and bounded message schema. Native tokens and arbitrary file paths never enter publication content. Script/network-dependent content shows partial-reading status; missing resources fail explicitly.

## Isolated QA

The runnable preparation command creates a disposable PostgreSQL container, migrates it, generates controlled EPUBs, seeds 50,000 visible books and 100,000 annotations plus a second owner's private book, and runs authenticated Fastify and native/WebKit scenarios:

```sh
QA_SIMULATOR_ID='<iPad simulator UUID>' native/scripts/qa.sh
```

Requires Docker, pnpm, Xcode, XcodeGen and a previously selected iPad simulator. No production database, books, certificate trust or real account is used. The test-only URLProtocol adapter maps `https://bookorbit-qa.test` requests to the isolated real HTTP listener on `127.0.0.1:55458`. It is compiled only into the test target. The production transport continues to require HTTPS.

The QA database has a four-core/eight-GiB container limit. Node runs on the host; TCP is loopback and PostgreSQL buffers remain warm. Both Fastify and native transport tests record 30 first/next-page repetitions, p50/p95 and failures. These results identify the actual setup and do not certify the complete four-core/eight-GiB server plus conditioned network deployment. `native/build/qa-native.log` and the `.xcresult` bundle contain native results. Review-time results are recorded separately.

The ABeeZee font is an OFL-licensed test fixture, excluded from the app. Its immutable source is google/fonts commit `a8bc01c6dcb2933dca0f37180df6c516e226b346`; see `QAFixtures/OFL.txt`. The image is a generated one-pixel PNG. No personal contents or credentials are test evidence. Follow [the physical smoke check](scripts/smoke-check.md) for the remaining device verdict.
