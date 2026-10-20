# Text-anchored EPUB ink through reflow

Audit date: **2026-10-20**. Planning and primary-source research for [Establish text-anchored EPUB ink reflow feasibility](https://github.com/mooneeb/bookorbit/issues/16), read live with [Validate text-following ink through actual EPUB reflow](https://github.com/mooneeb/bookorbit/issues/17). Repository baseline: `ce118e3890ea8c9019857cb7556552cdc9992f8e`. No renderer, deployment target, or storage schema is selected.

## Finding and scope

**There are credible building blocks for a bounded, explicitly associated annotation model. General automatic remapping of arbitrary freehand page ink is not established by the inspected APIs or sources.** Content anchors can recover the intended text; renderer geometry can locate that text in the new layout; PencilKit can preserve and manipulate editable strokes. The application still has to supply the relationships and placement rules connecting those pieces. This is a candidate for an experiment, not a feasibility promise. Evidence and limits follow below.

The governing example is: highlight **useful**, draw an arrow, and handwrite **important**. All three must retain their intended relationship after font size, line breaks, pagination, margins, orientation, and viewport changes. Page ink remains visible with Ink OFF. Pencil navigates like a finger when OFF. The subsequent [interaction resolution](https://github.com/mooneeb/bookorbit/issues/6#issuecomment-6289693465) confirms that fingers continue navigating while Ink is ON and Pencil writes. These are requirements from the live issue and delegation, not conclusions of this audit.

The earlier frozen-layout/marker-only ordinary-reading policy is superseded. This report does not substitute a snapshot, hidden ink opened from a marker, or a passage-linked canvas for visible page ink. The earlier [reader-engine report][prior-engines] and [Pencil report][prior-pencil] remain evidence for APIs and earlier unknowns, not authority to restore the old policy. PDFKit's accepted PDF geometry behavior does not validate EPUB remapping.

**Evidence labels:** **API/specification** means an inspected public contract. **Source observation** means behavior read in a pinned implementation, without executing it. **Upstream experiment** means an author's reported prototype/study, not a BookOrbit result. **Inference/proposal** means reasoning or a candidate design. **Unknown** means runtime proof or a product decision is still needed. No actual-renderer experiment or iPad test was run for this report.

## Inspected versions and source authority

- **BookOrbit:** [AGENTS.md at the baseline][agents], plus the vendored Foliate `view.js`, `overlayer.js`, `epubcfi.js`, and `paginator.js`. The existing reports were read from the parent checkout and their published copies pinned at `2060eb43cceb1c1d47394a6668071eb4e9f4333d`.
- **Readium Swift:** [3.11.1, released 2026-10-16][readium-release], peeled commit **`9a8c094b72245fd27043c9d298005e5c78b32a01`**, observed as the latest stable release in the live release listing. The earlier report inspected 3.11.0. This audit compared the selected locator, selection, navigator, and guide files at both versions: those files are byte-identical. The 4.0.0-alpha.2 prerelease was not used as the stable contract.
- **Upstream Foliate-js:** `main` resolved to **`78914aef4466eb960965702401634c2cb348e9b1`**, commit date 2026-05-01. Inspected `view.js`, `epubcfi.js`, `overlayer.js`, `paginator.js`, and README at that hash. This does not establish the upstream origin of BookOrbit's modified vendored copy. Claims about BookOrbit use the separate BookOrbit pin.
- **Standards:** [EPUB 3.3 Recommendation, 2026-01-13][epub-layout]; [EPUB CFI 1.1 IDPF Recommended Specification, 2017-01-05][cfi]; [Web Annotation Recommendation, 2017-02-23][annotation-selectors]. The CFI document is not a newer W3C Recommendation merely because W3C also hosts it.
- **Living geometry/DOM specifications:** CSSOM View editor's draft dated 2026-10-08, with [inspected source commit `e13fe879106ad83dd89faecab5edad868c7efbfa`][cssom-source]; live DOM Standard dated 2026-10-19, with [inspected `dom.bs` revision `8b515270f1644349b79a0a949cb6e121856d0fd9`][dom-source]. Draft text and source inspection are not proof of the selected WebKit runtime's behavior.
- **Apple:** current first-party PencilKit DocC data and API pages, WWDC20 stroke-model session, WWDC26 recognition session, and the first-party stroke-inspection sample. Apple does not expose immutable documentation revisions here. Retrieval date, per-symbol introduction metadata, sample checksum, and selected documentation checksums are recorded below. The available SDK/OS on the intended iPad was not established.
- **Prior art:** Bargeron and Moscovich, [Reflowing Digital Ink Annotations, CHI 2003][reflow-paper], the author-hosted paper linked from [Moscovich's publications page][reflow-author]. This is historical experimental evidence, not a current iPad API or a claim of modern EPUB compatibility.

## Content identity is distinct from current line rectangles

### What an anchor can identify

**API/specification:** CFI identifies structural points and contiguous ranges, including package/resource indirection, character offsets counted in UTF-16 units, assertions, and target-correction mechanisms. It also defines percentage spatial offsets for suitable content. None of these encodes that several ink strokes form a handwritten word or that an arrow connects that word to another passage. **Inference:** use content identity to find the text again; it cannot replace annotation interpretation. Percentage coordinates can be useful inside an unchanged image, but percentage page coordinates do not solve text reflow. [CFI sections 3.1 and 3.4-3.5][cfi].

**API/specification:** Web Annotation provides exact/prefix/suffix quotes, text positions, and start/end range selectors. Quote/position text uses normalized Unicode code points in logical order, unlike CFI's code-unit offsets. The recommendation allows a quote selector to match multiple occurrences and warns that text positions are brittle under content edits. **Proposal:** retain engine-native anchors plus original excerpt/context, and expose ambiguity rather than silently choosing or annotating every match. That single-target safety policy is additional application behavior, not what an ambiguous standard quote selector guarantees. [Selectors][annotation-selectors].

**API/specification:** a DOM range has node/offset boundaries, with common-root constraints; it is not a persistent object across document destruction/reload. **Proposal:** resolve a serialized anchor into a new range after resource reload. Cross-resource annotations need several resource-local anchors rather than one range across independent documents. [DOM ranges][dom-range]. Readium's HTML locator extension defines `cssSelector`, `partialCfi`, and `domRange`; `partialCfi` excludes the EPUB package indirection and wrapper, and its text context calls for raw DOM text. Those definitions do not establish that every navigator consumes every field. [HTML locator extension][readium-html].

### What geometry can and cannot tell us

**API/specification:** `Range.getClientRects()` returns current rectangles for selected elements/text fragments, in content order, using font metrics and applicable transforms. These are not glyph outlines, guaranteed one-per-line records, or live rectangles. `getBoundingClientRect()` collapses them into a bounding rectangle. **Inference:** preserve individual fragments; one union can span unrelated whitespace, lines, or columns. Re-measure after layout changes and account for the correct frame/viewport. Hit testing such as `caretPositionFromPoint()` can propose a text position, not the author's intended association. Its availability and precision need runtime checks. [CSSOM range geometry][cssom-range], [caret hit testing][cssom-caret].

**Inference:** PDF zoom/rotation can transform a fixed page's coordinate system. EPUB reflow changes where characters go relative to each other: a phrase can become two lines or cross a page boundary. One affine matrix for an entire drawing cannot generally express those independent displacements while keeping handwriting intact. A matrix fitted to a range's union rectangle can stretch a label across whitespace or connect the wrong line. This follows from [reflowable EPUB layout][epub-layout], the geometry contract above, and PencilKit's [affine drawing transform][pk-drawing-transform]; it is a limitation of that strategy, not proof that every remapping strategy is impossible.

## What the candidate renderers expose

### Foliate inside WKWebView

**Source observation:** BookOrbit's [`getCFI(index, range)`][bo-view] uses the range plus section CFI; `resolveCFI()` reconstructs the resource-local range. `draw-annotation` supplies the range and draw callback. The vendored [`Overlayer.add()` and `redraw()`][bo-overlayer] call `getClientRects()` and recreate SVG decorations from those rectangles. Highlight/underline implementations generate a shape per rectangle. The vendored [paginator][bo-paginator] observes resize, responds to font readiness, and redraws overlays during layout work. Upstream [view][foliate-view] and [overlayer][foliate-overlayer] expose the same broad seams at their separate pin.

**Inference:** an experiment can resolve real CFIs after layout and use the resulting fragments to position ink groups. A custom SVG callback accepting rectangles still has to implement each ink placement rule. It is not an arbitrary-stroke reflow engine. The [vendored CFI implementation][bo-cfi] also needs its own anchor-correction/round-trip fixtures; specification features must not be assumed merely because it parses CFIs.

**Unknown:** accurate DOM-to-native mapping across frames, CSS columns, scroll offsets, spread changes, visual viewport changes, and page clipping in WKWebView. The README's [scope/status][foliate-readme] does not establish an iPad integration. BookOrbit's fork must be tested independently of upstream. No private book loader or server is needed for public/local fixtures.

### Readium Swift EPUB

**Source observation:** 3.11.1 [`selection.js`][readium-selection] reports href, selected text/context, and a union selection rectangle. [`rangeFromLocator()`][readium-utils] uses quoted text with optional CSS scoping, then CSS/HTML IDs; this function does not consume `partialCfi` or `domRange`. This is a statement about that path, not every use of those fields elsewhere. Its vendored [quote matcher][readium-matcher] can approximate a quote and returns the highest-scoring match. Returning a range is therefore not proof of an exact, unique match. Edition/excerpt validation must precede accepting it.

**Source observation:** [`HTMLDecorationTemplate`][readium-template] distinguishes `.boxes` from `.bounds`; the default highlight uses boxes. [`decorator.js`][readium-decorator] resolves ranges, computes fragments, and positions decorations with writing-mode/column handling. [`rect.js`][readium-rect] merges/removes rectangles for decoration display; those processed boxes are not a character-to-stroke correspondence map. The navigator's public [`evaluateJavaScript()`][readium-navigator] targets the currently visible HTML resource. **Inference:** a custom current-range geometry bridge is a credible experimental seam, but the ordinary selection frame alone is insufficient for line/page-aware ink.

**Unknown:** the extra bridge's exact API surface, reliable layout-completion signaling, native overlay composition, offscreen resource lifecycle, and native/web CFI interoperability. Decorations or JavaScript access do not supply a PDFKit-style native page-overlay integration automatically. Neither renderer is selected by this audit.

## PencilKit mechanics, grouping, and editability

The following introduction versions come from Apple's served DocC metadata, not assumptions about the user's installed OS.

- **API, iPadOS 13:** [`PKDrawing.dataRepresentation()`][pk-save] and [`init(data:)`][pk-load] save/restore an editable drawing. **Proposal:** retain the editable source and its revisions; generated appearances are derivatives, not the only surviving source.
- **API, iPadOS 14:** [`PKDrawing.strokes`][pk-strokes] and `init(strokes:)` allow accessing/rebuilding subsets. [`PKStroke`][pk-stroke] exposes ink, path, transform, mask, and rendered bounds. [`transform`][pk-transform] is affine and mutable. **Inference:** translating a known label group is supported mechanically; deciding which strokes constitute that label remains app work.
- **API/upstream demonstration, iPadOS 14:** [`PKStrokePath`][pk-path] supports interpolation and construction from control points; [`PKStrokePoint`][pk-point] includes location, size, opacity, force, azimuth, altitude, and timing. Apple's [WWDC20 explanation][pk-session] identifies spline control points rather than a raw on-curve sensor trace, notes lossy point compression, and explains eraser masks/split strokes. [`maskedPathRanges`][pk-mask-ranges] exposes visible ranges. **Inference:** centerline-only exports, ignored masks, or repeatedly rebuilding points can change appearance/editing behavior. Use original strokes/transforms where possible; verify any generated/split strokes and masks.
- **API, iPadOS 18:** [`PKCanvasView.isDrawingEnabled`][pk-enabled] provides drawing enablement. **Inference:** Ink OFF must also route Pencil interaction through to reader navigation while continuing display. Disabling drawing alone is not evidence of correct reader hit testing, gesture delivery, or persistence.
- **API, iPadOS 27:** public [`PKStroke.id`][pk-id] and [`PKCanvasView.selection`][pk-selection] expose stroke identity and selected stroke IDs. **Inference:** these could support explicit selection/group assignment on a compatible deployment. Do not assume these APIs exist on an older baseline. Existing lasso UI does not by itself prove an older public selected-stroke-ID contract. An older-OS candidate could instead capture each explicitly started annotation/role into its own drawing, but arbitrary retrospective grouping then requires additional app work and proof.
- **API, iPadOS 27:** [`renderGroupID`][pk-render-group] concerns wet-ink compositing, not a semantic label/arrow group or an EPUB anchor. [`substroke(range:)`][pk-substroke] and [`RenderState`][pk-render-state] support slicing/preserving rendering details. Apple's [rendering guidance][pk-render-guide] warns that constructing modified strokes without carrying rendering state can alter their appearance. These newer conveniences must be availability-gated; older path access is not equivalent to a guaranteed fidelity-preserving split operation.
- **API, iPadOS 27:** [`PKStrokeRecognizer`][pk-recognizer] recognizes handwritten text and offers search, with language/scale considerations. It does not document recovering EPUB target ranges or arbitrary arrow-label relationships. [WWDC26][pk-recognition-session] is evidence of handwriting-recognition capabilities, not a general intent solver. OCR, handwriting transcription, and search are not requested and are not prerequisites of the proposed model.

**Source observation/upstream demonstration:** Apple's [stroke-inspection sample][pk-sample] constructs letters by taking known slices of an alphabet drawing and applying transforms (`HandwritingTutor/TextGenerator.swift`). It demonstrates manipulation of already assigned strokes, not automatic discovery of letters or EPUB relationships. Inspected archive: [first-party ZIP][pk-sample-zip], SHA-256 `5d349ebeb48755943e0e4bcfe879b1693e8fb9f6173ab484ffce12abd3a22b04`.

**Unknown:** reliable group identity after partial erasure, lasso moves, undo/redo, copying, and archive restore, especially on an older deployment without public stroke IDs. Stroke-array positions are not durable semantic identities. A [`canvasViewDrawingDidChange` notification][pk-change] signals drawing changes, not which changed stroke belongs to which range. The app must reconcile edits into its relationships. [Ink content-version compatibility][pk-compatibility] also remains a separate requirement.

## Can unstructured intent be inferred without grouping or recognition?

**No reliable general inference is established.** Without an explicit association or some interpretation step, raw coordinates/timing do not say whether a horizontal mark is an underline, an arrow shaft, part of a letter, or part of a diagram. The same nearby strokes may describe one word, a sentence, an image, or another note. Selecting the nearest word is itself a heuristic, not evidence that the relationship is correct. This is an inference about the information available in the inspected models, not a claim that useful recognition systems cannot be built.

**Upstream experiment:** the CHI 2003 Callisto study separated grouping/classification, anchoring, and re-rendering. Its evaluation used manually grouped/classified annotations to avoid confounding classification errors. It split/joined underlines, copied/scaled circles, and repositioned margin comments without parsing their text; it reported limitations for large circles. It also discusses arrows misclassified as underlines. This establishes bounded experimental precedent and the need to distinguish interpretation from geometry. It does not establish automatic intent inference or this user's iPad/EPUB requirements. [Sections 3 and 4.1-4.3][reflow-paper].

**Proposal:** measure optional proximity/time/shape suggestions only against separately recorded user-assigned ground truth, with correction and uncertainty visible. A stroke group plus its text target can be assigned without recognizing the handwritten word. Explicit grouping alone still does not identify arrow endpoints or mark type; those roles also need assignment or interpretation. Until independently validated, automatic suggestions cannot silently determine durable meaning.

## Bounded candidate to test, without selecting a schema

All steps in this section are **proposals/inferences**, not supported end-to-end features. The initial experimental scope is one resource-local text target, a semantic highlight, one associated handwritten label, and one connector. It assumes that a tester explicitly assigns the target, label strokes, connector role, and endpoints. Start with that bound to isolate placement mechanics; then test which authoring burden and shape changes the user can accept.

### Retain relationships and originals

Keep user ownership and source identity separate from layout. A candidate record needs the source file/revision fingerprint, resource identity, engine anchor(s), original excerpt/context, and explicit association provenance such as user-assigned versus suggested. Keep editable original drawings, app-owned group/role identities, local drawing coordinates, and placement revisions. This is a list of information needed for the experiment, not a database/API contract. [Project ownership/scale rules][agents], [anchor standards][cfi], [editable drawing persistence][pk-save].

Maintain a disposable layout result: current target fragments, page/column identity, label placement, connector endpoints/route, and a layout generation. Re-resolve anchors and recompute that result from originals after layout settles. Do not mutate the source geometry repeatedly on every reflow, accumulating transforms or replacing handwriting with an image.

### Treat the example's three roles differently

1. **Highlight useful.** With an actual selected text range, render the semantic highlight against its current fragments. If the user instead draws a freehand highlighter stroke, assigning it to a range and regenerating a semantic band is a visible interpretation/change of appearance that needs review. Preserving the original stroke privately does not establish that a regenerated appearance satisfies the desired page ink. A literal irregular highlight needs its own deformation/splitting rule. [Range-based Foliate drawing][bo-overlayer], [Readium boxes][readium-template].
2. **Handwritten important.** Preserve the assigned label's internal stroke layout and orientation; begin with translation at the original writing size, not independent per-letter warping or nonuniform scaling to the word box. Place it near the current target on that target's page, using a recorded preferred side/offset and available space. Optional uniform resizing, a dedicated annotation lane, or injected whitespace are separate user-visible experiments. None is assumed acceptable. A short note fitting at one size does not prove it will fit at every viewport.
3. **Arrow.** Keep the target-side endpoint attached to an explicitly identified boundary/fragment of useful, and the label-side endpoint attached to a point in the label's local coordinates. For a text-to-text arrow, retain two content anchors. A freehand shaft, head, and label may be one or many strokes; stroke order is not proof of endpoint direction. When endpoints move independently, test a recomputed connector with preserved style versus modifying the original shaft/head. Either requires an explicit role and an acceptance decision about changed geometry. The original arrow must remain recoverable/editable; generated segments need defined selection/erase behavior.

The crucial test is whether this still feels like the user's page ink. The candidate cannot claim success merely because a standard highlight and a preassigned picture move together.

### Reflow and editing lifecycle

For each layout change, resolve against the same source revision, validate the excerpt, obtain fresh fragment geometry, map it into the overlay's coordinate system, place the label, and update the connector as one layout generation. Discard stale asynchronous results from the previous generation. Resolve only loaded/visible resources and a bounded adjacent window. Fonts, delayed images, and column pagination can invalidate earlier measurements; [Foliate's font/resize handling][bo-paginator] illustrates why a settings event alone is not a completed-layout signal.

When Ink OFF, continue rendering annotations with the resolved text and let navigation work. When Ink ON, editing old ink must operate on the selected group, not on a flattened preview. Under a rigid local placement, inverse mapping can put new strokes back into the group's local coordinates. A warped or split stroke has a more complex inverse/ownership problem; do not extend the simple matrix assumption to it. Verify erase, lasso, undo, and new strokes separately after reflow, then reopen the archive. A convenient editor detached from the page cannot be the only demonstration of the required page interaction.

### Cases that exceed the initial bound

- **Cross-line/page underlines, circles, brackets, and long strokes:** assign a logical span and inspect each new fragment. Stretching, splitting, copying, or generating marks are different behaviors. Mapping every sampled point to its nearest character can damage letters, gaps, loops, and overlapping strokes. Preserve a source-to-derived-piece relationship if splitting is tested. A semantic multi-line highlight is easier than literal freehand reconstruction; it does not prove the latter.
- **Cross-page connectors:** one global canvas path may run through hidden columns/gutters. A label following a single target onto its new page is a simpler case than two endpoints on different pages. Possible continuation segments, repeated labels, a spanning view, or constrained placement require explicit review. No single-page capture can prove simultaneous visibility across separate pages. No marker-only replacement is selected.
- **Collisions:** several labels may compete for insufficient whitespace at legible size. Bounded candidate placement can try a few nearby positions and avoid covering text, but cannot assume a collision-free result. A reserved lane changes the text width and pagination; inserted space can trigger another layout pass or oscillation. Define a maximum retry count and report unresolved placement. Do not silently shrink, hide, pile up, or send ink to an off-page notes list and call it success.
- **Images/tables:** use an explicit element/cell/region target where appropriate, plus unchanged asset identity. CFI spatial offsets can express positions inside suitable content; they do not infer which object in an image an arrow denotes. Cropping, table restructuring, nested blocks, and spanning cells need separate fixtures. Text in an image is not automatically a selectable EPUB range, and OCR is not introduced.
- **RTL, vertical writing, hyphenation, ligatures, and combining characters:** logical anchor order differs from visual placement; one word can have several visual fragments. Identify endpoints by logical boundary plus intended visual attachment, not by array position or universally using the leftmost box. Verify selection normalization and complete grapheme coverage. [CFI offsets][cfi], [annotation text rules][annotation-selectors], [Readium writing-mode positioning][readium-decorator].

### Source replacement remains a separate safeguard

Layout changes to unchanged publication content may remap. A replaced file, changed edition, edited resource, or uncertain source identity must not silently inherit the notes even if a CFI resolves or a quote approximately matches. Retain the original source association and excerpts/context; require an explicit reviewed reattachment/migration before claiming a new target. A same-name file or matching book title is not adequate identity. Old ink must remain available with its original context. This is an application safety requirement from the delegation, informed by [Readium's approximate matcher][readium-matcher]; it is not a guarantee supplied by that matcher.

## Decisive fixture plan for the EPUB reflow prototype

This is proposed work for the [real-renderer prototype][prototype], not work completed here. Its overall aim is to establish whether the exact example survives actual EPUB layout and editable-ink transitions, and expose precisely where interpretation/placement decisions are required.

### Runtime and evidence rules

Use self-authored/public-domain local EPUB fixtures, never the private library/server. Record fixture bytes/hash, fonts/assets, exact renderer/fork commit, host app revision, WebKit/iPadOS/Xcode/SDK versions, device/Pencil model, and test time. Start in an actual candidate renderer; run the same decisive subset in the second candidate before drawing comparative conclusions. Foliate in a desktop browser can falsify anchor/placement assumptions early; it cannot validate WKWebView/PencilKit or Readium Swift. Record any browser-only drawing representation explicitly.

Author annotations through real selection/ink interactions. Choose among repeated useful occurrences, persist the engine-produced locator, then reload the document before testing reflow. Do not hardcode a known word's DOM ID/coordinates as the annotation model. Show independently whether the selected text stays the same and whether its geometry changes. Capture before/after resource, excerpt, fragment rectangles, page/column identity, group membership/provenance, endpoint bindings, and placement status. Actual text must visibly wrap or repaginate; zooming an unchanged screenshot is insufficient.

Each scenario should have its own content, local controls/reset, expected outcomes, per-scenario checkboxes, separate reactions, and a completion summary. Avoid a shared settings dashboard. Mark preassigned groups/endpoints as preassigned. A successful SVG placed next to a known word proves only that rendering primitive, not the required interaction or native editing.

### Atomic scenarios and expected evidence

1. **Exact example, ordinary reading:** select one useful in a real EPUB, highlight it, draw the arrow, and handwrite important. With Ink OFF, apply larger/smaller text, a forced line wrap, changed margins/line spacing, portrait/landscape, narrow/wide viewport, and a transition to another page/column. Expect the same selected occurrence, visible highlight, correctly directed arrow, and legible whole handwriting with the intended relationship. Record each change independently, then a combined sequence and return to the original layout. Pencil must navigate without editing.
2. **Old-ink editing after reflow:** reload the persisted example at a changed layout; enable ink, erase part of an old letter and arrow, lasso/move the label, and undo/redo. Expect edits to affect the intended original group and connector relationship, with other notes intact. Save, terminate/reopen, and verify stroke/mask/group restoration. A display derivative passing scenario 1 does not pass this scenario.
3. **New ink after reflow:** add strokes to the existing label and create a separate annotation in the changed layout. Reflow again and return. Expect correct local-coordinate ownership for both, no duplicate transforms or accidental grouping, and a valid undo history.
4. **A span becoming several fragments:** underline/circle a phrase across inline nodes, then force it across lines and pages; also merge lines by reducing text size. Expect the same logical span. Compare literal-stroke splitting against any explicitly proposed semantic regeneration, including appearance and editable-piece ownership. Do not mark the general freehand case passed if only a generated range highlight succeeds.
5. **Two targets separated by pagination:** draw a connector between two passages, then move them to different pages; include a single stroke crossing their original line boundary. Expect an explicit result or recorded unsupported combination, not an unnoticed clipped shaft or wrong endpoint. Show any continuation/duplication choice to the user before treating it as accepted.
6. **Unassigned ambiguous ink:** write two nearby comments, return later to dot an i, cross an existing arrow, and add a margin symbol. Run both explicit assignment and any suggested grouping on the same strokes. Expect a visible distinction between supplied relationships and inferred guesses, with correction tested. Report target/group/direction mistakes separately. No OCR/search acceptance criterion is added.
7. **Crowded labels and narrow margins:** assign several labels to adjacent targets, including a handwritten label wider than the available margin. Expect legibility and visibility to be evaluated alongside text occlusion and navigation. Record unresolved placements and every layout retry. Any lane, whitespace insertion, relocation distance, or size constraint is a concrete proposed trade-off, not a hidden success condition.
8. **Typography/direction:** repeat a target within duplicate paragraphs and use bidirectional/RTL text, vertical writing, emoji/combining marks, ligatures, and hyphenated/wrapped text. Expect exact occurrence recovery, valid range boundaries, and correct visual endpoint attachment after reload/reflow. Record unsupported content rather than normalizing it away.
9. **Images and tables:** connect a text word to an image region and a table cell; resize/orient the viewport and change text size. Expect the correct object/cell/region and readable nearby label without assuming text-range geometry explains image meaning. Include a cropped image and a wrapping/spanning cell as adverse cases.
10. **Changed source:** retain originals, then load fixtures with the same title/file name but edited text, reordered resources, removed targets, or duplicate quotes. Expect a source mismatch/ambiguous/unresolved outcome until explicitly reviewed. Normal layout-only fixtures must continue to resolve. No silent cross-edition migration.
11. **Lifecycle and bounded cost:** unload/reload chapters, cold-open saved notes, and rapidly resize during delayed font/image layout. Include a giant chapter and a declared dense fixture, for example 1,000 groups across resources. Expect no stale geometry, lost edits, whole-library scan, or unbounded active canvases. Measure time to first correct ink, reflow/bridge latency, active resources/groups/canvases, memory peak, save/reopen duration, and lookup work. Report actual counts and failures; set acceptable device budgets with the parent/user rather than inventing a passing threshold.

### Decision gates

Passing an anchor round trip is one gate. Preserving relationship/legibility in real reflow is another. Native editable old/new strokes, masks, input delivery, pressure/palm behavior, and device performance are a third. The user's live verdict on appearance, grouping burden, and crowded/cross-page behavior is a fourth. Record each gate separately, including failed combinations, so a browser placement pass cannot be reported as an iPad ink pass.

Before calling the bounded model feasible, require scenarios 1-3 to pass together in the intended native host, plus actual fragment/page changes and save/reopen evidence. Scenarios 4-11 establish which extension cases are supported, need a user-approved constraint, or remain unresolved. A failed renderer bridge may reject that route; a failed shape rule may reject that rule. Neither alone proves all EPUB ink impossible.

## Decisions to bring back through the parent

These are questions for the parent to present during the live review for [Validate text-following ink through actual EPUB reflow][prototype], not questions asked or resolved by this researcher.

1. Is selecting a target and explicitly grouping/assigning a handwritten label and connector acceptable, or must inference be part of the required experience? If inference is required, what corrections/uncertainty interactions are acceptable?
2. May highlights/underlines/connectors change shape or split after wrapping, while handwriting retains its original form? Which marks must preserve literal appearance, and which may use a semantic rendering?
3. May handwriting move into a dedicated page lane or trigger extra whitespace, and may it change size? If there is no legible placement, what visible page behavior is acceptable? This must be decided without silently retreating to marker-only reading.
4. For marks spanning pages or multiple targets, are continuation segments, duplication, or a spanning view acceptable? What must editing such a mark mean?
5. What is the actual OS/device baseline? Public selection/identity helpers introduced in 27 change the grouping implementation options; exact SDK availability and old-ink fidelity still require testing.

The report has no research-blocking dependency on these answers. They block a settled product promise and constrain the next experiment. Finger behavior while Ink ON is settled in the [interaction resolution](https://github.com/mooneeb/bookorbit/issues/6#issuecomment-6289693465); the renderer proof must preserve that input contract.

## Audit reproducibility and limits

Only first-party specifications, author-published research, Apple documentation/sample code, and renderer source were used as authority. Retrieved source/API files were inspected as text in temporary storage; no downloaded sample or dependency code was executed. Apple's API pages sometimes provide only a JavaScript shell, so their first-party DocC JSON was used for declarations/availability.

Selected Apple documentation payloads are pinned by SHA-256 below. The prefix is `https://developer.apple.com/tutorials/data/documentation/pencilkit/`; append the listed relative path. These checksums identify what was read, not an immutable Apple hosting promise.

- [`pkdrawing-swift.struct/strokes.json`](https://developer.apple.com/tutorials/data/documentation/pencilkit/pkdrawing-swift.struct/strokes.json): `0eb9341dbcbb51e4733a54255075cbf6c98a88dcc1875e76120c385940a0f1e9`.
- [`pkstroke-swift.struct.json`](https://developer.apple.com/tutorials/data/documentation/pencilkit/pkstroke-swift.struct.json): `9c58abdabe74fc2bec45d773c766a86e3492ce48f062cda2fedcf42679ac26b0`.
- [`pkstroke-swift.struct/transform.json`](https://developer.apple.com/tutorials/data/documentation/pencilkit/pkstroke-swift.struct/transform.json): `db292164b549e77f477ab4de0b7a670ddb085dea9632eb9adb6164f417647be5`.
- [`pkstroke-swift.struct/id.json`](https://developer.apple.com/tutorials/data/documentation/pencilkit/pkstroke-swift.struct/id.json): `3b436d159e5db1bfb7d23364f205c37c6e992ef0b8de0834404ad7fe1277bcdf`.
- [`pkcanvasview/selection.json`](https://developer.apple.com/tutorials/data/documentation/pencilkit/pkcanvasview/selection.json): `46f5ac41c18ecb763b4aa6ab5795e6335368998bfd412a85f47b48a1f7ccdb00`.
- [`pkstroke-swift.struct/rendergroupid.json`](https://developer.apple.com/tutorials/data/documentation/pencilkit/pkstroke-swift.struct/rendergroupid.json): `fc467926c4301ff544589be4b254e0095ca07f926050ee40dde9089f089e8cd6`.
- [`pkstrokerecognizer.json`](https://developer.apple.com/tutorials/data/documentation/pencilkit/pkstrokerecognizer.json): `cc51d186286b9eea1c100bee93b554bfea7dbaa8964bee9e184e762442b9ecfa`.

There is no BookOrbit renderer fixture, iPad/Pencil test, automatic-intent accuracy measurement, benchmark, or proof of native/web visual parity in this audit. No private server/library, production code, dependencies, migrations, map/ledger, assignment, or other issue was changed. Current research status is recorded in [Establish text-anchored EPUB ink reflow feasibility](https://github.com/mooneeb/bookorbit/issues/16).

Documentation verification: Prettier 3.9.9 write/check, `git diff --check`, and `git diff --cached --check` passed. All 53 reference-link definitions are used, with no undefined references; prohibited-text checks passed. The existing formatter in the main checkout was used without installing dependencies. Application tests, build, and ESLint were skipped because only this Markdown report changed.

[prior-engines]: https://github.com/mooneeb/bookorbit/blob/2060eb43cceb1c1d47394a6668071eb4e9f4333d/docs/wayfinder/bookorbit-ipad-reader/research/reader-engine-feasibility.md
[prior-pencil]: https://github.com/mooneeb/bookorbit/blob/2060eb43cceb1c1d47394a6668071eb4e9f4333d/docs/wayfinder/bookorbit-ipad-reader/research/native-pencil-capabilities.md
[agents]: https://github.com/mooneeb/bookorbit/blob/ce118e3890ea8c9019857cb7556552cdc9992f8e/AGENTS.md
[prototype]: https://github.com/mooneeb/bookorbit/issues/17
[epub-layout]: https://www.w3.org/TR/2026/REC-epub-33-20260113/#sec-layout
[cfi]: https://idpf.org/epub/linking/cfi/epub-cfi-20170105.html
[annotation-selectors]: https://www.w3.org/TR/2017/REC-annotation-model-20170223/#selectors
[cssom-source]: https://github.com/w3c/csswg-drafts/blob/e13fe879106ad83dd89faecab5edad868c7efbfa/cssom-view-1/Overview.bs
[cssom-range]: https://drafts.csswg.org/cssom-view/#dom-range-getclientrects
[cssom-caret]: https://drafts.csswg.org/cssom-view/#dom-document-caretpositionfrompoint
[dom-source]: https://github.com/whatwg/dom/blob/8b515270f1644349b79a0a949cb6e121856d0fd9/dom.bs
[dom-range]: https://dom.spec.whatwg.org/#ranges
[readium-html]: https://readium.org/architecture/models/locators/extensions/html.html
[readium-release]: https://github.com/readium/swift-toolkit/releases/tag/3.11.1
[readium-selection]: https://github.com/readium/swift-toolkit/blob/9a8c094b72245fd27043c9d298005e5c78b32a01/Sources/Navigator/EPUB/Scripts/src/selection.js#L17
[readium-utils]: https://github.com/readium/swift-toolkit/blob/9a8c094b72245fd27043c9d298005e5c78b32a01/Sources/Navigator/EPUB/Scripts/src/utils.js#L295
[readium-matcher]: https://github.com/readium/swift-toolkit/blob/9a8c094b72245fd27043c9d298005e5c78b32a01/Sources/Navigator/EPUB/Scripts/src/vendor/hypothesis/anchoring/match-quote.ts#L72
[readium-template]: https://github.com/readium/swift-toolkit/blob/9a8c094b72245fd27043c9d298005e5c78b32a01/Sources/Navigator/EPUB/HTMLDecorationTemplate.swift#L11
[readium-decorator]: https://github.com/readium/swift-toolkit/blob/9a8c094b72245fd27043c9d298005e5c78b32a01/Sources/Navigator/EPUB/Scripts/src/decorator.js#L203
[readium-rect]: https://github.com/readium/swift-toolkit/blob/9a8c094b72245fd27043c9d298005e5c78b32a01/Sources/Navigator/EPUB/Scripts/src/rect.js#L45
[readium-navigator]: https://github.com/readium/swift-toolkit/blob/9a8c094b72245fd27043c9d298005e5c78b32a01/Sources/Navigator/EPUB/EPUBNavigatorViewController.swift#L929
[bo-view]: https://github.com/mooneeb/bookorbit/blob/ce118e3890ea8c9019857cb7556552cdc9992f8e/client/public/assets/foliate/view.js#L566
[bo-overlayer]: https://github.com/mooneeb/bookorbit/blob/ce118e3890ea8c9019857cb7556552cdc9992f8e/client/public/assets/foliate/overlayer.js#L19
[bo-cfi]: https://github.com/mooneeb/bookorbit/blob/ce118e3890ea8c9019857cb7556552cdc9992f8e/client/public/assets/foliate/epubcfi.js#L296
[bo-paginator]: https://github.com/mooneeb/bookorbit/blob/ce118e3890ea8c9019857cb7556552cdc9992f8e/client/public/assets/foliate/paginator.js#L243
[foliate-view]: https://github.com/johnfactotum/foliate-js/blob/78914aef4466eb960965702401634c2cb348e9b1/view.js#L368
[foliate-overlayer]: https://github.com/johnfactotum/foliate-js/blob/78914aef4466eb960965702401634c2cb348e9b1/overlayer.js#L18
[foliate-readme]: https://github.com/johnfactotum/foliate-js/blob/78914aef4466eb960965702401634c2cb348e9b1/README.md
[pk-save]: https://developer.apple.com/documentation/pencilkit/pkdrawing-swift.struct/datarepresentation()
[pk-load]: https://developer.apple.com/documentation/pencilkit/pkdrawing-swift.struct/init(data:)
[pk-strokes]: https://developer.apple.com/documentation/pencilkit/pkdrawing-swift.struct/strokes
[pk-stroke]: https://developer.apple.com/documentation/pencilkit/pkstroke-swift.struct
[pk-transform]: https://developer.apple.com/documentation/pencilkit/pkstroke-swift.struct/transform
[pk-drawing-transform]: https://developer.apple.com/documentation/pencilkit/pkdrawing-swift.struct/transformed(using:)
[pk-path]: https://developer.apple.com/documentation/pencilkit/pkstrokepath-swift.struct
[pk-point]: https://developer.apple.com/documentation/pencilkit/pkstrokepoint-swift.struct
[pk-mask-ranges]: https://developer.apple.com/documentation/pencilkit/pkstroke-swift.struct/maskedpathranges
[pk-session]: https://developer.apple.com/videos/play/wwdc2020/10148/
[pk-enabled]: https://developer.apple.com/documentation/pencilkit/pkcanvasview/isdrawingenabled
[pk-id]: https://developer.apple.com/documentation/pencilkit/pkstroke-swift.struct/id
[pk-selection]: https://developer.apple.com/documentation/pencilkit/pkcanvasview/selection
[pk-render-group]: https://developer.apple.com/documentation/pencilkit/pkstroke-swift.struct/rendergroupid
[pk-substroke]: https://developer.apple.com/documentation/pencilkit/pkstroke-swift.struct/substroke(range:)
[pk-render-state]: https://developer.apple.com/documentation/pencilkit/pkstroke-swift.struct/renderstate-swift.struct
[pk-render-guide]: https://developer.apple.com/documentation/pencilkit/controlling-stroke-rendering-for-animation-and-editing
[pk-recognizer]: https://developer.apple.com/documentation/pencilkit/pkstrokerecognizer
[pk-recognition-session]: https://developer.apple.com/videos/play/wwdc2026/203/
[pk-sample]: https://developer.apple.com/documentation/pencilkit/inspecting-modifying-and-constructing-pencilkit-drawings
[pk-sample-zip]: https://docs-assets.developer.apple.com/published/9ab4eccb5c46/InspectingModifyingAndConstructingPencilKitDrawings.zip
[pk-change]: https://developer.apple.com/documentation/pencilkit/pkcanvasviewdelegate/canvasviewdrawingdidchange(_:)
[pk-compatibility]: https://developer.apple.com/documentation/pencilkit/supporting-backward-compatibility-for-ink-types
[reflow-paper]: https://www.moscovich.net/papers/reflowchi03.pdf
[reflow-author]: https://www.moscovich.net/article/research/
