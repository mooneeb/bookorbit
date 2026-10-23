# Browser reading compatibility prototype

Throwaway proof for [Validate PDF page ink and EPUB text-linked notes in browsers](https://github.com/mooneeb/bookorbit/issues/19), on `BO-19-browser-ink-notes-prototype`. The [hybrid decision](https://github.com/mooneeb/bookorbit/issues/17#issuecomment-6334584037) is the current contract: PDF page ink; EPUB typed or ink notes attached to exact selected words. This proof does not reshape freehand marks over EPUB text.

## Aim and starting point

Can the actual browser readers show the iPad's handwriting with the correct content association while keeping the editable native original? A page-image preview alone cannot establish PDF reader integration. A mocked page with fixed text cannot establish EPUB range recovery.

Run from the repository root:

```sh
pnpm prototype:browser-notes
```

Open `http://127.0.0.1:8767/`. Choose the browser you are using and start any walkthrough. Each starts from its own fresh reader and scratch note. You do not need to complete another walkthrough first. Restart affects only that sample and its review answers. Closing/reloading the tab discards its in-memory review; copy the summary or save the detailed review file first.

Use the six browser walkthroughs in Mac Chrome, Mac Vivaldi and Android Chrome. The two iPad checks can wait until the end and need only be reviewed once against the same originals. No native update or new signing action is needed for this proof. The [completed live review](evidence/live-review.json) records all selected browser and physical iPad checks, finished on 2026-10-23.

The first Mac Chrome review completed the original five browser walkthroughs. EPUB ink, typed-note editing and PDF navigation passed; PDF rotation alignment passed with a visibility qualification, and PDF zoom failed because outside handwriting was inaccessible. The [unaltered human verdicts](https://github.com/mooneeb/bookorbit/issues/19#issuecomment-6337329059) remain recorded. The added **Read handwriting outside the PDF page edge** walkthrough is the focused recheck for that failure. The passed EPUB walkthroughs do not need repeating for this correction.

| Walkthrough                                      | Its single question                                                                                        |
| ------------------------------------------------ | ---------------------------------------------------------------------------------------------------------- |
| Read a handwritten EPUB note as the text changes | Do the same selected words reopen the same handwriting through font-size and width changes?                |
| Edit a typed note linked to EPUB words           | Does saved sample text remain editable and associated with those words after closing/reopening and reflow? |
| Read PDF handwriting at different zoom levels    | Are the current PDF and handwriting readable and aligned at Fit, 2x and 4x?                                |
| Keep PDF handwriting aligned through rotation    | Do original crop/rotation and extra viewer rotations preserve alignment?                                   |
| Read and select PDF text with ink visible        | Do scrolling, panning and printed-text selection remain usable?                                            |
| Read handwriting outside the PDF page edge       | Is saved margin handwriting reachable and readable at Fit/2x/4x and every rotation?                        |
| Check the original EPUB handwriting on iPad      | Is the corresponding original still editable, including erase and Undo?                                    |
| Check the original PDF handwriting on iPad       | Is the corresponding PDF original still editable, including erase and Undo?                                |

Each step names an action and expected result, with its own attempted-check box. A checked box records that the user tried it. Only the separate, specific final answer records success or failure. There is also an explicit inability-to-complete answer. Automated observations never fill human checkboxes or verdicts.

## Engine and fixture boundaries

The separate Vite entry is [under the reader feature](../../../../../client/src/features/reader/prototypes/browser-notes/BrowserReview.prototype.vue). It has no production route, BookOrbit authentication, server API, database, library scan or sync connection. Its task-runner entry is the only normal workspace entry point added.

- EPUB uses the repository's actual vendored Foliate engine, including its File/ZIP loader, actual range CFI resolution, annotation drawing and marked-text hit testing. It checks resolved text against the stored quote. The note body is outside the book layout and preserves the same image through reflow. It loads the self-authored nine-chapter [EPUB fixture](../context-preservation/Fixtures/Reflow/reflow.epub), with its existing font/license.
- PDF uses installed, patched EmbedPDF/PDFium **2.15.1**, with the actual worker/WASM engine and page rotation, Scroller, tiling and pointer/selection components. A scratch viewport adapter reserves the full native drawing canvas around the unchanged PDF sheet and translates its DOM scroll origin through the engine's public viewport API. The overlay is read-only. It loads the previously published physical [PDF page and ink](../context-preservation/evidence/physical-review-build-4/examples/pdf/), not a background screenshot as a substitute for the PDF.
- One reader is mounted at a time. The PDF document limit is one, scroll buffer one, tiles 768 with zero extra rings. Only the small active fixtures are loaded. This is not a large-book/library performance result or a production storage/zoom budget.
- Transfer is local fixture delivery. Typed-note saves are in-memory sample edits. This does not implement or prove real synchronization, concurrency, note lists, Trash or automatic production refresh. Those complete-journey checks remain with the later note/sync and acceptance decisions.

The default public replay uses already published iPad handwriting with an explicitly supplied sample text association. It does not claim a native-authored CFI round trip for that public drawing. During the local review, an optional private fixture supplies the actual build-9 native text binding and its corresponding original drawing derivative. These modes are identified in the manifest and the collapsed evidence panel.

## Native ink provenance

The local exact-range replay reuses the drawing created in **Keep a note on a word as text grows**. The saved native selection is the 29-character range **most useful observation keeps**, not just useful. Its source-file hash matches the unchanged EPUB. Before the final physical edit/Undo check, the current/original drawing archives matched the browser source bytes. The user's subsequent editing changed the working revision; its byte identity is not claimed. The immutable original remains intact, the quote/CFI are unchanged, and the working archive still decodes with native PencilKit.

[export-ink.swift](export-ink.swift) reads a scratch `.drawing` copy, crops to `PKDrawing.bounds` with padding and renders transparent PNG using macOS PencilKit. It records the original and derivative hashes, crop, pixel size and stroke count, then checks the original bytes remain unchanged. This is an Apple-native render of an iPad drawing, not a new physical iPad capture. Its appearance must still be compared with the iPad. Private drawings and derivatives are not committed here.

To reproduce an optional local export:

```sh
swift docs/wayfinder/bookorbit-ipad-reader/prototypes/browser-compatibility/export-ink.swift input.drawing output.png
```

The operator supplies a separate scratch input/output path. A local `epub-note.json` additionally supplies `quote`, `cfi`, `sourceSha256`, `association` and `nativeWalkthrough`; the exporter supplies its ink hash/render fields. Set `BOOKORBIT_READER_PROOF_INPUT` to that private directory when starting or building. The config refuses a source-file hash mismatch and serves only its explicit fixture allowlist. It never serves the directory itself or a raw native drawing.

The PDF uses the previously published physical iPad PNG at **1280 by 960**, corresponding to a **640 by 480** drawing canvas. It keeps the original archive hash alongside that derivative. The single extracted PDF page retains MediaBox `[0,0,720,540]`, CropBox `[48,36,672,504]` and intrinsic rotation 90 degrees. PDFium reports unrotated crop dimensions **624 by 468** with page rotation 1.

The native canvas includes aspect-fit margins. Its inverse into crop-local top-left page coordinates is `matrix(0 -1.3 1.3 0 0 650)`. The overlay applies that inverse, scales once with the actual PDF state and shares the actual page rotation layer. It permits visible overflow because some original marks extend beyond the PDF crop into the native canvas margin. Widening/stretching the complete PNG to the page rectangle would give the wrong result. Compare margin marks too, especially on a narrow phone.

The first review found that visible SVG overflow alone did not enlarge the browser's scroll bounds: the outside word could not be reached at 2x/4x. [InkViewport.prototype.vue](../../../../../client/src/features/reader/prototypes/browser-notes/InkViewport.prototype.vue) now allocates real padding for the transformed full canvas at each scale and rotation. Reader coordinates retain their original PDF origin; pointer handling, scrolling and tile visibility receive the corresponding translated metrics. It also owns full-canvas centering instead of the gesture wrapper's paper-only centering. **Fit page and ink** fits the combined extent, while **Find handwritten useful** pans to a fixture-specific handwriting target. At 4x on a phone, panning may be needed to read the word in parts. This does not change the source PDF, its CropBox or any drawing bytes, and does not select a production margin-writing model.

The fixed 2x raster derivative is a candidate with a clarity limit. Testing 4x viewer zoom does not imply the PNG has 4x native detail. Blurring or inaccessible margin ink is a valid failure to report. This proof does not select the final export resolution, representation or reader stack.

## Runtime and completed live review

See [runtime observations](evidence/README.md) for exact automated versions and limits. Desktop headless checks and a narrow viewport are preliminary evidence, not the user's Mac/browser verdict or a physical Android result.

An initial Vivaldi run exposed a queued Foliate resize calling layout while the iframe body was absent. The scratch adapter guards its instance's public render call until a body exists and after teardown. The vendored files are unchanged. This finding must inform the later reader-stack decision; it is not a production fix or a general renderer certification.

The [live review evidence](evidence/live-review.json) records acceptance in Mac Chrome **155.0.8059.85**, Mac Vivaldi **8.2.4133.89** and Chrome **155.0.8059.84** on the Oppo Find X9 Pro with the user-reported Android 17 baseline. Chrome's initial PDF zoom failure and qualified rotation result remain in the history; the focused margin correction then passed. Vivaldi and Android each passed all six browser walkthroughs.

The connected **iPad Air 13-inch (M2), iPadOS 26.6.1**, running **Orbit Context PROTOTYPE 0.1, build 13**, reopened both matching originals. The user confirmed erase/Undo restored the mark for each. Read-only before/after copies and native PencilKit decoding support the provenance record without claiming identical working bytes after editing. These results complete the display experiment's live gates for the retained fixtures. Final storage, sync, production integration, reader selection and large-library behavior remain later decisions.

For a self-contained static runtime, build and serve the generated directory:

```sh
pnpm --filter client exec vite build --config vite.reader-prototype.config.ts
python3 -m http.server 8767 --bind 127.0.0.1 --directory docs/wayfinder/bookorbit-ipad-reader/prototypes/browser-compatibility/build
```

The build is ignored. An explicit `--bind 0.0.0.0` instead of loopback makes that scratch build accessible to a phone on the same reachable network. This serves only the generated prototype, not BookOrbit or its library. Stop the development server before using the same port. Generated builds may contain the chosen local handwriting derivative, so keep private builds local.
