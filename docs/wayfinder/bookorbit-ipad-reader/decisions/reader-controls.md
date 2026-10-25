# Everyday reading controls and preferences

Complete proposal for [Choose everyday reading controls and preference behavior](https://github.com/mooneeb/bookorbit/issues/22). All eleven live choices are accepted; the linked issue records final shared-understanding confirmation and resolution status. This document does not authorize production implementation or report the native reader as passing.

## Accepted controls

The [first live round](https://github.com/mooneeb/bookorbit/issues/22#issuecomment-6395961203) establishes:

1. EPUB supports page turns and continuous vertical scrolling, starting with page turns.
2. Both formats include supplied contents/outline, in-book search, a page/location jump, personal bookmarks, and links/footnotes with a way back.
3. EPUB supports font choice/size, line spacing, margins, light/dark/sepia themes, a system-theme option, and return to publisher styling.
4. PDF starts with continuous vertical scrolling and also supports single-page mode, Fit page/Fit width, pinch zoom, rotation and thumbnails.
5. Appearance and reading-mode settings stay device-specific, with app defaults and optional individual-book overrides. Notes and reading position retain their existing sync contract.

The [bookmark round](https://github.com/mooneeb/bookorbit/issues/22#issuecomment-6396042520) adds:

6. EPUB/PDF bookmarks sync between iPad and browser, including offline iPad additions/removals and honest local-versus-synced state.
7. A bookmark keeps an EPUB text location or PDF page and an automatic, editable chapter/page label. Reading notes provide comments/handwriting; no new bookmark comment editor is required.
8. Bookmark removal offers Undo, without bookmark Trash. It never removes a reading note or ink.
9. Removed/changed source books leave bookmarks listed with their label and original location, unavailable until original-source restoration or verified placement. A bookmark alone does not require a retained full excerpt/page.

The [conflict round](https://github.com/mooneeb/bookorbit/issues/22#issuecomment-6396103196) completes the choices:

10. Keep conflicting labels under one bookmark for owner review.
11. Keep a removed bookmark removed when an offline rename arrives; retain the unapplied label locally in Recovered changes. Explicit re-addition is allowed, not automatic restoration.

The [note model](note-model.md), [offline sync](offline-sync.md), [native stack](native-stack.md), [storage/recovery](storage-recovery.md) and [book-merge model](book-merge.md) remain accepted inputs. A bookmark is a deliberately saved place, separate from a text-linked note and the automatic reading position. Existing journals and whole-book notes keep their owners and online role.

## Observable reading behavior

| Control            | Required outcome                                                                                                                                                                                                                                                                             |
| ------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| EPUB mode          | Switch page turns/continuous scrolling without changing the source, note identities or logical reading place. Mode-dependent display geometry is recalculated. Do not interpret a new screen page number as a new canonical text location.                                                   |
| Contents/outline   | Present publisher-supplied entries with hierarchy and navigate to valid targets. A missing outline is clearly unavailable; do not manufacture personal bookmarks from PDF outline entries.                                                                                                   |
| Search             | Search available text in the active book/source, show bounded contextual matches, and navigate through them. Search highlights are temporary reader state, not saved annotations. Image-only content retains the accepted unavailable-text state.                                            |
| Page/location jump | PDF distinguishes source-page index from any displayed page label. EPUB uses a meaningful logical location/percentage and publisher page labels when available, without calling engine-sized locations printed pages. Validate targets and retain a way back from a deliberate jump.         |
| Links/footnotes    | Open supported in-book targets and provide a reading-return action distinct from exiting the reader. Prefer a temporary footnote presentation when the book identifies one; otherwise support a source-bound jump and return. Preserve the origin before navigation, including nested jumps. |
| EPUB appearance    | Offer the accepted controls, including the publisher font/styling choice, without modifying original bytes or canonical text structure. Font/layout changes preserve exact note association and the current logical location.                                                                |
| PDF mode/geometry  | Preserve source page and visible region where meaningful through scrolling/single-page changes, fit, zoom and viewer rotation. Compute transforms per page. Full ink extent stays reachable, including outside the crop; a fit operation must not hide retained margin comments.             |
| Thumbnails         | Navigate the PDF without loading every full-resolution page into memory. Clearly distinguish the current page and derive source identity from the document/page, not the thumbnail's rendered size.                                                                                          |

All controls use the chosen native core UI and supported accessibility behavior. Publication content remains in its contained engine. The supported publication-profile decision remains separate: both EPUB modes apply to supported reflowable content; fixed-layout/spread, writing-direction and unusual content requirements are not silently settled by this control inventory. Follow [Define supported EPUB and PDF publication profiles](https://github.com/mooneeb/bookorbit/issues/23).

## Device-specific preferences

The proposed implementation uses account/server-scoped local settings with format defaults and sparse file overrides, matching the reader's ability to keep EPUB and PDF presentation separate. A screen can describe these as This book and App defaults while retaining precise source/file identity internally. Settings and view geometry are separate from note identity and automatic progress.

Make each setting's scope visible. Editing a book override changes that book's local presentation; changing an app default affects books inheriting that field. Use app defaults removes the corresponding override and applies the current default. Returning to publisher styling is a distinct book choice that suspends app typography overrides in favour of the publication's typography, including when the app default uses a custom font. Theme and reading mode remain separate preferences. Neither action changes note contents/source bindings or erases a reading position.

Native appearance/mode changes are not sent through the existing account-wide preference endpoints and do not change a browser's font/layout. Do not toggle the website's existing preference-sync setting during native sign-in. Existing explicit website preference-sync behavior remains under that setting; new local storage must be isolated by authenticated account/server and browser profile or native installation. Old unscoped browser keys are not a safe pattern to copy.

Persist local changes before reporting them as retained. Opening another book, restarting the app or receiving remote notes cannot silently replace local preferences. Imported/reconnected/merged file identities use explicit stable mapping; conflicting old settings remain distinguishable instead of being picked from a matching title or filename. Invalid/out-of-range or unsupported settings fall back visibly to valid defaults while preserving the recorded value for diagnosis/recovery as appropriate.

Themes must retain readable text, controls and note context. EPUB appearance does not rewrite handwriting colours or archives. Choose an appropriate paper/background presentation for ink readability. PDF viewer chrome can follow the app theme while the source page and original drawing retain their colours. No PDF content inversion requirement is inferred from the EPUB theme choice.

## Bookmark identity, source and presentation

Keep the existing bookmark feature as owner. Extend it with stable client-generated UUIDs, retained user/book association, verified source descriptor, format-specific logical point, label provenance and lifecycle/revision metadata. Preserve existing integer/client UUIDs and integration mappings; do not migrate bookmark comments into reading annotations or create another owner in Notebook. A publisher PDF outline remains Book contents, not a list of the user's bookmarks.

A new EPUB bookmark captures the current canonical text point using the accepted source-bound serializer conventions, with bounded selector evidence to verify that point rather than a readable retained excerpt. A PDF bookmark captures the source page; viewer zoom, rotation and fit are preferences rather than another page identity. Use the complete source version, not filename/title, current primary-file status or a screen page number. At most one active bookmark occupies the same verified owner/association/source/location key. Equivalent locators converge; same words at different points and different source versions do not.

Generate an initial chapter/page label and permit renaming within the existing 500-character label bound. Retain whether the label was generated or deliberately edited. Label updates touch only that field, preserving any legacy comment/device metadata. Existing optional bookmark comments remain preserved and accessible through their existing web feature; the new native control does not add another comment editor or silently flatten those comments into reading notes.

Provide the reader's current-book list and a bookmark list reachable without opening a currently readable book. Both iPad and browser need source-aware list/open/add/rename/remove controls for the chosen formats, including PDF personal bookmarks. Keep this separate from Annotations' note identity. Existing Notebook can project bookmarks through the owning interface; its server projection alone does not establish a finished global UI.

When a source is removed/replaced, retain the label, identifying metadata, original source/location and unavailable state. Open an explanation instead of falling back to the current primary file or a same-numbered changed PDF page. Reconnection to an identical source uses complete verification and the accepted explicit association/reimport process. A changed binding requires verified placement and explicit approval; preserve original provenance. The bookmark adds no complete-book/page capture obligation. Own retained metadata does not grant access to a complete book in a now-inaccessible library.

## Bookmark sync, removal and recovery

Extend the capability-gated reader-sync coordination through the bookmark owner's exported service. Reuse durable local operations, account/server/recovery-generation scope, immutable request identity/digest, receipt/replay handling and deletion-aware paged changes. Notes, progress and bookmarks remain separate owners. Bookmark creates/renames/removals are automatic foreground work, with conditional background attempts; local saving and server acceptance remain distinct.

An offline create can arrive after its source was removed or replaced. Verify its retained user-owned association/prepared source and preserve the bookmark as unavailable, without requiring a live book row or attaching to a new primary file. Unestablished provenance stays local for review. Retained bookmark metadata must survive parent-book deletion without granting complete-book access or leaking another owner's data.

Creation carries the client UUID, verified location and immutable operation identity. Never treat a repeated POST at a tombstoned legacy CFI as authority to restore it. A duplicate accepted operation returns its prior outcome; competing creation at an active canonical key preserves routing/origin identities and any competing labels rather than producing ordinary duplicates. Canonicalization cannot bypass a prior identity's deletion barrier.

Keep separate label and lifecycle preconditions. A label-only change preserves untouched fields and cannot revive a removed bookmark. Removal checks the current lifecycle, publishes a deletion event and records a durable receipt. A known retry returns its recorded result instead of treating a repeated DELETE 404 as success. A masked/inaccessible 404 is not proof of deliberate deletion.

Offer Undo for an intentional removal without creating bookmark Trash. If the operation was certainly unsent it may be coalesced within the permitted local-draft rules; an uncertain/published removal remains immutable. Undo then becomes a new explicit intent dependent on the removal outcome and checked against the current lifecycle/location occupancy. Re-adding after removal is deliberate work, not a replay of an old create. Preserve removal barriers so late old operations cannot delete or resurrect a newer active bookmark at that place. Existing note Trash and ink Undo are unaffected.

For competing labels at the same saved place, preserve the current accepted label provisionally with Needs review and retain the submitted alternatives under one bookmark. Identical labels can converge; different labels are not resolved by device time or arrival order. An explicit resolution checks current label heads, lifecycle and canonical occupancy before choosing/saving a label. If the bookmark changed during review, refresh the alternatives. Independent creation at the same verified point/page follows this same single-bookmark review principle, with old origin identities preserved for safe routing.

When removal precedes an offline rename, reject active publication of that rename with an explicit removed outcome and preserve its exact unapplied label/identity/source provenance locally under Recovered changes. Do not add bookmark Trash or restore the bookmark. Explicitly saving that recovered work as a bookmark uses a new intent and respects current canonical occupancy; a bookmark already created there requires label review, not overwrite or an ordinary duplicate. A deleted origin identity never becomes an alias that authorizes a stale operation against a newer bookmark.

An older successful label receipt arriving after a removal cannot make the current removed state active or retire a newer pending intention. Reconcile the committed order and current lifecycle rather than replaying from a stale receipt. Recoverable drafts stay protected until their exact outcome is known. Bookmark recovered changes retain their kind and never become reading-note text automatically.

Use the accepted protected local-store and bounded transport rules for bookmark metadata/pending operations. The proposed app recovery manifest also carries those records and bookmark identity/source/receipt/recovery provenance, without adding complete books, page snapshots or credentials. Version that schema addition; an older importer must not report complete recovery while dropping unsupported bookmark records. Server backup includes the bookmark owner, aliases, lifecycle and referenced sync state in the coordinated cut. Preference settings remain device-local through normal updates; a recovery import must not overwrite another active account or silently replay an old device incarnation.

Visible browser bookmark lists/controls check for committed bookmark changes through the same visibility-aware refresh mechanism, with the accepted healthy visible-connection target measured after publication. Preserve an unsaved label and its observed revision. New bookmark publication never jumps an open book page or changes the automatic reading-position base merely because a list refreshed.

Guard legacy bookmark/KOReader/Kobo writers with source/identity/lifecycle compatibility. Keep their external mappings and known deletions, but do not let timestamp-based label replacement, an unversioned write or the old fixed exchange cap silently override protected new state. Unsupported affected writes pause with an actionable compatibility outcome. This adds no native audiobook reader, Kobo administration or promise of new cross-format bookmark placement.

The [source audit](../research/reader-controls-current-facts.md) establishes a useful existing bookmark owner, but not a safe native protocol. Current create DTOs accept CFI/title, the server generates UUIDs, and records have no verified file/version or mutation precondition. PDF sidebar outline entries are not personal bookmarks. A new native PDF bookmark or offline client cannot be implemented by submitting guessed fields to those strict legacy routes.

## Adapter and performance requirements

ReaderSession retains canonical source-bound navigation/selection and explicit display generations. Native controls request contents, bounded search results, mode/style changes and location navigation through that seam; they do not write progress or note records directly. Format-specific adapters own Foliate locations and PDFKit page geometry. Reading preference persistence stays outside the renderer, and any bookmark extension stays with the existing bookmark owner through an exported interface.

Use available Foliate history/selection/search seams only after verifying their wrapper behavior. The browser's router Back and hidden footnote styles do not already provide a native reading-return flow. Keep UI return history separate from sync-conflict resume choices; receiving a remote position must not jump an open page. A temporary footnote view does not create a new note or manufacture a completed read.

Search, contents, bookmarks and thumbnails are paginated/virtualized or processed incrementally. Use the accepted page/work budgets and bounded cancellation. Large-book search must not accumulate every result or every chapter DOM in memory; changing query/source cancels stale work and ignores late callbacks. Layout/style changes wait for active ink capture to become durable and never move an unfinished PDF stroke to another page.

The new native/browser contracts require explicit shared types/DTOs and capability checks. Existing data/settings and prototype widgets do not establish production API compatibility, source safety, offline queues, accessibility or memory behavior.

## Required acceptance

Use the [standalone control cases](../acceptance/reading-controls.md) for EPUB mode changes, PDF fit/mode/rotation with margin ink, contents/search/location jumps, footnotes/return, device-local defaults/overrides/reset, and the chosen bookmark behavior. Each has its own source fixture, initial settings/data, attempted-action checks and specific result. Repeat necessary controls with VoiceOver/larger interface text and during the agreed thirty-minute reading sessions.

Technical validation must additionally cover source-bound canonical equality, independent creation/label races, removal/Undo/late-operation permutations, lost responses, restart/restore, immutable operation identity, permission/access changes, browser drafts, legacy integration mapping/purge, isolated recovery and the accepted large-library budgets. The first recovery/legacy rollout must inventory existing bookmark IDs/comments/tombstones and unverified source placement before imposing new active uniqueness; no historical source hash is invented. New strict DTOs/shared/native fixtures, explicit mutation permissions and owner-filtered list/asset access must agree end to end.

Record source/engine/schema/runtime versions and exact observations. Earlier display and signing fixtures retain their accepted limits. No new native control, bookmark-sync or production reading result has been measured by this proposal.

All eleven product choices are answered. Obtain the user's final shared-understanding confirmation of this complete proposal before resolving the planning decision. The publication-profile decision and complete-journey handoff remain open; this proposal does not pass their validation gates or close the map.
