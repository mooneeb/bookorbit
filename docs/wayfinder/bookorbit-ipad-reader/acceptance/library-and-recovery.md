# Standalone library, lifecycle and recovery acceptance

Future integrated checks for [Agree the complete reading journey and build-readiness criteria](https://github.com/mooneeb/bookorbit/issues/13). The [acceptance index](README.md) links the existing reader/control/profile cases and technical matrix. The linked decision holds final shared-understanding status. Publishing these instructions does not run them or authorize a real install, merge, deletion or restore.

Every case initializes its own test account, source copies, note/bookmark state, device and declared server environment. No preceding case supplies setup or a pass. The preparer records source identities, expected contents, app/server/runtime versions and a run ID privately. Destructive and recovery checks use isolated test deployments and separate restore targets. Checkboxes mean attempted actions; each run separately records **Pass**, **Fail** or **Blocked**, the observed outcome and failing step. All format variants run independently. Never publish private library contents as test evidence.

## Choose and remove an offline book

**Question:** Can a chosen download be removed without losing reading notes or pending work?

**Setup:** Fresh supported EPUB/PDF copies, run separately, with no chosen downloads. This run will create its own mixed note and bookmark. The preparer also provides controlled low-space/cancel variants without exhausting the reader's personal storage.

- [ ] Choose the book explicitly, start its download and observe progress/cancel. An incomplete attempt is not Ready offline; retry reaches a verified complete package.
- [ ] Disconnect, read it, create the note/bookmark and check durable local saving. Reopen to confirm the saved work is present.
- [ ] Request removal of this download and inspect the confirmation. Remove the book package without moving notes to Trash or discarding pending operations.
- [ ] Open the saved note/context and bookmark list. Note contents stay available; unavailable complete-book navigation is explained honestly.
- [ ] In this run's controlled low-space variant, retry a new download/save. Disposable caches may clear, but existing chosen downloads/protected work do not disappear automatically and failed saving does not show Saved or Synced.

**Pass:** Explicit download/removal and failure states protect note/context/pending work. A downloaded book is not evicted without permission, and missing book bytes are distinguished from lost notes.

Trace: [Downloads and space](../decisions/storage-recovery.md#downloads-accounting-and-space-pressure), [local save states](../decisions/offline-sync.md#reader-visible-save-states).

## Review competing note text

**Question:** Can competing edits be resolved under the same note without losing either version or its ink?

**Setup:** Fresh selected-word mixed note created in this run on iPad and synced to one browser. Both contain known text and a distinct drawing. Disconnect the iPad before editing; use the same verified source/account.

- [ ] Edit the typed body differently on the offline iPad and browser. Keep each version identifiable.
- [ ] Reconnect and let foreground sync proceed. Open the conflict review and find both text versions under the same logical note, with the drawing retained.
- [ ] Choose/combine the intended text and save an explicit resolution. The current heads are checked; a newer competing arrival cannot be silently overwritten.
- [ ] Inspect the resolved note in the reader and both note lists, then reopen the iPad ink and try erase/Undo.

**Pass:** Competing contents remain reviewable until explicit resolution, one note remains active, and typed review never replaces the editable drawing. Independent text/ink merge has its separate technical check.

Trace: [Part revisions and review](../decisions/offline-sync.md#revision-and-conflict-rules).

## Move a reading note to Trash and restore it

**Question:** Does Trash recover the complete note while remaining separate from book removal and bookmark Undo?

**Setup:** Fresh EPUB mixed note and PDF page-ink note, each tested independently. Create the run's own source context, typed explanation and drawing, and sync them. The exact range/page is initially unoccupied by another active note.

- [ ] Move the note to Trash in the browser. The active reader/list view updates without leaving a duplicate active entry.
- [ ] Inspect Trash and reopen the retained contents/context. Text, drawing and context remain recoverable; no automatic expiry is implied.
- [ ] Restore it explicitly, allow sync and open it from the correct source words/page and both lists.
- [ ] On iPad, edit/erase/Undo the retained ink. Removing a highlight colour alone or removing a bookmark must not reproduce this whole-note Trash action.

**Pass:** One complete note can be explicitly restored with the same identity and editable original. Occupied-key restore collisions are tested separately in the technical matrix rather than silently replacing another note.

Trace: [Trash and restoration](../decisions/offline-sync.md#trash-permanent-deletion-and-restoration), [manual retention](../decisions/storage-recovery.md#retention-leases-and-replay-safety).

## Preserve late edits after permanent note deletion

**Question:** Do offline edits remain recoverable locally without resurrecting a permanently deleted note?

**Setup:** Fresh synced mixed note, with its own known original drawing/context. Disconnect the iPad, then prepare a different offline typed/ink edit. The browser permanently deletes that same note through the confirmed test Trash/emptying flow.

- [ ] Reconnect the iPad and sync. The deleted server note stays deleted; incoming local changes do not restore or upload it automatically.
- [ ] Open Recovered changes and inspect the unapplied text, editable ink and identifying context locally.
- [ ] Save this recovery candidate in the run's external app recovery file. It remains recoverable without creating a server note as a side effect.
- [ ] Explicitly choose to save the candidate as a new note only when intended. Check current source/range occupancy; a collision is reviewed under one active note rather than overwriting it.

**Pass:** Permanent deletion barriers hold, while late local work remains understandable and recoverable until an explicit new-note decision. Bookmark late-renames remain their own bookmark recovery case.

Trace: [Deletion recovery](../decisions/offline-sync.md#trash-permanent-deletion-and-restoration), [recovery format](../decisions/storage-recovery.md#unencrypted-ipad-reading-note-recovery).

## Import a book from iPad Files

**Question:** Can the in-app online management flow import a permitted file and return to the correct native library?

**Setup:** Fresh test library with an authorized importer, an independent denied user, and prepared EPUB/PDF plus another server-supported format. No file is from a personal original. Begin connected; this run owns all import jobs.

- [ ] Open import in the app's management pages, choose the prepared file from Files and follow visible upload/processing progress.
- [ ] Complete the job and return to native browsing. Only the actual imported entry appears, with source metadata refreshed and an honest native-reading availability label.
- [ ] Open the permitted EPUB/PDF through native reading; another managed format remains manageable without a false native-open promise.
- [ ] Exercise a denied-user attempt and an offline attempt. Permissions are enforced, and offline catalog mutation is unavailable without creating an unagreed pending import.
- [ ] In this run's disconnect/restart variant, inspect the saved job/current state before retrying. The app must not duplicate an uncertain completed import.

**Pass:** Real import/auth/job handoff works inside the app without crossing accounts or pretending offline management. File acceptance and native readability remain separate outcomes.

Trace: [Management/session boundary](../decisions/native-stack.md#online-management-and-account-sessions).

## Edit book metadata without moving old notes

**Question:** Does an online metadata/file change preserve original note placement until verified?

**Setup:** Fresh supported book with this run's mixed note, PDF page ink where applicable, bookmark and saved context. Sync it before editing. The preparer includes a metadata-only change that rewrites bytes and a separately revised-content variant; test each independently.

- [ ] Open permitted metadata management inside the app, edit the reference field and save. Return to native browsing and confirm the updated bounded view.
- [ ] If file bytes changed, inspect the source-change state rather than assuming the old binding still fits. Open the retained original note/context.
- [ ] Review any proposed new placement and accept only a verified association. Original context/provenance remain available; a filename/title match alone cannot relocate ink or selected words.
- [ ] Reopen note/bookmark lists and the browser. Unsaved drafts and the source-specific identity remain protected throughout the refresh.

**Pass:** Metadata changes are usable, and changed bytes receive the accepted conservative verification/approval flow without losing or silently moving notes. Ordinary layout changes remain a different operation.

Trace: [Source replacement](../decisions/note-model.md#replaced-or-missing-source-content), [management invalidation](../decisions/native-stack.md#online-management-and-account-sessions).

## Organize books in collections

**Question:** Can permitted organization inside the app preserve collection ownership and reading notes?

**Setup:** Fresh book, owner-controlled collections and a second user without access to one collection. Create this run's own synced note/bookmark. Start online with permitted book-management access.

- [ ] Open collection management inside the app and create/rename a test collection through the supported controls.
- [ ] Add the reference book, change its membership and return to native browsing; affected views refresh without full-library loading.
- [ ] Remove the membership or test collection through its confirmation flow. The book, source-bound notes and bookmarks are not deleted with that membership.
- [ ] Repeat the denied-user path. Collection identifiers or hidden controls cannot bypass server ownership/permission enforcement or disclose another user's contents.

**Pass:** Organization remains usable inside the app, with explicit owner/access behavior and independent reading-note lifetime. Full management inventory and scale coverage remain mandatory in the technical matrix.

Trace: [Management scope](../decisions/native-stack.md#online-management-and-account-sessions), [collection preservation on merges](../decisions/book-merge.md#scale-sync-and-backup-integration).

## Run and recover a bulk book-management action

**Question:** Can a long action show partial outcomes and resume/retry safely without guessing what happened?

**Setup:** Fresh authorized test library and a bounded selected/all-matching job with known successful, denied and failed items. The preparer injects disconnect/restart into this run. Existing notes/context are created within the run and recorded before source-changing actions.

- [ ] Start the permitted bulk action in embedded management, review its scope and observe meaningful progress/cancel/status.
- [ ] Disconnect or restart at the prepared point, reopen and query the persisted outcome before retrying uncertain work.
- [ ] Inspect successful/failed/skipped items through bounded pages. Retry the relevant failures without repeating already-completed destructive effects.
- [ ] Check source bindings, retained notes and current permissions. Any identity collapse requires its own explicit merge preview/confirmation, including scanner/rename proposals.

**Pass:** Progress and partial results survive the relevant interruption, retries are safe and bounded, and neither a full-library client array nor unconfirmed collapse is required.

Trace: [Management bounds](../decisions/storage-recovery.md#initial-negotiated-resource-limits), [merge publication](../decisions/book-merge.md).

## Merge book copies and review personal conflicts privately

**Question:** Can an explicitly confirmed merge preserve originals and owner-only reviewable state?

**Setup:** Two fresh test book entries with distinct and fully identical file variants, multiple users' private notes/journals/history and different collection memberships. Each has known conflicting mixed notes/ratings/status. The initiator has the required catalog permissions but no right to read other owners' private contents.

- [ ] Open merge preview, choose the surviving entry and inspect metadata/files before confirming. Renaming/scanner proposals cannot bypass this step.
- [ ] Complete the controlled merge. Distinct files stay separate; verified exact copies may deduplicate while old links/identities still route safely.
- [ ] As each owner separately, open retained conflicts/history and verify provisional values, Needs review and private alternatives. The initiator cannot read another person's review contents.
- [ ] Confirm journal entries, collection union and historical library attribution remain correct; no reading time or completion event is created by merging.
- [ ] Reconnect a device with this run's offline edit using an old identity. The edit routes or enters review without duplicating/deleting work. Reopen retained ink and try erase/Undo.

**Pass:** The confirmed merge preserves each owner's data and original sources, with explicit conflicts and safe old-link routing. No automatic unmerge is promised; crash/cancel/stale-preview cases remain separate technical checks.

Trace: [Confirmed merge contract](../decisions/book-merge.md).

## Renew and update the daily reader without losing work

**Question:** Does the production reader retain identity, pending notes and credentials through its supported free update route?

**Setup:** Isolated production-target test install on the intended iPad, with this run's downloaded EPUB/PDF, unsynced note/ink/bookmark, matching external recovery file and recorded remaining signing validity. The operator prepares reviewed builds and verifies actual app slots/entitlements. This is separate from the retained prototype's completed proof.

- [ ] Use the recorded stable-AppID SideStore manual import route, preserving the reader identity and cancelling any unexpected certificate-revocation request. Follow the documented Xcode fallback if that route cannot proceed safely.
- [ ] After renewal, compare this run's note IDs, finalized original bytes, saved context and pending operations before allowing reconciliation.
- [ ] Open offline within measured remaining profile validity. Read both formats and edit/erase/Undo the saved ink; local-versus-Synced states remain honest.
- [ ] Apply the controlled in-place reader update and repeat the same checks. Reauthenticate if required without wiping work, then reconcile and verify browser arrival.
- [ ] Record the supported fallback/recovery outcome. Any procedure that would erase a container requires a completed external recovery copy first; badge/background renewal is not assumed proved by manual import.

**Pass:** The actual reader's stable identity and editable/pending work survive the chosen renewal/update and supported recovery path. Seven days is measured from profile issuance; no thirty-day disconnected-launch guarantee or unconditional background refresh is inferred.

Trace: [Packaging and updates](../decisions/native-stack.md#build-dependencies-and-updates), [validated prototype route](https://github.com/mooneeb/bookorbit/issues/20#issuecomment-6299949060).

## Export and open local reading-note recovery

**Question:** Can an external recovery file preserve editable and pending work without uploading it into an unverified account?

**Setup:** Fresh isolated store containing this run's text/ink notes, context, conflicts, Trash, Recovered changes, bookmarks including an image-only EPUB page, positions and pending operations. Record expected counts/digests and a chosen-download list. A separate clean recovery workspace and Files destination are prepared; no personal store is erased.

- [ ] Save a recovery backup to Files. Observe progress/cancel and the capture time; the unencrypted format asks for no password. Completion requires the destination/provider verification, not a file still inside the app container.
- [ ] Open/import into the separate recovery workspace offline. Compare text, editable originals, context and all pending/recoverable/bookmark metadata with this run's references.
- [ ] Edit/erase/Undo supported recovered ink while isolated. No network replay or account merge occurs from archive provenance alone.
- [ ] Sign into the matching server/account and reconcile identities/receipts/current lifecycle before uploading. A removed note or bookmark does not silently return, and a label conflict remains reviewable.
- [ ] Confirm the file contains no credentials or full downloaded books. Books are refetched from the recorded list; note context remains available independently.

**Pass:** A verified external file recovers the expected logical state and supported editable originals while protecting the live store/account. Corrupt/provider/unsupported-format and size faults have independent technical checks.

Trace: [Recovery export/import](../decisions/storage-recovery.md#unencrypted-ipad-reading-note-recovery), [bookmark recovery](../decisions/reader-controls.md#bookmark-sync-removal-and-recovery).

## Restore server notes before full book restoration

**Question:** Can a clean server restore make notes usable safely before all original books return?

**Setup:** Separate operator-controlled recovery target and a valid off-primary backup of this run's declared database/assets, source manifests and private owner state. Record prerequisites, cut/completion times, tool/schema versions and the conditioned storage-policy dataset. A prepared matching iPad/browser and stale-device state are independent of other cases.

- [ ] Restore and verify note-bearing database/app assets and ownership/reference/hash integrity before exposing state. Preserve server identity and rotate the recovery generation for the restored history.
- [ ] Open saved note context in the authenticated browser and iPad, recover original editable ink, and try erase/Undo after reconciliation.
- [ ] While full book files are still restoring, confirm Source restoring and retained-context access. Missing-file scans and destructive source management must not classify staged absence as deliberate removal.
- [ ] Reconnect the stale device with this run's pending operations. Reconciliation preserves uncertainty/alternatives and does not blindly replay old accepted or deleted work.
- [ ] Complete the full-file inventory before re-enabling affected operations; record the notes-first elapsed time against the accepted prerequisites/reference environment and report any unmet target.

**Pass:** Notes/context become genuinely usable and editable through verified, generation-aware recovery, with full-library restoration separate and no cross-owner disclosure or stale resurrection. Repository integrity alone is not an application restore verdict.

Trace: [Coordinated backup](../decisions/storage-recovery.md#coordinated-server-backup), [recovery order and targets](../decisions/storage-recovery.md#recovery-order-and-acceptance-targets).
