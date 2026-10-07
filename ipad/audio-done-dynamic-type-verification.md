# Audio Done Dynamic Type repair

Issue: #2. Candidate starts from `a826dd22b0b859241773e9a9efe97d1b293ba793`.

## Confirmed failure

The original genuine-engine audio test on QA HEAD `e4262dd2` reached real AAC and MP3 playback, exact seek and chapter navigation, and the second-asset Save acknowledgment before the full, unfiltered native accessibility audit failed on `audioDone`.

Run artifacts are retained at `/tmp/bookorbit-audio-playback-qa-6a5e5800/test-results/ipad/run-63566-1791360571891/`.

- Audit text: `native-attachments/BB631564-E40F-4FD6-ADE4-E687779C7293.txt`.
- Issue detail: `native-attachments/240A7409-1913-44BD-84AF-D890BF6120B7.txt`.
- Full hierarchy: `native-attachments/9E8EBBDD-8F9E-4D11-8B62-9DA9078DCEE3.txt`.
- Inspected full saved-state screenshot: `native-attachments/EF023A4F-4946-47CD-A145-675166F2391C.png`.
- Inspected Done crop: `native-attachments/C8651F68-F1A5-4C51-8982-4C8674F61D60.png`.

The finding says: `User will not be able to change the font size of this SwiftUI.AccessibilityNode`. The hierarchy identifies the Done button at `{{763.5,36.0},{56.5,36.0}}`. The original label's 44-point minimum did not prevent the system navigation-bar presentation from constraining the actual button to 36 points high. Its default-size appearance does not establish Dynamic Type support.

## Repair

Move the same Done button into a persistent top safe-area inset below the navigation title. Use explicit SwiftUI `.body` text, allow vertical text growth, and provide a minimum 44-by-44-point label and rectangular hit area. Keep the system background and label colors. The button remains outside the scrolling content so it stays reachable when chapters require scrolling.

Preserve `model.close(); dismiss()`, `audioDone`, `.task` opening and disappearance cleanup. Playback, seek, Save, chapters, resource loading, production audio sources and all test assertions remain unchanged.

## Verification

From `/tmp/bookorbit-audio-done-dynamic-type-fix`, these checks passed:

```sh
xcrun swift-format format --in-place ipad/ReaderProof/Sources/AudioProofView.swift
xcrun swift-format lint --strict ipad/ReaderProof/Sources/AudioProofView.swift
xcrun swiftc -frontend -parse ipad/ReaderProof/Sources/AudioProofView.swift
git diff --check
```

The strict Swift 6 primary-file typecheck passed with exit 0 in 1.838 seconds. The exact command is retained at `/tmp/bookorbit-audio-done-strict-typecheck-command.txt`, with its empty diagnostic log at `/tmp/bookorbit-audio-done-strict-typecheck.log`. It checked `AudioProofView.swift` as the primary file against 90 actual production and proof source declarations, excluded the production app entry point, and used the installed iOS simulator SDK and macro plugins, strict concurrency and warnings as errors. The exclusive shared heavy-check lock was acquired and released for this check.

```sh
sh /tmp/bookorbit-audio-done-strict-typecheck-command.txt
```

No runtime verification has been run for this repair. The original High tester must rerun the unchanged genuine-engine test and full accessibility audit, inspect actual screenshots and hierarchy for the scalable Done control and reachable target, and verify its close action. No audit exemptions, fake accessibility nodes, test filters or assertion skips were introduced. Landscape, relaunch, handoff, expanded formats and fault scenarios remain outstanding from the original run.

Server/client lint and Prettier are inapplicable because this change contains only Swift UI and Markdown. No new tests were added.
