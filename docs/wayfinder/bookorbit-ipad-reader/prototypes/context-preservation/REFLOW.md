# Text-following ink experiment

Throwaway native prototype for [Validate text-following ink through actual EPUB reflow](https://github.com/mooneeb/bookorbit/issues/17), on `BO-17-text-following-ink`. Physical review is pending. This is planning evidence, not production app code.

Current candidate: build 10. Start with the [standalone underline and circle comparisons](MARK-COMPARISONS.md) to judge alternatives after the sentence-wrap failure. The [build 9 evidence](evidence/reflow-build-9/README.md) records its corrected physical loading, the successful single-word size changes and the failed sentence-wrap mark. No rule for adapting marks has been accepted.

## Aim and current candidate

Find out whether a note still means the same thing after the EPUB changes layout, and whether the required authoring effort is acceptable. The exact first example is a Pencil mark on **useful**, an arrow and handwritten **important**.

The app uses BookOrbit's actual vendored Foliate EPUB loader, paginator and CFI implementation at `ce118e3890ea8c9019857cb7556552cdc9992f8e`, hosted in WKWebView. It opens a real self-authored EPUB ZIP with nine separate chapters, repeated words, an embedded licensed font and adverse sample content. It does not move a preassigned SVG beside a hardcoded word. User-created notes begin with a real selection; Foliate serializes and resolves its CFI after layout changes and chapter reloads.

The proposed authoring rule is explicit: select words, start an ink group, then write its marks. Each group owns an editable PencilKit drawing. Its current placement uniformly scales with text size and follows the **first fragment** of the selected range. New strokes are inverse-transformed into that group's local coordinates. Groups are never inferred from proximity or stroke order. This is a bounded experiment whose limits need the user's reaction, not an accepted product rule.

This rule can keep a single-word mark, arrow and label together. It does not make a long literal underline, multi-target arrow or circle follow independently wrapped fragments. The wrap walkthrough deliberately exposes that limitation. Blue range boxes show resolved words for comparison; they are not the user's ink or a silently regenerated substitute for it. Possible group overlap and clipping are reported without hiding or shrinking a note to manufacture success.

## Baseline reflow walkthroughs

Open **Orbit Context PROTOTYPE** and choose **Keep a note on a word as text grows**. The list states the overall aim and keeps each walkthrough's progress separately. Each screen gives one current step, its own action, a tried checkbox, the expected check and a specific final question. A problem can be recorded without a successful verdict. Each walkthrough starts from its own source chapter and saved ink; no earlier walkthrough is needed. Its Restart button resets only that walkthrough after confirmation.

1. Turn writing off. Long-press and select a particular **useful** in the sample. Tap **Link selected words**.
2. Turn writing on. Mark the word, draw your arrow and handwrite **important**. Turn writing off; the ink stays visible.
3. Tick the step's tried checkbox and Continue. Use that walkthrough's layout action and inspect the result it names.
4. Save your specific answer. Return through All walkthroughs to choose another independent task.

**Edit next note** selects an existing group for native editing. The native PencilKit picker supplies pen, highlighter, eraser, lasso and the system Pencil interactions. Undo and Redo act on the current editing projection. A new layout or a different group starts a new Undo history; that limitation is explicit in the old-ink walkthrough. Both canvas and picker cap content at PencilKit version 4 for the iPadOS 26 baseline. No iPadOS 27 stroke-identity/selection APIs are used.

## Independent coverage

| Walkthrough                                     | Atomic question                                                                                                            |
| ----------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| Keep a note on a word as text grows             | Does the exact mark/arrow/handwritten-label example remain connected through larger and smaller text?                      |
| Let a marked sentence wrap                      | Does literal ink still mark the intended sentence when its range splits across lines?                                      |
| Change margins and turn the iPad                | Does the note remain usable through margin, width and physical orientation changes?                                        |
| Read and turn pages with ink enabled            | Do fingers navigate while the Pencil writes, and do both navigate with writing off while ink stays visible?                |
| Edit old ink after the text moves               | Do erase, Undo and lasso still edit old strokes after reflow and resource reload?                                          |
| Add new ink after a layout change               | Do new strokes stay in the intended old or separately created group through another reflow?                                |
| Choose which repeated word owns the ink         | Are the associations correct, and is explicit selection/group switching acceptable to the user?                            |
| Keep several handwritten comments readable      | Are nearby and oversized labels usable in a narrow layout, including visible overlap/clipping failures?                    |
| Keep reflowed ink through reopening and renewal | Does one independently authored note retain old/new editable ink through an offline cold reopen and actual signing update? |

Finger navigation while writing uses a recognizer on the common reader ancestor, limited to direct touches; Pencil drawing remains native. The underlying web view handles normal navigation with writing off. Simultaneous contact, palm rejection and Pencil Pro actions require physical testing. If text moves during a stroke, the native projection waits for the stroke to finish and reports this explicitly. That is experimental behavior to judge.

If the selected note is on another page, the writing overlay prevents Pencil navigation but cannot add ink to an offscreen group. Turn writing off, select words on the current page and start another group. This constraint is part of the explicit-assignment experiment and needs the user's acceptance.

## Files and runtime bounds

New files live under Documents/`PROTOTYPE-WIPE-ME/reflow-walkthroughs/<walkthrough>`, separate from all previously accepted preserved-page notes:

- `review.json`: explicit target CFIs, exact quotes/context, complete source SHA256, group UUIDs, base coordinates/font, progress, actual answers and the local scratch marker.
- `<group>.drawing`: authoritative current editable drawing in canonical coordinates.
- `<group>-original.drawing`: retained pre-reflow drawing when a layout action is first used.
- `geometry.json` and `geometry-history.json`: current/bounded recent range fragments, source validation, viewport/flow/location, projections, canonical stroke counts/hashes, runtime and measurement observations.
- `resource-requests.json`: the last forty local bundled-resource requests, with relative paths, containment results and HTTP status. No complete device bundle paths are recorded.

At most twelve groups can be created per walkthrough. One group has the active native canvas; other visible groups use native-rendered images. Foliate loads one resource at a time in this configuration. Geometry history keeps sixty packets. These are experiment bounds, not agreed product quotas or a library-scale test. JS measurement timing is not total bridge/reflow latency. Process RSS excludes separate WebKit/GPU processes.

The app starts an HTTP listener bound only to `127.0.0.1` for bundled EPUB and renderer modules. It serves only `Fixtures/Reflow/` and `foliate/`, rejects paths outside those roots, and stops when leaving the walkthrough. It needs no home-server connection or external website. This server runs inside the app, not as a separate Mac background command.

## Build and probe

From this directory, `python3 Reflow-fixture.py` deterministically rebuilds the EPUB. Its content and font provenance are in `Fixtures/Reflow/fixture-provenance.json` and the existing font license. Run `./run.sh simulator 10` or `./run.sh device 10`. The app identity remains `dev.mooneeb.bookorbit.contextprototype`; the earlier preserved-page walkthroughs remain accessible from the home list, and their files are not reset.

The optional simulator launch arguments `--reflow-scenario=size --reflow-probe --simulator-input` run a separately labelled probe. It programmatically selects the second occurrence through a DOM Range, uses Foliate-generated CFIs and synthetic native PKStroke data, then exercises size, width, flow and chapter reload. Its files use a separate `PROBE-` prefix. It writes no checkboxes or human answers. This can expose renderer/bridge failures and check source drawing hashes; it does not establish authoring usability, physical Pencil fidelity or acceptance.

The initial browser inspector timed out twice with `Preview automation snapshot timed out after 15000ms.` Native simulator checks are used instead. Mac/Android inline reader validation still belongs to its own ticket.

## Limits and remaining gates

Physical user verdicts, old/new native stroke editing, pressure/eraser masks, palm handling, simultaneous input, real-device performance, offline cold reopen and signing preservation of these new groups must still be collected. No new profile or successful physical reflow is claimed from a simulator build. Use the accepted manual SideStore IPA import route, preserving the identifier and unchecking Append Team ID; ordinary reader badge/background refresh remains unvalidated.

Arbitrary freehand intent recognition, independent connector endpoint remapping, literal stroke splitting across lines/pages, automatic collision resolution, vertical writing, RTL layout and image/table-region attachment are not solved by this candidate. Adverse text in the fixture does not establish those cases. Source fingerprint mismatch refuses reattachment; the full retained-source/relink workflow remains separate. The already accepted preservation prototype does not prove these reflow behaviors, and this prototype does not choose the production note model, reader stack or sync contract.

The [local-editing round](LOCAL-EDITING.md) adds independent underline and circle checks in build 11. It tests separate native editing of wrapped line copies in the same line layout. Further reflow of an edited copy remains unresolved.

The [erased-gap reflow round](GAP-REFLOW.md) adds a fresh underline walkthrough in build 12. It uses actual character CFIs and native masks to investigate a saved erasure through further layout changes and native editing. Circle reconstruction and general handwriting remain separate gates.
