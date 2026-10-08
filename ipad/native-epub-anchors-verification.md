# Native EPUB anchor proof

Issue [#2](https://github.com/mooneeb/bookorbit/issues/2), QA 3 and QA 4. This separate ReaderProof feature implements the next experiment proposed in [native anchor research](native-epub-anchors-research.md). The production EPUB engine remains undecided under ADR 0004. Implementation and source checks do not establish runtime acceptance.

## Implemented behavior

An authorized reader opens **Inspect native anchors** from a delivered EPUB file. The proof fetches the actual OPF and first linear XHTML chapter through authenticated public routes. It retains XML element order, namespaces, IDs and original UTF-16 character data, coalescing adjacent text and CDATA across comments. Its package path comes from the real OPF itemref, including any itemref ID; it is not an assumed spine index.

Native TextKit 2 displays selectable paragraphs and inline emphasis. **Locations** accepts a saved CFI, resolves its source endpoints and selects the corresponding native range. Genuine native touch or keyboard selection reports its actual range through `UITextViewDelegate`. Changing font size, Dynamic Type or orientation keeps the source document independent of layout. Multiple discontiguous ranges, generated paragraph separators and cross-paragraph selections report unsupported feedback rather than inventing coordinates.

**Save highlight** posts the selected literal text and generated CFI to the existing owning annotation route with `bookFileId`. The UI accepts only an acknowledged response with matching book, file, CFI, text and exact position status. It retains a bounded list of the latest 20 highlights and can reopen one through the same resolver. An uncertain POST is never automatically repeated. Checking the list may establish that a matching passage is present; it cannot prove which request created it, so the original save remains unconfirmed and another POST stays disabled.

**Save position** creates a point CFI at the selection start, posts only the existing text-source fields and checks the public progress readback. The proof preserves the acknowledged book percentage; it does not estimate whole-book progress from one chapter's flattened text. Narration and TTS positions are outside this experiment. A failed write retains the selection and location draft. Writes disable closing and repeated actions. The API pins all proof requests to the same authenticated session generation and cancels streamed responses on completion or failure.

The shared package now owns `CreateAnnotationPayload` and the existing 2,000-character CFI bound. Backend validation retains all prior decorators and location constraints. The web annotation creator consumes that shared request contract. Generated Swift uses audited EPUB request/response projections and a paginated list projection. No database schema or route behavior changed.

## Deliberate diagnostic bounds

Info JSON is capped at 1 MiB and 4,096 spine/manifest entries. Actual OPF transport is capped at 256 KiB; actual chapter transport at 64 KiB, with advertised size checked against delivered bytes. XML has at most 4,096 elements, depth 64, bounded attributes and 131,072 source UTF-16 units. Projection has at most 128 paragraphs, 4,096 runs and 32,768 UTF-16 units. UTF-8 XML without a DOCTYPE and XHTML paragraphs with `span`, `em`, `strong`, `b`, or `i` are supported. Original whitespace is retained. The CFI subset accepts character-data point/range endpoints, escaped element assertions and package indirection; unsupported temporal/spatial, text-assertion and side-bias syntax fails explicitly.

These limits make the proof bounded. They do not constitute production support for large chapters, full XHTML/CSS, headings, links, images, tables, ruby, vertical text, fixed layout, pagination or a complete CFI grammar. No source file, audit or fixture is replaced by a mocked text renderer.

## Required autonomous acceptance

Run a High-effort tester against an isolated real server, migrated database and delivered EPUBs using the cached iPad simulator. Assert through native UI, authenticated HTTP, actual web UI and delivered files only. Preserve original PDFs and the prior plain native chapter diagnostic as regressions. No new runtime, dependency download, physical iPad or user input is required for this gate.

1. Resolve the independent plain oracle `epubcfi(/6/2[c1ref]!/4/2[p1],/1:6,/1:14)` and visibly select literal `😀 café` at UTF-16 `[6,14)`. Exercise actual native selection, create a highlight, read the ACK through public HTTP and reopen its passage in the actual web reader and native UI after relaunch, font change and rotation.
2. Deliver the independently derived rich source `Alpha <!--ignored--><![CDATA[😀 ]]><em id="em1">cafe&#x301;</em> omega.` and resolve `epubcfi(/6/2[c1ref]!/4/2[p1],/1:6,/2[em1]/1:5)`. It must select the same literal `[6,14)` across original source chunks in both renderers. Use non-default OPF paths/itemref IDs and nonlinear items to prove actual package mapping.
3. Save and resume a point CFI, preserving independent narration values through public API and web UI. Check unsupported/malformed anchors, ID/package mismatches, surrogate boundaries, multiple ranges and generated separators. Never infer correctness from matching percentages alone.
4. Exercise denied/hidden entry points, missing/changed resources, false length headers and byte limits, expired sessions, account switching, held/failed writes, interrupted acknowledgement and relaunch. Confirm no automatic duplicate annotation create. A matching old highlight must not become a false new-write acknowledgement.
5. Run full accessibility audits and inspect actual images of selection, emphasis, location controls and error states in representative portrait/landscape, default/large text, light/dark and Reduce Motion configurations. Record source text, selected endpoints and artifact hashes alongside screenshots. No audit filtering or automatic baseline acceptance.

The tester must supply named test IDs and a runnable harness command when its QA feature is prepared. Physical VoiceOver behavior, Pencil input, native pagination, real-device performance, audible narration and human-reviewed visual baselines remain separate unproved requirements, not waived acceptance.

## Verification record

- Node syntax and canonical contract generation: passed.
- Swift formatting, syntax parsing and diff checks: passed.
- Strict Swift 6 primary-file typecheck: passed with complete concurrency and warnings as errors, using all actual production/proof declarations and installed macro plugins. Exact command and empty diagnostics are retained at `/tmp/bookorbit-native-epub-anchor-strict-typecheck-command.txt` and `/tmp/bookorbit-native-epub-anchor-strict-typecheck.log`.
- Shared types and plugin API builds, server/client typechecks, full server/client ESLint and Xcode generation: passed. Individual results, commands and logs are retained in `/tmp/bookorbit-native-epub-anchor-source-checks.json` and `/tmp/bookorbit-native-epub-anchor-*-command.txt`/`.log`.
- Both-architecture simulator builds of ReaderProof and production BookOrbit: passed. Logs `/tmp/bookorbit-native-epub-anchor-BookOrbitReaderProof-build.log` and `/tmp/bookorbit-native-epub-anchor-BookOrbit-build.log` retain the existing OIDC initializer deprecation and AppIntents metadata warning. These are build checks, not native UI acceptance. The exclusive source gate was released after all subprocesses completed.
- End-of-issue suites and two-axis review: pending.
- Authenticated HTTP, native simulator, browser, delivered-file and visual/audit acceptance: not run for this feature.
