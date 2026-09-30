# Spec: BookOrbit iPad App with Apple Pencil Pro

Status: ready-for-agent (local spec, not published to an issue tracker)

Related: GLOSSARY.md, ADR 0001 (full native port), ADR 0002 (foliate-js for EPUB), ADR 0003 (fork-only tables with separate migrations)

## Problem Statement

I run BookOrbit on my home Kubernetes cluster, reachable only over Tailscale. On my iPad Air 13" (M2) I can only use BookOrbit through the browser, which means my Apple Pencil Pro is reduced to a finger: I cannot write in the margins of a PDF, cannot sketch next to a passage, cannot handwrite a Note, and none of the Pencil Pro gestures (squeeze, barrel roll, hover, haptics, double-tap) do anything. The Official App only targets iPhone and Apple Watch, its source is not available, and it has no Pencil support. Reading and annotating on the iPad, which should be the best place to study a book, is the worst.

## Solution

A native iPadOS 26 app, the iPad App, built in this fork. It ports every screen of the web app natively and adds a Pencil-first reading and annotating experience:

- On Fixed-layout Books (PDFs, comics) I can write directly on the page, as Ink Annotations.
- On any book I can highlight a passage and attach a Note (handwritten with Scribble, stored as text) and/or a Sketch (a drawing on its own canvas).
- Text recognized from Ink Annotations and Sketches is stored, so everything I write is searchable in the annotations hub on every surface (iPad App, the iPad App running on my Mac, and the web app in Mac and Android browsers).
- Downloaded books work fully offline and sync when I am back on Tailscale.
- The server changes needed to store ink ship from my fork as a versioned container image that my cluster runs instead of upstream's.

## User Stories

### Installing and connecting

1. As the owner, I want to install the iPad App on my iPad without a paid Apple Developer account, so that I pay nothing.
2. As the owner, I want AltStore with AltServer on my Mac to re-sign the iPad App automatically while my iPad is on home Wi-Fi, so that the 7-day free signing never strands me.
3. As the owner, I want to fall back to re-installing from Xcode, so that I can recover if an automatic refresh was missed.
4. As the owner, I want to build and run the iPad App on my Mac signed to run locally, so that I get the same app on the Mac without expiry.
5. As a reader, I want to enter my server address (for example books.mooneeb.dev) on first launch, so that the app knows which BookOrbit server to use.
6. As a reader, I want the app to tell me clearly when the server is unreachable (for example Tailscale is off), so that I know it is a network problem and not a login problem.
7. As a reader, I want to sign in with username and password, so that I can use my existing account.
8. As a reader, I want to sign in with a magic link, so that I can log in the same ways the web app supports.
9. As a reader, I want to sign in with single sign-on (OIDC) through a system browser sheet, so that SSO works like on the web.
10. As a reader, I want my session to refresh silently, so that I am not logged out every 15 minutes.
11. As a reader, I want my login tokens stored in the Keychain, so that they are not readable by other apps.
12. As a reader, I want to sign out, and signing out clears my offline data for that account, so that switching accounts leaves nothing behind.
13. As a reader, I want the iPad App to appear with its own device label in my active sessions list, so that I can revoke it from the web.

### Library and browsing (Phase 1 and 2)

14. As a reader, I want to browse my libraries with the same grid and list layouts as the web app, so that the iPad App feels like BookOrbit.
15. As a reader, I want library browsing to page and virtualize, so that tens of thousands of books scroll smoothly.
16. As a reader, I want to search and filter my library with the same filters as the web app, so that I can find books quickly.
17. As a reader, I want to open a book's detail page with metadata, formats, progress, and annotations, so that I can decide what to read.
18. As a reader, I want to browse authors, series, collections, and smart scopes natively, so that I can navigate my library the way I do on the web.
19. As a reader, I want the dashboard (continue reading, recent, random) natively, so that my home screen matches the web.
20. As a reader, I want to download a book file for offline reading, so that I can read without Tailscale.
21. As a reader, I want to see and manage my downloads and the storage they use, so that I can free up space.
22. As a reader, I want Stage Manager, Split View, and multiple windows to work, so that I can read a book next to my notes.
23. As a reader, I want hardware keyboard shortcuts and trackpad support, so that the app works well with a Magic Keyboard.
24. As a reader, I want cover images cached, so that browsing is fast and works offline for downloaded books.

### EPUB reading (Reflowable Books)

25. As a reader, I want EPUBs to render with the same engine as the web reader, so that my highlights land on the exact same passages on every surface.
26. As a reader, I want my web reader settings (fonts, theme, margins, layout) available on the iPad App, so that books look the way I configured them.
27. As a reader, I want my reading position synced with the server, so that I can continue where I left off on the web.
28. As a reader, I want to bookmark a location, so that I can return to it.
29. As a reader, I want to select text with my finger or the Pencil and create an Annotation with a color and a Style, so that I can mark passages.
30. As a reader, I want a Pencil stroke under a passage to create an underline Annotation snapped to the text, so that underlining feels like on paper.
31. As a reader, I want circling or scribbling over a passage to create a highlight Annotation snapped to the text, so that highlighting feels natural.
32. As a reader, I want hover to preview which passage a highlight would snap to, so that I get it right the first time.
33. As a reader, I want a haptic tap when a stroke snaps to text, so that I know it registered.
34. As a reader, I want every tool on an EPUB to snap to text rather than leave ink on the page, so that my marks survive reflow.

### PDF and comic reading (Fixed-layout Books)

35. As a reader, I want PDFs to render natively with smooth zoom and page navigation, so that reading is fast.
36. As a reader, I want comics (CBZ, CBR, CB7) to render natively, so that I can read them on the iPad.
37. As a reader, I want the highlighter tool on a PDF to snap to text and create a normal Annotation, so that PDF highlights appear in the hub like any other.
38. As a reader, I want the pen, marker, and pencil tools to draw ink directly on the page, margins included, so that I can write on the page itself.
39. As a reader, I want all ink I draw on one page to be a single Ink Annotation, so that the hub and search results are predictable.
40. As a reader, I want pressure and tilt to shape my strokes, so that ink looks like real writing.
41. As a reader, I want barrel roll to rotate the highlighter and fountain pen nib, so that I can control stroke angle.
42. As a reader, I want the eraser to remove individual strokes, so that I can fix mistakes without deleting the whole page of ink.
43. As a reader, I want the lasso to select, move, and delete strokes, so that I can tidy up my writing.
44. As a reader, I want to undo and redo ink changes, so that I can recover from mistakes.
45. As a reader, I want Ink Annotations to appear at exactly the same place on the page every time I open the book, on the iPad App and in the browser, so that my margin notes stay attached to the right text.
46. As a reader, I want text recognized from my Ink Annotation stored with it, so that I can find it by searching.
47. As a reader, I want to write on comic pages too, so that I can annotate panels.

### Pencil Pro interaction

48. As a reader, I want squeezing the Pencil Pro to open the tool palette at the pencil tip, so that I can switch tools without reaching for the toolbar.
49. As a reader, I want double-tap to toggle between my current tool and the eraser (following my system setting), so that erasing is instant.
50. As a reader, I want hover to show where my stroke will land, so that I can write precisely.
51. As a reader, I want haptic feedback on palette changes, so that I can switch tools without looking.
52. As a reader, I want every Pencil Pro gesture to have an on-screen equivalent, so that nothing depends on squeeze alone.
53. As a reader, I want Scribble to work in every text field (search, notes, forms), so that I never have to put the Pencil down to type.
54. As a reader, I want to use my finger to scroll and turn pages while the Pencil draws, so that I don't draw by accident.

### Notes and Sketches

55. As a reader, I want to select a passage and choose "Add note" to open a large writing area where my handwriting is converted to text with Scribble, so that my Notes are typed text I can search and export.
56. As a reader, I want to see and correct the converted text while I write, so that recognition errors don't end up in my Notes.
57. As a reader, I want to type a Note with the keyboard instead, so that I can use whichever is faster.
58. As a reader, I want to select a passage and choose "Add sketch" to open a drawing canvas, so that I can draw diagrams, arrows, or anything that isn't words.
59. As a reader, I want a passage to have both a Note and a Sketch, so that I can explain in words and draw at the same time.
60. As a reader, I want at most one Note and one Sketch per Annotation, adding to the existing canvas when I sketch again, so that each passage stays tidy.
61. As a reader, I want text recognized from a Sketch stored with it, so that sketches with words in them are searchable.
62. As a reader, I want a diagram-only Sketch saved even though no text was recognized, so that drawings are never rejected.
63. As a reader, I want Notes and Sketches on both EPUBs and PDFs, so that I can annotate every kind of book the same way.
64. As a reader, I want Sketches shown alongside the passage rather than over the page, so that they never cover the text.

### Annotations hub and search

65. As a reader, I want the annotations hub natively on the iPad App, with filters for color, style, and source, so that I can review everything I marked.
66. As a reader, I want the hub to show Ink Annotations and Sketches with a preview of the ink, so that I can recognize them at a glance.
67. As a reader, I want to search across Notes and the recognized text of Ink Annotations and Sketches, so that everything I wrote is findable.
68. As a reader, I want a search result to open the book at the right page or passage, so that I can jump straight back to context.
69. As a reader using a browser on my Mac or Android phone, I want to see Ink Annotations on PDF and comic pages read-only, so that my margin writing is visible everywhere.
70. As a reader using a browser, I want to see Sketches in the reader and hub read-only, so that my drawings are visible everywhere.
71. As a reader using a browser, I want to delete an Ink Annotation or Sketch, so that I can clean up from any device.
72. As a reader using a browser, I want to correct the recognized text of an Ink Annotation or Sketch, so that search stays accurate.
73. As a reader using a browser, I want an Ink Annotation never to show up as a big highlight box over the page, so that the web PDF reader stays readable.
74. As a reader, I want export (Markdown, CSV, JSON) to include recognized text from Ink Annotations and Sketches, so that my handwriting ends up in my notes.
75. As a reader, I want the recognized text of Ink Annotations and Sketches sent to Readwise like any other annotation text, so that my Readwise reviews include my handwriting.

### Offline and sync

76. As a reader, I want downloaded books fully readable and annotatable offline, so that I can work on a plane.
77. As a reader, I want Annotations, Notes, Sketches, Ink Annotations, bookmarks, and progress I make offline queued and synced automatically when the server is reachable again, so that I never lose work.
78. As a reader, I want pending changes to survive the app being killed or the iPad restarting, so that nothing is lost in between.
79. As a reader, I want to see whether there are unsynced changes, so that I know when it is safe to rely on another device.
80. As a reader, I want the latest edit to win when I changed the same Annotation offline on the iPad and online on the web, so that conflicts resolve predictably.
81. As a reader, I want a deletion on either side to win over an edit on the other, so that deleted annotations stay deleted.
82. As a reader, I want a book's annotations refreshed when I open it online, so that changes from the web show up.
83. As a reader, I want reading sessions recorded from the iPad App, so that my statistics include iPad reading.

### Listening (Phase 3)

84. As a listener, I want to stream and download audiobooks with background playback and lock screen controls, so that I can listen natively.
85. As a listener, I want audiobook progress and bookmarks synced, so that I can continue on the web.
86. As a listener, I want Read Along (EPUB3 media overlays), so that I can read and listen together.
87. As a listener, I want podcasts natively, so that the podcast section works on the iPad.
88. As a reader, I want text to speech, so that I can listen to ebooks.

### Personal settings and integrations (Phase 4)

89. As a user, I want account, profile, privacy, notifications, and restrictions settings natively, so that I can manage my account from the iPad.
90. As a user, I want appearance settings (theme, covers, icons, layout, behavior, language) natively, so that the iPad App looks the way I like.
91. As a user, I want reader settings (ebook, PDF, comics, audio, fonts) natively, so that I can tune reading from the iPad.
92. As a user, I want Kobo, KOReader, OPDS, email, Hardcover, Readwise, StoryGraph, and TTS settings natively, so that I can configure integrations from the iPad.
93. As a user, I want to edit a book's metadata and fetch metadata from providers natively, so that I can curate my library from the iPad.
94. As a user, I want the tools (entity manager, bulk rename, duplicates, missing resources) natively, so that library upkeep works on the iPad.
95. As a user, I want statistics, goals, achievements, and What's New natively, so that the whole web experience is on the iPad.
96. As a user, I want book requests and Book Dock natively, so that I can request and ingest books from the iPad.

### Admin (Phase 5)

97. As an admin, I want user management, account activity, magic links, OIDC, server fonts, TTS, audit log, metadata, file naming, and maintenance screens natively, so that I can run the server from the iPad.
98. As an admin, I want admin screens shown only when my permissions allow them, so that the iPad App matches server-side permission checks.

### Parity and upstream

99. As the owner, I want a screen that upstream adds but I haven't ported yet to open inside the iPad App in a signed-in web view, so that I never lose access to new features.
100. As the owner, while the port is in progress, I want not-yet-ported screens to use the same in-app web view, so that the app is usable from Phase 1.
101. As the owner, I want a parity checklist generated from the web app's routes and re-checked after every upstream merge, so that I can see what is still missing.
102. As the owner, I want upstream merges to be conflict-free on the server schema, so that staying current is cheap.

### Release and deployment

103. As the owner, I want fork releases tagged in the four-part form of upstream version plus a revision (for example v3.1.0.1), so that the tag tells me which upstream release it is based on.
104. As the owner, I want pushing a release tag to build and publish the container image to my fork's registry, so that my cluster can pull it.
105. As the owner, I want upstream's semantic-release to never run from my fork, so that nothing publishes by accident.
106. As the owner, I want my running fork to still tell me when upstream publishes a newer release, so that I know when to merge.
107. As the owner, I want my Kubernetes deployment to switch from upstream's image to my fork's image without data loss, so that the ink features become available on my existing library.
108. As the owner, I want release notes on each fork release describing the iPad-related changes, so that the version number doesn't need to.

## Implementation Decisions

### Architecture

- The iPad App is a native SwiftUI app for iPadOS 26 and later, living in its own top-level folder in this repository, outside the pnpm workspaces. Upstream never touches that folder. (ADR 0001)
- The iPad App is a full native port of every web screen, delivered in five phases: (1) foundation and readers with Pencil, (2) your library (annotations hub, collections, smart scopes, series, authors, statistics, achievements), (3) listening (audiobooks, podcasts, TTS), (4) personal settings, integrations, book editing and metadata fetch, tools, (5) admin.
- Screens not yet ported, including screens upstream adds later, open in an in-app web view that shares the signed-in session. Once a screen is ported natively, its web view entry is removed.
- The iPad App also runs on the Mac, built locally and signed to run locally. No Mac-specific work.
- All non-UI logic lives in a Swift package inside the app folder: the generated API client, the offline store, the outbox and sync engine, conflict resolution, and the rules that turn Pencil strokes into Annotations. SwiftUI views stay thin and depend on this package.
- The Swift API client is generated from the server's OpenAPI document with Apple's swift-openapi-generator. The server's OpenAPI document is the contract between server and app. Server DTO changes for fork features must be reflected in it.

### Readers

- EPUB: foliate-js hosted in a web view, the same engine and CFI generation as the web reader. Native code owns Pencil input. The web view exposes a small bridge for hit-testing a point or stroke to a text range and CFI, rendering Annotations, and reporting selection. (ADR 0002)
- PDF: PDFKit, with PencilKit canvases per page for Ink Annotations.
- Comics: a native image viewer with the same per-page PencilKit ink layer as PDFs.
- On EPUBs every tool snaps to text; there is no ink on the page. On PDFs the highlighter snaps to text and creates a normal Annotation; pen, marker, and pencil create ink.
- Stroke classification (a stroke under a passage becomes an underline; a circle or scribble over it becomes a highlight) is a pure function of stroke geometry and text layout, living in the Swift package.

### Pencil Pro

- Squeeze opens the tool palette at the tip. Double-tap follows the system preference (default: toggle eraser). Barrel roll rotates the highlighter and fountain pen nibs. Hover previews stroke position and, on EPUBs, the passage a highlight would snap to. Haptics confirm snaps and palette changes.
- Every Pro-only gesture has an on-screen equivalent.
- Scribble is enabled in every text field.
- Finger input scrolls and turns pages; Pencil input draws.

### Domain model

- Ink Annotation: one per page of a Fixed-layout Book, holding all ink on that page, plus recognized text. It is backed by an upstream Annotation row so that it takes part in the hub, search, export, and Readwise. That row's text is the recognized text, and its position is the page with a bounding rect in the same PDF coordinate space the web reader uses.
- Note: always text. Handwriting in the Note editor goes through Scribble; ink is not kept. Uses the existing upstream Annotation note field.
- Sketch: ink on its own canvas, attached to an Annotation, plus recognized text. At most one Sketch per Annotation. An Annotation can have both a Note and a Sketch.
- Handwriting recognition runs on the device and supports English only.
- A Sketch or Ink Annotation with no recognized text is still saved.

### Server (additive only, ADR 0003)

- A new fork-owned server module owns ink. Its fork-only tables are:
  - an ink table linking an upstream Annotation to its PencilKit drawing data, a generated SVG rendering, recognized text, and kind (page ink or sketch), with its own version and timestamps for sync;
  - a record of which Annotations were created on the iPad App.
- The fork-only tables are defined in a separate Drizzle schema entry with their own migrations folder and migrations table. They reference upstream tables by foreign key only. Upstream tables, check constraints, and migration history are never modified. Both configs are generated with Drizzle Kit, never hand-written.
- Upstream Annotation rows created by the iPad App keep origin web. The fork table records that they came from the iPad.
- Ink API, scoped to the current user and following the existing annotation controllers:
  - put or replace the page ink for a book file and page;
  - put or replace the Sketch for an Annotation;
  - get the ink for a book (all pages and sketches), with an updated-since parameter so the app can fetch only changes;
  - get a single rendered SVG;
  - update recognized text (used by the web to correct it);
  - delete.
- Writes to ink also update the backing upstream Annotation (text and position) through the annotation module's exported service. The ink module never queries annotation tables directly.
- Ownership is checked on every call; non-owners get ForbiddenException. Every controller method injects the current user.
- Request bodies containing drawing data have an explicit size limit, and ink is never returned in bulk list endpoints, only per book.
- Stored ink format: PencilKit drawing data is the source of truth for editing on Apple devices. The SVG is regenerated by the iPad App on every save and is never edited independently.
- Conflict rule, enforced on the server: each write carries the client's last-seen version and the edit timestamp. The most recent edit wins per Annotation, Ink Annotation, or Sketch. A delete always wins over an edit.
- Logs follow the project format with stable events (for example `ink.put_page`, `ink.put_sketch`, `ink.delete`) and start/end/fail phases for writes.

### Sync

- The Swift package keeps an offline store (books, files, progress, bookmarks, Annotations, ink) and a persistent outbox of pending mutations that survives app restarts.
- When the server is reachable, the outbox drains in order, and changes are pulled per book when a book is opened and for downloaded books in the background. There is no whole-library annotation pull.
- Upstream annotation endpoints have no updated-since support. The app re-fetches one book's Annotations at a time, which is small and bounded. Ink uses the fork's updated-since endpoint.
- Reading sessions are recorded from the iPad App with the existing ios source.

### Web client (thin changes to upstream code)

- New fork-owned components render Ink Annotations read-only on PDF and comic pages, and Sketches read-only in the reader and hub. They draw from the stored SVG.
- Upstream files receive only thin hooks: mount the ink layer, suppress the highlight box of an Annotation that backs an Ink Annotation, and show ink previews in the hub.
- The web can delete Ink Annotations and Sketches and edit their recognized text. It cannot edit ink.
- The web comic reader gains a read-only ink layer; it does not gain other annotation features.

### Auth

- The app uses the existing native client kind on login, refresh, magic link, and OIDC. Tokens come back in the response body and are stored in the Keychain.
- OIDC uses ASWebAuthenticationSession with the server's configured native redirect URI.
- One server and one account at a time. Signing out clears local data.

### Distribution and release

- Free Apple ID signing. AltStore with AltServer on the owner's Mac refreshes the 7-day signature on home Wi-Fi; Xcode reinstall is the fallback. The app must not rely on capabilities unavailable to free provisioning (notably iCloud and push notifications).
- The fork disables upstream's semantic-release workflow and adds a tag-triggered workflow. Pushing a four-part tag (upstream version plus revision, for example v3.1.0.1) builds and publishes the container image to the fork's GitHub Container Registry, with the same version passed as the app version.
- The server's update check reads the first three parts of the version and compares against upstream releases, which serves as a merge reminder. In-app What's New keeps reading upstream's release notes unless pointed at the fork.
- The migration job runs both the upstream and fork migration sets.

## Testing Decisions

A good test exercises external behavior through the highest available seam and asserts on what a user or client would observe: HTTP responses, rows visible through the API, rendered output. Tests do not assert on internal calls, private helpers, or query shapes.

### Seam 1: server HTTP end-to-end tests

- New e2e specs in the server test suite, using the existing reader-state-isolation harness (real Postgres, scanned library with EPUB and PDF fixtures, logged-in users).
- Cover:
  - creating, replacing, fetching, and deleting page ink and Sketches;
  - the backing Annotation's text and position being updated;
  - recognized text appearing in hub search and in Markdown, CSV, and JSON export;
  - updated-since fetches returning only changes and tombstones;
  - the latest-edit-wins and delete-wins rules;
  - rejection of oversized drawing payloads;
  - user scoping: an outsider gets forbidden or not found;
  - no bulk ink in list endpoints.
- A test asserts the fork migration set is independent of upstream's: separate folder, separate journal, and no references to fork tables in upstream migrations. It sits alongside the existing migration journal test.
- Prior art: the annotations hub e2e spec, the KOReader annotation exchange e2e spec, the Kobo annotation sync e2e spec, the authorization matrix e2e spec, and the migration journal test.

### Seam 2: the iPad App's Swift package

- Tested with Swift Testing through the package's public interface, with HTTP faked at the URL loading layer.
- Cover:
  - outbox persistence across restarts;
  - ordered draining when connectivity returns;
  - conflict outcomes matching the server rules;
  - per-book annotation refresh;
  - token refresh and sign-out wiping local data;
  - stroke classification (underline versus highlight versus ignored) against recorded stroke fixtures;
  - one-Ink-Annotation-per-page merging;
  - a Sketch or Ink Annotation with empty recognized text still saving.
- SwiftUI views and live Pencil input are not unit-tested; they are checked manually on the iPad Air M2 with the Pencil Pro.
- No prior art in this repo. This seam is new.

### Seam 3: web client component tests

- Vitest and Vue Test Utils tests for:
  - the read-only ink layer on PDF and comic pages, drawn from SVG and positioned by page coordinates;
  - suppression of the highlight box for Annotations that back Ink Annotations;
  - ink previews in the hub;
  - editing recognized text;
  - deleting Ink Annotations and Sketches.
- Prior art: the existing reader and annotation feature component tests in the client.

The server's OpenAPI document, already covered by its existing test, is the contract between Seam 1 and Seam 2.

## Out of Scope

- Android native app, iPhone support, Apple Watch, and any change to the Official App.
- Editing ink in the web app.
- Ink on the page of Reflowable Books (EPUBs).
- Handwriting recognition in languages other than English.
- Multiple saved servers or accounts in the iPad App.
- App Store or TestFlight distribution, and anything requiring a paid Apple Developer account (iCloud, push notifications).
- Sending ink to Kobo or KOReader. Those devices receive only what upstream already sends for the backing Annotation.
- Adding updated-since support to upstream annotation endpoints.
- Modifying upstream tables, constraints, or migrations.
- Web comic reader annotation features beyond the read-only ink layer.
- Publishing this spec or its slices to a GitHub issue tracker.

## Further Notes

- Facts to verify at the start of Phase 1:
  - the exact coordinate space of PDF annotation rects in the web reader, so ink positions line up;
  - how an empty recognized text is represented, given upstream requires Annotation text;
  - that Drizzle's migrator behaves as ADR 0003 assumes;
  - that PencilKit, AltStore refresh, and Keychain work under free provisioning;
  - Pencil Pro behavior when the iPad App runs on the Mac (expected: no Pencil; trackpad and keyboard only).
- Because Ink Annotations and Sketches are backed by upstream Annotation rows, KOReader may receive a PDF Annotation with a page-sized rect and recognized text. This is accepted, since KOReader and Kobo are out of scope.
- The parity checklist is generated from the web app's route table. After each upstream merge, new routes appear as unported and fall back to the in-app web view automatically.
- Scale: ink is fetched per book, never per library. The hub shows ink previews using the existing hub pagination. Background sync of downloaded books uses bounded concurrency.
