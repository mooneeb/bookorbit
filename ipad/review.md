# Interim review for issue #2

Comparison point: `8fecae94e65204618fc4db846da19c4e0007e4aa`, the commit at task start. Two independent agents reviewed `4d017f73` against that point. Follow-up independent reviews inspected the session fixes and final simulator-execution delta after `fd834c3f`. Both axes found no new material issue in the recovery delta and verified the final HTTP/native results and evidence. The complete [issue #2](https://github.com/mooneeb/bookorbit/issues/2) remains in progress.

## Standards

No hard documented-standard violations remain in the reviewed source.

The collection follow-up review found a logging breach and a possible orchestration smell in the native harness. `runNativeTests()` now owns the workflow and emits the required start/end/fail events with duration and canonical log sanitization. The independent follow-up verified both corrections and found no new material correctness, ownership or scale issue in the collection delta.

- Possible Duplicated Code: expired-session recovery, logout and password change each removed credentials and cleared session state, with differing cancellation behavior. The shared `invalidateSession()` now owns those operations. Resolved.
- Separate correctness finding: concurrent refresh waiters returned decoded credentials before generation validation and Keychain persistence. The shared task now validates and persists before returning to any waiter; task identity protects newer refreshes from old cleanup. Resolved.
- Follow-up correctness finding: an old resume request could invalidate newer credentials, or foreground validation could restore an account after sign-out/reconnection. Resume now checks its captured session generation. Foreground validation checks API and operation identity and serializes its own requests. The follow-up review found no remaining material race in these changes. Resolved.

## Spec

- P1, open: "Dashboard shelves, large-library grid/list/table search/filter/sort, authors/series ... collections, smart scopes, saved views, and sharing rules" and metadata/cover workflows are partial. Native browsing has list/grid, search, three sorts, book/file details, collection creation and membership. Collections use bounded owner/public pages with viewer-scoped book counts. Smart scopes, saved views, sharing controls and the remaining management breadth are still pending.
- P1, open: "Baseline ebook/PDF/comic/audio reading ... are usable online" is partial. Production PDF reading now uses genuine native page curl and acknowledged cross-client progress/resume. Integrated EPUB/comic/audio reading, the remaining reader controls, preferences, bookmarks, background audio, bridging, Read Along and TTS remain to implement.
- P1, open: "Every acceptance criterion and every numbered human QA step maps to named automated tests" and human-reviewed visual comparisons are incomplete. Both native entry journeys and the library accessibility audit now pass; screenshots remain captures, and visual regression baselines, the representative matrix, controlled failure coverage and measured budgets remain outstanding. Bounded HTTP payloads do not prove native rendering or memory performance.
- P1, open: "Native installation ... and a real reachable home-server connection" and "A human completes the entire ticket walkthrough" still require AltStore/device/network evidence and the integrated human journey. Localhost supports the automated fixture.
- P2, resolved: "secure credentials" and "local persistence ... together" were undermined by concurrent refresh success before persistence. The shared completion and invalidation changes above address this finding; actual native local/OIDC relaunch and session-revocation/recovery journeys now pass.

No material scope creep was found. The missing native reading and complete end-to-end journey block issue completion.

The collection review additionally identified unhelpful duplicate-name recovery. The native 409 response now explains that another name is required. The UI test asserts that feedback, corrects the name, creates the second collection and continues through membership/relaunch. The independent Spec follow-up verified the correction and opened the actual conflict screenshot from `run-82002-1791226552724`. No new collection finding remains; the four full-issue P1 gaps above remain open.

Both axes identified a correctness issue in the intermediate metadata-lock contract: resolving a utility alias generated a separate nested metadata model without explicit-null encoding. The generator now follows the declared exported request reference and reuses `BookMetadataTextUpdatePayload`. Both independent follow-ups verified the source correction. Further independent reviews found no new material issue in native selection, switch interaction, permission visibility or bounded collection paging. The combined `run-5222-1791229022639` subsequently passed all 6 HTTP tests, 7 native journeys and 2 cross-client browser tests, resolving the earlier library accessibility, text replacement and toggle execution failures. The four full-issue P1 gaps still block completion.

The additional dismissal check exposed a stale native library result after editing a title. The library now refreshes its current query/page on detail dismissal. The expanded native metadata journey passed in `run-14688-1791229775711`, including zero results for the previous search and reopening the corrected title after relaunch.

Both independent axes found no new material source finding in the dismissal refresh and full-screen editor corrections. The focused permitted-editor journey subsequently passed in `run-21706-1791230375910`, including both complete accessibility audits. Earlier editor font, contrast and visible-background audit failures remain recorded with their corrections in [verification.md](verification.md).

Standards: 0 open material findings in the reviewed delta. Spec: 4 open P1 findings, covering management breadth, native reading, complete automated/visual/performance evidence, and physical/integrated human evidence.

2026-10-06 follow-up: both approved-base review agents examined the native bounded text input, visible geometry assertions and response-synchronized browser checks. Standards: zero new material findings. Spec: zero new material findings in this delta, with the four whole-issue P1 gaps unchanged. The default-size 140/180-point geometry limits do not establish larger Dynamic Type coverage. Source review does not override the pending native input/focus test or the failed combined browser gate. Latest runtime correction awaits verification; no complete-issue approval is claimed.

2026-10-06 subsequent metadata review: both approved-base agents reported zero new material findings after the native input retained UIKit accessibility traits and the editor used a scrolling container with a visible keyboard-dismissal control. The focused Unicode journey and its full keyboard-dismissed accessibility audit passed in `run-71130-1791272695601`. The system keyboard's empty prediction-cell audit failures remain documented. The next full editing run, `run-73960-1791273009394`, passed seven of eight native journeys and failed before metadata editing at entry navigation; browser tests did not execute. Source review does not establish a passing combined gate.

## Isolated PDF proof follow-up

### Standards

The approved-base Standards agent found no new material documented-standard violations or unnecessary abstractions in the canonical progress contracts, server DTO/controller mapping, authenticated bounded file-delivery buffer or bounded page-controller cache. A loading/error dismissal defect was corrected by keeping Close reader available outside the loaded-document branch.

The agent also identified a correctness P2: `PDFProofModel.close()` cancels an outstanding progress save, so closing while its GET or POST is pending can discard the latest completed page turn. The acknowledged-save journey excludes this trigger. Flush or retain pending progress before dismissal while preserving cancellation during initial loading. A controlled HTTP-delay journey is prepared; the correction is not yet verified.

### Spec

The approved-base Spec agent identified the same P2 against the issue's same-passage resume and interrupted-write requirements. The current test waits for Position saved before leaving. No additional material proof defect or scope creep was found; PDFKit follows ADR-0004's native PDF requirement, and delivery is bounded, authenticated, size/MIME checked and incomplete-file cleaned.

The four P1 full-issue gaps remain: management breadth, production reader breadth, complete automated/visual/performance evidence, and physical/integrated human acceptance. The agents reviewed before the final first-page title correction. Runtime `run-82028-1791273992424` subsequently passed the isolated PDF curl, rotation, acknowledged-save relaunch and both complete accessibility audits. This does not resolve the pending-save P2 or the four whole-issue P1 findings.

Standards: zero new material Standards findings and one remaining correctness P2. Spec: one new proof P2 and four existing full-issue P1 findings.

The complete editing gate subsequently passed in `run-83761-1791274138209`: six HTTP tests, all eight native journeys and both browser handoffs. All 24 PNGs were opened and inspected. The pending-position proof reproduced the P2 in `run-90075-1791274850402`; its correction awaits the controlled-delay and browser gate. The four full-issue P1 gaps remain.

## PDF close and browser handoff follow-up

### Standards

The independent follow-up found zero new hard Standards violations or heuristic smells. The immediate-close cancellation P2 is resolved. A new correctness P2 remains: after a persistent save failure the only Close action retries the save and prevents dismissal. Provide a distinct confirmed-discard path or durable pending storage.

### Spec

The independent follow-up found zero new material Spec defects or scope creep and verified the source correction for pending-save close. Failed-save retry and force termination before acknowledgement remain unproved. The four full-issue P1 gaps remain unchanged. Runtime `run-91807-1791275047940` subsequently passed both native PDF cases and the actual pixel-verified browser passage handoff; all 12 PNGs were opened. This resolves the immediate-close runtime gate but not the persistent-failure P2.

Standards: zero hard/smell findings and one correctness P2. Spec: four whole-issue P1 gaps, with fault/termination coverage still partial.

2026-10-06 persistent-failure follow-up: both independent axes found zero new material PDF findings. Standards verified that explicit Retry and confirmed discard resolve the exit trap. Spec verified the passing public-boundary journey while keeping interrupted POST and termination-before-acknowledgement coverage partial. All five native PNGs from `run-96598-1791275377194` were opened. Standards: zero open material PDF findings. Spec: the four full-issue P1 gaps remain.

## EPUB proof review

### Standards

The independent approved-base review found no new hard documented-standard violation. The asset handler restricts bundled files to its reader root and unique local host; native book delivery checks frame identity, authorized paths, active requests, resource limits and session identity. One correctness P2: the rotation assertion read the previously displayed selection while the new asynchronous resolution was pending. The model now clears that output and the UI test awaits fresh text and checks the rotated anchor; runtime verification remains pending.

A judgment call remains: possible Duplicated Code in the authenticated byte-request/refresh/cancellation sequence shared by deliveredFile and epubResource. The resource and complete-file limits differ. A private transport helper may improve consistency after the current runtime slice is green; this is not a hard violation.

### Spec

The independent approved-base review identified the same stale-result P2 against the required same logical passage after layout changes. The initial literal UTF-16 range expectation correctly and independently covers an astral emoji and combining mark. No other new material defect or scope creep was found in this narrow source delta. Local WebKit layout follows ADR-0004; compilation does not establish renderer execution or satisfy the pre-integration proof requirement.

The four existing whole-issue P1 gaps remain: management/metadata/cover breadth, production reader breadth, complete automated visual/configuration/performance coverage, and physical/integrated acceptance. Module loading, hostile-publication security, actual CFI execution and the corrected rotation assertion remain unproved. Standards: zero hard findings, one pending correctness P2 and one heuristic duplication finding. Spec: one pending proof P2 and four existing whole-issue P1 findings.

Both independent follow-ups verified that clearing the old result and awaiting the new one resolves the stale-result P2. `run-14777-1791276830507` subsequently passed actual loading, the literal UTF-16 anchor and fresh rotated resolution. Neither axis treats returned range text as proof of a painted selection. Standards: zero new material findings, with transport duplication still a heuristic cleanup opportunity. Spec: the four whole-issue P1 gaps remain. The next unfiltered accessibility run failed on the paragraph's hit region; that runtime finding remains open.

2026-10-06 selected-passage and native gesture follow-up: both independent agents found no new material source defect after the real Selection text and same-range CSS Custom Highlight change. `run-27795-1791277865730` passed the portrait/landscape literal text, exact anchor and actual selected-passage pixel assertions. The native opt-out covers all eight script pointer/touch registrations and pending callbacks; web defaults remain enabled. It removes Foliate's native script swipe/cross-page pointer selection behavior, whose native equivalent is still required. The unchanged full audit remained red in `run-31686-1791278118246`.

2026-10-06 plain-chapter diagnostic follow-up: Standards found no new material violation or correctness issue, with optional duplication cleanup in two JavaScript operations. Spec found no new material mismatch or scope creep. The diagnostic bypasses paginator layout/interaction while still using Foliate's publication loader and the native authenticated delivery path, so it does not isolate every publication transformation or confirm a platform false positive. `run-36630-1791278645783` reached the ordinary delivered text and failed the same full hit-region audit. Both agents retain the original accessibility gate and all four whole-issue P1 gaps. Standards: zero new material findings. Spec: four existing P1 gaps, with the reader accessibility finding unresolved.

2026-10-06 EPUB acknowledged-save follow-up:

### Standards

No new hard documented-standard violation. One correctness P2 remains: saving a new chapter's CFI copies obsolete Kobo and KOReader text-location fields. Kobo delivery skips CFI conversion when an existing Kobo location is present, so the old chapter could be resumed. Companion text locations must be derived from the new passage or cleared; independent narration fields must survive. The reset-before-open journey does not cover this. A public HTTP/native UI regression with an old text location and separate narration tuple is under verification. Possible duplicated progress-payload assembly remains a judgment call.

### Spec

No new material mismatch, scope creep or incorrect implementation in the narrow acknowledged-save/resume delta. The genuine native test supports acknowledged save, immediate reopen and full relaunch. Shared-browser inspection subsequently showed the saved second chapter, with the screenshot/OCR limitation recorded. Interrupted saves, failure/retry, termination before acknowledgement and concurrent narration updates remain unproved. The unchanged full EPUB accessibility audits and the four whole-issue P1 gaps remain open.

Standards: zero new hard violations and one open correctness P2. Spec: four whole-issue P1 gaps, with fault, accessibility and integration coverage partial.

2026-10-06 obsolete-location follow-up: both independent source reviews accept omitting page/Kobo/KOReader locations when saving a new text CFI while preserving the independent narration tuple. The genuine RED run retained the old chapter. Native `run-53767-1791280431681` and combined native/web `run-57094-1791280810275` subsequently passed that regression. The latter also passed exact OCR assertions for the actual second chapter after web Read and reload; all six PNGs were opened. The stale companion-location P2 is resolved. GET-then-POST narration preservation is still a snapshot, with concurrent narration updates and interrupted writes unproved. Standards: zero open material findings in this correction; transport duplication remains a judgment call. Spec: the four whole-issue P1 gaps and unchanged full reader accessibility failures remain open.

## Bibliographic metadata review

### Standards

Both public date and year inputs must use the canonical publishedYear lock. The initial new date toggle adds an invalid publishedDate lock, so saving it is rejected with 400. This is a hard API-contract breach and correctness P2. A native lock/save/reopen regression is being executed before correction.

The new list inputs lack per-name validation. An author longer than 500 code points reaches an existing varchar limit and fails. Genre/tag normalization uses a 200-UTF-16-unit substring, which loses valid Unicode names before the 200-character PostgreSQL limit. This is a correctness P2 in the exposed editing workflow; the underlying server behavior predates this slice. Add useful native feedback and public-boundary coverage for valid Unicode persistence and excessive names.

The review otherwise accepts changed-field omission, explicit scalar clears, empty-array list clears, preserved commas, typed numeric ranges and date/year coupling. Generating a canonical lock enum is a possible prevention improvement, not a required abstraction for this correction. Runtime remains pending.

### Spec

The invalid publication lock conflicts with the required persistent metadata locks. Unbounded relation inputs and Unicode truncation conflict with metadata persistence and useful validation feedback. The same two P2 corrections need public native/API evidence. No new scope creep was found. Basic bibliographic editing does not establish matching/comparison/custom-field/cover/file-write parity. The four whole-issue P1 gaps and required full EPUB accessibility failures remain open.

Standards: one hard breach and two correctness P2 findings. Spec: two slice P2 findings and four whole-issue P1 gaps.

### Publication lock and clearing follow-up

Standards: the independent follow-up finds no new hard breach or material correctness issue. Both inputs use publishedYear and one toggle describes the shared lock. Clear actions respect locks and preserve date/year coupling. Footer errors/progress remain visible. The test uses actual Clear controls with exact empty/replacement assertions and bounded unobscured-control scrolling. The relation-name P2 remains open; runtime and new-form accessibility are pending.

Spec: the independent follow-up finds no new material defect or scope creep. The source correction addresses persistent metadata locks, while Clear controls and visible save feedback serve the required clearing/failure workflows. Saving empty scalar/list results is still a separate unproved behavior. Basic editing remains partial parity. The relation-name P2, four whole-issue P1 gaps and full EPUB accessibility failures remain open. Source review is not runtime GREEN or issue completion.

### Relation-name follow-up

Standards: independent review finds no new hard violation or material correctness defect. Native and DTO bounds count the same code points on payload names, and server normalization preserves supplementary Unicode. A scale concern about allocating the entire imported name was addressed with a loop stopping at 200 code points; the existing 64 metadata regressions passed after that refinement.

Spec: independent review finds no new material defect or scope creep. Public HTTP evidence resolves valid Unicode persistence and rejection without mutation through both routes. Native invalid/exact-limit checks execute, but the new form audit found three contrast failures in `run-85379-1791284301463`; corrected execution remains required. Saving empty values, broader metadata/cover parity, the four whole-issue P1 gaps and full EPUB accessibility remain open.

## Metadata runtime follow-up

The parallel Standards and Spec follow-ups found no new material defect in the relation-name and clear-persistence corrections. The bounded normalization loop retains at most 200 code points. Native invalid/exact-limit name validation and its unfiltered audit passed in `run-89522-1791284774741`. The clear-persistence tracer's first run failed the date placeholder audit; removing duplicate placeholders retained visible headings and accessibility labels, then the unchanged audit and Save/public-record/relaunch assertions passed in `run-93646-1791285241948`. The same database's maintained web/reload check passed in `run-93646-1791285241948-web`. Every actual PNG from those checks was opened and inspected.

The prior four P1 issue-wide gaps remain: management/metadata/cover breadth, production reader breadth, the visual/configuration/performance matrix, and integrated physical/human acceptance. The full EPUB accessibility gate remains failed/open. The cover slice is in progress and was excluded from this narrow follow-up's new-defect findings.

## Cover source review

### Standards

The independent follow-up found a correctness P2 in image delivery: initial or repeated image loads can overlap Save/Revert, and their completions only check whether the editor is closed. A delayed old-version response can therefore replace the fresh saved preview. A public native UI/delayed HTTP regression is required before correction; load completions need operation and version protection. A second P2 concerns concurrent locks: after a 409, Reload cover refreshes images without the book's lock snapshot, leaving forbidden editing enabled. Recovery must refresh authoritative metadata while retaining the staged selection. The final follow-up found no new hard standards violation. Duplicated authenticated streaming/refresh logic across file and cover delivery remains a design judgment to assess during refactoring.

### Spec

Two new P2 findings are open. Native preparation silently downsizes selections to 2,048 pixels and converts them to JPEG, losing large-image resolution and PNG transparency compared with the web's original-file upload. Original upload artifacts must be preserved separately from bounded display previews. The same stale-load race can show old artwork beside the new public source/version and success feedback. Existing 640-by-960 and revert proofs cannot detect these defects.

The original four whole-issue P1 gaps and full EPUB accessibility failures remain open. Current evidence correctly limits the web proof to the native-reverted originals; custom-image web handoff, retry and concurrent-lock behavior remain pending. No new scope creep was found. Source review did not execute runtime checks.

## Cover corrections follow-up

### Standards

The independent approved-base follow-up found no new material documented-standard breach or correctness defect in the focused cover delta. Original upload bytes and detected MIME are preserved, while the display preview alone is bounded. Image success and failure completions check operation identity, cover version and closed state. Save, Revert, Reload and close invalidate superseded loads. A real 409 refreshes authoritative book information; failed refresh retains a state that blocks mutations until successful reload, preserving pending selections. The fault proxy holds a genuine upstream image body, and tests verify visible pixels and authenticated delivered artifacts. The previous stale-image and concurrent-lock P2 findings are resolved in source.

The existing possible Duplicated Code finding in authenticated byte delivery remains optional cleanup: cover delivery, deliveredFile and epubResource repeat refresh/validation/cancellation logic with different resource limits. It is a heuristic rather than a documented-standard breach or new blocker.

### Spec

The independent follow-up found no new material Spec defect or scope creep. The original-resolution/transparency, stale-preview and concurrent-lock P2 findings are corrected in source and supported by focused native/public-artifact results. The original custom-image native/web run is `run-32303-1791287709184`; the concurrent-lock run is `run-38968-1791288300060`; actual delayed-body rendered-pixel recovery passes in `run-45962-1791288874398`; upload/unavailable-lock retry passes in `run-53124-1791289228671`. The affected combined production native/web suite is running and is not yet a passing gate. Interrupted writes, ambiguous acknowledgements and termination with a staged selection remain unproved.

The four whole-issue P1 gaps remain: management/metadata/cover breadth, production reader breadth, visual/configuration/performance acceptance, and integrated physical/human acceptance. Full EPUB accessibility remains failed/open. Source review and focused cover passes do not satisfy the requirement that the entire end-to-end walkthrough works.

Standards: zero new material breaches or correctness findings, one existing optional duplication heuristic. Spec: zero new slice defects, four existing whole-issue P1 gaps and the unchanged EPUB accessibility gate.

## Omitted narration locators API follow-up

### Standards

The independent approved-base review found no new hard standard violation or material correctness issue in the server API slice. The service keeps omission distinct from explicit null. The atomic repository conflict update omits undefined narration columns, preserves committed independent narration and still accepts explicit-null clears. New rows initialize omitted locators to null. Downstream ebook/audio conversion continues to resolve the position represented by the current request; it does not mistake retained narration for the new text location. CFI/page/device companion reset semantics are unchanged. Existing unit-expectation maintenance agrees with the new omission behavior. A possible Data Clumps heuristic remains in the pre-existing long positional repository argument list; a named input object is optional cleanup.

### Spec

The independent review found no new material mismatch or scope creep. The genuine two-session HTTP regression maps to concurrent sessions and independent playback states. The corrected API still needs fresh public HTTP GREEN. The native PDF/EPUB proof models currently copy narration from an earlier GET and can overwrite newer values by sending them explicitly, so the API correction alone does not complete concurrent reader synchronization. A separate native/public regression and correction are required. Physical reader acceptance is unproved. The four whole-issue P1 gaps and the full EPUB accessibility failure remain open.

Standards: zero new hard violations or material correctness findings, one existing optional data-clump heuristic. Spec: zero new API-slice findings; native snapshot-copying, four whole-issue P1 gaps and full EPUB accessibility remain open.

## Reader progress ordering follow-up

### Standards

The independent approved-base follow-up resolves the native copied-narration and web dirty/overlapping-save findings. PDF and EPUB text writes omit the independent narration locators. The web reader captures genuinely pending narration separately from loaded progress, acknowledges it before its coalesced text write, and clears only the exact successful pending object. One active save promise and a bounded queued flag serialize entire flushes; queued flushes capture current state when executed and recheck tracking before writing. The real delayed-acknowledgement browser regression has no assertion weakening. The Foliate strict comparison selects the matching chapter without mutating its index. No new hard documented-standard violation, material correctness defect or heuristic smell remains in this reviewed delta. Earlier optional transport duplication and positional progress arguments remain separate judgments.

### Spec

The independent follow-up resolves both web ordering P2 findings. Genuine native, browser and public API RED/GREEN journeys cover copied old narration, another session's concurrent narration, local pause/turn before debounce and a real successful POST acknowledgement delayed six seconds. The final controlled-delay journey awaits both text responses before asserting the visible chapter's public position. This serves server-delay, concurrent-session and independent-playback requirements without mocking core persistence. The follow-up reports no new mismatch, scope creep or assertion defect.

The final EPUB checkpoint passes nine HTTP journeys, the native companion-position journey and all four browser journeys. It does not override the four unresolved production native cases, failed unfiltered EPUB accessibility or the four whole-issue P1 gaps: broader management/metadata/cover parity, integrated production readers, visual/configuration/performance acceptance, and integrated physical/human acceptance. Physical evidence proves signing/launch and restoration of the normal private app, not real-network reading or Pro performance. Issue #2 remains open.

Standards: zero new material findings and existing optional cleanup judgments. Spec: zero new reader-progress slice findings, four whole-issue P1 gaps and the unchanged EPUB accessibility gate.

## Production PDF integration follow-up

### Standards

Both the production app and proof app compile the same native PDF reader sources. The approved-base Standards agent reports zero new hard violations or material correctness defects. Authenticated delivery/session validation, bounded adjacent page-controller cache, acknowledged saving and retry/discard behavior survive the move. Metadata Clear controls reuse the existing component and respect locks/saving. The public UI/API/file tests retain independent passage/OCR/progress assertions. PDFKit memory performance remains unmeasured. Existing transport duplication is optional cleanup.

### Spec

The approved-base Spec agent reports zero new material defects or scope creep in this delta. Production file details now lead into the PDF reader; this advances baseline PDF reading without claiming complete reader parity. Canonical public metadata supplies the browser heading after legitimate earlier metadata edits; independent file ID, page-two progress/percentage, delivered response and literal OCR assertions remain intact. Four whole-issue P1 gaps remain: management breadth, reader breadth, automated visual/configuration/performance coverage, and physical/integrated human acceptance. Unfiltered EPUB accessibility remains failed/open.

Standards: 0 new material findings. Spec: 0 new material delta findings, with 4 whole-issue P1 gaps still open. The focused production PDF and permitted-editor journeys pass, but the combined run failed before Unicode input and never reached browser execution; source review does not override that failed gate.

Subsequent runtime `run-74164-1791298971057` passed all nine HTTP journeys, both selected production PDF/Unicode native journeys, and the actual browser PDF handoff/reopen. All eleven actual PNGs and the public progress JSON were opened and inspected. This resolves the narrow Unicode setup and production PDF handoff gates; it does not establish the complete production aggregate or the four whole-issue P1 requirements.

## Observable watcher regression follow-up

### Standards

The independent approved-base agent found no new material Standards defect in replacing the existing filesystem test's fixed post-resume sleep with `vi.waitFor`. Both original assertions are retained. Missing delivery still fails within ten seconds, and a forbidden paused-file call remains in the accumulated spy history and cannot disappear on a later assertion attempt. Real filesystem behavior, cleanup and the twenty-second test budget are unchanged. Source review does not turn an interrupted aggregate green.

### Spec

The independent approved-base agent found no assertion weakening, silenced failure or new test boundary. The change follows the issue's instruction to await observable outcomes instead of fixed sleeps. Only the assertions repeat; the write/resume actions run once and history is not cleared. The serial focused watcher run subsequently passed all 39 existing tests. The earlier aggregate failure remains recorded and a fresh full run is required.

Standards: 0 new material findings. Spec: 0 new delta findings, with the 4 whole-issue P1 gaps unchanged.

## Current checkpoint review

### Standards

The final approved-base review found no new product correctness or test-integrity defect. It identified one hard logging breach in the physical fixture proxy's missing completion/failure lifecycle logs. The correction now emits a single start before listen, a duration-bearing end after normal shutdown, and a duration/errorClass/canonically sanitized failure on listener error. Close is idempotent and failure suppresses a misleading success log. The independent follow-up resolves that finding; real-process normal/failure smoke checks also passed. Optional authenticated-transport duplication and the positional repository progress arguments remain judgments rather than hard violations.

### Spec

The final approved-base review found no new material defect, scope creep or assertion weakening in completed changes. The focused production PDF/Unicode native summary has two executed passes without skips; independent browser OCR contains the literal second passage. The new direct-page-navigation public UI/progress test is an explicitly pending TDD slice, not current acceptance coverage. All four whole-issue P1 gaps and unfiltered EPUB accessibility remain open. The full server regression subsequently passed 14,694 cases, with six existing conditional skips; it does not override the pending client/native/browser aggregates or integrated acceptance.

Standards: 0 open material findings, 2 optional cleanup judgments. Spec: 0 new completed-slice findings, 4 whole-issue P1 findings plus the unchanged EPUB accessibility gate.

## PDF page navigation follow-up

### Standards

The independent approved-base review found no new documented-standard breach or test-integrity defect in direct page navigation, semantic footer actions, the bounded curl-controller update or the unfiltered accessibility diagnostics. Both reviewers identified a possible repeated appearance-task load in the retained reader. The correction guards loaded/loading/closed state before suspension and clears loading with `defer`; the follow-up resolves this source concern. No new material finding or heuristic smell remains. Existing optional transport duplication and positional progress arguments remain separate judgments.

### Spec

The independent review found no new scope creep or material defect. The strengthened existing journey controls a real progress request, observes pending page three and unchanged public progress, reopens navigation, cancels, releases the request, requires acknowledgement, relaunches and verifies the exact persisted passage. The strict release and asynchronous reset retain test integrity; the audit handler always returns false and excludes no issue.

The before-guard delay run passed and is not a reproduced lifecycle RED. Its initial saved page is null, so it does not demonstrate rollback from an older numeric page or temporary-file retention. The actual feature RED was the earlier missing Go to page control. Final corrected `run-18346-1791302158522` passed nine HTTP journeys, both native PDF journeys and actual browser handoff/reopen. All fourteen PNGs, both public progress JSONs and both OCR JSONs were inspected. This resolves the focused navigation gate, not the complete production aggregate.

Standards: 0 new material findings. Spec: 0 new slice findings; the 4 whole-issue P1 gaps and failed unfiltered EPUB accessibility remain open. Issue #2 remains incomplete.

## PDF text search follow-up

### Standards

The approved-base independent review identified retained `searchSelection` during reader close. Close now clears the selection before document/file cleanup; the reviewer resolves the source finding without claiming a reproduced leak. It also identified an unsafe temporary array pointer in the new screenshot helper, and the same issue at three earlier cover-test pixel sites. All four helpers now construct the context, draw and read pixels within `withUnsafeMutableBytes`; only a measured count escapes the PDF helper. The reviewer resolves these source concerns. Formats, exact color/alpha assertions and public boundaries remain unchanged. No new documented-standard breach or material smell remains; existing optional transport duplication remains separate. Fresh PDF-search and original-resolution/alpha cover execution subsequently passed; the rendered-cover path remains pending after a picker setup failure.

### Spec

The independent review found one P2 coverage gap: search passage/progress assertions could pass with highlighting removed. The existing native journey now recognizes the delivered literal line from actual PDF surface pixels, asserts blue fill in the matched range and none on the unselected prefix, and checks cleared pixels after curl away/back, relaunch and another curl. No private PDFKit state is asserted, and all original passage, progress and full-audit assertions remain. The painting-disabled sensitivity run failed with exact literal OCR still present and match fill zero. The reviewer resolves the source gap. The restored three-PDF-journey/web run passed, followed by a fresh native search pass with the corrected screenshot buffer.

No further material source defect or scope creep was found. Application results and phrases are bounded, previous searches stop and stale-document callbacks are rejected, but PDFKit engine memory, latency, cancellation/concurrency and broader configuration acceptance remain unproved. Standards: zero open source findings after corrections. Spec: zero open slice source findings, with the remaining cover-helper rerun and complete acceptance gates pending. The four whole-issue P1 gaps and failed unfiltered EPUB accessibility remain open. Issue #2 remains incomplete.

## PDF contents and delayed-cover follow-up

### Standards

The independent approved-base review found no new documented-standard breach, material correctness defect or test-integrity issue. Contents limits each level to 100 siblings, guards depth and ancestor cycles, validates local destinations and retains the guarded reader lifecycle. The controlled cover transfer forwards actual captured bytes in order, holds completion, clears interval/watchdog state on release/close/expiry and preserves strict release failure when no response is held. The earlier assumption about a sixty-second native timeout was wrong: the actual twenty-second inactivity timeout motivated the real-byte slow-transfer correction, leaving production timeout behavior unchanged. A possible duplicated footer button style is an optional judgment, not a required correction.

### Spec

The independent review found no new material slice defect, scope creep or weakened oracle. Contents comes from the delivered PDF and preserves independent native passage, public saved progress, relaunch, genuine curl and unfiltered audits. The delayed-cover journey retains pre-Save held state, strict response release, rendered pixels and independent delivered image assertions. Source review does not prove outline pagination, malformed/no-outline cases, engine-scale behavior or broader configurations.

Final runtime `run-66536-1791306706533` passed nine HTTP journeys, all four selected native journeys and the actual browser handoff/reopen, with no native skips or expected failures. All twenty native and both browser PNGs and related public progress/pixel/OCR records were opened and inspected. This resolves the focused contents and rendered-cover helper gates. Standards: 0 new material findings, 1 optional duplication judgment. Spec: 0 new slice findings; all 4 whole-issue P1 gaps, failed unfiltered EPUB accessibility and complete 21-native/7-browser acceptance remain open. Issue #2 remains incomplete.
