# Issue 2 delivery and verification

This note records the private native iPad client delivery for
[issue 2](https://github.com/mooneeb/bookorbit/issues/2) on 2026-10-08. The user
approved moving to review and integration after a short functional smoke, with
the exhaustive native matrix and unresolved accessibility audit findings
deferred. Completion under that revised scope does not establish every original
acceptance criterion. Earlier implementation and verification notes retain their
historical results and outstanding findings.

## Delivered source

The reviewed baseline is `f3bd12fe55df273af74e32a3d0c68269431bac49`, descended
from the approved starting commit `8fecae94e65204618fc4db846da19c4e0007e4aa`. The
frozen scope inventory accounts for 49 component boundaries. Its final named
source omissions were implemented in the metadata and reader integration waves.
The final reviewed source is `6ebda623904192f65c1e92fcc9318aae0864c92a`. Final review repairs
are recorded below.

| Area                       | Implemented behavior                                                                                                                                                                                | Primary source                                                                                                           |
| -------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| Connection                 | Server profiles, local/OIDC sign-in, Keychain credentials, refresh/logout, password change and recovery                                                                                             | [Connection](../Sources/Connection/)                                                                                     |
| Library                    | Bounded search/filter/sort, list/grid/table, cell editing, presets, saved views and backup, series collapse, Home shelves, authors/series, collections and smart scopes                             | [Library](../Sources/Library/)                                                                                           |
| Book management            | Book/file details and delivery, metadata/custom fields/locks/provider comparison, staged suggestions and rich descriptions, covers, selected-book delete/move/writeback and individual file actions | [Library](../Sources/Library/)                                                                                           |
| Fixed-page reading         | PDF and comic reading, page navigation/search/contents/thumbnails, appearance/layout/animations, bookmarks and acknowledged progress                                                                | [Reader](../Sources/Reader/)                                                                                             |
| Reflowable reading         | Local EPUB renderer, publisher content and format delivery, settings/fonts/themes, nested contents, location/section navigation, bookmark search/sort, dictionary/translation and reader chrome     | [EPUB](../Sources/Reader/EPUB/), [renderer](../EPUBReader/)                                                              |
| Listening and continuity   | Native audiobook playback and bookmarks, recorded narration/Read Along, system/server TTS, sleep controls, selected reading-position reset and local/remote position choice                         | [Reader](../Sources/Reader/)                                                                                             |
| Server and web integration | Owning user-scoped routes and permission checks, canonical shared contracts and generated Swift models, reader bookmarks/progress/settings and compatible web controls                              | [types](../../packages/types/src/), [server](../../server/src/modules/), [web reader](../../client/src/features/reader/) |

Book queries retain 40-result pages; named directories and catalog operations use
bounded pages or targeted queries. Cover/media work uses bounded transfers,
caches and selected-file delivery. Source bounds are implemented; complete
runtime performance and pressure acceptance is deferred.

Ordinary highlights, passage notes, PDF ink, annotation hub and explicit offline
packages belong to issue 3. Uploads, ZIP delivery and bulk rename belong to issue 4. Full personal reading-history parity and Kobo/KOReader resets belong to issue 5. Existing personal fields and individual reading-position reset remain in this
delivery.

## Verification actually completed

The retained regression record covers each existing suite once at `b8ea398`,
followed by whole-file reruns of the original failures after five test-fixture
repairs. Deduplicated results are 1,508 files, 21,949 passing tests, zero failing
tests and six existing skips. The two earlier and 19 later existing-test repairs
are integrated in the candidate. No assertions were weakened and no new skips
were added. This is not a claim that every suite ran again on the final commit.

Full server/client Prettier and ESLint passed at `42763e99`. All 21 subsequent
server/client paths before the final server repair are existing test files,
covered by exact scoped format/lint receipts at `b8ea398` and `b093643`. The final
server repair has its own full server and final cache-file lint/format receipts. The `f3bd12f` production simulator build passed, including its universal
artifact, Swift 6 strict checks over 233 declarations, scoped format/parse checks,
signature verification and source/asset closure checks. Existing OIDC initializer
deprecation and AppIntents metadata warnings remain. Build and source checks do
not imply runtime or physical-device acceptance.

The latest metadata-controls public HTTP/delivered-file phase passed all eight
cases. The metadata-suggestions public phase passed 11 cases; its web counterpart
passed seven-field Save and canonical public readback. The latter retains
screenshot/fresh-reopen evidence gaps. Earlier focused native/web/file results
remain in [verification.md](../verification.md) and the owning feature notes;
their passes apply only to their recorded source and configuration.

The reduced native smoke reached production sign-in, library search and target
book navigation, metadata editor entry, checked draft inputs, a publisher choice,
series reordering, and provider comparison/Apply. It also selected genuine author
and narrator HTTP 200 choices into the unsaved draft. These are observed steps,
not complete journey passes. The controls run was canceled before completion.
The suggestions run retained an unresolved series-chooser locator/scroll failure
and a canceled second case; Save/reopen was not verified.

The requested short EPUB open/page-turn/resume smoke did not execute: device UI
automation was disabled, and the cached runner retained an obsolete search
selector and legacy 50,000-book fixture prerequisites. No new harness or fixture
was created to expand the approved short smoke.

## User-approved deferred coverage

- The complete native functional matrix, including remaining metadata
  Cancel/Reset, locks, ordered series, cover failure/order, stale acknowledgment,
  save/reopen and reader continuity cases.
- Unresolved accessibility audit findings and the complete accessibility,
  Dynamic Type, VoiceOver, keyboard, layout and Reduce Motion matrix.
- Current-source EPUB reading smoke, full format/fault/concurrency coverage,
  performance and memory-pressure measurements, and remaining visual evidence.
- Physical iPad installation/home-server proof, Pencil/physical keyboard checks,
  perceived device reading/audio behavior and human visual baseline approval.

Original physical and accessibility criteria remain unproved. Deferred, canceled
and unresolved cases retain their actual status; they are not relabeled passing.

## Review and integration

The Standards and Spec reviews are pinned to `f3bd12f`. The Spec review found
that book details displayed rich-description HTML literally. Approved repair
`1048a51e210b10807bf57b4d0b9a934c5d13fba2`, integrated as `16ee4ec0`, reuses bounded
native rich rendering with supported formatting and safe links while retaining
canonical HTML. Native format/lint, parse and strict Swift 6 typechecking passed.
Rendered UI/reopen verification remains deferred. The Spec review records one
resolved finding and zero outstanding findings. A final signed production arm64
simulator build of the integrated repair passed in 66.107 seconds, compiling all
219 production Swift files. Signature and source/asset manifests passed. The
minimum measured memory availability was 51%, with 82.901 GiB disk free.

The final build requested two Xcode jobs and Swift driver jobs, but Xcode placed
its default `-j8` after the supplied `-j2`, so effective driver concurrency was
eight. The raw command and driver log preserve that scheduling deviation. The
resource floor remained satisfied; the build was not repeated for provenance.

The Standards review found repeated decompression from byte zero for EPUB audio
ranges. Approved repair `d70cdd87d7c85a7fccd653fe24cc75192fb5da60`, integrated as
`6ebda623`, stages decoded compressed audio once per user/source revision/entry
and reads stored entries directly. Typed `EPUB_AUDIO_CACHE_BYTES` configuration
defaults to a 2 GiB staging budget, with two extraction jobs and 64 reservations.
Every request retains authentication, download permission and library checks.
Active readers/waiters pin entries; source replacement and cancellation release
the corresponding resources. Capacity pressure returns 503 with Retry-After.

Final server compilation passed with zero TSC issues and 1,293 SWC files. Full
server lint, final cache-file lint, format and whitespace checks passed. The 107
targeted existing tests passed with one existing skip before the final pipeline
lifecycle adjustment. Independent public checks verified three exact late or
repeated 256 KiB ranges, stable ETag/206 headers, EOF 416, anonymous 401 and
foreign-library warm-cache 403.

The broader HTTP command verified 128 successive ranges, stored-entry bypass,
capacity pressure, replacement/new ETag and revoked permissions/access, then
exited 1 at its cancellation assertion. After the lifecycle repair, a separate
final compiled HTTP gate passed cancellation cleanup in 28 ms and an immediate
retry delivering 262,144 exact bytes. The earlier matrix was not repeated after
that final adjustment. These retained observations and the final passing gate
are distinct; the original command is not relabeled passing. Standards review
records one resolved finding and zero outstanding findings.

All 219 built Swift rows remain byte-identical after the server-only repair, so
the production native build was not repeated.

Generated Drizzle migrations `0102` through `0105`, their snapshots and the
generated Swift contracts are intentional deliverables. The sole newly added
binary fixture is `server/test/ipad/fixtures/cover-audio.m4a` (5,316 bytes).
Generated projects, builds, result bundles and the experimental QA runner
branches remain outside the product commit.

The main checkout's 18 existing user documents are protected independently by a
SHA-256/status manifest. Integration uses a fast-forward from `a9c9899` after the
reviewed candidate is approved, then compares every protected file and its
status. The completion document is the only additional documentation commit. No PR, push or publication is part of this integration.

## Evidence index

Detailed local records are preserved under
`~/.codex/bookorbit-issue2-checkpoints/20261008-post-restart/`:

- `scope-closure/issue2-final-source-coverage-closure-20261008.json`
- `auth09-integration/checked-coherent-handoff.json`
- `full-suite-test-only-final-integration/checked-nineteen-test-final-handoff.json`
- `final-full-suite-testing/final-full-suite-testing-handoff.json`
- `metadata-draft-controls-testing/user-reduced-scope-final-handoff.json`
- `metadata-draft-suggestions-testing/native-reduced-scope-results.json`
- `reduced-native-smoke/epub-core-short-native-smoke.json`
- `shared-native-runner-batch3/reduced-scope-final-qa-handoff.json`
- `final-main-integration/protected-before.json`
- `final-main-integration/artifact-scope-inspection.json`
- `final-main-integration/final-native-build-result.json`
- `final-main-integration/final-native-driver-provenance.json`
- `final-main-integration/final-native-source-manifest.json`
- `final-main-integration/final-native-artifact-manifest.json`
- `final-main-integration/format-lint-coverage.json`
- `final-code-review/spec-report.md`
- `final-code-review/spec-01-repair/validation.md`
- `final-code-review/standards/repair-approval.json`
- `final-code-review/std-01-repair/REPORT.md`

These records include source revisions, artifact hashes and retained raw failure
evidence. The local QA branches and artifacts are preserved for future work.
