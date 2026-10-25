# Standalone reading-control acceptance

Acceptance cases for the complete proposal in [Choose everyday reading controls and preference behavior](https://github.com/mooneeb/bookorbit/issues/22). All eleven product choices are answered; the issue holds final confirmation/status. These are future implementation checks, complementing the [reading-note walkthroughs](reader-walkthroughs.md).

Every case starts from its own fresh fixture/account-scoped state, including any notes/settings it needs. No preceding case supplies setup or a pass result. Use separately named copies on a test deployment; do not replace personal originals. Record device/runtime, app/server builds, source digest and run identity. Checkboxes record attempted actions; record a separate **Pass**, **Fail** or **Blocked** verdict, with the observed result and failing step. A blocked or unrun case is not passed.

## Switch EPUB modes without losing the reading place

**Question:** Do page turns and scrolling preserve the same logical place and note association?

**Setup:** Fresh downloaded, supported reflowable EPUB with a known sentence in a middle chapter. This run creates its own text-linked ink note there. Begin with no book override and the accepted initial paginated default.

- [ ] Open the book, navigate to the sentence and create a labelled note with a distinct drawing. Confirm local saving and close the note.
- [ ] Switch to continuous vertical scrolling. The original sentence remains the reading target and opens the same note.
- [ ] Change font size/orientation, scroll away/back, then switch to page turns. The note remains attached to its original words; no page-number conversion moves its source binding.
- [ ] Close/reopen offline. The chosen local mode and saved note remain available. Try ordinary forward/back navigation with writing off, and finger navigation while Pencil writing is enabled.

**Pass:** Mode/layout changes and reopening preserve the logical place, note identity and editable ink, with the chosen mode retained. The test does not extend the publication profiles beyond the separate profile decision.

## Switch PDF modes with page and margin ink

**Question:** Do continuous scrolling, single-page view and fit/zoom/rotation keep the correct page and its ink usable?

**Setup:** Fresh downloaded text PDF with multiple page sizes, nonzero crop origin, intrinsic rotation and labelled reference words. In this run create ink marking a reference word and a comment beyond that page's edge. Start from the accepted continuous vertical mode.

- [ ] Navigate to the reference page, draw its marks, save locally and disable writing. Ink stays visible during reading.
- [ ] Change to single-page mode, navigate away/back and return to continuous scrolling. Check the original page and marks each time.
- [ ] Use Fit page, Fit width, pinch zoom and viewer rotation. Reach the complete margin comment by panning; opening a sidebar/thumbnail must not crop it out of the accessible extent.
- [ ] Close/reopen offline. Confirm retained mode/settings and source page, then erase a small mark and Undo.

**Pass:** Each supported view preserves source-page alignment, editable originals and reachable margin ink. Viewer rotation does not rewrite source PDF coordinates; a fit label must accurately describe what is fitted.

## Navigate contents and page/location targets

**Question:** Can the reader reach the intended source target without mistaking display pagination or publisher outlines for personal data?

**Setup:** Fresh EPUB with nested chapter contents and fresh PDF with an outline, physical page indices and distinct printed page labels. Include a separate no-outline fixture. Each begins with no personal bookmark or prior navigation history.

- [ ] Open the supplied contents and choose a nested target in each format. Confirm the intended heading/page appears.
- [ ] Use the page/location jump. PDF makes its page numbering/label convention clear; EPUB identifies its logical/percentage location without promising an engine location is a printed page.
- [ ] Enter an invalid/out-of-range target and check the useful validation result. Return to the previous reading place through the reader's navigation action.
- [ ] Open the no-outline fixture. Its unavailable contents state is clear and it remains readable. The publisher outline is never listed as user-authored bookmarks.

**Pass:** Valid targets are accurate, invalid/missing targets are understandable, and reading return is distinct from closing the reader. Navigation does not create a note or bookmark without an explicit action.

## Search a downloaded book and return to reading

**Question:** Can offline search find available source text and navigate matches without unbounded work or stale results?

**Setup:** Fresh downloaded EPUB and text PDF with a known repeated search term at recorded locations; image-only content provides a separate unavailable-text check. No search state comes from another case.

- [ ] Disconnect the server and search each text source. Inspect contextual matches and navigate to a specific occurrence.
- [ ] Move through matches and return to the prior reading place. Search highlighting is temporary and does not add a reading annotation.
- [ ] Search a common term with many matches, cancel/change the query, then switch sources. Results remain bounded and late work cannot replace the active query/source.
- [ ] Open the image-only check. The app explains unavailable text without claiming OCR or successful search of nonexistent words.

**Pass:** The intended occurrence is found from the complete local publication where text exists, results/control response stay within the accepted resource targets, and cancellation/source changes do not leak stale results.

## Follow footnotes and return from links

**Question:** Can the reader inspect linked content and return to the original place using an in-reader action?

**Setup:** Fresh EPUB with a tagged footnote and nested internal links, and fresh PDF with known internal targets. Record the initial logical place in each; no previous case provides history.

- [ ] Open the EPUB footnote. Its content is readable in the supported temporary/jump presentation; return to the calling sentence.
- [ ] Follow two internal targets and use the reading-return action twice. Verify each origin rather than merely returning to the library screen.
- [ ] Follow a PDF internal target and return. Change zoom/layout before returning and check the original logical target remains correct.
- [ ] Open a permitted external link through the supported external-navigation flow and return to the app. The book/source/account and local draft remain intact; the publication gains no trusted native bridge access.

**Pass:** Linked content is reachable within the supported profile and the reader has an understandable way back. Source-bound history, note identity and the existing resume-conflict policy remain separate.

## Keep local defaults and book overrides separate

**Question:** Do local settings persist with visible scope while other books/devices remain predictable?

**Setup:** Fresh account-scoped state with EPUB copies A and B, PDF copy C, and a supported browser on the same account. Record browser appearance and any existing explicit website preference-sync setting. No override is imported from another case.

- [ ] Set an EPUB app default. Open A/B and confirm both inherit it. Set a visibly different book override on A and verify B still uses the default.
- [ ] Change A's font/size, spacing, margins, theme and mode. Reopen it offline; the selected overrides remain. PDF C retains its independent format/view settings.
- [ ] Change the app default again. A's overridden fields remain; inherited fields follow their default. Use app defaults on A and confirm the corresponding overrides are removed and the current default applies.
- [ ] Check the browser and then change its own appearance. Neither direction silently changes the iPad's local settings or automatic reading position. The app has not toggled the website's explicit preference-sync setting.
- [ ] Change authenticated account/server scope. The new scope cannot inherit the old account's stored overrides accidentally; returning to the original scope recovers its settings.

**Pass:** Settings survive normal reopening/update persistence with understandable scope, reset means removing the intended override, and defaults/overrides do not cross accounts, formats or native/browser stores unintentionally.

## Restore publisher styling without altering notes

**Question:** Can the reader return to the book's own typography while keeping notes and accessible controls?

**Setup:** Fresh supported reflowable EPUB with embedded publisher styling and a note created in this run. Record a reference paragraph and drawing. Use both normal interface text and larger interface text/VoiceOver for the required controls.

- [ ] Apply custom font, size, line spacing, margins and theme. Confirm the selected-word note still opens the same contents.
- [ ] Return to publisher styling. The intended typography override resets without changing source bytes, logical position or note content.
- [ ] Try light/dark/sepia and the system-theme option, including a system appearance change while the app is open. Text, controls, context and the original ink remain readable; no archive is recoloured or flattened.
- [ ] With larger UI text and VoiceOver, reach every required setting/reset action and return focus to reading. Reopen the note and try erase/Undo.

**Pass:** Appearance changes respect source identity and saved ink, scope/reset labels are clear, and required controls/readable content remain accessible. PDF page colour inversion and automatic handwriting transcription are not inferred requirements.

## Save an offline bookmark and find it in the browser

**Question:** Does a manually saved place arrive as the same personal bookmark without changing the automatic resume position?

**Setup:** Fresh downloaded EPUB and PDF with known reference places and no bookmarks. Use the physical iPad and each selected browser on the same account. A PDF with its own outline distinguishes publisher contents from personal bookmarks. This run starts with its own clean bookmark/sync state.

- [ ] Disconnect the iPad. Bookmark the EPUB reference place and PDF reference page; rename each generated label and confirm the local save state.
- [ ] Move elsewhere, close/reopen offline and return through the bookmark list. EPUB reflow resolves the original point; PDF opens the original page independently of the saved zoom/rotation preferences.
- [ ] Save the same verified place again. It opens/identifies the existing active bookmark instead of creating ordinary duplicates. Continue reading to another stopping place.
- [ ] Reconnect and allow foreground sync. In each visible browser, find and open the personal bookmarks without reloading, including PDF bookmarks distinct from its supplied outline.
- [ ] Confirm both formats use the original source/location and labels. A list refresh does not jump an open page or silently overwrite an independently reached resume position.

**Pass:** Source-bound bookmark identity/label survives offline reopening and converges across the selected browsers and iPad. Local-versus-synced state is honest; normal reading-position policy remains separate.

## Remove a bookmark and Undo without affecting a note

**Question:** Does bookmark Undo restore the intended saved place while notes/ink remain untouched?

**Setup:** Fresh EPUB and PDF sources. This run creates a bookmark and a separate reading note at each reference place, with distinct label/text/ink, then syncs the baseline. No data comes from the offline-arrival case.

- [ ] Remove the EPUB bookmark offline. Its reading note remains available with unchanged contents. Use the offered Undo and verify the bookmark label/place returns.
- [ ] Remove the PDF bookmark, allow its removal to publish and check the browser list. Page ink and its note-list entry remain; no bookmark Trash entry is created.
- [ ] Use the still-offered Undo for that removal and let it sync. The correct bookmark returns once and no reading-note lifecycle changes.
- [ ] Repeat removal without Undo and explicitly bookmark the same place again. Old retries/late acknowledgments do not remove or resurrect the wrong lifecycle identity; the user sees one active saved place.

**Pass:** Removal/Undo and intentional re-add are source/identity safe, idempotent through retries, and independent of note Trash and Pencil drawing Undo. Technical evidence distinguishes unpublished, uncertain and accepted removal outcomes.

## Keep an unavailable bookmark accessible

**Question:** Does removing/replacing its source preserve a bookmark without opening guessed content?

**Setup:** Fresh copied EPUB/PDF sources and independently created, synced bookmarks with recognisable labels. Retain matching original test bytes separately; prepare changed-content replacements. Use a test operator with required management permissions, not personal originals.

- [ ] Remove one test source/book. Open the bookmark list without opening a readable book; the original label and unavailable-source state remain visible.
- [ ] Open that bookmark. It explains why the original location is unavailable, without claiming to retain a complete book page/excerpt just for the bookmark.
- [ ] Replace the other source with changed words/pages and open its bookmark. It does not jump to a guessed primary file or same-numbered changed PDF page.
- [ ] Restore matching original bytes through the verified association process, then reopen the saved place. A deliberately approved changed binding requires verified placement and retains provenance.

**Pass:** Labels and original source locations survive while access remains honest. Own bookmark metadata grants no full-book or other-user access; unavailable placement is not silently discarded or remapped.

## Recover pending bookmark metadata

**Question:** Can the app recovery format preserve pending bookmark work without exporting credentials or full books?

**Setup:** Fresh test source and local account store; this run creates a labelled bookmark and reading note while disconnected. Use a fresh isolated recovery target, not an in-place wipe of personal work. Record source/operation identities and the existing account/server recovery generation.

- [ ] Export the proposed unencrypted app recovery file and validate its manifest. It includes bookmark metadata/source bindings and pending operation provenance alongside the required note data/download list, without complete books or credentials.
- [ ] Open the file in the isolated offline recovery workspace. The pending label and unavailable-source metadata are readable; no network upload occurs from unverified account claims.
- [ ] Sign in to the matching scope, verify/reconcile generations and recover publication availability. Resume the saved operations or retrieve already-accepted outcomes using their original immutable identities.
- [ ] Verify one active bookmark/label and the preserved note after convergence. An old receipt or rolled-back device sequence cannot replay an already-deleted state or cross accounts.

**Pass:** Pending bookmark work survives coherent recovery with the same safety rules as the reader's durable queue; the proposed metadata addition does not weaken the accepted recovery format's isolation, size or encryption policy.

## Review competing bookmark labels

**Question:** Do competing labels remain reviewable under one saved place without losing a newer edit?

**Setup:** Fresh verified EPUB/PDF source and a labelled bookmark created/synced during this run. Open the same bookmark on iPad and browser; record its initial label/lifecycle heads. Repeat each format independently. A technical subcase starts from no bookmark and independently creates one at the same verified location on both clients.

- [ ] Disconnect the iPad and rename its bookmark. Rename the same bookmark differently in the browser, then reconnect the iPad.
- [ ] Find one active bookmark with Needs review and both labels available. No device clock or automatic arrival-order winner discards a label.
- [ ] Resolve by choosing/editing a label within its validated size. Change the bookmark concurrently during a separate review attempt and check that the comparison refreshes instead of discarding the newer label.
- [ ] Reopen and inspect both clients. Repeat the independently created same-location subcase with different labels; origins converge safely to one active saved place with reviewable alternatives.

**Pass:** Both labels are preserved for owner review, resolution checks current heads/lifecycle/occupancy, and retries/aliases do not create duplicates or overwrite a newer change.

## Preserve an offline rename after bookmark removal

**Question:** Does removal stay effective while the iPad keeps the unapplied label locally?

**Setup:** Fresh verified source with a bookmark created/synced during this run. Open the same record on iPad/browser and record its heads. No state comes from the competing-label or Undo case.

- [ ] Disconnect the iPad and change its bookmark label. In the browser remove that bookmark and allow its removal to publish.
- [ ] Reconnect the iPad. The bookmark remains removed in both ordinary lists; the unapplied local label appears under bookmark Recovered changes, with its original location/provenance.
- [ ] Close/reopen and export/import that run's recovery copy on an isolated target. The local candidate remains protected and does not upload as an active deleted bookmark.
- [ ] Explicitly save the recovered work as a bookmark. If another active bookmark now occupies the point/page, review labels under one entry rather than overwriting it. Replay the old rename/removal responses and confirm they cannot change the newer lifecycle.

**Pass:** No automatic restoration, label loss, accidental reading-note conversion or stale-operation effect occurs. Explicit re-addition is distinguishable from an old retry.

## Technical correctness and scale matrix

Run each row from a fresh account/source/operation fixture with recorded expected identities/revisions. Human visual verdicts are separate from instrumentation. These cases remain unrun until an implementation exists.

| Fresh setup and action                                                                                                           | Required result                                                                                                                                                 |
| -------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Create/rename/remove/Undo with a response lost after commit, then retry the same operation.                                      | Same receipt/result and one event; immutable payload/digest, no duplicate or unintended restoration.                                                            |
| Exit before/after local persistence, request transmission, server acceptance and receipt persistence.                            | Last acknowledged local state/pending work survives; uncertain operations are looked up/retried without rewriting them.                                         |
| Queue a rename/remove while another actor creates at the same point, resolves a label or changes lifecycle.                      | Current canonical occupancy and lifecycle checks protect every origin; removed identities cannot modify the newer active bookmark.                              |
| Receive an old successful label receipt after removal or a successor edit; return after feed/receipt compaction.                 | Current state is not replaced; replay floors/reconciliation preserve pending candidates and prevent resurrection.                                               |
| Load existing bookmark IDs/comments, tombstones and KOReader/Kobo links, including records beyond the old 500-item exchange cap. | Preserve original IDs/data/mappings, page all eligible results, and guard unsupported legacy writes/purge against protected new state.                          |
| Load unverifiable legacy CFI/positions or a changed/missing source.                                                              | Keep original metadata and show verification/unavailable state; do not invent historical hashes or fall back to the primary file.                               |
| Attempt unauthorized cross-user/source/association access and switch native/browser account/server scope.                        | Owner/permission checks prevent reads/writes/leaks, including local settings and recovery candidates. Own unavailable metadata grants no complete-book access.  |
| Recover a store/export after server-generation rotation with pending labels/removals and the same source now occupied.           | Isolated validation/reconciliation precedes upload; preserve immutable operations and the agreed conflict/removal rules.                                        |
| Search, contents, thumbnail and bookmark lists exceed one page while sources/queries/layouts change.                             | Bounded work/memory, cursor/virtualized results, cancellation and generation checks; no library-sized array or stale callback replaces active state.            |
| Change fonts, mode, fit or page while an ink stroke/preview save is active.                                                      | Final drawing data stays on its original note/page and durable local state; view reconstruction does not create/delete identities.                              |
| Exercise new request/response fixtures for bookmarks and source-bound PDF placement.                                             | Native records, shared types, strict DTOs, routes and response acknowledgments agree; unsupported capabilities pause affected writes with local work preserved. |

Use the numeric targets, dataset/profile and repetition methodology from [storage/recovery](../decisions/storage-recovery.md), including the declared working-set limits. Record extra bookmark counts and skew explicitly; the old 500-record cap is not an accepted total-data limit. No source audit or unrun case is a completed production result.
