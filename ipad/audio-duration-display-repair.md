# Audio duration display repair

Issue #2, source base `6a5e5800`, repair branch `BO-2-audio-duration-fix`.

The original actual run `run-23680-1791358656475` passes all 17 authenticated HTTP tests, then fails `AudioReaderProofTests/test99RealAACMP3PlaySeekChapterSaveRelaunchAndWebHandoff` at line 185. The unchanged expected label is `0:03 / 0:24`; the actual label is `0:03 / 0:23`. Read the complete tester packet at `/tmp/bookorbit-audio-playback-qa-6a5e5800/ipad/audio-duration-display-bug.md`.

## Diagnosis and change

Independently reran installed ffprobe against the original delivered AAC artifact: its stream and container report `24.000000` seconds, stream time base `1/44100`, duration ticks `1058400`. The actual AVPlayer reached Ready, advanced while playing and reached the requested three-second seek. Opened the original advanced screenshot, failure screenshot and hierarchy, plus independently extracted frames at 20 and 40 seconds of the original recording. The 40-second frame shows Ready, Play available, seek value 3 and `0:03 / 0:23`; controls remain visible without clipping. This evidence confirms a presentation defect. The precise framework-measured fractional duration was not recorded; no specific decoder or transport cause is claimed.

`AudioProofModel.timeLabel` previously floored both elapsed and total seconds. Total duration now uses nearest-second presentation while elapsed and saved-position labels still floor completed seconds. A near-integer total below 24 now displays `0:24`. Clock formatting rejects non-finite, negative and out-of-bound input before integer conversion, using the same maximum as preparation. Minute counts use integer interpolation to avoid the old 32-bit `%d` truncation for very large valid durations. The existing minutes:seconds layout is preserved, including `60:00` at an hour.

Boundary reasoning: elapsed 59.9 remains `0:59`; total 59.9 displays `1:00`; total 3599.9 displays `60:00`; zero remains `0:00`. Engine duration, sampled positions, seek targets, persisted milliseconds, manifest validation, API and loader are unchanged. No tests, fixtures, expected assertions, audit settings or dependencies changed. No helper-mirroring tests were added.

## Verification and handoff

- `xcrun swift-format format -i ipad/ReaderProof/Sources/AudioProofModel.swift` and strict swift-format lint passed.
- Strict Swift 6 primary-file typecheck passed with real production/proof declarations, installed iPhoneSimulator 27.0 SDK, arm64 iOS 26.0 simulator target, complete concurrency, warnings as errors and installed macro plugins. Exact command: `/tmp/bookorbit-audio-duration-strict-typecheck-command.txt`; empty successful log: `/tmp/bookorbit-audio-duration-strict-typecheck.log`.
- `git diff --check` passed. Prettier/ESLint are not applicable to the sole Swift source change; Markdown was formatted with installed Prettier.
- No server, full build or native/browser harness was run by the repair agent. The root explicitly allocated the short source compiler check; the owned heavy gate was released immediately afterward. The High tester owns the unchanged runtime rerun. Source typechecking does not establish runtime acceptance.
- Original test file SHA-256: `52f03e7af169b687622f0d3a540c14404aa6d21012d6b158dcdd88ab6b26f367`. The test file is QA-owned and absent from this production-base worktree. Original MP3, save/relaunch, audits and browser stages were unreached, so none is passing evidence.

## Preserved original evidence

Artifacts remain immutable under `/tmp/bookorbit-audio-playback-qa-6a5e5800/test-results/ipad/run-23680-1791358656475/`. SHA-256 values:

| Artifact                                                                | SHA-256                                                            |
| ----------------------------------------------------------------------- | ------------------------------------------------------------------ |
| `/tmp/bookorbit-audio-first-real-engine-public-precision-corrected.log` | `1ecfd5b2805ece9905789c131cb1fd8232d752099e60b2c84dddb2b3a751eec8` |
| `audio-fixture/track-1.m4a`                                             | `03f0d211dbb6c812751542ec48b11be47ddc11a11457cb5e0c9a66d1ecb348f2` |
| `audio-fixture/track-2.mp3`                                             | `0552e875e3b7d4f13d7ff5853028cf8634628963010ea5c962ed4ee4e8b60855` |
| `native-seek-failure-final-frame.png`                                   | `5fa9febd4dd967c2ac0829e899bc44d3e9606ddfc452521a2b3055420c3678ed` |
| `native-attachments/821F270E-13F7-4DC9-B4BD-A3DDF9531AE1.mp4`           | `dcdb38e3de16b43b4902e96797ebb23d96a542038cfd4338d3226fe353fb014a` |

The earlier QA-only startup/HTTP corrections remain documented by the tester: explicit empty-array element type and PostgreSQL percentage representation tolerance of 1e-5 percentage points. This production repair does not address or change them. Issue #2 remains open and the broader audio/physical-device acceptance requirements remain outstanding.
