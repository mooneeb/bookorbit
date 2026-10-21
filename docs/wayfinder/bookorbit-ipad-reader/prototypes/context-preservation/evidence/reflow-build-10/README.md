# Build 10: standalone underline and circle comparisons

The [comparison guide](../../MARK-COMPARISONS.md) states the question, exact steps and limits. The user requested alternatives after the literal sentence-wrap mark failed. No permission to change mark semantics has been inferred from that request.

Both unsigned simulator and iPad builds compile with the iPadOS 26 baseline. Swift format/lint, JavaScript syntax and shell syntax checks pass. The build command now regenerates its Xcode project so newly added prototype source files are included. No production code or automated test suite was added.

The separate simulator probes use an actual first-sentence DOM selection, Foliate-generated CFI and synthetic native PencilKit mark. Each has zero tried checks and no human answer. The original canonical drawing hash is unchanged after every appearance and the return to the original layout. The underlines produce two line-specific copies. The circle probe also exercises two copied outlines, one enclosing copy and two newly generated neat outlines. The selected text is **The most useful observation keeps its original context.**

- [Underline probe](simulator/underline-compare/comparison-probe.json), [original after wrapping](simulator/underline-compare/comparison-mark-original.png), [per-line copies](simulator/underline-compare/comparison-mark-per-line.png).
- [Circle probe](simulator/circle-compare/comparison-probe.json), [copied outlines per line](simulator/circle-compare/comparison-mark-per-line.png), [one enclosing copy](simulator/circle-compare/comparison-mark-enclosing.png), [new neat outlines](simulator/circle-compare/comparison-mark-neat.png).
- [Legacy review compatibility](legacy-review-compatibility.json): the actual controller reads the prior physical single-word fixture in the simulator, preserving its original groups, answer, tried checks, source hash and drawing bytes. That pre-existing human answer was not supplied by the probe.

The composites pair the actual WKWebView snapshot with the native-rendered drawing. They are appearance evidence from synthetic inputs, not the user's hand-drawn alternatives or a physical Pencil acceptance result. Simulated copied circles cross some letters, which is retained as an observed limitation. The neat variant changes shape and pressure, and is identified as such.

[iPad preparation](ipad-preparation.json) records 199 scratch files backed up privately and a matching staged IPA round trip. During staging, the running older maintenance walkthrough appended a reopen identifier to its record. The other 198 files, including every editable drawing, stayed unchanged; its ink revision also stayed unchanged. The fresh after-staging snapshot is the pre-install comparison baseline. Nothing was restored or reset. Actual installation, profile dates, preservation and live appearance choices remain pending.

The native listener is bound to loopback and stops on leaving a walkthrough; both simulator probe listeners were stopped. No Mac background server was started. Raw physical notes, account/Team/device identifiers, signed exports and device-tool logs remain private.
