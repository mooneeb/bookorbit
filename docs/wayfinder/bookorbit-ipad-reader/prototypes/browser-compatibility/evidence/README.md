# Browser proof: review evidence

The [completed live review](live-review.json), recorded 2026-10-23, separates actual human verdicts from the earlier automated preparation below. All selected browser and native-original gates passed for the retained EPUB/PDF fixtures. The initial Chrome margin failure remains recorded with its correction and recheck.

| Live target                                                  | Recorded result                                                                                                          |
| ------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------ |
| Mac Chrome 155.0.8059.85                                     | Original EPUB, typed-note and navigation checks passed; PDF margin failure corrected and accepted in its focused recheck |
| Mac Vivaldi 8.2.4133.89                                      | All six browser walkthroughs passed                                                                                      |
| Oppo Find X9 Pro, recorded Android 17, Chrome 155.0.8059.84  | All six browser walkthroughs passed; exact Chrome version supplied separately by the user                                |
| iPad Air 13-inch (M2), iPadOS 26.6.1, prototype 0.1 build 13 | Both matching native originals reopened; the user erased a small part and successfully restored it with Undo             |

Before native editing, fresh read-only copies matched both browser source drawings, the EPUB quote/CFI and the PDF source/preview. After the checks, both working archives still decoded with native PencilKit: 12 EPUB strokes and 20 PDF strokes. Their working bytes changed during the user's edit/Undo sessions. The EPUB immutable original and source PDF are unchanged; pre-edit drawings remain privately backed up. Native editing acceptance comes from the user's physical actions and replies, not these archive checks alone.

The final PDF reply was: **Yes, editing works and Undo restored the mark**. The EPUB reply and all browser reports are linked in the structured evidence. Private drawings, derivatives, device identifiers and backup paths are excluded from this published record.

These results cover the disclosed small fixtures and tested views only. Transfer remains local fixture delivery and typed saves remain in memory. Production sync, note lists, Trash, freshness, concurrent editing, storage/reader selection and library scale remain outside this experiment.

## Historical preparation observations

Recorded 2026-10-22 on macOS **27.0.1**. [Runtime observations](runtime-observations.json) are preliminary automated observations, not human acceptance or a physical Android/iPad result.

- Installed Chrome **155.0.8059.85** and Vivaldi **8.2.4133.89** each completed 24 scripted reader actions in the local static build. The exact selected text resolved through normal, larger and narrow EPUB layouts; saved sample typed text reopened; PDF Fit/2x/4x and document rotations 0/1/2/3 were exercised. Both final runs recorded zero runtime exceptions.
- A real highlighted-range mouse click opened the ink note through Foliate's annotation event. A real mouse drag in the PDF selection layer returned **A useful observation** with the display-only ink present. These are actual reader interactions, not pre-positioned text/SVG substitutes.
- A 390px viewport kept the document width at 390px and rendered one PDF ink overlay. This is desktop emulation, not a test of the Oppo phone, its touch behavior or memory use.
- Chrome additionally exercised the static build on a plain HTTP LAN origin with `isSecureContext` false. EPUB and PDF loading worked in that context. This does not establish phone network reachability.
- The original scratch EPUB drawing's hash stayed unchanged. Re-export with the updated native helper produced the same crop and PNG hash. At this preparation stage, actual iPad originals and native editing were still pending.
- Review checkboxes and answers remained unfilled. No script supplied the user's verdict.

Initial diagnostics included unresolved Vite image imports and a Vivaldi queued resize while the iframe body was absent. The scratch entry now leaves its allowlisted fixture URLs untransformed and guards its renderer instance against layout before a body exists or after teardown. Vendored Foliate files are unchanged. Fresh static runs passed after those corrections. A console summary script also initially assumed every scenario had been visited; its output formatting was corrected without changing application verdicts.

No unit-test suite was added to this throwaway prototype, following the Prototype skill. The relevant executable checks are actual-engine runtime observations, client typecheck, targeted lint, native export execution, static build, formatting and link/diff checks. Normal repository push hooks are also required before publication is reported complete.

The fixed 2x PDF image may blur when enlarged. At this preparation stage, native margin ink, crop geometry, fonts, pressure/texture appearance and text selection still needed live review in the selected browsers. No complete BookOrbit sync, note-list integration, Trash or final reader/storage decision is claimed. Those later decisions remain open.

The user explicitly chose to prepare the browser portion and connect the iPad later. The original five Mac Chrome walkthroughs were then reviewed; see the [human results](https://github.com/mooneeb/bookorbit/issues/19#issuecomment-6337329059). The failed zoom result and rotation visibility qualification remain recorded. Neither iPad original-editing walkthrough had a verdict at that stage.

## Margin-clipping correction

The native drawing extends beyond the numbered PDF frame into the original canvas margins. The first browser integration rendered SVG overflow but supplied only the paper rectangle as its scroll extent. At 2x/4x, the handwritten `useful` target was outside the reachable scroll bounds. This is a failed display case, not expected loss of note content.

The scratch viewport now reserves the transformed native-canvas bounds and maps DOM scrolling back to the unchanged PDF origin. **Fit page and ink** includes the whole canvas. **Find handwritten useful** offers a fixture-specific location aid. The new independent **Read handwriting outside the PDF page edge** walkthrough asks for readability, reachability and alignment through zoom and rotation. Passed EPUB results do not need repeating for this correction.

[Margin recheck observations](margin-recheck.json) record 24 combinations per installed headless browser: desktop and 390px emulation, Fit/2x/4x, and four document rotations. Every corner of the sample outside-word region could be brought into the viewport in all combinations. Actual mouse dragging still selected `A useful observation`, mouse panning changed scroll position, and no runtime exceptions were recorded. Original PDF, drawing and preview hashes are unchanged. Automated checks and human answers stayed unfilled.

The previous 24-action mount/reflow sequence also completed again in each browser with exact EPUB quotes, reopened sample typed text and no runtime exceptions. Vivaldi's headless surface screenshots repeated viewport tiles even after a fresh navigation; those captures do not establish visual fidelity. Its normal interactive review was still pending at this stage and subsequently passed.

These historical geometry and executable interaction observations alone do not settle human visual clarity, physical Android touch/gestures, or iPad editability. The subsequent live verdicts above complete those gates for the retained fixtures, including the margin correction. Acceptance at the tested 4x view does not add detail to the fixed 2x PNG or select a production export resolution.
