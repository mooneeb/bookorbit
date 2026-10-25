# Acceptance index: personal BookOrbit iPad reader

Complete review collection for [Agree the complete reading journey and build-readiness criteria](https://github.com/mooneeb/bookorbit/issues/13). The [specification](../specification.md) indexes authoritative decisions. Their confirmed product/architecture policies are requirements; final approval of this assembled handoff remains in the linked journey decision. No production run, installation, server operation or private-book access is authorized by publishing the collection.

## What this collection establishes

The handoff contains 53 named standalone walkthrough families plus the [technical fault and operational matrix](technical-and-operations.md). Each named variant is a separate fresh run, so 53 names are not a fixed count of executions. The first version must satisfy all required workflows/profiles and declared conditions before daily use. Optional or excluded content needs its specified partial/refusal behavior; it is not silently counted as supported.

Every human walkthrough contains one question, complete setup, attempted-action checkboxes and a specific pass result. No preceding walkthrough supplies setup or a pass. The future test interface must identify the current task and expected result, allow revisiting the tested views and keep actual human verdicts separate from checkboxes. No prototype is launched by this index.

Planning readiness means complete decisions, ownership, refusal/recovery semantics, acceptance and a usable implementation handoff. Daily-use acceptance additionally requires evidence from the implemented system. Required correctness/ownership/anchoring/recovery/accessibility failures block daily use; documented minor cosmetic issues may remain only under the already-accepted rule. Both formats require actual thirty-minute sessions with private representative library copies plus controlled fixtures.

## Evidence record for each run

Record the case name and variant, unique run identity, test date, required/partial/unsupported classification and fresh setup. Keep private source digests, known words/images/order, account aliases, initial note/bookmark/operation/revision identities and expected asset references available to the test operator. Record app/server/capability/schema/engine versions, intended device/OS, actual browser versions and relevant tool/environment versions.

Record attempted steps, actual observed outcome, human readability/usability/accessibility verdicts, and Pass/Fail/Blocked with the first failing step. Retain failed evidence when retrying. A blocked, unrun, partial or mocked-delivery case does not become a production pass. Record performance dataset/network/cache conditions, at least thirty ordinary repetitions, p50/p95/failures and combined-memory methodology where the storage policy requires them. Fault outcomes require exact correctness rather than averaged success.

Publish sanitized summaries and fixture identities. Keep personal books, handwriting, credentials, full paths and sensitive diagnostic payloads private. A document/reference/lint/typecheck result is planning verification, not device or production integration evidence.

## Coverage and policy owners

| Required area                                                                                                                     | Human walkthrough collection                     | Technical/operational coverage and owner                                                                                                                                                                                                            |
| --------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Offline EPUB/PDF reading, selected words, visible page ink, Pencil/Scribble and browser arrival                                   | Reader journeys                                  | [Local saving/assets/lifecycle](technical-and-operations.md#local-saving-assets-and-lifecycle-gates); [native stack](../decisions/native-stack.md), [notes](../decisions/note-model.md).                                                            |
| Contents/search/location/links, modes/themes/preferences, bookmarks and resource/page locations                                   | Controls/bookmarks and profiles                  | [Conflict/lifecycle gates](technical-and-operations.md#conflicts-deletion-bookmarks-and-reading-position); [controls](../decisions/reader-controls.md), [profiles](../decisions/publication-profiles.md).                                           |
| Exact source preservation, changed/removed/reimported files, cross-format placement and source-verified resume                    | Reader journeys, controls/bookmarks and profiles | [Identity/contract gates](technical-and-operations.md#identity-migration-and-contract-gates); [notes](../decisions/note-model.md), [reading position](../decisions/offline-sync.md#reading-position).                                               |
| Text/ink conflicts, Trash/restore, permanent deletion, dirty drafts and healthy automatic browser refresh                         | Reader journeys and library/lifecycle/recovery   | [Conflict/lifecycle](technical-and-operations.md#conflicts-deletion-bookmarks-and-reading-position) and [browser/authentication](technical-and-operations.md#browser-refresh-authentication-and-containment); [sync](../decisions/offline-sync.md). |
| Available-text VoiceOver, larger UI text, meaningful order, authored alternatives and honest image-only/partial content           | Reader journeys and profiles                     | [Packaging/device gates](technical-and-operations.md#packaging-device-continuity-and-scale); [profiles](../decisions/publication-profiles.md), [native input](../decisions/native-stack.md#pdf-workspace-and-native-input).                         |
| Full online book management, imports/all formats, ownership, long jobs and private merge/history preservation                     | Library/lifecycle/recovery                       | [Management/merge gates](technical-and-operations.md#book-management-and-merge-correctness); [management inventory](../decisions/native-stack.md#online-management-and-account-sessions), [merges](../decisions/book-merge.md).                     |
| Free signing, production updates, migration/old-client capability and dependency provenance                                       | Library/lifecycle/recovery                       | [Identity](technical-and-operations.md#identity-migration-and-contract-gates) and [packaging](technical-and-operations.md#packaging-device-continuity-and-scale); [native packaging](../decisions/native-stack.md#build-dependencies-and-updates).  |
| Explicit downloads, protected local work, unencrypted app recovery, coordinated restic backup, retention and notes-first recovery | Library/lifecycle/recovery                       | [Recovery/retention gates](technical-and-operations.md#appserver-recovery-and-retention); [storage/recovery](../decisions/storage-recovery.md).                                                                                                     |
| Large-library resource bounds, latency, memory and pressure/refusal behavior                                                      | All applicable collections                       | [Scale gates](technical-and-operations.md#packaging-device-continuity-and-scale) and exact [conditioned targets](../decisions/storage-recovery.md#recovery-order-and-acceptance-targets).                                                           |

## Verification sequence after implementation

Establish contract/migration/fault correctness on isolated fixtures before personal data. Then verify physical native input/rendering and the selected browsers, embedded online management and lifecycle/conflict flows, actual renewal/update continuity, app/server recovery and conditioned scale measurements. Finish sustained actual-library reading and the complete regression set after relevant fixes. Each walkthrough still creates its own setup; this ordering is a test strategy, not a dependency on another walkthrough's hidden state.

The implementation report must link all required outcomes or explicit unmet requirements, the human thirty-minute verdict in each format, actual environment/profile measurements and remaining cosmetic defects. Any newly exposed product/architecture decision returns to a precise decision ticket rather than being silently deferred. The planning map's completion does not mark this future report complete.

## Reader and Pencil journeys

12 standalone families in [reader and pencil journeys](reader-walkthroughs.md):

- [Read an EPUB note after an offline reading session](reader-walkthroughs.md#read-an-epub-note-after-an-offline-reading-session)
- [Read PDF page ink after an offline reading session](reader-walkthroughs.md#read-pdf-page-ink-after-an-offline-reading-session)
- [Reselect words without duplicating a note](reader-walkthroughs.md#reselect-words-without-duplicating-a-note)
- [Use the Apple Pencil tools and writing toggle](reader-walkthroughs.md#use-the-apple-pencil-tools-and-writing-toggle)
- [Enter typed text with Scribble while keeping ink](reader-walkthroughs.md#enter-typed-text-with-scribble-while-keeping-ink)
- [Keep an unsaved browser draft when ink arrives](reader-walkthroughs.md#keep-an-unsaved-browser-draft-when-ink-arrives)
- [Read with VoiceOver and larger interface text](reader-walkthroughs.md#read-with-voiceover-and-larger-interface-text)
- [Keep a note with its original source after replacement](reader-walkthroughs.md#keep-a-note-with-its-original-source-after-replacement)
- [Remove and reimport a book without losing its notes](reader-walkthroughs.md#remove-and-reimport-a-book-without-losing-its-notes)
- [Resume from a chosen competing reading position](reader-walkthroughs.md#resume-from-a-chosen-competing-reading-position)
- [Keep notes separate across a book's formats](reader-walkthroughs.md#keep-notes-separate-across-a-books-formats)
- [Read comfortably for thirty minutes in each format](reader-walkthroughs.md#read-comfortably-for-thirty-minutes-in-each-format)

## Everyday controls and bookmarks

13 standalone families in [everyday controls and bookmarks](reading-controls.md):

- [Switch EPUB modes without losing the reading place](reading-controls.md#switch-epub-modes-without-losing-the-reading-place)
- [Switch PDF modes with page and margin ink](reading-controls.md#switch-pdf-modes-with-page-and-margin-ink)
- [Navigate contents and page/location targets](reading-controls.md#navigate-contents-and-pagelocation-targets)
- [Search a downloaded book and return to reading](reading-controls.md#search-a-downloaded-book-and-return-to-reading)
- [Follow footnotes and return from links](reading-controls.md#follow-footnotes-and-return-from-links)
- [Keep local defaults and book overrides separate](reading-controls.md#keep-local-defaults-and-book-overrides-separate)
- [Restore publisher styling without altering notes](reading-controls.md#restore-publisher-styling-without-altering-notes)
- [Save an offline bookmark and find it in the browser](reading-controls.md#save-an-offline-bookmark-and-find-it-in-the-browser)
- [Remove a bookmark and Undo without affecting a note](reading-controls.md#remove-a-bookmark-and-undo-without-affecting-a-note)
- [Keep an unavailable bookmark accessible](reading-controls.md#keep-an-unavailable-bookmark-accessible)
- [Recover pending bookmark metadata](reading-controls.md#recover-pending-bookmark-metadata)
- [Review competing bookmark labels](reading-controls.md#review-competing-bookmark-labels)
- [Preserve an offline rename after bookmark removal](reading-controls.md#preserve-an-offline-rename-after-bookmark-removal)

## EPUB and PDF profiles

16 standalone families in [epub and pdf profiles](publication-profiles.md):

- [Read and annotate a reflowable EPUB](publication-profiles.md#read-and-annotate-a-reflowable-epub)
- [Read horizontal RTL and mixed-direction text](publication-profiles.md#read-horizontal-rtl-and-mixed-direction-text)
- [Keep a note on the correct fixed EPUB page](publication-profiles.md#keep-a-note-on-the-correct-fixed-epub-page)
- [Bookmark an image-only EPUB page](publication-profiles.md#bookmark-an-image-only-epub-page)
- [Read with bundled and obfuscated EPUB fonts](publication-profiles.md#read-with-bundled-and-obfuscated-epub-fonts)
- [Understand a font substitution or failure](publication-profiles.md#understand-a-font-substitution-or-failure)
- [Read and annotate a static table](publication-profiles.md#read-and-annotate-a-static-table)
- [Read an SVG diagram and its authored description](publication-profiles.md#read-an-svg-diagram-and-its-authored-description)
- [Read mathematical notation without changing its meaning](publication-profiles.md#read-mathematical-notation-without-changing-its-meaning)
- [Read a PDF with embedded and non-Latin text](publication-profiles.md#read-a-pdf-with-embedded-and-non-latin-text)
- [Read and write on scanned or mixed PDF pages](publication-profiles.md#read-and-write-on-scanned-or-mixed-pdf-pages)
- [Read existing PDF marks and comments without importing them](publication-profiles.md#read-existing-pdf-marks-and-comments-without-importing-them)
- [Follow available PDF text with VoiceOver](publication-profiles.md#follow-available-pdf-text-with-voiceover)
- [Read static fallback content with clear missing-feature information](publication-profiles.md#read-static-fallback-content-with-clear-missing-feature-information)
- [Understand unsupported layout and interactive profiles](publication-profiles.md#understand-unsupported-layout-and-interactive-profiles)
- [Keep a failed source-bound jump honest](publication-profiles.md#keep-a-failed-source-bound-jump-honest)

## Library, lifecycle and recovery

12 standalone families in [library, lifecycle and recovery](library-and-recovery.md):

- [Choose and remove an offline book](library-and-recovery.md#choose-and-remove-an-offline-book)
- [Review competing note text](library-and-recovery.md#review-competing-note-text)
- [Move a reading note to Trash and restore it](library-and-recovery.md#move-a-reading-note-to-trash-and-restore-it)
- [Preserve late edits after permanent note deletion](library-and-recovery.md#preserve-late-edits-after-permanent-note-deletion)
- [Import a book from iPad Files](library-and-recovery.md#import-a-book-from-ipad-files)
- [Edit book metadata without moving old notes](library-and-recovery.md#edit-book-metadata-without-moving-old-notes)
- [Organize books in collections](library-and-recovery.md#organize-books-in-collections)
- [Run and recover a bulk book-management action](library-and-recovery.md#run-and-recover-a-bulk-book-management-action)
- [Merge book copies and review personal conflicts privately](library-and-recovery.md#merge-book-copies-and-review-personal-conflicts-privately)
- [Renew and update the daily reader without losing work](library-and-recovery.md#renew-and-update-the-daily-reader-without-losing-work)
- [Export and open local reading-note recovery](library-and-recovery.md#export-and-open-local-reading-note-recovery)
- [Restore server notes before full book restoration](library-and-recovery.md#restore-server-notes-before-full-book-restoration)

## Review and evidence status

The seven policy models and three daily-use review choices are already confirmed. The current [final readiness audit](../research/final-handoff-readiness-facts.md) found no new unanswered core decision; it required this assembly and status reconciliation. Historical [earlier readiness findings](../research/complete-journey-readiness-facts.md) retain the conditions at their audited snapshot.

Completed preservation, signing and browser prototype reviews remain bounded fixture evidence. They are indexed in the [specification](../specification.md#evidence-boundary); none supplies a pass to these future runs. Final confirmation/status of this planning handoff remains in the linked complete-journey decision.
