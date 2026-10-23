# Reading-note identity, anchors and storage

Review record for [Choose note identity, anchoring, and storage ownership](https://github.com/mooneeb/bookorbit/issues/8). This specification combines the nine live product choices with the proposed technical model. The linked issue records final acceptance and current status. This document does not authorize production implementation.

## Accepted behavior

The [first round](https://github.com/mooneeb/bookorbit/issues/8#issuecomment-6363544698), [second round](https://github.com/mooneeb/bookorbit/issues/8#issuecomment-6363610931) and [third round](https://github.com/mooneeb/bookorbit/issues/8#issuecomment-6363801007) establish:

1. A text-linked note may contain typed text, editable handwriting, or both. Scribble enters typed text; it does not replace the handwriting archive.
2. There is one note for an exact selected range. Reselecting that range opens the existing note.
3. After sync, BookOrbit retains editable ink originals and browser previews so a replacement iPad can recover editable notes. This does not require unlimited historical revisions.
4. Different ranges have separate notes, including overlapping ranges and identical words at different locations.
5. All freehand handwriting on one PDF page forms one page-ink entry in both lists. Explicit text-linked notes are separate entries.
6. Removing a book leaves its notes and saved excerpts/pages available in Annotations with a Book removed label. This does not keep the complete book readable.
7. EPUB and PDF notes share the book's notes list but stay placed on their original source file. Automatic placement across formats is not required.
8. If an identical file is reimported after removal, offer to reconnect its saved notes after verifying a full content match. Reconnection requires the user's choice.
9. Removing highlight colour keeps its attached text/ink note, accessible from a note marker and the lists. Moving the whole note to Trash is a separate action.

The existing format decision remains: freehand PDF page ink, and EPUB notes attached to exact selected words with handwriting in a separate note canvas.

The [reading-note glossary](../../../../GLOSSARY.md) defines the terms. The [completed browser proof](../prototypes/browser-compatibility/README.md) establishes compatibility for its retained fixtures, not a production sync protocol or a final reader stack.

## Proposed owner and identities

Extend the existing annotation feature as the owner of reading annotations. Both the book's Highlights list and global Annotations already read and edit that owner. Avoid creating journal copies, Notebook copies, or browser-only notes for the same annotation.

| Concept            | Identity and responsibility                                                                                                                                                                                                                                    |
| ------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Reading annotation | One stable client-generated UUID, scoped to the authenticated account and server connection. Preserve the existing server integer ID for legacy clients. The UUID survives offline creation, upload, Trash, restore, signing renewal and ordinary app updates. |
| Text-linked note   | An annotation on one exact range in a verified source content version. It has an optional highlight style, typed body and editable ink canvas. A highlight without a body remains a valid annotation.                                                          |
| PDF page ink       | An annotation containing the user's drawing for one page of a verified PDF content version. No selected text is required. An optional typed explanation may accompany the drawing.                                                                             |
| Book association   | A stable user-owned association ID for the library book, with a nullable current book link and retained title/author/source metadata. It survives removal of that library entry; the entry is not an immutable edition.                                        |
| Content binding    | The original source identity plus an exact text selector or PDF page/geometry. Source bindings are independent of screen layout and survive deletion of mutable navigation links.                                                                              |
| Annotation asset   | A user-owned editable drawing, display preview, or saved-context resource with verified bytes and an explicit reference from its annotation. It is not an arbitrary public file URL.                                                                           |

The note ID is independent of its source locator, current file path, rendering size and installation build. A different screen layout updates display geometry, not identity. Moving a file while preserving its verified content changes navigation information, not the note. Never use matching quote text alone as note identity.

Create the user/book association lazily when preparing a book for reading or download, return its ID with the reading metadata, and cache it for offline use. Do not pre-create associations for every user/library book combination. Keep the association ID stable when a book disappears. On an approved identical-file reconnection, reuse that association and all note IDs while updating only the current navigation links. Two independently present library entries remain separate associations, even if their files have identical bytes; a shared digest alone never merges their notes.

For new verified annotations, enforce at most one active text-linked note per `(user, book association, source content version, canonical selected range)` and one active page-ink annotation per `(user, book association, PDF content version, page index)`. Different occurrences of the same words and different overlapping ranges remain distinct. Canonical ranges must resolve to the same text boundaries; equivalent serializer output must not create duplicates.

UUID retry identity and range/page uniqueness solve different problems. If two offline devices independently create the same selection, preserve both submitted contents and expose the collision to the later sync decision. Do not silently discard one body or accept two ordinary active notes for that key. Restore collisions, tombstones and conflict resolution belong to [Choose offline sync, conflict, and deletion behavior](https://github.com/mooneeb/bookorbit/issues/9).

## Source identity and anchoring

Bind new notes to the actual delivered bytes, verified by a full SHA-256 digest and format, with the original source revision, file UUID and byte size retained as provenance. For transformed delivery, keep both the original source digest and the delivered artifact digest, variant and transform version. These hashes can differ. A file's database ID, path, primary-file status, ISBN or scanner fingerprint does not prove unchanged content. Use the delivery artifact's verified hash/revision contract as the existing starting point; do not substitute the scanner's sampled MD5.

Start with original-file delivery for new source-bound notes. A transformed EPUB representation can share the original source only after its canonical range mapping has been validated; it is not equivalent merely because its title or extracted quote matches. The later reader-stack decision must explicitly validate any required delivery transformation instead of silently treating it as the original file.

### EPUB text-linked notes

Keep a canonical range selector including the EPUB resource/spine location and text boundaries, a CFI representation, the exact selected quote, and bounded surrounding text. Resolve within the verified source version and verify the quote before showing a highlight or opening from selected words. The surrounding text helps diagnose ambiguity; it is not permission to relocate a note to a different edition.

Font size, viewport width and pagination are ordinary layout changes. Recover the same range through the current renderer and draw its highlight there. Keep the note's ink on its independent canvas, preserving handwritten letter shapes. Do not project or split arbitrary strokes over EPUB text.

The same logical range may have renderer-specific locator representations. Validate their association to the canonical selection; an arbitrary CFI string or screen rectangle alone is not a universal cross-engine identity. If a range cannot be resolved unambiguously, keep the note accessible from the lists and its saved context, and show that its in-book location needs attention.

### PDF notes and page ink

Retain the source content version, zero-based page index, MediaBox, CropBox, intrinsic page rotation, units and coordinate convention. The displayed page number is a label, not identity. Text-linked PDF notes additionally retain their exact quote and source-page selection rectangles.

For page ink, preserve the native canvas size, drawing bounds and its transform into unscaled PDF page coordinates. Viewer zoom and rotation are display transforms. The visible and scrollable bounds include ink outside the page crop; clipping an original margin comment is not acceptable.

The browser proof's `matrix(0 -1.3 1.3 0 0 650)` is fixture evidence, not a transform to hardcode for arbitrary PDFs. The chosen reader must compute each document's geometry. The final stack decision owns renderer-specific adapters and vector/raster budgets.

### Replaced or missing source content

An unexpected content hash/revision change leaves the original binding and saved context intact. Open the retained excerpt/page with the note and clearly identify the changed or missing source. Do not fall back to the current primary file or overlay old PDF ink on a same-numbered page of a changed file. Hash changes trigger verification, not a claim that the reading text necessarily changed: even metadata edits or EPUB repackaging can change bytes. Until unchanged placement is established, this conservative version asks rather than silently adopting the changed file.

Any user-approved association with changed content needs a separately verified new binding and retains the original binding/context. PDF page ink also requires explicit placement verification; finding a similar page does not prove that its old coordinates fit. This is distinct from ordinary reflow or zoom.

The shared book notes list includes all its source versions and formats. Opening a note chooses its recorded source file, or saved context if that file is unavailable. It does not place an EPUB note at guessed PDF words. For an identical reimport, verify the complete bytes, offer to reconnect the retained association, and change its navigation link only after the user chooses it. Do not assume cross-format or cross-book matching from a shared title, ISBN, quote or sampled hash.

## Editable ink, previews and saved context

Use a native editable drawing archive as the authoritative ink content. Store its encoding/version, app/runtime provenance, byte length and SHA-256 with it. The tested PencilKit archive is the initial candidate for the supported iPad baseline; final native API selection remains with the reader-stack decision. Browser display must never replace the editable archive with an image.

Store browser previews alongside the originals. An ink revision manifest explicitly associates a preview with the exact drawing hash/revision, canvas/crop bounds, pixel dimensions, transparency and rendering provenance. A PNG is the tested derivative candidate; the fixed 2x test does not select a universal production resolution. Generate native-dependent derivatives on a supported native device rather than assuming a Linux server can run PencilKit.

Each new ink revision uses immutable asset bytes. Verify uploaded bytes before activating a manifest that references them. A typed-body update changes only that field; it must not overwrite a concurrently stored drawing or preview. An unavailable or mismatched preview is labelled unavailable, not presented as if it were current ink. Exact revision publication and retry behavior belong to the sync decision.

Keep metadata and references in PostgreSQL and immutable asset files in a dedicated managed directory under BookOrbit's configured app-data storage, outside watched book folders and the disposable delivery cache. This reuses the existing self-hosted installation and needs no separate cloud service. Keep local note metadata and assets durable inside the iPad app; the native persistence library is a later stack choice. Both stores belong to the authenticated server/account association.

Saved context is independent of the mutable book file and delivery cache:

- EPUB: preserve the selected quote, nearby readable excerpt and a self-contained retained view where needed to understand the note. Package resources needed to read that retained view; do not leave hidden font/image/chapter dependencies on the replaced book.
- PDF: preserve the annotated source page and its geometry, including the native ink canvas/margins. An extracted PDF page or self-contained retained view must retain the original reading context and editable ink association.
- Keep the original source identity and bounded identifying metadata. Complete previous editions are not required to remain readable.

Do not call a note safely synced until its required original ink, matching display derivative, and saved context are durably stored and referenced. Local work remains available if the server is unreachable or incompatible. If context capture or preview generation fails, retain the ink locally for retry and clearly report the incomplete preservation; never replace a valid saved version with an incomplete one. The later sync decision will define status wording, batching, acknowledgment and conflict semantics.

## Ownership and lifetime

All annotations, bindings and assets are user-owned. Library sharing does not share a user's notes. Controllers pass the authenticated user; all reads, downloads and mutations check ownership and applicable permissions. Sensitive/destructive handlers require explicit `@RequirePermission` metadata; do not copy the existing metadata-free mutation pattern. Superuser exceptions must follow the existing explicit access pattern. Guessing a UUID, hash or storage path grants no access.

Removing a current book/file link must not cascade-delete annotations or their assets. Retain the owner's identifying metadata and saved context and expose orphaned notes through user-scoped annotation routes, without requiring an extant book to authorize access to the user's own note. This is not access to the removed full book or to another user's notes.

Removing highlight appearance is a style change when a note body or ink remains: retain the range and show its note marker. Clearing the last appearance from a highlight-only annotation may remove that empty visual annotation through recoverable Trash; it must not silently delete a body. Explicit Move note to Trash affects the complete annotation. No helper should interpret an omitted ink field in a typed edit as a request to erase ink.

Trash applies to one logical annotation and all of its text, ink and context references. Keep those assets while the annotation is recoverable. Removing a local book download or an inactive delivery-cache artifact does not remove note assets. Erasing ink is a content edit, not permission to permanently delete a note or discard all recoverable versions.

Do not collect a replaced/orphaned asset while an active or recoverable annotation/revision still references it, or while a publication is unfinished. Actual retention periods, storage quotas, exports/backups and collection grace periods are deliberately left to [Set library scale, storage, backup, and export requirements](https://github.com/mooneeb/bookorbit/issues/12); tombstone and device-acknowledgment rules belong to the sync decision. No indefinite historical-revision promise is made here.

## Existing records and API boundaries

Keep current annotation IDs and content intact. Extend annotation storage for stable client identity, a discriminated text-range/PDF-page kind, verified source binding, optional mixed content and asset manifests. PDF page ink has no required quote; existing text-range contracts keep their nonempty selected-text validation. Add stable user-owned book associations so a removed book's notes retain their common identity without a live book FK. Extend position identity beyond its current `(annotationId, format)` uniqueness so retained source versions and file-specific selectors cannot overwrite one another. Make mutable book/file references nullable without losing the independent original source/context.

Journal entries remain independent whole-book notes; reviews remain independent review values. Do not convert or duplicate them into reading annotations simply to show a list. The existing server Notebook is a read projection over owners, not a second note store. If it includes the new annotation kinds, project their same IDs and ownership instead of copying the contents. Existing personal note data must not be silently discarded as a side effect of changing book-removal behavior.

Legacy annotations may contain duplicate ranges or anchors with no verified source revision. Preserve their IDs and bodies; flag unverifiable associations for review. Do not invent historical source hashes, merge notes by matching text alone, or delete a duplicate to force a new uniqueness rule. Migration must retain every existing body/asset and identify any unresolved canonical-range collision before enforcing active uniqueness. Backfill can establish present-day verification, not prove missing original-edition provenance.

Use explicit capability-gated contracts for mixed notes, PDF page ink, verified bindings and assets. New input fields require declared DTOs and shared types, not JSON fields sent into existing strict request validators. Legacy quote-based routes retain their supported shapes and partial typed-note semantics; ink/page variants must not be disguised as highlights with fake selected text. Unsupported clients receive an explicit limitation rather than a destructive replacement or an empty note.

Extend origin/device capability declarations explicitly for the native reader; the current web/Kobo/KOReader origin enum and deletion acknowledgments are not a complete iPad contract. Legacy device projections must preserve unknown ink assets, and unsupported permanent-deletion requests must not bypass the new asset/lifecycle checks.

New source-bound readers must not use legacy primary-file fallback or automatic conversion as authority for a changed edition. A migration/adapter must distinguish verified, unresolved and legacy-unverified associations. Clients that cannot represent the extension must not publish writes that erase its fields. Detailed operation/precondition and deletion contracts are the next sync decision, not established by the existing annotation `version` field.

Serve list metadata and small previews with bounded, user-scoped pagination. Fetch full drawings, saved context and detailed geometry on demand for the active note/page. Index the ownership, active-range/page key, book association, lifecycle and list order. Do not download every note/ink asset or load an entire library to open a page. Existing unbounded per-book reads and capped journal lists are not sufficient templates for the new offline protocol.

## Repository evidence and alternatives

Read-only audit baseline: `9edec0c3b563daa3c6bc4c3141a568b2e3381e57`. Production server/shared-type sources are unchanged from main `ce118e3890ea8c9019857cb7556552cdc9992f8e` at this audit. Prototype observations are separate from deployed capabilities.

- [Annotation, journal and position schema](https://github.com/mooneeb/bookorbit/blob/9edec0c3b563daa3c6bc4c3141a568b2e3381e57/server/src/db/schema/reader.ts#L508): annotations currently have integer IDs, user/book ownership, optional typed text and device-sync state; positions are unique per format. Book deletion currently cascades through note records. There are no authoritative ink/preview/context assets.
- [Shared web mutation owner](https://github.com/mooneeb/bookorbit/blob/9edec0c3b563daa3c6bc4c3141a568b2e3381e57/client/src/features/annotations/composables/useAnnotationMutations.ts#L12): the book and global lists already mutate the same annotation. Extending this owner requires fewer duplicate projections than starting with journals.
- [Journal creation](https://github.com/mooneeb/bookorbit/blob/9edec0c3b563daa3c6bc4c3141a568b2e3381e57/server/src/modules/book-journal/book-journal.service.ts#L29): journals already have retry identity but require a nonblank text body and lack file/version/PDF/ink support. This does not make them the natural owner of page ink.
- [Notebook projection](https://github.com/mooneeb/bookorbit/blob/9edec0c3b563daa3c6bc4c3141a568b2e3381e57/server/src/modules/notebook/notebook-sql.ts#L61): server aggregation exists; no production browser Notebook consumer was found in the bounded audit. Do not claim a new web Notebook surface exists.
- [Book/file schema](https://github.com/mooneeb/bookorbit/blob/9edec0c3b563daa3c6bc4c3141a568b2e3381e57/server/src/db/schema/books.ts#L23) and [scanner fingerprint](https://github.com/mooneeb/bookorbit/blob/9edec0c3b563daa3c6bc4c3141a568b2e3381e57/server/src/common/utils/file-hash.utils.ts#L8): existing IDs and sampled hashes are insufficient edition identity.
- [Delivery artifact service](https://github.com/mooneeb/bookorbit/blob/9edec0c3b563daa3c6bc4c3141a568b2e3381e57/server/src/modules/book/delivery-artifact.service.ts#L34): verified full SHA-256 and expected-revision checks exist, but note anchors do not yet reference them or preserve earlier source content.
- [Create-annotation validation](https://github.com/mooneeb/bookorbit/blob/9edec0c3b563daa3c6bc4c3141a568b2e3381e57/server/src/modules/annotation/dto/create-annotation.dto.ts#L40): unselected page ink and arbitrary new fields cannot use the current request unchanged.

Alternative owners considered: extending journals would reuse their client UUID but need both existing web lists and anchor/ink semantics added; creating a new independent note service would avoid old assumptions but duplicate ownership and migration work. Extend annotations with explicit variants, keeping source bindings and asset handling inside that feature boundary. Revisit this choice if the later stack or protocol decision produces a concrete incompatibility, rather than adding a second owner preemptively.

## Acceptance and handoff

The final design must demonstrate:

- The same note UUID opens from selected text, the reader, both lists and recovery on a replacement iPad. Typing in the browser preserves ink.
- Reselecting an exact range opens its note; overlapping different ranges and repeated quote text elsewhere remain distinct.
- Several freehand marks on one PDF page form one list entry; a different page has another entry and independent geometry.
- Normal EPUB reflow preserves the range and note canvas; PDF zoom/rotation preserves page ink and accessible margins.
- Source replacement, file removal and book removal preserve original context and editable assets without automatic relocation or cascade loss.
- Trash/restore and offline identity collisions preserve data and follow the later selected conflict/deletion policy.
- Older/unsupported clients cannot erase unknown ink content, bypass user ownership or turn an unverified anchor into an approved edition change.

Final shared-understanding confirmation must be recorded on the linked decision before it is closed. The next decisions still own synchronization, native stack, scale/backup/export policy and complete reading-journey acceptance. No schema migrations, production API changes, server deployment or new physical-device experiment are part of this document.
