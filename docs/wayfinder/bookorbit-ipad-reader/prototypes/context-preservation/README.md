# Original annotation context experiment

Throwaway native prototype for [Validate preservation of original annotation context on EPUB and PDF](https://github.com/mooneeb/bookorbit/issues/15). Kept off main on `BO-15-annotation-context-prototype`.

**Question:** after a book is replaced or removed, can its original excerpt and editable ink still reopen, and which capture looks acceptable?

This is a capture bench for source replacement. Ordinary EPUB reading still requires visible text-following ink through reflow. This prototype does not decide the production reader, note schema, sync protocol, or reflow solution. It uses no private books, account, server, or production app data.

## Start here

Open **Orbit Context PROTOTYPE** on the iPad. It opens a list of walkthroughs, or returns to the exact step you left open. Choose **Check a saved EPUB page** first.

The first walkthrough has one purpose: decide whether a saved page and your ink remain readable when enlarged. It does not ask you to remove a book, go offline, use another device, or judge failure handling.

1. **Write on this sample page.** Turn writing on, circle useful, draw an arrow, and write important. Turn writing off. The ink stays visible. Press **Save this page and my handwriting**. If you return to a page already saved in this walkthrough, the button says **Continue with this saved page**.
2. **Inspect one saved view at a time.** The app takes you through page image at 1x, 2x and 4x, then PDF copy at those same sizes. Each step names the format and size on screen. Drag with a finger to look around an enlarged page.
3. **Answer that step's specific question.** Tick its two items after trying them, even if they failed. Then answer whether that particular view is readable and aligned. You can report a problem or that you could not judge it. Optional comments belong to that view. There is no generic Keep/Change verdict and no demand to choose an implementation format.
4. **Finish.** The final screen lists your actual answers. Return to the walkthrough list when ready. You may stop after this walkthrough. Later walkthroughs do not depend on finishing it.

A page image stores the background as pixels. A PDF copy may keep text sharper when enlarged. Both preserve the same separately editable handwriting. Seeing no visible difference is a valid observation.

## Independent walkthroughs and coverage

Each row below has its own sample source, drawing, saved page, progress, questions and reset. Every walkthrough begins with writing and saving its own sample. No other walkthrough has to run first. A restart confirms deletion of only that walkthrough's files. The new walkthroughs use a separate `guided-walkthroughs` folder and fresh samples. Earlier prototype pages and editable ink files remain unchanged, with viewing buttons under Earlier prototype notes. Earlier generic review fields do not answer the new questions automatically.

| Walkthrough                                 | Single question                                                             | Complete task within that walkthrough                                                                                                                     |
| ------------------------------------------- | --------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Check a saved EPUB page                     | Is a saved single-column page readable with correctly placed ink?           | Write, save, inspect the text/picture/margins and ink in each format at 1x/2x/4x, answer each view                                                        |
| Check saved EPUB columns                    | Are the correct columns and ink preserved?                                  | Its own column sample, write/save, inspect column edges and content at each format/size, answer each view                                                 |
| Check a saved PDF page                      | Do saved PDF words, corners and ink remain aligned?                         | Its own cropped/rotated PDF, write/save, inspect each format/size, answer each view                                                                       |
| Reopen an EPUB note offline                 | Can a saved EPUB note reopen and remain editable without its original book? | Its own sample, write/save, remove only that book, fully close and reopen offline, erase/Undo/add ink, answer recovery and editing questions              |
| Reopen a PDF note offline                   | Can a saved PDF note reopen and remain editable without its original book?  | Its own PDF, the complete removal/offline/reopen/edit task, its own answers                                                                               |
| Keep my writing when a page cannot be saved | Is an incomplete save explained without losing writing?                     | Its own deliberately missing picture, write, check saving, read the refusal, reopen the sample, check ink and answer                                      |
| Read an EPUB note on other devices          | Is the exported EPUB note readable in each real browser?                    | Its own sample, write/save, share a self-contained file, check Mac Chrome, Mac Vivaldi and Android Chrome separately, record browser versions and answers |
| Read a column EPUB note on other devices    | Is the exported column note readable in each real browser?                  | Its own column sample and the complete share/three-browser review                                                                                         |
| Read a PDF note on other devices            | Is the exported PDF note readable in each real browser?                     | Its own PDF and the complete share/three-browser review                                                                                                   |
| Keep a note beside its original words       | Does the saved note retain its original sentence when revised words differ? | Its own sample, write/save, compare the saved inked page beside a rendered revised sample, answer the context question                                    |
| Keep a local note through an app update     | Do page, editable ink and a local marker survive installation maintenance?  | Its own sample, write/save and local unsent marker, wait for an actual in-place update or signing refresh with the agent, reopen/edit and answer          |

The offline walkthroughs explain Wi-Fi/cellular changes and keeping Bluetooth for the Pencil only when you reach that step. There is no global offline checklist. The installation walkthrough explicitly waits for a real update/refresh; the app does not pretend to perform signing itself.

The original-words walkthrough now shows your retained original page with its actual ink beside a rendered local revision that changes useful to revised. It does not move ink to the revised page, import a complete replacement book or relink a note. An earlier text-only dialog was insufficient for the user to judge. On its finished screen, Retry with the page comparison keeps the earlier review in a history file and clears only that step's tried checks and answer for a new review. The browser walkthroughs show archival note previews, not BookOrbit sync or ordinary inline browser reading. The update walkthrough's marker is an isolated local file, not a production upload queue.

## Run from source

From this directory, run `./run.sh project`. XcodeGen 2.46.0 and Xcode are required. Choose your iPad and your own Personal Team in Xcode for the physical review. The deployment target is iPadOS 26.0; no iPadOS 27-only drawing APIs are used. The native harness is necessary to judge real PencilKit drawing and retained WebKit/PDF output; an HTML drawing imitation would not establish those facts.

## What is being compared

| Scenario      | Page image                                    | PDF copy                                                                  | Fixture boundary                                                                              |
| ------------- | --------------------------------------------- | ------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| Scrolled EPUB | Public WebKit viewport snapshot               | Public WebKit PDF capture, explicit content-offset rectangle              | Embedded Source Serif font, SVG image, table, margins, nonzero vertical offset                |
| Column EPUB   | Same viewport snapshot                        | Same PDF API at a nonzero horizontal offset                               | Two CSS columns; no claim about Readium/Foliate integration                                   |
| PDF           | Core Graphics rendering of the displayed crop | `PDFPage.dataRepresentation`, drawn with the same crop/rotation transform | Self-authored PDF with CropBox origin (48, 36), intrinsic 90 degree rotation and corner marks |
| Missing image | Capture is blocked                            | Capture is blocked                                                        | Resource decode failure must not become a complete archive                                    |

The EPUB is a small self-authored publication directory with OPF, spine, navigation, XHTML and resources. The harness directly loads its known spine resource into an app-owned `WKWebView`. It does not implement ZIP import, DRM, arbitrary EPUB navigation, a Readium capture adapter, or a complete EPUB renderer. This is a supported capture-seam experiment, not a selected reading stack.

The fixed-PDF background is rendered again when switching zoom, up to 4x rasterization for this viewport. The raster candidate retains its original pixels. The browser preview renders both backgrounds at 2x and overlays a current native-rendered ink PNG. It requires neither a PencilKit decoder nor WebArchive support. The original editable drawing remains on iPad. The build 4 physical review accepted both saved-background formats at 1x, 2x and 4x for the single-column EPUB, column EPUB and cropped/rotated PDF fixtures; this does not establish arbitrary-book fidelity or a higher useful zoom.

## Scratch files and bounds

Files live only in this app's Documents/`PROTOTYPE-WIPE-ME/guided-walkthroughs/<scenario>` directory, accessible through Files or Xcode's container download:

- `source/`: removable working copy, including font and image resources.
- `retained/background.png` and `background.pdf`: alternative backgrounds without PencilKit ink.
- `retained/ink.drawing`: editable PencilKit data, saved on drawing changes.
- `retained/record.json`: original quote, neighboring context, anchor, source-resource SHA-256, capture geometry, OS, timing, output dimensions, process-lifetime peak RSS observations, ink revision, launch IDs and human review.
- `retained/ink-preview.png` and `preview.html`: regenerated on sharing, tied to the current ink revision. Earlier exports do not update by themselves.
- `retained/walkthrough.json`: current guided step, per-step tried checkboxes, specific answers and comments. Earlier generic verdicts in `record.json` are retained as history.
- `active-walkthrough.txt` at the scratch root: the walkthrough to resume after fully closing the app. Leaving through All walkthroughs clears only this pointer, not the saved note.

EPUB hashing covers the chapter resource, not the complete publication or its font dependencies. PDF hashing covers the original PDF. These fixture identifiers do not decide production identity. The comparison of revised quotes performs no migration.

The capture viewport is 640 x 480 points. One capture runs at a time, with one active canvas. Raster output is capped at 8 million pixels; each written artifact at 16 MiB. PDF display is rendered at scale 2 at 1x/2x and scale 4 at 4x. Required EPUB font/image readiness has an 8-second timeout. These are bench limits, not accepted product quotas or maximum zoom guarantees. The small fixtures do not stress huge chapters, large scans, or global storage scale.

The reported RSS is the current app process's **lifetime high-water mark**, observed before/after capture via `getrusage`. It includes earlier work, excludes separate WebKit/GPU processes, and does not isolate capture allocations. It is not an iPad memory budget. PNG compressed bytes differ from decode memory.

Capture writes backgrounds and ink before publishing its metadata. Missing resources cannot produce a complete record. This is scratch-file persistence, not a crash-safe production transaction. Disk-full, interrupted writes, corrupted assets, and backup recovery have not been validated. Missing required archive files are reported without automatically discarding them or reconstructing from the book.

## Builds

`./run.sh simulator` builds an unsigned simulator app. `./run.sh device` builds an unsigned device IPA at `build/OrbitContextPrototype-unsigned.ipa` for a later SideStore compatibility trial. An optional second argument sets the build number, for example `./run.sh device 3`. `./run.sh project` opens Xcode for a normal signed build. Generated projects and build outputs are ignored. Do not install over any real reader or delete real app data.

The dedicated bundle ID is `dev.mooneeb.bookorbit.contextprototype`. The user selected their Personal Team in the ignored Xcode project and trusted its Developer App on the iPad. Xcode signed and installed build 1, then installed build 2 in place with clearer comparison labels. Developer Mode was already enabled; the OS was not upgraded. SideStore and LocalDevVPN were not installed by this work. SideStore may change signing identifiers; record the actual installed identity during that separate trial. No account identifiers, certificates or raw provisioning profiles are included in the evidence.

## Device and renewal gate

The required physical target is iPad Air 13-inch (M2), iPadOS 26.6.1, Apple Pencil Pro. It is now connected, and the user confirmed the app opens. A first manually inked scrolled-EPUB capture and an in-place update have been recorded on that device. The saved backgrounds, editable drawing and original context survived build 1 to build 2 unchanged. The source was still present during that update, so this is not an offline/source-free recovery result. Simulator output remains separate: Air 13-inch (M3), iOS 26.0.

The actual free profile was issued **20 October 2026 at 14:11:25 UTC** and expires **27 October 2026 at 14:11:25 UTC**, or **7:11:25 pm Pakistan time**. The update reused this profile; it did not prove a fresh signing renewal. See the [physical observations and remaining gates](evidence/README.md).

All eleven preservation walkthrough behaviors are now accepted, including the corrected original/revised page comparison and post-update erase/Undo check. See the [final physical review](evidence/physical-review-build-5/README.md). The tested background shortlist includes both page images and PDF copies through 4x for these fixtures; final reader/storage selection remains a later decision.

The outstanding manual prerequisite is [Validate free signing renewal and note preservation on the intended iPad](https://github.com/mooneeb/bookorbit/issues/20). It owns current-OS SideStore/LocalDevVPN compatibility, actual signing identity and profile dates, on-device refresh, data preservation and the free Xcode fallback. The [recorded installation policy](https://github.com/mooneeb/bookorbit/issues/11#issuecomment-6291640322) remains conditional until that work is complete. Normal Xcode updates that reuse the existing profile do not prove renewal. Fully disconnected use remains bounded by the actual remaining signing lifetime, not a new 30-day guarantee.

Exact browser versions at review remain incompletely recorded, particularly Android Chrome. Successful archival preview responses do not substitute for normal inline-reader browser validation or EPUB reflow validation.

## API and fixture provenance

Capture uses Apple's public [WebKit snapshot](<https://developer.apple.com/documentation/webkit/wkwebview/takesnapshot(with:completionhandler:)>), [WebKit PDF](<https://developer.apple.com/documentation/webkit/wkwebview/createpdf(configuration:completionhandler:)>), and [PDF page data](https://developer.apple.com/documentation/pdfkit/pdfpage/datarepresentation) APIs, plus separately serialized PencilKit data. See [the archival investigation](../../research/annotated-view-preservation.md) for documented limits. That report's original ordinary-reading workflow has been superseded by [the live interaction decision](https://github.com/mooneeb/bookorbit/issues/6#issuecomment-6289693465); only its archival evidence is used here.

The text, SVG and generated PDF are self-authored fixtures. Source Serif 4 Regular comes from Adobe's [4.005R source](https://github.com/adobe-fonts/source-serif/tree/2823e993c53fca27c5c8749f529b56a5a7c77b6b), with its [OFL license](Fixtures/FONT-LICENSE.md). No online resources are needed at runtime.
