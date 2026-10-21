# Build 12: an erased underline gap through further reflow

The [standalone guide](../../GAP-REFLOW.md) describes the question, six steps, exact outcomes and prototype constraints. It extends the successful same-layout local-edit checks with a real word/character-bound eraser gap through further layout changes. This is an underline-only candidate, not a circle or arbitrary-handwriting result.

Both simulator and unsigned iPad builds compile for the iPadOS 26 baseline. Swift format/lint, JavaScript syntax and diff checks pass.

The [native simulator probe](simulator/underline-gap-reflow/gap-probe.json) uses the actual first-sentence Foliate selection, synthetic PencilKit underline and a native mask beneath the e in useful. It follows that exact character CFI through 24-point wider text and 40-point text. Native-rendered ink in the expected erased crop drops from 224 to 8 pixels and from 585 to 12 pixels respectively. The visible drawings contain 72 and 70 native fragments. This is a bounded fixture observation, not a physical latency or full-library result.

The [wider](simulator/underline-gap-reflow/comparison-gap-wide.png) and [larger](simulator/underline-gap-reflow/comparison-gap-large.png) composites pair the actual EPUB render with native ink. A later synthetic native edit is saved through the real delegate and reloaded with matching saved bytes and rendered pixels. Original whole-sentence ink stays unchanged. All six checkboxes remain false and no human answer is supplied. These checks do not establish physical erasing or Undo/Redo.

[Initial diagnostics](initial-diagnostics.json) record the omitted-space gap and the faint endpoint-strip join before the current interior-strip rule. All synthetic iterations are retained privately.

The [compatibility check](legacy-review-compatibility.json) exercises the actual build 12 controller with copies of both physical build 11 local-edit reviews. Native ink bytes, groups, line bindings, answers and checks remain unchanged. The underline review began with an empty aggregate book fingerprint; loading fills it with the same EPUB fingerprint already present on its groups. That field change is explicitly recorded. This proves decoding/storage compatibility, not matching old layouts or new human acceptance. Both simulator launches and their listeners were stopped afterward.

[iPad preparation](ipad-preparation.json) records a successful fresh backup after the user reconnected/unlocked the device. All 242 files match after staging, with none changed, missing or added. Reader erased gap - build 12.ipa has a matching transfer round trip and the original app identity. Actual installation, signing dates and live gap-reflow results remain pending.

After the user reported installing build 12, the [first installation check](ipad-installation-attempt-1.json) found all 242 saved files unchanged. A fresh copy of the on-device installer still matches build 12, but the installed reader metadata and reader-only SideStore signed export both report build 11. The export retains build 11's earlier signing dates. The cause is not established. The reader was left unopened and a fresh import of the exact build 12 file was requested. This is not a verified build 12 installation or a live walkthrough result.

The guide links the primary Apple mask documentation and states the candidate's explicit underline role, borrowed whitespace joins, character limit and unresolved native fragment interaction limits. Raw physical ink and private device/signing information remain outside the repository. No production code changed.
