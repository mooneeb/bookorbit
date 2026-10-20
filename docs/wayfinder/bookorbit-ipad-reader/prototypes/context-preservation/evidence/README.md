# Preservation capture evidence

Recorded 2026-10-20. [Decision remains open](https://github.com/mooneeb/bookorbit/issues/15). [Run the native walkthrough](../README.md) before giving a fidelity verdict.

## Walkthrough redesign after the user review

The user rejected the build 2 review structure as confusing. Merely renaming Raster and Fixed page did not solve the problem: saving, offline recovery, browser viewing, zoom and a generic verdict were still mixed together. They explicitly requested fixing that experience before resuming the offline question. No fidelity or offline approval was inferred.

Build 4 replaces that screen with eleven independent guided walkthroughs. The [walkthrough inventory](../README.md#independent-walkthroughs-and-coverage) maps each one to a single question and its complete task. Each has its own source, ink, progress, per-step tried checkboxes, concrete answer choices and reset. Page-clarity steps each show one format at one zoom level; their answers name readability and alignment. Other walkthroughs own offline recovery, the missing-picture refusal, specific browser checks, original/revised sentence context and installation maintenance.

Old `record.json` checks, verdicts, saved pages and ink remain intact in their original folders, with a viewing entry on the walkthrough list. New tasks use their own `guided-walkthroughs/<scenario>` folders and neutral sample text, so old book text cannot contradict the current instructions. New human responses live separately in each `walkthrough.json`; no previous response is automatically approved. A walkthrough with a reported problem may finish as reviewed without being counted as successful. The offline review remains pending until the user returns to its separate task.

The [build 4 verification record](guided-walkthroughs-build-4/physical-update.json) confirms a signed in-place installation on the intended iPad and byte-for-byte retention of all 17 prior scratch files. Remote launch was refused because the iPad was locked, so physical presentation of the revised UI still needs the user to unlock and open it. The same free profile was reused.

The [simulator fixture run](guided-walkthroughs-build-4/simulator-capture-run.json) created each of the ten successful walkthrough archives independently and refused the incomplete eleventh sample. [Fixture checks](guided-walkthroughs-build-4/standalone-fixtures.json) found separate folders and no supplied human answers. The [walkthrough list](guided-walkthroughs-build-4/walkthrough-list.png), [one page-image inspection step](guided-walkthroughs-build-4/page-image-1x.png) and [one enlarged PDF inspection step](guided-walkthroughs-build-4/pdf-copy-4x.png) are actual simulator screenshots. These demonstrate presentation and runnable fixture paths, not the user's approval of clarity or physical Pencil fidelity.

## Physical iPad installation and first capture

The intended **iPad Air 13-inch (M2), iPadOS 26.6.1**, is now connected. The user selected their Personal Team in Xcode, trusted the Developer App on the iPad, and confirmed the prototype opens. Strict code-signature validation and profile/device membership checks passed. [Installation metadata](physical-ipad-26.6.1/installation.json) records the initial launch rejection before trust, then the successful trusted launch. Account, device and team identifiers and raw profiles are excluded.

The free profile was issued **20 October 2026 at 14:11:25 UTC** and expires **27 October 2026 at 14:11:25 UTC**, exactly seven days later. The controlled build 1 to build 2 update reused that profile; **a fresh provisioning renewal has not been demonstrated**.

The first [manually inked scrolled-EPUB capture](physical-ipad-26.6.1/scroll/preview.html) retains the actual backgrounds, editable drawing, preview and original context from that iPad. Capture geometry records vertical offset 1100 and a 640 x 480 point viewport. Its two recorded ink revisions are not synthetic fixture strokes. The record deliberately labels input as manual and requires a separate physical Pencil review; tool behavior and the user's fidelity verdict cannot be inferred from the drawing file.

Single physical-fixture observations: **70.2 ms** capture/write time, **1280 x 960** raster pixels, **367,688 bytes** PNG, **53,458 bytes** PDF, and **10,630 bytes** editable ink. App-process lifetime peak RSS was **142.9 / 152.2 MiB** before/after. As with simulator measurements below, these exclude readiness/export time and separate WebKit/GPU processes. They are not a memory budget or large-book benchmark.

The [in-place update manifest](physical-ipad-26.6.1/in-place-update.json) verifies installation and launch of build 2 under the same bundle/signing team without uninstalling or resetting. Background PNG, PDF and drawing hashes were unchanged. Original context, source identity, human checks and verdict were preserved, and a new app launch was recorded. **The working source existed before and after this update**, so this demonstrates update retention, not source-free offline restoration.

The user asked what Raster and Fixed page meant and reported no visible difference. Build 2 now calls them **Page image** and **PDF copy**, with a short explanation. This is a request for clearer labeling, not approval of all zoom levels or recovery. [The interaction observation](physical-ipad-26.6.1/interaction-observation.json) keeps those verdicts pending. The retained physical HTML was exported before this update and still uses the older labels: Raster means Page image; Fixed page means PDF copy. Exporting again in build 2 updates those headings without changing the saved drawing.

[Current prerequisite observations](physical-ipad-26.6.1/prerequisites.json) found no standard SideStore or LocalDevVPN installation through targeted device queries. Renamed forks are not excluded by that lookup. Neither compatibility nor refresh preservation has been tested.

## What actually ran in the simulator

- Xcode 27.0 (27A266a), iOS 27 SDK, deployment target 26.0. Unsigned device and simulator builds passed. The device IPA's Payload layout, bundle identity, iPad-only family, minimum OS and bundled fixtures were checked.
- Execution: **iPad Air 13-inch (M3) simulator, iOS 26.0 (23A343)**. This is not the intended Air M2 on iPadOS 26.6.1.
- The capture run made four deterministic synthetic strokes per successful scenario: translucent underline, arrow, and two corner marks. No human handwriting, Pencil pressure/tilt, native eraser/Undo, or hardware gesture was tested.
- WebKit capture ran at actual vertical offset **1100** for the scrolled EPUB and horizontal offset **1800** for the column EPUB, in a 640 x 480 point viewport. The returned word geometry, font name and original context are in each record.
- The PDF fixture uses a nonzero crop origin and intrinsic 90 degree rotation. The same displayed-page transform was used for its raster and extracted-page candidate. This does not validate an eventual production PDF reader adapter or every PDF rotation.
- The missing-image fixture failed image decoding and produced **no complete archive**. Its actual WebKit exception and the absent-record observation are in the [capture log](simulator-26.0/capture-run.json). Pending scratch-ink recovery in that failure scenario still needs manual review.

An initial repeat run exposed asynchronous scroll-position reporting. The fixture now waits for the requested offset, with bounded resource readiness and a nonzero-offset gate. The recorded run completed without fixture failures. A successful API callback alone is not a visual-fidelity verdict.

## Retained outputs

Open one self-contained comparison at a time. Each contains both candidate backgrounds and the same native-rendered synthetic ink. These are recorded output examples, not simulated writing controls.

- [Scrolled EPUB comparison](simulator-26.0/scroll/preview.html)
- [Column EPUB comparison](simulator-26.0/columns/preview.html)
- [Cropped/rotated PDF comparison](simulator-26.0/pdf/preview.html)

The corresponding folders retain PNG/PDF backgrounds, separate editable `ink.drawing`, ink preview, fixed-page preview and capture record. The browser files label synthetic input and contain their own images, original quote and neighboring context. There are no runtime font or book-resource requests.

The owner inspected the native screenshot and both EPUB/PDF candidate backgrounds. At normal size the retained text, illustration, table, margins and column layout were present in these fixtures. A T3 headless HTML render also loaded the four 1280 x 960 images used for the scrolled EPUB's background/ink comparisons and displayed their separate layers. This is an agent inspection of a rendering fragment, not the human's acceptable-fidelity decision. The collaborative browser rejected a local file URL as an unsupported protocol; no HTTP server was started.

## Actual Mac browser attempts

The named Mac binaries reported **Google Chrome 154.0.8037.98** and **Vivaldi 8.2.4133.89**. Each was tried with an isolated temporary profile, local self-contained simulator exports and a 720 x 2000 headless viewport. The [attempt manifest](mac-browsers/attempts.json) distinguishes produced screenshots from completed audits.

Chrome produced screenshots for the [scrolled EPUB](mac-browsers/chrome/scroll.png), [column EPUB](mac-browsers/chrome/columns.png) and [PDF](mac-browsers/chrome/pdf.png). Inspection of the scrolled-EPUB screenshot showed both backgrounds, overlaid ink and quoted context. All Chrome commands nevertheless reached the 35-second limit before returning a completed DOM audit. Vivaldi also timed out and produced no screenshots. The isolated processes were stopped and temporary profiles removed; no user's browser session was changed.

These are partial Chrome rendering observations, not completed browser acceptance. Vivaldi rendering, interactive zoom, current physical-ink exports and the actual Android Chrome device remain unverified. An automation timeout alone does not establish a browser format incompatibility. Archival previews also do not prove inline ink in BookOrbit's normal browser reader.

## Source-free cold reopen and controlled simulator update

After capture, all three working sources were deleted. The deliberately broken fourth scenario's remaining source copy was also removed, so no scratch font/image copy remained. The original app process was terminated. An unsigned build with the **entire bundled Fixtures directory removed**, version advanced from **0.1 (1)** to **0.1 (2)**, was installed in place under the same bundle ID. A new process reopened the retained files.

The [cold-reopen log](simulator-26.0/cold-reopen-run.json) and [verification manifest](simulator-26.0/verification.json) record:

- All three sources absent, four restored synthetic strokes per scenario, and original quoted context available.
- Background PNG, fixed PDF and editable drawing SHA-256 values unchanged across the update.
- Original quote/context unchanged, distinct capture/reopen launch identifiers, and no fixture seed in the updated app.
- Every human checkbox untouched and every verdict still **Not reviewed**.

There was no new source rendering on this reopen path. The simulator remained network-connected; the experiment used local files only. This demonstrates source-independent local restoration in this simulator, not a physical airplane-mode launch, seven-day provisioning behavior, SideStore refresh or Xcode signing-identity transition. Simulator containers can change paths during an in-place installation; the checks retrieved the current container again rather than assuming its old path.

## Bounded observations

Single recorded run, not a benchmark. All raster backgrounds are **1280 x 960** pixels. Four synthetic strokes serialized to **849 bytes** in each example.

| Fixture             | PNG bytes | Fixed PDF bytes | Capture/write time | App lifetime peak RSS before/after |
| ------------------- | --------: | --------------: | -----------------: | ---------------------------------: |
| Scrolled EPUB       |   136,560 |          53,451 |            55.0 ms |                  216.8 / 236.4 MiB |
| Column EPUB         |   144,105 |          53,564 |            70.9 ms |                  266.6 / 266.6 MiB |
| Cropped/rotated PDF |    69,490 |          15,823 |            13.2 ms |                  274.7 / 274.7 MiB |

Capture time includes background generation and writes before the record was created; it excludes font/image readiness, preview export and cold reopening. RSS is the app process's lifetime high-water mark, not isolated capture usage, total WebKit/GPU memory, an intended-iPad measurement, or an accepted budget. Do not extrapolate these tiny fixtures to large chapters/scans or library storage.

The native bench caps the viewport, active canvas/capture count, written artifact size and raster pixels. Those are experimental guardrails, not product quotas. No maximum useful zoom or acceptable visual difference has been chosen.

## Reproduce the measurements

From the prototype directory, build with `./run.sh simulator`. Install on an iPad simulator, then launch the dedicated `dev.mooneeb.bookorbit.contextprototype` app with `--capture-fixtures`. **That argument resets only this prototype's fixture scenarios. Do not use it after adding review ink you want to keep.** It writes `capture-run.json` under Documents/`PROTOTYPE-WIPE-ME` and retained assets under its `guided-walkthroughs/<scenario>` folders. Current builds exercise all ten successful walkthrough fixtures plus the deliberately incomplete eleventh sample. Historical build 1 simulator evidence below used the original three sample folders.

Record SHA-256 values for `background.png`, `background.pdf` and `ink.drawing`, plus each original context. Terminate the app. Copy the unsigned simulator app to a separate build directory, remove that copy's `Fixtures` directory, and advance its Info.plist build version. Remove any remaining `*/source` scratch folders. Install the copied app in place, then launch with `--reopen-fixtures`. Compare the new container's assets and context against the recorded values. Do not uninstall or reset the prototype between those steps.

These two launch modes are evidence-capture conveniences, not unit tests or production behavior. Manual normal launch chooses a scenario through its title. `--scenario=columns`, `--scenario=pdf`, and `--scenario=missing` are optional direct launch shortcuts.

## Still required before resolution

The intended Air M2, iPadOS 26.6.1, is installed and running. Required next evidence:

1. Complete physical Pencil/tool editing, erase/Undo, source-free cold offline reopening, enlargement and appearance review across the first three scenarios. The first manually inked EPUB and its device measurements are recorded above; the user has not yet approved fidelity or offline recovery. The missing-resource ink recovery check also remains manual.
2. The actual user's Mac Vivaldi 8.2.4133.89 / Chromium 152.0.7977.170, Mac Chrome 154.0.8037.98, and Oppo Find X9 Pro / Android 17 / actual Chrome build. Browser file-opening and image/PDF behavior must be tested there, not inferred from T3's renderer. Ordinary inline reading integration belongs to the separate browser validation decision.
3. SideStore/LocalDevVPN compatibility, installed identity, newly issued profile, on-device refresh, update and fallback transition with preserved local ink/context. Xcode bootstrap, actual seven-day profile dates and a same-identity normal update are recorded above. That update did not renew the profile or prove a SideStore transition. There is no production sync queue in this app; pending-state renewal validation is not completed.
4. The user's choice of acceptable candidates, zoom ceiling, visual defects and failure/recovery behavior. No agent verdict substitutes for this exchange.

Other unverified combinations include obfuscated/app-selected fonts, fixed-layout EPUB spreads, RTL/vertical scripts, huge chapters/scans, unusual PDF fonts/forms/links/tags, every rotation/crop combination, dynamic-color ink under changed appearance, interrupted/disk-full writes, corrupted archives and backup restoration. A final shortlist cannot claim these cases work.

Native builds, Swift format/lint, shell syntax, fixture XML/resource references, IPA structure, source-removal restoration and evidence consistency are the relevant checks. No tests were added under the prototype skill. Production server/client ESLint, app tests, typechecks and migrations are inapplicable because no production source, API, database or dependencies changed. Generated build outputs are not committed.
