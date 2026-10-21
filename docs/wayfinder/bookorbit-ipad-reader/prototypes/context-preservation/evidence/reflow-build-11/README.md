# Build 11: independent local edits to wrapped marks

The [walkthrough guide](../../LOCAL-EDITING.md) describes two independent five-step native checks. The user chose copied marks per line as the appearance direction and explicitly requires edits to affect only the words on the edited line. These are desired behaviors, not physical editing results.

Each current line receives a separate native drawing and exact CFI/quote binding. Fixed text reference frames prevent the remaining ink from being stretched into an erased area. The original whole-sentence drawing stays unchanged. Switching lines and reloading clear Undo history, explicitly stated in the walkthrough. Subsequent splitting or joining of an edited piece during further reflow remains unresolved.

Both the simulator and unsigned iPad builds compile for the iPadOS 26 baseline. Swift format/lint, JavaScript syntax and diff checks pass.

- [Underline probe](simulator/underline-local-edit/local-edit-probe.json) and [circle probe](simulator/circle-local-edit/local-edit-probe.json): each uses the actual EPUB first-sentence CFI, two line-range CFIs and synthetic native strokes. A shortened native path is supplied through the real drawing-save delegate. The edited line changes; the second line's file bytes stay unchanged; both native displays match their saved drawings after switching and reloading. The source whole-sentence ink remains unchanged. All five tried checks remain false and no human answer is present. These probes do not exercise physical pixel erasing or native Undo/Redo.
- [Initial diagnostics](initial-diagnostics.json) retain the observed zero-width-space preparation failure and the corrected archive-versus-pixel measurement distinction.
- [Prior-review compatibility](legacy-review-compatibility.json): the actual build 11 controller loads a copy of the physical build 10 circle review, preserving its groups, original/current native ink bytes, existing answer, checks, source and appearance choice. That prior answer is not new acceptance.
- [iPad preparation](ipad-preparation.json): all 217 saved scratch files are backed up privately and unchanged after staging, with none missing or added. Reader local editing - build 11.ipa has an exact round trip and keeps the original app identifier. Installation, signing dates and physical local-editing verdicts are pending.

The simulator prototype and its loopback listener were stopped after each run. Raw physical notes, device/account identifiers and signing material remain private. No production changes were made.
