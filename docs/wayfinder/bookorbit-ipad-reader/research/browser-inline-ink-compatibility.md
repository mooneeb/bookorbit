# Native-to-browser inline ink compatibility

Research date: **2026-10-20**. Primary-source investigation for [Establish native-to-browser inline ink compatibility, #18](https://github.com/mooneeb/bookorbit/issues/18), under the [iPad reader Wayfinder map](https://github.com/mooneeb/bookorbit/issues/1). Application source is pinned to **`ce118e3890ea8c9019857cb7556552cdc9992f8e`**. This is planning evidence, not an implementation, schema, renderer selection, or device-compatibility certification.

## Finding

**Public primitives support browser-readable ink derivatives and direct overlays in both existing readers. They do not establish end-to-end native ink compatibility.** Preserve the native editable drawing separately. PencilKit supplies serialization, stroke inspection and native rendering; Foliate supplies current text ranges and SVG drawing callbacks; EmbedPDF supplies composed page layers and coordinate transforms. No documented Apple browser decoder or built-in complete drawing-to-SVG exporter was established. [PencilKit drawing surface][pk-drawing], [Foliate annotation path][bo-view], [PDF page composition][bo-pdf-viewport].

**PDF has a bounded coordinate-and-appearance compatibility experiment. EPUB additionally has an unresolved meaning-and-placement problem.** A transparent image or vector path can be placed on the current reading page, but an original page-sized overlay cannot follow independent changes to line wrapping, pagination, and handwritten-label placement. The useful highlight, arrow and handwritten important example needs relationships and fresh browser geometry, not merely an exported picture. The previous [text-anchored ink investigation][prior-reflow] establishes the distinction; it does not validate an automatic interpretation algorithm or approve explicit grouping as an authoring requirement.

### Contract carried into this research

The [accepted browser decision][browser-decision] requires page ink directly on the current EPUB/PDF reading page on MacBook and Android. Marker-plus-preview is insufficient. Separate passage-linked notes retain open/close behavior. Both the existing Annotations hub and per-book Highlights list must show iPad notes; typed text, including Scribble-entered text, remains browser-editable; any note can be recoverably trashed/restored; browser stroke editing is excluded. Preserve navigation with visible ink.

The same decision requires an online visible browser to update without reload within 10 seconds after server acceptance of the complete note and required assets, refetch on tab return, and preserve unsaved browser text. This report identifies rendering implications only. Conflict resolution, lifecycle and transport remain separate decisions. The [accepted Pencil interaction][interaction-decision] keeps ink visible with writing ON or OFF: ON assigns Pencil to writing and finger to navigation; OFF lets both navigate.

Source replacement is distinct from reflow of unchanged content: retain original annotated excerpt/context and do not silently move annotations to a different or uncertain edition. Retaining every earlier edition in full is not required. All candidates must preserve the repository's user ownership, backend access control and bounded-work requirements. [Browser decision][browser-decision], [project rules][agents].

## Evidence boundary and reproducibility

- Read the repository `AGENTS.md`, `docs/COMMIT_GUIDELINES.md` and the parent's tracker instructions. GitHub issues/comments were read only. Existing research at planning commit `61bf7f97ce25daed6c86e1bc98e4c0921465a219` supplied context; application claims below were checked against the pinned source.
- Inspected BookOrbit's vendored Foliate files and first-party Foliate-js commit **`78914aef4466eb960965702401634c2cb348e9b1`**. Upstream is comparative evidence; BookOrbit's modified copy is the integration authority. [Pinned upstream view][foliate-view], [upstream overlayer][foliate-overlayer], [BookOrbit copy][bo-view].
- Inspected published **EmbedPDF 2.15.1** `models`, `plugin-annotation`, `plugin-rotate`, `plugin-scroll`, `core`, `engines` and `pdfium` artifacts, including declarations and embedded `sourcesContent` from source maps. All seven downloaded tarball SHA-512 values matched their registry integrity and entries in BookOrbit's lockfile. Repository patches to core, engines, scroll and zoom remain part of the actual runtime. [Package pins][bo-packages], [lockfile][bo-lock], [patch directory][bo-patches].
- Apple documentation was read with its public DocC JSON, including per-symbol platform metadata, where HTML required JavaScript. These pages are mutable and were checked on the research date. Metadata is not a compilation against the intended SDK.
- No native Swift source exists in this audited application baseline. No iPad drawing was captured, archive decoded, derivative rendered, or browser/device experiment executed here. Actual Mac browser/macOS, Android browser/OS and intended iPadOS are still unknown. No deployed version of `books.mooneeb.dev` is inferred. No private books, home server, production changes or long-lived prototype server were used.

## PencilKit originals, inspection and export

### Confirmed public primitives

| Primitive             | Verified availability and behavior                                                                                                                                                                                                                                                                        | Compatibility implication                                                                                                                                                                      |
| --------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Editable archive      | `PKDrawing.dataRepresentation()` and throwing `init(data:)` persist and restore drawing content from iPadOS 13. [Save][pk-save], [restore][pk-restore].                                                                                                                                                   | Keep the original archive authoritative for native editing; an image is a derivative. Neither API documents a portable archive grammar.                                                        |
| Stroke model          | Stroke inspection/construction, `PKStroke`, `PKStrokePath`, `PKStrokePoint` and per-stroke transforms are available from iPadOS 14. Whole-drawing affine transforms date to iPadOS 13. [Strokes][pk-strokes], [stroke][pk-stroke], [path][pk-path], [point][pk-point], [drawing transform][pk-transform]. | A native exporter can inspect and partition assigned strokes and transform copies. These APIs do not attach ink to EPUB text.                                                                  |
| Native raster         | iPadOS `image(from:scale:)` returns `UIImage` from a drawing-space crop at a supplied scale, from iPadOS 13. `UIImage.pngData()` produces PNG data and can fail. The distinct macOS overload returns `NSImage`. [iPad image][pk-image], [PNG][png], [macOS image][pk-mac-image].                          | Native-to-PNG is a documented export chain. Native macOS rendering does not make that API available inside a Mac browser. Transparency, appearance and crop padding need fixture verification. |
| Graphics context      | Async `draw(in:frame:from:darkUserInterfaceStyle:)`, from iPadOS 26, maps a source drawing rectangle into a destination `CGContext` frame with an appearance flag. [Context rendering][pk-context].                                                                                                       | Another native rendering route. A context accepting PDF output does not establish that every ink becomes a portable vector path or SVG.                                                        |
| Content compatibility | `requiredContentVersion` and content limits are available from iPadOS 17. Newer inks can make an archive fail to load on older systems; Apple describes fallback or tool restriction strategies. [Compatibility][pk-compat], [required version][pk-required].                                             | Archive readability and derivative readability are different checks. A browser image cannot repair an unsupported editable archive. No tool restriction is selected here.                      |

Apple also supplies native macOS versions of drawing/stroke APIs; the table gives iPad floors relevant to authoring, not a claim that PencilKit exists only on iPad. [Drawing platforms][pk-drawing], [stroke platforms][pk-stroke].

### A path is not a complete appearance

PencilKit paths use cubic B-spline control points. Connecting those points directly does not reconstruct the drawn curve; use on-curve interpolation when deriving sampled geometry. A point's size can be nonsquare, its azimuth affects orientation, and stored force is not itself the rendered width. Apple's WWDC20 explanation also notes lossy point storage. [Data-model explanation][pk-session], [on-curve interpolation][pk-interpolate].

Point opacity is documented as **0-2**, multiplying ink opacity. It cannot simply be copied into a browser alpha field expecting 0-1. Strokes also carry ink type/color, affine transform, rendering bounds and masks; partial erasure can produce masked or independent pieces. Ignoring these can restore erased ink or shift/crop the visible mark. [Opacity][pk-opacity], [stroke properties][pk-stroke], [masked path ranges][pk-masked].

**Availability matters for newer tools and export conveniences:**

- Content version 3, from iPadOS 17.5, adds barrel-roll information; version 4, from iPadOS 26, includes Reed Pen. Version 2 covers the additional iPadOS 17 inks described in Apple's compatibility guidance. Test the actual allowed tools rather than assuming that pen, marker and pencil exhaust the catalog. [Version 3][pk-v3], [version 4][pk-v4], [older compatibility guidance][pk-compat].
- Apple's current catalog lists `PKStrokePath.bezierRepresentation` returning `CGPath`, and the Bézier-path initializer, with **27.0** platform metadata. The associated article describes exporting curve shape plus separately retained point attributes for native reconstruction. That is real documented Bézier interoperability; it is **not** complete drawing-to-SVG export, archive decoding in JavaScript, or an older-iPad API. [Bézier property][pk-bezier], [import/export article][pk-bezier-guide].
- `PKStroke.id`, `renderGroupID`, `renderState` and `substroke(range:)` likewise have 27.0 metadata in the inspected catalog. Apple's rendering article describes grain state and wet-ink blending among compatible strokes. Rendering groups describe compositing, not semantic labels or text anchors. No 27.0 API is assumed available on the intended device. [Stroke ID][pk-id], [render group][pk-render-group], [render state][pk-render-state], [substroke][pk-substroke], [rendering article][pk-render-guide].

**Inference:** a custom SVG/Canvas exporter could approximate selected inks using interpolated points, variable-width filled outlines, per-point appearance and clipping. Constant-width polylines lose information. Reconstructing textured pencil/crayon, watercolor/marker overlaps, tilt/roll, erasure and newer ink state is materially harder. Independently exporting small groups can change compositing between overlapping strokes even when each group looks correct alone. A native rendering of the same crop supplies a useful visual reference, not proof that a custom browser renderer matches PencilKit.

### What was not established

The reviewed drawing API lists archive save/load, images, transforms, strokes and context rendering. It does not document a full SVG exporter or an Apple JavaScript/WASM `PKDrawing` decoder. The newer Bézier surface does not change that conclusion. **This is a bounded documentation finding, not proof that no third-party reverse engineering exists.** No reverse-engineered archive format or dependency is proposed. The existing NestJS server's ability to store opaque bytes must not be mistaken for an ability to render them. [Drawing API][pk-drawing], [Bézier API][pk-bezier].

## Actual EPUB integration: Foliate

### Anchors and current fragments

The pinned `view.js` exposes `getCFI(index, range)`, `resolveCFI()` and `resolveNavigation()`. Annotation addition resolves the target resource and `Range`; when its overlayer exists, it emits `draw-annotation` with `draw`, `annotation`, `doc` and `range`. The supplied `draw` callback registers a renderer with that range. BookOrbit's wrapper already subscribes and draws semantic highlight, underline, strikethrough and squiggly SVG geometry. This is content-overlay infrastructure, not a preview card. [Vendored view][bo-view], [wrapper events][bo-foliate], [current drawing functions][bo-foliate-annotations].

An EPUB CFI identifies a publication position/range, not an enduring browser rectangle. A DOM `Range.getClientRects()` returns current fragment rectangles; wrapping can produce several fragments for one logical target. A union bounding box loses gaps and line identities. Quote/context selectors offer another way to describe target text, but require normalization and ambiguity handling; they do not supply drawing intent. [CFI 1.1][cfi], [CSSOM range geometry][cssom], [Web Annotation selectors][selectors].

If native authoring uses Readium, a Readium locator is not automatically a Foliate CFI. A compatible experiment must resolve the same source resource and exact text boundaries independently in the browser and validate the excerpt. DOM construction, text-node normalization, publisher CSS and injected styles can differ. The previous audit describes Readium's locator/selection seams; no tested cross-engine adapter exists here. [Readium locator specification][readium-locator], [native/web anchor research][prior-reflow], [Foliate CFI conversion][bo-cfi].

### Overlay coordinates and lifecycle

`Overlayer.add()` obtains the range's client rectangles and appends the custom SVG element returned by the callback. `redraw()` obtains fresh rectangles and replaces that element. The overlayer has `pointer-events: none`; its existing hit test uses target rectangles, not arbitrary stroke geometry. Therefore custom paths/images are mechanically plausible, but a handwritten label outside the range does not automatically gain correct hit testing. The browser can remain display-only. [BookOrbit overlayer][bo-overlayer], [upstream equivalent][foliate-overlayer].

These rectangles belong to the chapter iframe's viewport coordinate space. The paginator places the overlay in its own wrapper and adjusts offsets for columns, vertical writing and scrolled padding. BookOrbit separately adds iframe offsets when positioning an outer selection popup. **Inference:** place content-local derivatives through the matching overlay convention, or explicitly compose iframe, pagination, scroll and outer transforms. Do not add the popup's outer offset a second time inside the overlayer, or copy iPad screen points into it. [Paginator expansion][bo-paginator], [popup positioning][bo-foliate], [CSSOM coordinates][cssom].

The pinned paginator uses `ResizeObserver` and `document.fonts.ready` to expand/redraw; `setStyles()` can trigger another expansion. `getContents()` exposes the currently loaded reflowable chapter. The view emits `load`, `relocate` and `create-overlay`; BookOrbit currently re-adds stored annotations after load using a timer. These are useful lifecycle seams, not a universal completed-layout promise. [Paginator][bo-paginator], [view events][bo-view], [wrapper reload behavior][bo-foliate].

**Candidate integration work, unimplemented:** resolve only the active resource and bounded adjacent content; compute fresh fragments after fonts/layout settle; tag asynchronous results with document/layout generation; discard results for replaced chapters; update visible ink in one consistent generation. Fixed-layout EPUB uses another renderer and needs its own coordinate fixture if included. A single huge chapter still needs bounded annotation geometry and paint work even though its DOM is loaded. [Reflowable paginator][bo-paginator], [fixed-layout renderer][bo-fixed], [scale requirements][agents].

Font family/fallback, font size, line height, viewport, writing mode and pagination settings can differ between iPad and browser even with unchanged source bytes. The browser reader already changes these styles. **Inference:** matching settings is not sufficient evidence for matching line breaks; resolve against the browser's actual layout. Redrawing semantic highlight rectangles is simpler than moving arbitrary freehand ink. [Reader styles][bo-reader-state], [EPUB layout specification][epub-layout].

## Actual PDF integration: EmbedPDF/PDFium

### Page identity and coordinates

The shared application contract explicitly defines PDF annotation positions as **zero-based page index, unscaled points, top-left origin**, with a bounding rectangle and segment rectangles. `buildPdfAnnotationObject()` turns these into EmbedPDF text-markup objects; it does not carry native strokes. Native PDFKit documents page space with a lower-left origin. A generic `height - y` is insufficient when crop origin, intrinsic rotation, chosen display box or normalization differs. [Shared contract][bo-types], [existing converter][bo-pdf-render], [PDFKit conversion][pdfkit-convert].

The published engine's `src/lib/pdfium/engine.ts`, recovered from its source map, has explicit page/device conversion routines that account for crop-box origins, page rotation and normalized rotation. These are inspection evidence for the required distinctions, not a public bridge from any prospective iPad renderer. Preserve source PDF identity, page index, page boxes/dimensions, orientation and the drawing-to-page transform in fixtures. Test the eventual native engine against the application's coordinate convention. [Engines 2.15.1 artifact][embed-engines], [application engine patch][bo-engine-patch].

### Direct page layers and events

`PdfDocumentViewport.vue` composes `RenderLayer`, `TilingLayer`, `SearchLayer`, `SelectionLayer` and `AnnotationLayer` inside each `Scroller` page's `Rotate` component. A display-only SVG/raster/Canvas layer can be tested alongside those layers. It must use page-local coordinates and scale once. The published `Rotate` component combines page intrinsic rotation with document rotation and computes the CSS transform from scaled dimensions. An outside layer must reproduce that mapping correctly; nesting inside it avoids manually reproducing some transforms, but does not automatically scale arbitrary child geometry. [Application composition][bo-pdf-viewport], [Rotate 2.15.1 source map][embed-rotate-map].

The scroll capability exposes `getRectPositionForPage`, `onPageChange`, `onScroll`, `onLayoutChange` and state; rotation exposes `onRotateChange`. Scroller source subscribes by document ID and cleans up on replacement. The existing popup combines transformed page-local geometry with the actual page element's browser bounds because horizontal centering is not included in every scroll metric. Use this evidence when validating fit, spreads, resize and scroll alignment. [Scroll 2.15.1 source map][embed-scroll-map], [rotation source map][embed-rotate-map], [BookOrbit popup logic][bo-pdf-highlights].

BookOrbit configures one active PDF document, scrolling buffer size 3, tiling and zoom 0.25-4. These bound some active rendering, not all document memory: the PDF is currently fetched into an `ArrayBuffer`. Overlay work should follow mounted/visible pages and release page assets when unmounted. Do not turn this seam into a giant canvas covering every page or a full-library fetch. [Viewer setup][bo-pdf-reader], [Scroller][embed-scroll-map], [project scale rules][agents].

### Existing annotation plugin is not a PencilKit renderer

The plugin can display `PdfInkAnnoObject`, but the 2.15.1 model contains lists of point positions with one stroke width, opacity and color per annotation. Its Vue renderer emits `M`/`L` paths with round caps/joins. It does not encode PencilKit's per-point size, textured inks or masks. Splitting into many objects to approximate these is additional conversion, complexity and bounded-work risk, not native fidelity. [Models 2.15.1][embed-models], [ink renderer in published Vue source map][embed-annotation-map].

The application currently registers the annotation plugin with `autoCommit: false` and all annotations locked, uses database-derived IDs, and creates text-markup objects for rendering without feeding plugin edits into persistence. This is a useful precedent for a browser display projection. It is not an ink payload API, Trash implementation or final ownership choice. Read-only overlays must also leave page gestures and text selection usable. [Viewer configuration][bo-pdf-reader], [highlight orchestration][bo-pdf-highlights].

Apple's PDFKit example uses a PDF annotation appearance plus application-specific archived drawing data; optional burn-in is separate. This offers a PDF-specific derivative candidate: other renderers can display appearance without understanding editable PencilKit content. It still needs an actual PDFium appearance-rendering test, correct duplicate-layer handling and later decisions about user-scoped source files versus derived PDFs. A flattened PDF alone cannot be the editable source. [WWDC22 PDFKit example][pdfkit-session], [custom PDF graphics and appearances][pdfkit-graphics].

## Representation candidates, without a format decision

All candidates retain authoritative editable originals and enough original excerpt/context to recover the annotation's source association. The following are **engineering inferences to compare experimentally**, not selected contracts.

| Candidate                                                             | Direct inline use                                                                                                                                                                                                             | Principal limits                                                                                                                                                                                                                                                                 |
| --------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Native-rendered transparent raster crops                              | Browser can position an image on a PDF page or a bound EPUB label/mark group. Native generation is documented. [Image][pk-image], [PNG][png].                                                                                 | Captures native appearance at one crop/scale/appearance. Resolution, alpha edges and memory matter. A whole page crop cannot perform EPUB reflow; a crop containing source text would duplicate stale text over the current page. Separate crops can change overlap compositing. |
| Restricted SVG filled shapes/outlines                                 | Foliate's SVG seam and a PDF page SVG layer can place paths, clip them and transform bound groups. [Foliate overlayer][bo-overlayer], [SVG paths][svg-paths].                                                                 | Custom native conversion is required. A centerline is insufficient for variable width. Advanced texture, wet blending and erasure may diverge. SVG export is not supplied by the audited `PKDrawing` API.                                                                        |
| Bounded numeric geometry rendered with Canvas/SVG                     | App-generated finite paths can avoid accepting arbitrary uploaded markup and provide one controlled drawing vocabulary. [Canvas path primitives][canvas-paths].                                                               | Requires an exporter and renderer, appearance rules, versioning and sample/segment limits. Transferring point attributes does not reproduce Apple's renderer or infer semantic groups. No new dependency is selected.                                                            |
| Hybrid semantic highlight + native raster label + generated connector | Uses fresh EPUB range fragments; preserves handwriting's internal layout; permits endpoints to move independently. Could also be drawn on fixed PDF pages. [Range drawing][bo-foliate-annotations], [native image][pk-image]. | Changes original freehand appearance/arrow geometry if substituted. Needs known roles, bindings, endpoints, placement and cross-page behavior. It is not accepted merely because the three parts move together.                                                                  |
| EmbedPDF ink objects                                                  | Existing plugin draws fixed-page polylines, with locked display behavior available. [Model][embed-models], [renderer][embed-annotation-map].                                                                                  | Useful for deliberately simple vector derivatives, not general PencilKit fidelity; not an EPUB placement solution.                                                                                                                                                               |
| PDF annotation appearance/derived PDF                                 | Browser PDF renderer paints the page/annotation in normal reading. [PDFKit example][pdfkit-session].                                                                                                                          | PDF-only; potential file rewriting, duplicate rendering and source identity concerns. Ordinary separate transparent overlays can test coordinate compatibility without deciding document ownership.                                                                              |

A saved annotated-view image remains useful recovery/reference evidence and may supplement lists. It is not a substitute for current-page inline reading. Nor does translating/scaling a single page image establish text-following ink. [Browser contract][browser-decision].

## Information a compatible reflow candidate would need

This is a **logical experiment inventory**, not field names, database design, note identity or an approved interaction. Explicit authoring bindings are not settled product behavior. A researcher may supply ground-truth bindings to isolate layout mechanics in #17/#19, but must disclose them and cannot claim the real authoring problem is solved.

1. **Verified content target:** same publication/source revision and resource; exact intended text span with original quote/context; a resolver for each actual renderer; a distinguishable unresolved/ambiguous result. A range identifier alone does not identify the text when an edition changes. [CFI][cfi], [selectors][selectors].
2. **Stroke membership and roles:** which original strokes form the highlight, arrow and handwritten label; their local drawing space, original transforms, order and clipping/compositing relationships. Array order, proximity and PencilKit rendering groups are not proof of these semantic roles. Group identity after erasing, lasso, undo/redo or archive reopen needs validation. [Stroke model][pk-stroke], [native rendering groups][pk-render-guide].
3. **Attachment meaning:** which current text boundary/fragment the arrow points to; which point on the handwritten label it leaves; two content anchors for a text-to-text connector. Direction, endpoints and arrowhead membership are not implied by an arbitrary freehand path. A preferred label side/offset can inform placement, but is not a guaranteed free-space solution.
4. **Fresh layout result:** target fragment rectangles and their resource/page/column identities; source-to-overlay transform; label placement; connector geometry; clipping and layout generation. Browser CSS pixels, native drawing points and PDF page points must stay distinguishable. Recompute from the originals after layout changes rather than accumulating transforms. [CSSOM][cssom], [Foliate paginator][bo-paginator], [PDF contract][bo-types].
5. **Declared shape-change behavior:** semantic highlight fragments versus a literal irregular highlighter stroke; translation versus scaling/warping handwriting; original arrow deformation versus generated shaft/head. All change what the user sees and need a verdict. There is no approved blanket transformation rule.

**Actual unresolved blockers:** there is no accepted way to derive all these relationships from unconstrained drawing; explicit groups/bindings have not been accepted as an authoring burden; no accepted collision or cross-page connector behavior exists. The same target can gain multiple line fragments, several labels can exhaust whitespace, and independently anchored endpoints can land on different pages. Nearest-word assignment, silent shrinking, hiding ink or replacing it with a marker cannot be called a compatible solution. A source-replacement mismatch must retain original context for reviewed recovery rather than silently remap. These remain product/renderer experiments, consistent with the [earlier feasibility limits][prior-reflow] and [browser requirement][browser-decision].

## Authorization, asset safety and bounded integration

These are requirements for evaluating candidates, not a new sync/storage specification.

- Treat originals, derivatives, excerpt/context and any generated annotated PDF as user-owned data. Every read, upload, regeneration, trash/restore and asset fetch must verify ownership and applicable backend permission, including direct asset URLs. Opaque IDs or hashes are not authorization. Apply the repository's documented superuser-bypass pattern explicitly where appropriate. [Project rules][agents], [OWASP authorization guidance][auth-guidance].
- Do not rely on a browser-only restriction for iPad-only stroke editing. An uploaded derivative must not become an executable document. For SVG, generated allowlisted elements/attributes or strictly validated numeric geometry are easier to constrain than arbitrary markup. Exclude scripts, event handlers, `foreignObject`, external URLs and uncontrolled CSS/resources; validate finite coordinates, counts and dimensions. SVG image mode has restrictions that inline SVG does not inherit automatically. [SVG processing modes][svg-conformance], [upload guidance][upload-guidance].
- Validate actual content and decoded pixel dimensions, not only filename/MIME. Bound original bytes, derivative bytes, decompressed pixels, path/point counts, crop sizes and export concurrency. A tiny compressed image can still require substantial decoded memory. If authenticated fetch produces a blob URL for display, release it when evicted and avoid embedding credentials in document markup or logged asset URLs. Authentication delivery remains an implementation choice. [Upload limits][upload-guidance], [object URL lifecycle][blob-urls], [application fetch helper][bo-api].
- Scope fetches and caches by user, source/book file and current content window; cap decoded asset memory and work per frame; cancel stale loads. Paginated note lists and page-window rendering solve different problems. Existing EPUB `useAnnotations` loads an unpaginated whole-book list; PDF fetches pages of 100 but accumulates loaded rows. Neither is a sufficient visible-ink retrieval contract for a very heavily annotated book. [EPUB note load][bo-epub-store], [PDF note load][bo-pdf-store], [scale rules][agents].
- A received note revision must not display against assets/geometry from a different revision. A visible update should invalidate the affected reader layer and relevant list rows while keeping an unsaved typed draft intact. Theme/reflow changes can require browser placement even when assets are unchanged. The existing hub, per-book list and readers are real surfaces to extend; their current text contract has no ink original/derivative fields. The 10-second behavior remains unimplemented and needs integration evidence, not a selected polling/push protocol here. [Shared contract][bo-types], [hub][bo-hub], [book list][bo-book-highlights], [accepted update contract][browser-decision].

### License constraints checked

Foliate-js at the inspected upstream commit is MIT; its README identifies separate zip.js and fflate licenses. The library is distinct from the Foliate desktop application. Preserve the relevant notices. [Pinned library license][foliate-license], [dependency notices][foliate-readme].

The inspected 2.15.1 published EmbedPDF package metadata says MIT; the inspected plugin/core/PDFium artifacts contain MIT notices, and PDFium carries its own BSD-style and bundled third-party notices in `LICENSE.pdfium`. Use the shipped versions' actual notices: the upstream repository's current licensing policy differs. No upgrade or full transitive WASM/font distribution audit was performed. [Annotation metadata][embed-annotation-meta], [core metadata][embed-core-meta], [PDFium artifact][embed-pdfium], [upstream licensing authority statement][embed-licensing].

BookOrbit's pinned application license and additional terms also apply to reused application material; Apple's SDK/API terms are a separate source of obligations. This report adds no dependency and makes no licensing decision about a future renderer or distribution. [Application license][bo-license], [additional terms][bo-terms], [Apple agreements][apple-terms].

## Small isolated fixture plan for #19

This is proposed work for [browser HITL validation, #19][browser-prototype], using native fixtures from [actual EPUB reflow proof, #17][native-prototype]. It is not an executed test suite or claim of device coverage. Do not replace missing native fixtures with hand-authored browser paths and call it native compatibility.

### Fixture package and comparison rules

Use self-authored/public-domain local publications only. Start with one short reflowable EPUB containing repeated useful occurrences, a target near a page break, and room for the decisive highlight/arrow/important example. Add one small two-page PDF with normal and offset crop boxes, asymmetric landmarks, and intrinsic rotation. Include a few overlapping pressure strokes, highlighter/marker passes, a partly erased stroke and an allowed newer ink. Keep the set small; extend only when a failure exposes a distinct case.

For each native fixture, retain original publication bytes/hash and source resource/page, the unmodified `PKDrawing` archive/hash, actual content version, native reference crops, export crop/scale/appearance/transform and any derivative bytes/hash. Retain separately supplied group/role/endpoint ground truth with provenance, including whether a tester assigned it manually. Archive bytes/hash can establish transport preservation; reopened native appearance and editing establish a different property. Re-saving need not produce byte-identical archives.

Record actual device/Pencil, iPadOS, Xcode/SDK, native engine/app revision, browser engine/version, OS, viewport/DPR, fonts and the exact patched web-reader revision. Use the actual MacBook and Android runtime once known; desktop emulation is preliminary evidence only. Unknown versions remain unknown until the installation decision. No hosted-server access or long-lived prototype restart is needed for an isolated local fixture harness.

### Decisive runs and evidence

1. **Original preservation:** export, store/transfer fixture bytes through an isolated harness, reopen on the authoring iPad, and edit/erase/undo existing ink. Compare original and transported archive hashes before reopening. Show ink visible with writing ON and OFF and finger navigation intact. A preview-only reopen fails this check.
2. **Native appearance to current browser page:** display each candidate derivative directly on the EPUB/PDF reading content, then compare with the native reference at matched geometry and multiple zoom/DPR settings. Inspect pressure taper, nib shape, opacity/overlap, erased gaps, edges and crop clipping on light/dark backgrounds. Report deviations per tool; do not use image-card screenshots as inline evidence.
3. **Real EPUB reflow:** load #17's actual native example with disclosed bindings into Foliate. Change font size, family/fallback, viewport and pagination enough to change wrapping and page assignment. Show useful remains the intended occurrence and the handwriting/arrow retain their relationship. Capture current fragments and transforms. Repeat near a page boundary; report cross-page/collision failure explicitly. A controlled prebound success proves only placement under those assumptions; obtain the live authoring/appearance verdict separately.
4. **PDF geometry:** place marks at asymmetric content landmarks; test zoom minimum/maximum, fit width/page, 0/90/180/270 viewer rotation, intrinsically rotated pages, offset crop box, scroll and resize. Capture coordinate residuals in page points as well as screen images. Set a perceptual alignment tolerance with the user instead of inventing a certified threshold. Watch for double rotation/scaling and stale layers after unmount/remount.
5. **Bounded work and navigation:** use a locally generated many-page/annotation fixture without expanding the human review set. Record visible/mounted pages, active assets, decoded pixels, geometry count, requests and peak memory while moving around. Evict old content; verify navigation and text selection through ink. Test a large single EPUB resource separately from many small chapters. A small fixture success is not a large-library performance result.
6. **Surface and refresh integration:** once an agreed isolated note/asset contract exists, show the same native note inline, in Annotations and in per-book Highlights; typed edits and recoverable trash/restore should update those views. Inject accepted complete revisions while the reader is open and visible, measure acceptance-to-display against 10 seconds, refetch on return, and retain an unsaved browser text draft. A mock revision event verifies only UI invalidation, not real server/iPad delivery or the later conflict protocol. Check two users cannot fetch each other's originals/derivatives even with known IDs.
7. **Source change safeguard:** replace fixture content/edition while preserving an apparent matching word/location. Confirm no silent attachment to new content and that original excerpt/context remains recoverable. Full historical-edition retention is not an acceptance condition.

Stop claiming success at the first missing prerequisite: absent actual native fixture, unresolvable cross-engine target, unsupported ink export, unacceptable transformation, unresolved collision/cross-page placement, or unknown device runtime. A user verdict on #19 is still required after technical measurements. Keep working evidence separate from a final note schema, ownership model, native stack or sync decision.

## Status handed back to the parent

**Confirmed:** public native serialization/inspection/rendering; newer, version-gated Bézier interoperability; concrete direct-overlay seams in both pinned web readers; existing text-note surfaces; and current absence of ink fields in the shared contract.

**Reasonable candidates:** native-rendered crops, controlled vector/numeric derivatives, a hybrid of bound semantic marks and preserved handwriting, and PDF-specific appearances. None has measured fidelity or end-to-end compatibility here.

**Still blocked on experiments/decisions:** unconstrained freehand intent and acceptable authoring burden; cross-engine target resolution; transformation, collision and cross-page behavior; crop/rotation/zoom fidelity; actual device/browser versions and native archive round trips. #17 supplies native reflow evidence; #19 supplies browser and human validation. #18's research can inform those gates without declaring them passed.

**Verification:** documentation-only change. Existing repository Prettier formatting/check and staged diff whitespace checks passed; all 85 citation labels resolve to definitions, and pinned application file targets exist. Application lint, build and unit/device tests do not validate this report and are not run. No production code, schema, dependency, migration, issue/map mutation or PR is part of this work.

[agents]: https://github.com/mooneeb/bookorbit/blob/ce118e3890ea8c9019857cb7556552cdc9992f8e/AGENTS.md
[browser-decision]: https://github.com/mooneeb/bookorbit/issues/7#issuecomment-6290292381
[interaction-decision]: https://github.com/mooneeb/bookorbit/issues/6#issuecomment-6289693465
[prior-reflow]: https://github.com/mooneeb/bookorbit/blob/61bf7f97ce25daed6c86e1bc98e4c0921465a219/docs/wayfinder/bookorbit-ipad-reader/research/text-anchored-ink-reflow.md
[native-prototype]: https://github.com/mooneeb/bookorbit/issues/17
[browser-prototype]: https://github.com/mooneeb/bookorbit/issues/19
[pk-drawing]: https://developer.apple.com/documentation/pencilkit/pkdrawing-swift.struct
[pk-save]: https://developer.apple.com/documentation/pencilkit/pkdrawing-swift.struct/datarepresentation()
[pk-restore]: https://developer.apple.com/documentation/pencilkit/pkdrawing-swift.struct/init(data:)
[pk-strokes]: https://developer.apple.com/documentation/pencilkit/pkdrawing-swift.struct/strokes
[pk-stroke]: https://developer.apple.com/documentation/pencilkit/pkstroke-swift.struct
[pk-path]: https://developer.apple.com/documentation/pencilkit/pkstrokepath-swift.struct
[pk-point]: https://developer.apple.com/documentation/pencilkit/pkstrokepoint-swift.struct
[pk-transform]: https://developer.apple.com/documentation/pencilkit/pkdrawing-swift.struct/transformed(using:)
[pk-image]: https://developer.apple.com/documentation/pencilkit/pkdrawing-swift.struct/image(from:scale:)-220d0
[pk-mac-image]: https://developer.apple.com/documentation/pencilkit/pkdrawing-swift.struct/image(from:scale:)-6p3zc
[png]: https://developer.apple.com/documentation/uikit/uiimage/pngdata()
[pk-context]: https://developer.apple.com/documentation/pencilkit/pkdrawing-swift.struct/draw(in:frame:from:darkuserinterfacestyle:)
[pk-compat]: https://developer.apple.com/documentation/pencilkit/supporting-backward-compatibility-for-ink-types
[pk-required]: https://developer.apple.com/documentation/pencilkit/pkdrawing-swift.struct/requiredcontentversion
[pk-session]: https://developer.apple.com/videos/play/wwdc2020/10148/
[pk-interpolate]: https://developer.apple.com/documentation/pencilkit/pkstrokepath-swift.struct/interpolatedpoints(in:by:)
[pk-opacity]: https://developer.apple.com/documentation/pencilkit/pkstrokepoint-swift.struct/opacity
[pk-masked]: https://developer.apple.com/documentation/pencilkit/pkstroke-swift.struct/maskedpathranges
[pk-v3]: https://developer.apple.com/documentation/pencilkit/pkcontentversion/version3
[pk-v4]: https://developer.apple.com/documentation/pencilkit/pkcontentversion/version4
[pk-bezier]: https://developer.apple.com/documentation/pencilkit/pkstrokepath-swift.struct/bezierrepresentation
[pk-bezier-guide]: https://developer.apple.com/documentation/pencilkit/importing-external-drawing-data-into-pencilkit
[pk-id]: https://developer.apple.com/documentation/pencilkit/pkstroke-swift.struct/id
[pk-render-group]: https://developer.apple.com/documentation/pencilkit/pkstroke-swift.struct/rendergroupid
[pk-render-state]: https://developer.apple.com/documentation/pencilkit/pkstroke-swift.struct/renderstate-swift.property
[pk-substroke]: https://developer.apple.com/documentation/pencilkit/pkstroke-swift.struct/substroke(range:)
[pk-render-guide]: https://developer.apple.com/documentation/pencilkit/controlling-stroke-rendering-for-animation-and-editing
[pdfkit-convert]: https://developer.apple.com/documentation/pdfkit/pdfview/convert(_:from:)-4evlx
[pdfkit-session]: https://developer.apple.com/videos/play/wwdc2022/10089/
[pdfkit-graphics]: https://developer.apple.com/documentation/pdfkit/adding-custom-graphics-to-a-pdf
[readium-locator]: https://readium.org/architecture/models/locators/extensions/html.html
[cfi]: https://idpf.org/epub/linking/cfi/epub-cfi-20170105.html
[selectors]: https://www.w3.org/TR/2017/REC-annotation-model-20170223/#selectors
[cssom]: https://github.com/w3c/csswg-drafts/blob/e13fe879106ad83dd89faecab5edad868c7efbfa/cssom-view-1/Overview.bs
[epub-layout]: https://www.w3.org/TR/2026/REC-epub-33-20260113/#sec-layout
[svg-paths]: https://www.w3.org/TR/SVG2/paths.html
[svg-conformance]: https://www.w3.org/TR/SVG2/conform.html#secure-static-mode
[canvas-paths]: https://html.spec.whatwg.org/multipage/canvas.html#canvaspath
[blob-urls]: https://www.w3.org/TR/FileAPI/#dfn-revokeObjectURL
[upload-guidance]: https://cheatsheetseries.owasp.org/cheatsheets/File_Upload_Cheat_Sheet.html
[auth-guidance]: https://cheatsheetseries.owasp.org/cheatsheets/Authorization_Cheat_Sheet.html
[foliate-view]: https://github.com/johnfactotum/foliate-js/blob/78914aef4466eb960965702401634c2cb348e9b1/view.js#L368
[foliate-overlayer]: https://github.com/johnfactotum/foliate-js/blob/78914aef4466eb960965702401634c2cb348e9b1/overlayer.js#L18
[foliate-readme]: https://github.com/johnfactotum/foliate-js/blob/78914aef4466eb960965702401634c2cb348e9b1/README.md#license
[foliate-license]: https://github.com/johnfactotum/foliate-js/blob/78914aef4466eb960965702401634c2cb348e9b1/LICENSE
[bo-view]: https://github.com/mooneeb/bookorbit/blob/ce118e3890ea8c9019857cb7556552cdc9992f8e/client/public/assets/foliate/view.js#L500
[bo-overlayer]: https://github.com/mooneeb/bookorbit/blob/ce118e3890ea8c9019857cb7556552cdc9992f8e/client/public/assets/foliate/overlayer.js#L19
[bo-paginator]: https://github.com/mooneeb/bookorbit/blob/ce118e3890ea8c9019857cb7556552cdc9992f8e/client/public/assets/foliate/paginator.js#L243
[bo-fixed]: https://github.com/mooneeb/bookorbit/blob/ce118e3890ea8c9019857cb7556552cdc9992f8e/client/public/assets/foliate/fixed-layout.js
[bo-cfi]: https://github.com/mooneeb/bookorbit/blob/ce118e3890ea8c9019857cb7556552cdc9992f8e/client/public/assets/foliate/epubcfi.js
[bo-foliate]: https://github.com/mooneeb/bookorbit/blob/ce118e3890ea8c9019857cb7556552cdc9992f8e/client/src/features/reader/epub/composables/useFoliate.ts#L196
[bo-foliate-annotations]: https://github.com/mooneeb/bookorbit/blob/ce118e3890ea8c9019857cb7556552cdc9992f8e/client/src/features/reader/epub/composables/useFoliateAnnotations.ts
[bo-reader-state]: https://github.com/mooneeb/bookorbit/blob/ce118e3890ea8c9019857cb7556552cdc9992f8e/client/src/features/reader/epub/composables/useReaderState.ts
[bo-pdf-viewport]: https://github.com/mooneeb/bookorbit/blob/ce118e3890ea8c9019857cb7556552cdc9992f8e/client/src/features/reader/pdf-v4/components/PdfDocumentViewport.vue
[bo-pdf-reader]: https://github.com/mooneeb/bookorbit/blob/ce118e3890ea8c9019857cb7556552cdc9992f8e/client/src/features/reader/pdf-v4/PdfV4ReaderView.vue#L89
[bo-pdf-render]: https://github.com/mooneeb/bookorbit/blob/ce118e3890ea8c9019857cb7556552cdc9992f8e/client/src/features/reader/pdf-v4/lib/pdf-annotation-render.ts
[bo-pdf-highlights]: https://github.com/mooneeb/bookorbit/blob/ce118e3890ea8c9019857cb7556552cdc9992f8e/client/src/features/reader/pdf-v4/composables/usePdfHighlights.ts
[bo-pdf-store]: https://github.com/mooneeb/bookorbit/blob/ce118e3890ea8c9019857cb7556552cdc9992f8e/client/src/features/reader/pdf-v4/composables/usePdfAnnotations.ts
[bo-epub-store]: https://github.com/mooneeb/bookorbit/blob/ce118e3890ea8c9019857cb7556552cdc9992f8e/client/src/features/reader/epub/composables/useAnnotations.ts
[bo-types]: https://github.com/mooneeb/bookorbit/blob/ce118e3890ea8c9019857cb7556552cdc9992f8e/packages/types/src/annotation.ts#L85
[bo-hub]: https://github.com/mooneeb/bookorbit/blob/ce118e3890ea8c9019857cb7556552cdc9992f8e/client/src/features/annotations/views/AnnotationsHubView.vue
[bo-book-highlights]: https://github.com/mooneeb/bookorbit/blob/ce118e3890ea8c9019857cb7556552cdc9992f8e/client/src/features/book/composables/useBookHighlights.ts
[bo-api]: https://github.com/mooneeb/bookorbit/blob/ce118e3890ea8c9019857cb7556552cdc9992f8e/client/src/lib/api.ts
[bo-packages]: https://github.com/mooneeb/bookorbit/blob/ce118e3890ea8c9019857cb7556552cdc9992f8e/client/package.json#L43
[bo-lock]: https://github.com/mooneeb/bookorbit/blob/ce118e3890ea8c9019857cb7556552cdc9992f8e/pnpm-lock.yaml
[bo-patches]: https://github.com/mooneeb/bookorbit/tree/ce118e3890ea8c9019857cb7556552cdc9992f8e/patches
[bo-engine-patch]: https://github.com/mooneeb/bookorbit/blob/ce118e3890ea8c9019857cb7556552cdc9992f8e/patches/%40embedpdf__engines%402.15.1.patch
[embed-models]: https://registry.npmjs.org/@embedpdf/models/-/models-2.15.1.tgz
[embed-engines]: https://registry.npmjs.org/@embedpdf/engines/-/engines-2.15.1.tgz
[embed-annotation-map]: https://unpkg.com/@embedpdf/plugin-annotation@2.15.1/dist/vue/index.js.map
[embed-rotate-map]: https://unpkg.com/@embedpdf/plugin-rotate@2.15.1/dist/vue/index.js.map
[embed-scroll-map]: https://unpkg.com/@embedpdf/plugin-scroll@2.15.1/dist/vue/index.js.map
[embed-annotation-meta]: https://registry.npmjs.org/@embedpdf/plugin-annotation/2.15.1
[embed-core-meta]: https://registry.npmjs.org/@embedpdf/core/2.15.1
[embed-pdfium]: https://registry.npmjs.org/@embedpdf/pdfium/-/pdfium-2.15.1.tgz
[embed-licensing]: https://github.com/embedpdf/embed-pdf-viewer/blob/176ec6daac51458c9e80733b9c92a66a3bc5e2d1/LICENSING.md#authority
[bo-license]: https://github.com/mooneeb/bookorbit/blob/ce118e3890ea8c9019857cb7556552cdc9992f8e/LICENSE
[bo-terms]: https://github.com/mooneeb/bookorbit/blob/ce118e3890ea8c9019857cb7556552cdc9992f8e/ADDITIONAL_TERMS.md
[apple-terms]: https://developer.apple.com/support/terms/
