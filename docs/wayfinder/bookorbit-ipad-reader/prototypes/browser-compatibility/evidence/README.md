# Browser proof: preparation evidence

Recorded 2026-10-22 on macOS **27.0.1**. [Runtime observations](runtime-observations.json) are preliminary automated observations, not human acceptance or a physical Android/iPad result.

- Installed Chrome **155.0.8059.85** and Vivaldi **8.2.4133.89** each completed 24 scripted reader actions in the local static build. The exact selected text resolved through normal, larger and narrow EPUB layouts; saved sample typed text reopened; PDF Fit/2x/4x and document rotations 0/1/2/3 were exercised. Both final runs recorded zero runtime exceptions.
- A real highlighted-range mouse click opened the ink note through Foliate's annotation event. A real mouse drag in the PDF selection layer returned **A useful observation** with the display-only ink present. These are actual reader interactions, not pre-positioned text/SVG substitutes.
- A 390px viewport kept the document width at 390px and rendered one PDF ink overlay. This is desktop emulation, not a test of the Oppo phone, its touch behavior or memory use.
- Chrome additionally exercised the static build on a plain HTTP LAN origin with `isSecureContext` false. EPUB and PDF loading worked in that context. This does not establish phone network reachability.
- The original scratch EPUB drawing's hash stayed unchanged. Re-export with the updated native helper produced the same crop and PNG hash. Actual iPad originals and native editing remain pending until the user connects it.
- Review checkboxes and answers remained unfilled. No script supplied the user's verdict.

Initial diagnostics included unresolved Vite image imports and a Vivaldi queued resize while the iframe body was absent. The scratch entry now leaves its allowlisted fixture URLs untransformed and guards its renderer instance against layout before a body exists or after teardown. Vendored Foliate files are unchanged. Fresh static runs passed after those corrections. A console summary script also initially assumed every scenario had been visited; its output formatting was corrected without changing application verdicts.

No unit-test suite was added to this throwaway prototype, following the Prototype skill. The relevant executable checks are actual-engine runtime observations, client typecheck, targeted lint, native export execution, static build, formatting and link/diff checks. Normal repository push hooks are also required before publication is reported complete.

The fixed 2x PDF image may blur when enlarged. Native margin ink, crop geometry, fonts, pressure/texture appearance and text selection still need live review in the selected browsers. No complete BookOrbit sync, note-list integration, Trash or final reader/storage decision is claimed. Those later decisions remain open.

The user explicitly chose to prepare the browser portion and connect the iPad later. The original five Mac Chrome walkthroughs have now been reviewed; see the [human results](https://github.com/mooneeb/bookorbit/issues/19#issuecomment-6337329059). The failed zoom result and rotation visibility qualification remain recorded. Neither iPad original-editing walkthrough has a verdict.

## Margin-clipping correction

The native drawing extends beyond the numbered PDF frame into the original canvas margins. The first browser integration rendered SVG overflow but supplied only the paper rectangle as its scroll extent. At 2x/4x, the handwritten `useful` target was outside the reachable scroll bounds. This is a failed display case, not expected loss of note content.

The scratch viewport now reserves the transformed native-canvas bounds and maps DOM scrolling back to the unchanged PDF origin. **Fit page and ink** includes the whole canvas. **Find handwritten useful** offers a fixture-specific location aid. The new independent **Read handwriting outside the PDF page edge** walkthrough asks for readability, reachability and alignment through zoom and rotation. Passed EPUB results do not need repeating for this correction.

[Margin recheck observations](margin-recheck.json) record 24 combinations per installed headless browser: desktop and 390px emulation, Fit/2x/4x, and four document rotations. Every corner of the sample outside-word region could be brought into the viewport in all combinations. Actual mouse dragging still selected `A useful observation`, mouse panning changed scroll position, and no runtime exceptions were recorded. Original PDF, drawing and preview hashes are unchanged. Automated checks and human answers stayed unfilled.

The previous 24-action mount/reflow sequence also completed again in each browser with exact EPUB quotes, reopened sample typed text and no runtime exceptions. Vivaldi's headless surface screenshots repeated viewport tiles even after a fresh navigation; those captures do not establish visual fidelity. Its normal interactive review remains pending.

These are geometry and executable interaction observations. They do not settle human visual clarity, physical Android touch/gestures, or iPad editability. The fixed 2x PNG's possible 4x blurring is unchanged. The margin correction still needs a live user verdict; the issue remains open, with the remaining browser reviews and two independent iPad checks pending.
