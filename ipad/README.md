# BookOrbit iPad App

The native iPadOS 26 client built in this fork (spec: `docs/specs/ipad-app.md`). It lives outside the pnpm workspaces; upstream never touches this folder.

## Layout

```
ipad/
  BookOrbit.xcodeproj    App target. `App/` is a folder-synchronized group: adding files never edits project.pbxproj.
  App/                   The app shell only: entry point, root navigation, account tab, FeatureRegistration.swift.
  Config/                Info.plist additions, BookOrbit.xcconfig, and your git-ignored Signing.local.xcconfig.
  BookOrbitKit/          Swift package with all feature code, one target per feature.
    OpenAPI/             The server's OpenAPI document, merged with the overlays.
  Tools/                 regenerate-api-client.sh, test-package.sh, the OpenAPI export script and overlays/.
```

## Package targets

| Target                  | Owns                                                                           | Ticket |
| ----------------------- | ------------------------------------------------------------------------------ | ------ |
| `BookOrbitAPI`          | Client generated from the server's OpenAPI document                            | 01     |
| `BookOrbitCore`         | App identity, `EventLog` (project log format), `sanitizeLogValue`              | 01     |
| `BookOrbitAuth`         | Server address, sign-in, Keychain tokens, silent refresh, sign-out, sign-in UI | 01, 03 |
| `BookOrbitFeatureKit`   | The extension point (`FeatureRegistry`, `FeatureScreen`, `ReaderEntryPoint`)   | 01     |
| `BookOrbitLibrary`      | Paged book list, covers, placeholder book detail                               | 01, 03 |
| `BookOrbitPDFReader`    | PDF reader                                                                     | 04     |
| `BookOrbitEPUBReader`   | EPUB reader                                                                    | 05     |
| `BookOrbitComicsReader` | Comics reader                                                                  | 07     |
| `BookOrbitInk`          | Ink Annotations and Sketches (non-UI logic shared by the readers)              | 04+    |
| `BookOrbitSync`         | Offline store and outbox                                                       | 08     |
| `BookOrbitMyLibrary`    | Annotations hub, collections, smart scopes, series, authors, statistics        | 09     |
| `BookOrbitListening`    | Audiobooks, podcasts, text to speech                                           | 10     |
| `BookOrbitSettings`     | Personal settings, integrations, book editing, tools                           | 11     |
| `BookOrbitAdmin`        | Admin screens                                                                  | 12     |
| `BookOrbitFeatures`     | Umbrella product the app links; re-exports every feature target                | -      |
| `BookOrbitTestSupport`  | `StubServer`, a fake BookOrbit server at the URL loading layer, for tests      | -      |

Every planned feature already has its target, wired into `Package.swift`, `Sources/BookOrbitFeatures/Exports.swift`, and `App/FeatureRegistration.swift`. A ticket fills in its own target. If a new target is ever needed, add it to those three files (one entry per line), never to the Xcode project. The EPUB reader target already bundles `Resources/` for foliate-js.

SwiftUI views inside the package are wrapped in `#if os(iOS)` (true for iPad and Mac Catalyst), so `swift test` on macOS builds everything else.

## Extension point

`App/FeatureRegistration.swift` is the one place the shell learns about features. It already lists every feature target, one per line:

```swift
screens: [LibraryFeature.screen]
    + MyLibraryFeature.screens
    ...,
readers: [
    PDFReaderFeature.entryPoint,
    EPUBReaderFeature.entryPoint,
    ComicsReaderFeature.entryPoint,
].compactMap { $0 }
```

A reader ticket sets `entryPoint` in its own target (it starts as `nil`), and a later-phase ticket fills in its target's `screens`, so neither edits this file.

- A `FeatureScreen` becomes a top-level tab. It receives a `FeatureContext` (the signed-in `AuthenticatedSession` and the registry).
- A `ReaderEntryPoint` becomes a button on a book's detail page whenever it can open the book (`ReaderEntryPoint(formats: ["pdf"])` or a custom `canOpen`). The reader is presented full screen and dismisses itself with `@Environment(\.dismiss)`.

Account data (downloads, outbox, caches) must live under `AccountStorage.directory(named:)`, so that signing out, or signing in as a different account, wipes it.

## API client

The client is generated with swift-openapi-generator from the server's own OpenAPI document. The document is produced without a database or running server: the server is built, and Nest's preview mode lists every controller without starting any providers.

Regenerate after server changes, or after editing an overlay:

```sh
ipad/Tools/regenerate-api-client.sh
```

Each feature owns one overlay, `Tools/openapi/overlays/<feature>.json`:

```json
{
  "operations": ["BookController_globalQuery"],
  "schemas": { "BooksPage": {} },
  "patches": {
    "BookController_globalQuery": {
      "requestBody": {},
      "responses": { "201": {} }
    }
  }
}
```

- `operations`: the `operationId`s to generate. The script merges every overlay's list into the generator config.
- `schemas`: shapes added to the document. The server does not declare response schemas (its services return plain TypeScript types), so the overlays supply what the app decodes. Two overlays may declare the same schema only if they are identical.
- `patches`: request bodies and responses replaced per `operationId`. Each operation can be patched by one overlay only.

The export fails loudly if an overlay names an operation the server does not have.

## Parallel work

Tickets that run at the same time touch their own package target and their own overlay. The remaining shared files are `Package.swift`, `Exports.swift`, `FeatureRegistration.swift`, and the generated API files:

- On a conflict in `BookOrbitKit/OpenAPI/openapi.json` or `Sources/BookOrbitAPI/GeneratedSources/`, take main's version and rerun `ipad/Tools/regenerate-api-client.sh`.
- On a conflict in one of the lists (one entry per line), keep both lines.

## Tests

```sh
ipad/Tools/test-package.sh                        # all BookOrbitKit tests
ipad/Tools/test-package.sh --filter TokenRefresh  # one suite
```

Swift Testing through each target's public interface, with HTTP faked at the URL loading layer by `StubServer`. The script adds the Swift Testing plugin path that Command Line Tools installs need; with Xcode selected it is plain `swift test`.

## Building and installing

Create `ipad/Config/Signing.local.xcconfig` (git-ignored) with your free Apple ID team:

```
DEVELOPMENT_TEAM = ABCDE12345
// Only if the default bundle identifier is taken:
// PRODUCT_BUNDLE_IDENTIFIER = dev.yourname.bookorbit
```

- iPad: open `ipad/BookOrbit.xcodeproj`, choose the iPad, and run. The app needs no entitlements, so free provisioning works. Install it through AltStore (with AltServer on the Mac) to refresh the 7-day signature on home Wi-Fi; re-running from Xcode is the fallback.
- Mac: choose "My Mac (Mac Catalyst)". The Mac build is signed to run locally and does not expire.
- Plain HTTP is allowed only for local-network addresses; anything else needs HTTPS.
- Command line: `xcodebuild -project ipad/BookOrbit.xcodeproj -scheme BookOrbit -destination 'generic/platform=iOS Simulator' build`.

## Manual checks on the iPad

1. First launch asks for the server address. With the VPN (Tailscale) off, "Continue" reports the server as unreachable; with a wrong password, sign-in reports a login failure instead.
2. Sign in, browse the book list (covers load while scrolling), and open a book's placeholder detail page.
3. The session is visible through the sessions API: `GET /api/v1/auth/sessions` for your account lists a native session labelled "BookOrbit iPad App on iPad" ("on Mac" for the Mac build). A web sessions screen is out of scope.
4. Leave the app for more than 15 minutes and come back: the list still loads (the access token refreshed silently).
5. Revoke the session from another client (`DELETE /api/v1/auth/sessions/:id`): the app returns to the server screen saying the session ended.
6. Sign out from the Account tab: the session disappears from the sessions API and the app starts from the server screen.
7. Relaunch after a day in the background: still signed in (Keychain, background refresh).
