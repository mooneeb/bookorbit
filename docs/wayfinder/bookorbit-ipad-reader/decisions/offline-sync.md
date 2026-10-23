# Offline note sync, conflicts and recovery

Specification prepared for shared review in [Choose offline sync, conflict, and deletion behavior](https://github.com/mooneeb/bookorbit/issues/9). All eight product choices are accepted; the linked issue records final shared-understanding confirmation and resolution status. This document describes the proposed behavior and contracts, not an implemented service.

## Fixed inputs and accepted choices

Use the [accepted note model](note-model.md) and its [confirmed resolution](https://github.com/mooneeb/bookorbit/issues/8#issuecomment-6364511603). One logical note may combine typed text and ink; an exact range or PDF page has one active entry. Notes use stable identities, verified source bindings, revision-matched previews and saved context. Book removal retains notes; source replacement never silently relocates them.

The [first sync round](https://github.com/mooneeb/bookorbit/issues/9#issuecomment-6364721591) establishes:

1. Competing edits to the same typed body remain versions of the same note for comparison and resolution. Do not silently choose a winner or create two ordinary notes.
2. If the browser moves a note to Trash while the iPad edits offline, keep it in Trash and preserve the incoming changes for review. Restoration is explicit.
3. Browser text edits and iPad handwriting edits combine automatically when they affect different parts. Competing edits to the same part require review.

The [second accepted round](https://github.com/mooneeb/bookorbit/issues/9#issuecomment-6368605587) adds:

4. Unsynced edits arriving after permanent deletion stay locally under Recovered changes. Do not restore or upload the deleted note; saving as a new note requires an explicit action.
5. If restoring a note would collide with an active note on the same exact range or PDF page, review both versions under one note before completing restoration. Preserve both contents and keep one active entry.
6. Include reading-position sync for each source file.
7. Automatically sync while the iPad app is open, with background attempts when iPadOS permits. Saved on iPad can remain local until reopening; Synced requires server acceptance.

The [final live choice](https://github.com/mooneeb/bookorbit/issues/9#issuecomment-6368790649) completes the product rules:

8. When devices independently reach different reading positions, offer both places at the next resume so the reader chooses. Keep an already-open page in place. Ordinary sequential reading resumes where the reader last stopped, including when rereading earlier pages.

The existing browser target remains: a visible, online reader/list updates without reload, targeting ten seconds after server acceptance of the note and all required assets; recheck on returning to the tab and preserve unsaved text. This is not a promise to finish iPad uploads while its app is closed.

## Scope, durable local state and operation identity

Scope every store, queue, cursor, transfer and credential to the authenticated account and verified server instance. Include a sync recovery generation in the handshake; an origin URL or the existing server UUID alone cannot identify a restored or cloned database history. Server ownership is always derived from authentication, never trusted from a submitted user ID.

Persist each finished local edit and its assets before reporting that it is saved on the iPad. Keep pending work in durable application data, outside disposable download caches. Queue an immutable operation with its own UUID, distinct from the stable note UUID. Record its exact payload digest, changed part, base revisions, lifecycle revision, required asset references and dependencies. Never reuse an operation ID for changed bytes or a different intention.

Each enrolled device incarnation also has a durable, monotonically increasing operation sequence. The UUID identifies the intention; the incarnation/sequence supports replay barriers after full receipts are compacted. Enforce both identities and their digest mapping. A restored or retired incarnation cannot silently restart at sequence one.

Local drafts may coalesce edits before transmission, without discarding the latest durable drawing. Once an operation may have reached the server, keep its identity and payload for outcome lookup/retry. A later edit gets a new operation ID. An older response must not replace newer local work or acknowledge unsent successors.

Serialize dependent edits to the same part. A successor names its predecessor and expected result, or is materialized from a durable draft after the predecessor is acknowledged. Do not mutate an uncertain operation to attach a newer edit. If its predecessor conflicts, retain the newer draft on that candidate branch for review rather than treating it as an independent overwrite of the canonical note.

Use atomic local file placement and a local metadata transaction to connect durable assets, the saved revision and pending work. On restart, reconcile incomplete saves and transfer tasks before transmission; keep the last complete revision and recoverable drafts. A process exit between any two steps must not make an incomplete drawing appear saved. A local-storage failure leaves the save visibly incomplete and must never produce Synced.

Normal in-place app/signing renewal preserves account association, note IDs, pending operation IDs and assets. A restored installation must reconcile its device registration before replaying work; do not assume a rolled-back local counter or credential proves a new operation. The tested signing/update preservation is recorded in [Validate free signing renewal and note preservation on the intended iPad](https://github.com/mooneeb/bookorbit/issues/20#issuecomment-6299949060). That test did not validate this network queue.

Offline creation may still publish after the source book was removed or replaced. Verify the retained, user-owned book association and original source descriptor from download/preparation, then retain the original binding and context. Do not require the removed live book row or silently bind the note to the replacement primary file. If ownership/provenance cannot be established, keep the work locally for review instead of discarding or relocating it.

## Reader-visible save states

| State                               | Meaning                                                                                                                                                                                |
| ----------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Saved on iPad                       | The current edit and required local assets are durable. This says nothing about server acceptance.                                                                                     |
| Waiting to sync / Syncing           | Current local work is pending or transferring. The previous accepted server revision can remain visible elsewhere.                                                                     |
| Synced                              | The server durably accepted the current note revision and all required originals, previews and context; the iPad durably recorded that result. Other devices may still be catching up. |
| Needs review                        | Competing versions or uncertain history require a choice. Server preservation of a candidate does not make it the accepted active revision.                                            |
| Recovered changes                   | Local edits refer to a permanently deleted note. They are outside ordinary sync until explicitly saved as new.                                                                         |
| Sign-in required / Upgrade required | Sync is paused; downloaded reading and local notes remain available.                                                                                                                   |

Statuses apply to the current local revision. An acknowledgment of an older revision cannot turn a newer pending edit into Synced. Background scheduling and an uploaded asset alone never satisfy that label.

## Revision and conflict rules

Maintain server-controlled revisions for independent parts: typed body, ink bundle, highlight appearance and approved source binding. The ink bundle includes the editable archive, exact matching preview and canvas/coordinate metadata. Treat those related ink fields as one atomic part. Keep lifecycle revision separate and check it for every mutation.

Ordinary updates name only the part they change and its observed base revision. Apply a change when that part and lifecycle preconditions still match, even if another part changed. This combines text and ink without whole-note replacement. Do not use wall-clock time, arrival order or the existing annotation device-delivery `version` as authority to overwrite a competing edit.

Create publishes the complete initial note atomically. Subsequent ordinary mutations change one part, so a body edit need not wait for an unrelated drawing upload. A compound conflict resolution declares every part and head it resolves; either those checks hold together or the comparison refreshes.

On a same-part conflict, retain the submitted candidate, its required assets and the current server version under one note. Return a durable conflict identity and current heads. Other notes and independent parts continue syncing. A conflict is a terminal result for that submitted operation, not an invitation to keep retrying it or a claim that it became the active version.

Resolution is a new explicit operation: choose a retained version or save an edited combination. Check the heads and lifecycle again when applying it; a change arriving during review produces a refreshed comparison rather than being lost. Browser text remains editable. Existing ink versions can be viewed for review, while drawing or combining strokes requires the iPad.

Independent offline creations for the same verified range/page key converge to one canonical note. Preserve submitted contents as reviewable versions when they compete. Preserve old IDs as resolvable aliases after an explicit collision resolution; do not create a second ordinary active entry or silently discard either submission. A restore collision follows the explicit review flow below.

## Asset transfer and atomic publication

Stage uploads as immutable, user-owned files with a declared role, byte length and SHA-256. Bind upload sessions to the account and proposed note identity. Use stable transfer request IDs, verified offsets and file-backed chunks. Expired staging can be recreated from local originals; it does not make the local note disposable or authorize a new note identity.

1. Persist the local original, matching preview, coordinate metadata and required saved context.
2. Upload missing assets with bounded concurrency and resumable offsets. Verify complete bytes before marking an asset ready.
3. Submit the immutable metadata operation with the complete asset manifest and revision/lifecycle preconditions.
4. Activate the new references, part revisions, operation result and change-feed event in one database transaction only after all referenced files are durably ready. Do not hold a database transaction while uploading bytes.
5. Persist the response locally before retiring the operation from the pending queue. If the response is lost, query/retry the same operation.

An upload HTTP 202, successful chunk or completed drawing upload is not note publication. A failed preview/context transfer leaves the previous valid server revision visible and the local edit pending. Never pair a new drawing with a stale preview while labelling it current. Unreferenced staging files may be collected under the later storage policy, while active, recoverable and unfinished-publication references remain protected.

Store immutable files under managed app-data storage; metadata transactions reference ready assets. A crash between file placement and metadata commit can leave an orphan file for later cleanup. A crash after metadata commit but before responding is recovered by the same operation receipt. Coordinated backup/restore must verify that referenced files actually exist; no SQL transaction makes an independent filesystem backup atomic.

Publication and garbage collection share reference/lease checks. Keep ready staging protected while its manifest is being committed; collection cannot remove it between readiness verification and reference activation. A missing or corrupt referenced file is a recovery error, never permission to show an unrelated preview as current.

## Retry results and durable acknowledgments

The server records each operation result with its payload digest and publication/conflict outcome. Replaying the same identity and bytes returns that result without duplicating the note, revision or event. Reusing the identity with different bytes is rejected. Operation result publication is atomic with the mutation it describes.

An old receipt reports its historical outcome, not a promise that the note is still active or unchanged. Reconcile the current lifecycle/revisions before updating the local active view. Receipts retain outcome identities and digests rather than deleted note bodies or asset contents; permanent deletion must not leave a second content archive inside retry records.

Keep full receipts until the client durably records the result. The client acknowledges a contiguous persisted operation sequence, with unresolved gaps excluded. After full receipt compaction, retain a per-incarnation replay floor: an operation at or below that floor cannot execute again. Return a reconciliation requirement if its full result is no longer available. Never skip an unacknowledged gap merely because a higher sequence completed. Retiring a device registration invalidates its incarnation and requires reconciliation before a new one can replay rebased work. Exact receipt budgets and device-retirement periods belong to the storage decision; safety cannot depend on a guessed timeout.

Allocate a sequence when materializing an immutable operation, not for a draft that might disappear. An abandoned operation requires a recorded cancellation/skip outcome after its execution state is known; the client cannot erase a sequence gap or reuse it. Authentication/envelope failures without a recorded result leave the operation pending for corrected transport or explicit recovery.

A missing expired receipt is not proof that an operation never ran. Device acknowledgment distinguishes durable metadata application, operation-result persistence and offline availability of large assets; receiving an HTTP response or listing a note is not the same as persisting all of its drawing files.

Retry transient failures with bounded exponential backoff and jitter, respecting Retry-After. Connectivity recovery, returning to the foreground and explicit Sync now can schedule another attempt. Do not create a tight retry loop for authentication, permissions, validation, conflicts or unsupported protocol versions. Pause only the affected note/transfer when safe; one bad operation must not stop unrelated notes.

## Change feed and long-offline recovery

Use an opaque account-scoped checkpoint over a committed, server-ordered change feed. Include edits, conflict state, Trash, restore, permanent-deletion markers, identity aliases, book-association changes and reading positions. A timestamp-only list cursor is not sufficient. All annotation/progress writers, including legacy adapters, must emit the same transactional changes through their owning feature boundaries.

Allocate feed order with committed mutations; do not advance a checkpoint past an invisible, not-yet-committed event merely because a higher allocated database ID exists. Fetch bounded pages and advance the local checkpoint only after a transaction persists the received state. Heavy drawings are fetched separately on demand or for downloaded books; metadata catch-up must not load every ink asset into memory.

Bootstrap uses a stable paged metadata snapshot and a recorded feed watermark. Keep the required snapshot/feed history under a bounded lease; finish baseline application and then catch up changes after its watermark. Do not keep a database transaction open across user network requests. Expired snapshot leases or checkpoints restart metadata reconciliation without clearing local drafts, pending operations or recovery versions.

A very long server outage has no automatic discard deadline for local notes. Free signing still limits fully disconnected app launch to the remaining profile lifetime; internet renewal can remain possible while BookOrbit itself is unreachable. Authentication and signing expiry are different clocks.

When history was compacted, rebuild the server mirror and compare pending bases against current heads. Apply only provably safe updates; retain uncertain changes for review. Do not interpret a missing generic response, HTTP 404 or missing snapshot row as permission to delete the local note. Permanent deletion requires an explicit owned deletion marker.

After a coordinated database/asset restore, change the sync recovery generation and require a full reconciliation. Preserve local work and previous receipts while comparing the restored server with remembered state. Do not replay uncertain old operations or overwrite newer local copies blindly. The restore procedure must rotate this generation: automatic detection of an unmanaged clone/rollback with identical credentials and identifiers is not promised. The later backup decision must include this requirement.

## Trash, permanent deletion and restoration

Trash and restore are lifecycle operations on the whole note, with explicit lifecycle preconditions. A stale content edit never silently restores a trashed note. Preserve its candidate content as a conflicting version; show review/Restore actions. Old deletion acknowledgments cannot delete a later restored version.

Permanent deletion needs a durable replay-prevention marker. Deleted IDs and canonical-key generations must not become ordinary unknown creations when delayed operations arrive. Retain the minimum markers or require a new synchronization generation and reconciliation before compacted history can be replayed. Actual content-retention and collection periods remain with [Set library scale, storage, backup, and export requirements](https://github.com/mooneeb/bookorbit/issues/12).

Before sending note assets after reconnection, check incoming lifecycle changes or the note's current lifecycle. If permanent deletion wins a race with an already-started upload, reject publication under that deleted identity and retire unreferenced staging under the collection policy. Never retain the late edits as a server-side note or conflict candidate after permanent deletion. A transfer already in flight cannot be recalled; its bytes must not become an active or recoverable server revision.

Persist all unsynced content, editable originals and necessary saved context locally under Recovered changes before retiring its queue entries. Stop further uploads for the deleted identity. Explicit Save as new note creates a fresh identity and current creation intent; it does not clear the deletion marker or restore the old identity. Recheck ownership, source binding and exact-range/page uniqueness. If another active note occupies that key, review the recovered content under that note instead of creating a duplicate.

When restoring an older note into an occupied key, keep the older note in Trash and the current note active until review completes. Show both contents; choose or combine them under the one active note. The resolution transaction checks both identities, current part heads, lifecycle revisions and key occupancy. Preserve the retired identity as an alias after the accepted combination, including all retained unresolved versions. If either note changed while being reviewed, refresh the comparison. Restoration never silently overwrites the newer note.

## Browser freshness and drafts

Use foreground, visibility-aware five-second head checks as the initial refresh mechanism, with an immediate check on focus/reconnection and after mutations. Authenticated push invalidation may reduce latency later, but is not the correctness mechanism. The existing SSE/socket infrastructure does not establish a note subscription.

If the head changed, refresh only affected visible list pages, the active source/page and open-note metadata with bounded queries. Fetch their current state independently of a large historical backlog; catch up the metadata checkpoint separately. Retain scroll/navigation and text selection. Do not reload the application or fetch the entire library to refresh a note.

A dirty editor retains its typed draft and base body revision. Incoming changes are shown as available updates rather than replacing the draft. An ink-only arrival can refresh its preview without overwriting the typed body. Saving the draft uses its observed part revision and may enter the same conflict review flow. Both lists and the reader address the same note, not copied bodies.

The accepted ten-second target is measured from server publication of the note and required assets, over a healthy connection while the browser is visible. Inaccessible server/assets show a pending or retry state. Browser draft survival through remote refresh is required; a complete offline browser editor is not added by this protocol.

## Authentication, server changes and lifecycle

Serialize native credential refresh and durably replace rotated credentials before other requests rely on them. Existing native token defaults are configurable; neither a default refresh-token duration nor a rotation grace window is a local-data retention policy. Reauthenticate to the same account without resetting downloads, note IDs or the queue.

On failed refresh, keep offline reading/editing available and mark sync as needing sign-in. Authentication, permission and capability failures do not acknowledge or discard operations. Do not retry a native request with conflicting cookie/body refresh credentials. Never treat an access-masking 404 as a deletion.

Signing out or changing server/account freezes the old scoped queue rather than uploading it into the new scope. A new handshake verifies server instance, authenticated account, recovery generation and supported capabilities before upload. Reconnecting the same scope resumes its work; moving work to another scope requires a separate explicit migration, not automatic ID reuse.

Keep cached notes and downloads isolated between accounts. A newly signed-in account cannot browse or attach the old account's queue/assets. Reauthentication to the original scope recovers its retained work; credentials are stored in the platform's protected credential store rather than the operation payload.

Unsupported server/client capabilities pause affected sync and show an upgrade instruction while preserving local reading and edits. An app update must not silently downgrade stored ink into text or images. Device-registration loss is a recovery event, not a reason to discard pending work.

Apple allows conditional background transfers and system-scheduled work; it does not provide a fixed refresh deadline. File-backed background URLSession transfers can reconnect after normal system termination. A force quit cancels those transfers and prevents automatic relaunch. BGContinuedProcessingTaskRequest is available on iPadOS 26 but begins from a person's foreground action, not an unattended reconnect trigger. These APIs remain candidates for the later native stack decision, not measured native sync behavior.

Automatic foreground sync is required after durable saves, on reopening, on regained connectivity and on an explicit Sync now request. Background work is best effort. Closing the app before publication can leave the edit only on the iPad until reopening. Keep that distinction visible through the save states above; do not promise a fixed background completion time.

## Reading position

Reading-position sync is included for the iPad and selected browsers. Scope it to the account, source file and verified source version. Keep a format-specific logical locator independent of the current screen layout: EPUB content location and PDF page location, plus a percentage for display/fallback within that verified version. Do not silently transfer a position to another format, replacement file or transformed delivery without a verified mapping.

The existing file-progress route is an integration seam, not a safe offline replay contract. Extend the owning progress service with stable operation identity, device sequence, base revision and an explicit accepted/conflicting result, and include its committed changes in the reader-sync feed. Persist/coalesce unsent iPad positions durably; serialize uncertain saves just like other operations. A failed HTTP request must not be mistaken for an accepted position.

Sequential progress may move backwards when rereading. Neither highest percentage nor an untrusted device clock proves the intended resume position. A fetched position is not a new reading action: initial restore, incoming updates and opening a resume chooser must not write it back as fresh progress.

If the submitted base matches the accepted position, advance the shared resume revision to that new stopping place. Independent saves based on an older revision preserve competing positions rather than silently selecting the latest arrival or furthest percentage. Identical verified logical locations may converge without a choice. Keep the latest stopping point on each unresolved branch; later reading on that branch must not erase the other alternatives.

Capture the progress base when continuing from an observed/chosen position. A remote head refresh must not silently rebase an already-open reading branch or its unsynced stopping point. Successors to the device's own acknowledged saves can use those accepted revisions; independent remote reading still produces the resume choice.

Offer the alternatives at the next resume, with enough source/location and device information to recognize each. Do not jump an already-open page when a remote position arrives. Selecting a place is an explicit resolution operation checked against the current alternatives and revision. If another place changed during that choice, refresh the alternatives rather than discarding it. Applying the chosen location is navigation, not an extra progress event; subsequent reading creates a new save based on the accepted result. Choosing an earlier place is valid.

Progress ownership remains with the book/reading-progress feature, through its public service boundary. Do not move its database queries into the annotation module. Apply Kobo status, book read-status and any existing narration/sibling progress side effects only after a position is accepted, with idempotent transactional intent or a durable delivery queue. Replaying an already-accepted operation must not repeat a status transition, clear newer reset state or create a fresh reading event. Unresolved candidates have no such effects.

Keep existing Kobo/KOReader/narration integrations behind explicit adapters. Their timestamps, percentage guards and sibling conversion rules cannot establish causal precedence over a protected source-bound iPad/browser position. An adapter without a valid base/source mapping must not silently overwrite it; retain an incoming candidate for review or return an unsupported-write response. This decision does not add automatic cross-format resume or change the accepted note-placement rule.

## Proposed contract boundaries and bounds

Implement an explicit capability-gated reader-sync surface. The annotation feature owns notes, assets and their lifecycle; the book/reading-progress feature owns progress. Coordinate through exported services, with one consistent publication/checkpoint contract. These surfaces are proposed, not existing routes:

| Surface                                  | Required meaning                                                                                                                      |
| ---------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| Session/handshake                        | Authenticate the account, enroll/recover device identity, verify scope/generation, negotiate capabilities and bounds.                 |
| Paged snapshot and changes               | Supply a stable baseline/watermark and committed incremental lifecycle/content metadata, including deletions.                         |
| Asset staging/status/chunks/finalization | Resume verified user-owned bytes without publishing an incomplete note.                                                               |
| Mutations and operation lookup           | Apply immutable operations with part/lifecycle preconditions, durable retry identity and per-operation outcomes.                      |
| Conflict resolution                      | Compare current heads and explicitly select/save a resolution without losing a newer arrival.                                         |
| Reading-position update/resolution       | Apply a source-bound locator using retry identity and revision checks, preserving competing positions for the accepted resume policy. |
| Durable acknowledgment                   | Record local persistence and accepted results separately from asset availability.                                                     |

Use shared types and declared DTOs for every field. Existing strict validators reject arbitrary additions, and the legacy annotation version is not a complete precondition contract. Keep legacy IDs and supported projections, prevent unsupported clients from replacing unknown ink, and require ownership plus explicit permissions on sensitive/destructive routes. An unversioned legacy write cannot establish safe conflict preconditions: require a valid recorded base for protected notes, or return a capability/upgrade response rather than guessing. A permitted text-only write must still preserve the ink and other untouched parts.

Initial negotiated bounds: at most 50 metadata operations per batch, 100 change/snapshot items per page, two concurrent asset uploads and five-second visible-browser checks. Stream uploads in bounded chunks; exact byte quotas, preview dimensions, staging leases, history budgets and backup/export limits remain with the storage/scale decision. Process operation results independently; do not roll back all valid notes because another operation needs review.

## Required validation scenarios

These are future protocol acceptance cases, not tests reported as passing. Carry them into [Agree the complete reading journey and build-readiness criteria](https://github.com/mooneeb/bookorbit/issues/13). Each fixture must identify its account, source version, note/operation identities, expected revisions and saved asset digests.

| Scenario                                                                               | Required result                                                                                                                                     |
| -------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| Response lost after publication; same operation retried                                | One mutation/event, the same recorded outcome, no duplicate note or repeated side effects.                                                          |
| App exits after local save, during a chunk, after upload or before receipt persistence | Complete local work and retry identity survive; resume verified bytes or retrieve the prior result.                                                 |
| Ink arrives but preview/context fails, or collection races publication                 | Previous complete server revision remains current; required assets stay protected; incomplete content never reports Synced.                         |
| Same body edited on two devices; text and ink edited separately                        | Same-part alternatives enter review; independent parts combine without overwriting each other.                                                      |
| Browser refresh while typed text is unsaved                                            | Draft and observed revision survive; saving detects competition rather than overwriting it.                                                         |
| Trash, permanent deletion and restoration race offline work                            | Trash retains candidates; permanent deletion keeps late edits only in local recovery; occupied-key restoration reviews both under one active entry. |
| Old acknowledgment arrives after a newer edit or restore                               | It cannot retire newer work, change its status to Synced or delete the restored note.                                                               |
| Authentication expires or refresh response is lost; account/server changes             | Local notes survive; sign-in/recovery pauses sync; credentials and operations never cross scopes.                                                   |
| Device returns after feed/receipt compaction or a coordinated server restore           | No stale replay or silent local deletion; rebuild metadata, compare known heads and preserve uncertain work for review.                             |
| Source book is removed/replaced before an offline note arrives                         | Verify ownership and original source; preserve the saved context and original binding without attaching to the replacement.                         |
| Visible browser receives an accepted note during a large backlog                       | Current reader and affected list pages refresh within the healthy-connection target without reloading or fetching the full library.                 |
| Reading position retries, moves backwards or arrives concurrently                      | No repeated side effects or clock-based overwrite; apply the accepted resume-conflict policy within the verified source version.                    |
| App is suspended or force quit before acceptance, then reopened                        | Show the honest local/pending state; foreground sync resumes without relying on a background deadline.                                              |

The stack decision must select local persistence, transfer and serialization mechanisms that can meet these invariants. The storage decision must set asset/receipt/feed budgets, snapshot leases, device retirement and coordinated backup/restore procedures without weakening them. No production schema/API/native code is changed by this document.

## Evidence and remaining validation

Source audit baseline: `8fa3760b66885b3219a775cdd41e3d25a852b191`. Existing production paths provide useful pieces, not this complete protocol:

- [Annotation writes](https://github.com/mooneeb/bookorbit/blob/8fa3760b66885b3219a775cdd41e3d25a852b191/server/src/modules/annotation/annotation.repository.ts#L323): no generic create retry key or edit base revision; existing version/ack state targets device exchange.
- [Native authentication](https://github.com/mooneeb/bookorbit/blob/8fa3760b66885b3219a775cdd41e3d25a852b191/server/src/modules/auth/auth.service.ts#L352) and [rotation](https://github.com/mooneeb/bookorbit/blob/8fa3760b66885b3219a775cdd41e3d25a852b191/server/src/modules/auth/auth-session.repository.ts#L68): native transport and rotating refresh tokens exist; a production iPad queue does not.
- [Server identity](https://github.com/mooneeb/bookorbit/blob/8fa3760b66885b3219a775cdd41e3d25a852b191/server/src/modules/server-identity/server-identity.repository.ts#L12): its persisted UUID can survive a clone/restore and cannot identify a changed history by itself.
- [Upload sessions](https://github.com/mooneeb/bookorbit/blob/8fa3760b66885b3219a775cdd41e3d25a852b191/server/src/modules/upload/upload-session.service.ts#L97): resumable staging and idempotency exist for book import, not authoritative note assets.
- [Notebook paging](https://github.com/mooneeb/bookorbit/blob/8fa3760b66885b3219a775cdd41e3d25a852b191/server/src/modules/notebook/notebook.service.ts#L75): bounded current-state lists are not a deletion/change feed.
- [Browser editor](https://github.com/mooneeb/bookorbit/blob/8fa3760b66885b3219a775cdd41e3d25a852b191/client/src/features/annotations/components/shared/AnnotationEntryDetail.vue#L34): an in-memory draft exists without this revision-aware reconciliation.
- [File progress schema](https://github.com/mooneeb/bookorbit/blob/8fa3760b66885b3219a775cdd41e3d25a852b191/server/src/db/schema/reader.ts#L207), [progress DTO](https://github.com/mooneeb/bookorbit/blob/8fa3760b66885b3219a775cdd41e3d25a852b191/server/src/modules/book/dto/save-progress.dto.ts#L7) and [browser upsert](https://github.com/mooneeb/bookorbit/blob/8fa3760b66885b3219a775cdd41e3d25a852b191/server/src/modules/book/book.repository.ts#L2453): user/file scope exists, but no verified source revision, edit precondition or operation receipt; delayed text saves can overwrite current progress.
- [Browser progress client](https://github.com/mooneeb/bookorbit/blob/8fa3760b66885b3219a775cdd41e3d25a852b191/client/src/features/reader/shared/composables/useReaderProgress.ts#L106) and [save side effects](https://github.com/mooneeb/bookorbit/blob/8fa3760b66885b3219a775cdd41e3d25a852b191/server/src/modules/book/book.service.ts#L2390): debounced saves do not provide durable offline acknowledgment; accepted progress can affect Kobo, read status and sibling files.
- [Apple background transfers](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background), [background session conditions](<https://developer.apple.com/documentation/foundation/urlsessionconfiguration/background(withidentifier:)>), [refresh scheduling](https://developer.apple.com/documentation/backgroundtasks/bgtaskrequest/earliestbegindate) and [continued processing](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtaskrequest): primary lifecycle constraints, not physical-device transfer results.

All eight product choices are recorded; final shared-understanding confirmation of this complete proposal is required before resolving the planning decision. Native network/auth fault tests, crash recovery, interrupted publication, browser convergence and coordinated restore must become explicit acceptance cases in [Agree the complete reading journey and build-readiness criteria](https://github.com/mooneeb/bookorbit/issues/13); the earlier browser proof used fixture transfer and does not pass them. These future checks do not prevent settling the design, but must pass before claiming its production implementation works.
