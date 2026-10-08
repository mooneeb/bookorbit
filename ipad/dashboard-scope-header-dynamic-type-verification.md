# Dashboard shelf header Dynamic Type

Issue: #2. Source comparison: `e796cd84`. Retained failing runtime: `806ab571`.

The dashboard tester's actual native run `run-22650-1791326305853` failed the
full accessibility audit in
`DashboardJourneyTests/testIPADE01Dashboard05BoundsPartialFailureAndDisabledShelves`.
This repair agent independently read the complete issue attachment
`3FC201D4-3039-4667-9FC8-1DAC70C30872.txt` and inspected the actual full screenshot
`073F6DD7-9765-484A-BB59-EC3F0F034836.png`, the element crop
`FE4C17BE-CB63-4463-A212-EEDB77159039.png`, and the matching hierarchy
`9D2A35EE-7916-40B5-9C53-5BBCC0E6919E.txt`.

The artifacts are retained under
`/tmp/bookorbit-dashboard-qa-c3fea03d/test-results/ipad/run-22650-1791326305853/native-attachments/`.
The audit identifies the visible `Missing private scope` shelf header at
`{{159.0, 633.0}, {206.5, 26.5}}`, with identifier
`dashboardShelf-missing-scope`, and reports that the user cannot change its font
size. The full image shows the complete header above the failed-shelf message
and existing retry action. This is a reported font-scaling issue rather than
an assertion that this normally sized screenshot clips the heading.

The existing header already uses the semantic `.title2` font. No fixed-point
font or native Dynamic Type override was found. Preserve that font and its
heading trait, and allow the text to keep its intrinsic vertical height while
wrapping within the shelf's available width. This matches the existing native
organization heading layout. The correction applies to the owning shelf
header, including the missing-scope state; its wording, identifier, foreground,
shelf ordering, cards, and retry behavior stay intact.

Apple's [Dynamic Type guidance](https://developer.apple.com/videos/play/wwdc2024/10074/)
recommends semantic fonts and layouts that accommodate growing text. That
guidance supports the layout correction, but does not establish the cause of
this specific runtime audit result.

Targeted Swift formatting, strict format lint, Swift syntax parsing, and
`git diff --check` passed. No test, audit type, or finding was hidden or changed.
The dashboard tester must rerun the unchanged journey and full audit, and the
actual corrected artifacts must be inspected before this defect can be called
verified. Compilation, corrected runtime checks, and visual baseline approval
remain pending; this checkpoint claims source verification only.
