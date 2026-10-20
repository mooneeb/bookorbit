# Physical walkthrough review

Historical build 4 snapshot. The two then-outstanding verdicts are now accepted in the [final build 5 human review](../physical-review-build-5/README.md). Raw answers below are preserved as recorded.

Read-only iPad collection after the user reported all walkthroughs done except the final installation check. Device: iPad Air 13-inch (M2), iPadOS 26.6.1. App build reviewed: 4.

[Summary](summary.json) and `answers/` retain the user's actual responses. `records/` contains each complete archive's capture/context metadata. Legacy generic verdicts remain Not reviewed because the guided responses are stored separately; use the guided answers as the review evidence.

## User outcomes

| Walkthrough                                 | Recorded result                                            |
| ------------------------------------------- | ---------------------------------------------------------- |
| Check a saved EPUB page                     | All six format/zoom views readable and aligned             |
| Check saved EPUB columns                    | All six format/zoom views readable and aligned             |
| Check a saved PDF page                      | All six format/zoom views readable and aligned             |
| Reopen an EPUB note offline                 | Page and ink returned; erase, Undo and new ink worked      |
| Reopen a PDF note offline                   | Page and ink returned; erase, Undo and new ink worked      |
| Keep my writing when a page cannot be saved | Clear refusal; ink kept after reopening                    |
| Read an EPUB note on other devices          | Both previews readable/aligned in all three named browsers |
| Read a column EPUB note on other devices    | Both previews readable/aligned in all three named browsers |
| Read a PDF note on other devices            | Both previews readable/aligned in all three named browsers |
| Keep a note beside its original words       | Unable to judge: text-only dialog had no ink               |
| Keep a local note through an app update     | Own fixture saved; update/editing answer pending           |

Both tested background approaches are acceptable for readability/alignment through 4x in these local fixtures according to the user's responses. That is a bounded capture shortlist, not a universal-format claim or a final storage/reader choice. It does not establish normal EPUB text reflow or browser inline-reader integration.

The offline source directories are absent and their records contain distinct capture/reopen launch IDs. The internet-off setting and edit/Undo result are the user's confirmations. Their edited current drawings are saved under `examples/offlineEPUB` and `examples/offlinePDF`; old pre-edit HTML was deliberately excluded. The browser previews for the three clarity samples include current ink, but their embedded walkthrough answer text predates finishing the review. Use the separate answer JSON for the final responses.

Browser version fields were left blank. Prior installed Mac binary versions are known from environment inspection, but those should not be mistaken for captured version evidence at review time. Exact Android Chrome version remains unrecorded.

## Physical capture observations

Single small sample per row. Each raster output is 1280 x 960. The RSS values are app-process lifetime high-water marks, excluding separate WebKit/GPU processes and prior allocations' attribution. Capture time excludes resource readiness/export. These values are observations, not benchmarks or memory budgets.

| Fixture             | Capture/write | PNG bytes | PDF bytes | Lifetime peak RSS before/after |
| ------------------- | ------------: | --------: | --------: | -----------------------------: |
| Single-column EPUB  |       56.3 ms |   357,055 |    53,282 |              103.8 / 113.8 MiB |
| Column EPUB         |       53.6 ms |   397,726 |    53,880 |              169.1 / 169.1 MiB |
| Cropped/rotated PDF |       29.4 ms |    63,881 |    14,162 |              178.4 / 178.4 MiB |

## Controlled update

[Update to build 5](update-to-build-5.json) records an actual signed in-place update under the selected Team and unchanged bundle, without uninstalling or resetting. All 163 pre-update scratch files retained their exact hashes before launching, including guided answers, archived pages, editable ink, local context and the maintenance marker. Build 5 then launched the maintenance walkthrough successfully. This is evidence for normal Xcode update retention; the post-update physical editing answer was pending at this snapshot and is now accepted in the final review.

The existing free profile was reused, with its recorded 27 October expiry. No new provisioning renewal, SideStore compatibility or SideStore-to-Xcode transition is claimed. The local marker is a scratch file, not a production sync queue.

## Corrected context comparison

The earlier inability to judge is kept in `answers/replacement.json`, including the user's actual explanation. Build 5 replaces the dialog with a saved original page and its actual ink beside a rendered revised sample, retaining original words and anchors without automatically moving the ink. [Simulator presentation evidence](../visual-comparison-build-5/provenance.json) uses a copy of this physical fixture. Its visual inspection is not the user's revised approval.

The retry button saves the prior review in the app before clearing only this step's tried checks/answer. Other walkthroughs and all archived ink remain intact. Both verdicts were pending at this snapshot and have since been accepted in the final review. The encompassing preservation decision stays open.
