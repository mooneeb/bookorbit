# BookOrbit iPad: connected EPUB reading

Issue [#25](https://github.com/mooneeb/bookorbit/issues/25), governed by [#24](https://github.com/mooneeb/bookorbit/issues/24) and its pinned native-stack contract. Base commit: `f2a7a111881899e7c6cb233a0ec2d8a9c25235c6`.

This independent app targets iPadOS 26.0 and later with Swift 6, SwiftUI and a UIKit WebKit reader. Stable production identity: `dev.mooneeb.bookorbit.reader`. There are no extensions, push, iCloud entitlements or third-party Swift packages. A checked-in Xcode project builds without XcodeGen; `project.yml` is its reproducible source (XcodeGen 2.44 or later).

Open `BookOrbit.xcodeproj` in Xcode 27 or later and select a simulator or iPad. Simulator build:

```sh
xcodebuild -project native/BookOrbit.xcodeproj -scheme BookOrbit \
  -sdk iphonesimulator -derivedDataPath native/build CODE_SIGNING_ALLOWED=NO build
python3 native/scripts/check-assets.py
```

For a physical iPad, select your free Apple Personal Team in Signing & Capabilities, enable Developer Mode, trust the connected Mac and keep the bundle ID stable. Network access to Apple signing services and an available free AppID/app slot are prerequisites. Provisioning lasts at most seven days from issuance. This build does not establish SideStore renewal or preservation acceptance. Follow [the independently prepared device check](scripts/smoke-check.md); physical checks remain unrun.

The configured HTTPS origin must serve the current BookOrbit API at `/api/v1`. Password/native-session sign-in verifies server instance and `/auth/me` account identity before opening the catalog. Tokens remain in device-only, after-first-unlock Keychain items keyed by origin, server UUID and account ID. A credential-free account reference enables explicit identity verification before Keychain refresh on relaunch. Redirects, cookies and response caching are disabled in native transport. Expired access tokens renew through one serialized refresh and are saved to the scoped Keychain before retry. Revoked sessions show a reconnect error; sign-out cancels active transports before removing credentials. Server library access remains authoritative on preparation and every member request.

The catalog replaces one 50-item page at a time using the existing strict book-query contract. Details choose an explicit original EPUB file. Unsupported native formats stay labelled unavailable. The reader has page navigation and returns to details; no legacy progress, bookmarks, annotations or note writes occur. Downloads, offline readiness, notes and synchronization are unavailable. There is no new durable record kind or competing recovery owner in this increment.

The server prepares an expiring online snapshot from a bounded copy of the original, then streams/decompresses members into private files and hashes them before returning a complete manifest. Maximum original: 512 MiB; entries: 20,000; central directory: 8 MiB; expanded: 2 GiB; XHTML/CSS/XML/SVG: 4 MiB each; other members: 32 MiB; manifest: 256 KiB; preparation: 120 seconds. ZIP64/multidisk and ambiguous paths are refused. One lease per authenticated login session and two concurrent preparations use a ten-GiB global byte budget, five-GiB per-account budget and bounded metadata count. Reopening reclaims a lost lease for that same login session while other devices keep their leases. Authenticated resource requests and foreground heartbeats renew a thirty-minute idle lease. Idle leases are removed on expiry, close or normal shutdown. A server process crash may leave temporary snapshot directories for operator cleanup. These are disposable online resources, never recovery data or an offline package receipt. Multi-replica deployments require request affinity for a lease.

A native loopback listener binds only 127.0.0.1 and an unpredictable reader path, accepts GET only, caps headers at 8 KiB, sixteen bounded connections, two active responses and a 30-second deadline. The native transport downloads the original to a bounded temporary file, hashes it in 64 KiB buffers before opening and deletes it. A size-based total deadline permits transfers down to 64 KiB/s plus two minutes; heartbeat renewal continues during verification. The loopback adapter validates member size and SHA-256 before exposing it to WebKit. Static images are capped at 16 million pixels and 8,192 pixels per side. JavaScript receives member requests, never the original ZIP, library collection, native tokens or remote API access. Retained renderer object URLs are capped at 128 MiB and released capacity is reusable; an exceeded envelope explicitly refuses reading. All text loads enforce a 4 MiB bound irrespective of filename. Declared publication media types select contained XHTML/HTML/SVG parsing, with the frozen engine's HTML fallback, and chapters enforce 100,000 DOM nodes and ten-second resource/initial load deadlines. The combined-process 512 MiB release target still requires corpus measurements.

Frozen trusted Foliate files have per-file hashes in [dependencies.json](dependencies.json); their origin is the repository's modified snapshot, not a claimed upstream release. The app bundles the Foliate MIT notice and BookOrbit AGPL/additional terms. ZIP/fflate/PDFium are not bundled or invoked. Every publication document receives a restrictive CSP before frame loading; scripts and unsolicited network content are blocked. WebKit uses a nonpersistent store, content rules, navigation policy and main-frame/origin/session-validated messages. Static media/fixed-layout and unsupported resources fail explicitly. Available-text and control accessibility must pass the physical smoke check; simulator text assertions do not claim that pass.

Run native transport/rendering tests on an available iPad simulator:

```sh
xcodebuild -project native/BookOrbit.xcodeproj -scheme BookOrbit \
  -destination 'platform=iOS Simulator,name=iPad Air 13-inch (M3)' \
  -derivedDataPath native/build CODE_SIGNING_ALLOWED=NO test
```

The native executable test connects through the real transport adapter with fault-controlled URLSession responses, opens Foliate in WKWebView, asserts chapter text, turns a page, returns and checks denied/disconnected states. The real NestJS HTTP adapter test uses isolated PostgreSQL, scanned files, native login, catalog/details, a second permitted owner, a denied account and immutable source replacement:

```sh
E2E_DATABASE_URL=postgres://postgres@localhost:55425/bookorbit_25 \
  pnpm --dir server exec vitest run --config vitest.config.e2e.ts test/native-epub.e2e-spec.ts
```

Migrate that disposable database first using the repository's normal `db:migrate` tooling. Never point the test at a production database. Full native-to-real-HTTPS/device interaction is part of the unrun device check.
