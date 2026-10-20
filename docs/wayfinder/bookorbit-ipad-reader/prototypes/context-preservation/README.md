# Original annotation context experiment

Throwaway native prototype for [Validate preservation of original annotation context on EPUB and PDF](https://github.com/mooneeb/bookorbit/issues/15). Kept off main on `BO-15-annotation-context-prototype`.

**Question:** after a book is replaced or removed, can its original excerpt and editable ink still reopen, and which capture looks acceptable?

This is a capture bench for source replacement. Ordinary EPUB reading still requires visible text-following ink through reflow. This prototype does not decide the production reader, note schema, sync protocol, or reflow solution. It uses no private books, account, server, or production app data.

## Start here

From this directory, run `./run.sh project`. XcodeGen 2.46.0 and Xcode are required. Open the generated app in an iPad simulator first, or select your iPad and your own Personal Team in Xcode for the physical review. The deployment target is iPadOS 26.0; no iPadOS 27-only drawing APIs are used.

On launch, the app explains the aim and shows one scenario. Choose a scenario from its title. Each has its own source, ink, archive, reset, checks, verdict and feedback. There is no shared settings dashboard. Ink starts OFF. The native tool picker appears after you explicitly enable ink. The page is a fixed capture surface, not the final reader's navigation model.

For each of the first three scenarios:

1. Turn **Ink ON**. Circle useful, draw an arrow, write a margin comment, and put marks near the page corners. Use the native highlighter, eraser and Undo too.
2. Press **Capture both candidates**. Compare **Page image** and **PDF copy** at **1x, 2x, 4x**. A page image saves the background as pixels; a PDF copy may retain sharper text when enlarged. Both keep the ink separately editable. Look at the word, image, columns, page margins and ink. Turn ink off to hide the tool picker; the ink stays visible. Report what you can read and any alignment problems; no visible difference is a useful observation, not a requirement to choose a file format.
3. Press **Remove scratch source**. This removes the scenario's working source and its fonts/images, releases its WebKit view, and opens only retained files.
4. Fully close the app in the app switcher, disconnect internet, and reopen it. Do not uninstall or restart the scenario. Confirm that the original page and editable strokes are still available. Try erase, Undo and new ink. The app identifies reopening in a new process separately from pressing its reopen button.
5. Use **Inspect revised quote** to compare original and changed words without moving the note. This is a quote comparison, not a full replacement-book loader or relink implementation.
6. Press **Export current preview and review**. Open the self-contained HTML on the Mac in Vivaldi and Chrome, and on the Oppo in Chrome. Compare both examples and quote context. Capture the exact browser versions used. This is an archival excerpt preview, not proof of inline ink in BookOrbit's ordinary browser reader.
7. Tick each check only after trying it, including an unacceptable result. Choose **Keep**, **Change**, or **Cannot judge** separately. In feedback, name the acceptable candidate, maximum useful zoom, defects, and acceptable failure behavior. Export again after editing ink or feedback.

The fourth scenario deliberately lacks an image. Enable ink, make a mark, and try capture. Expect an incomplete-capture message, no source-removal action, and retained scratch ink after reopening the scenario. Its review is exported separately. The local reset deletes only that scenario after confirmation.

No checks or human verdicts are supplied by the automatic fixture run.

## What is being compared

| Scenario      | Page image                                    | PDF copy                                                                  | Fixture boundary                                                                              |
| ------------- | --------------------------------------------- | ------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| Scrolled EPUB | Public WebKit viewport snapshot               | Public WebKit PDF capture, explicit content-offset rectangle              | Embedded Source Serif font, SVG image, table, margins, nonzero vertical offset                |
| Column EPUB   | Same viewport snapshot                        | Same PDF API at a nonzero horizontal offset                               | Two CSS columns; no claim about Readium/Foliate integration                                   |
| PDF           | Core Graphics rendering of the displayed crop | `PDFPage.dataRepresentation`, drawn with the same crop/rotation transform | Self-authored PDF with CropBox origin (48, 36), intrinsic 90 degree rotation and corner marks |
| Missing image | Capture is blocked                            | Capture is blocked                                                        | Resource decode failure must not become a complete archive                                    |

The EPUB is a small self-authored publication directory with OPF, spine, navigation, XHTML and resources. The harness directly loads its known spine resource into an app-owned `WKWebView`. It does not implement ZIP import, DRM, arbitrary EPUB navigation, a Readium capture adapter, or a complete EPUB renderer. This is a supported capture-seam experiment, not a selected reading stack.

The fixed-PDF background is rendered again when switching zoom, up to 4x rasterization for this viewport. The raster candidate retains its original pixels. The browser preview renders both backgrounds at 2x and overlays a current native-rendered ink PNG. It requires neither a PencilKit decoder nor WebArchive support. The original editable drawing remains on iPad.

## Scratch files and bounds

Files live only in this app's Documents/`PROTOTYPE-WIPE-ME/<scenario>` directory, accessible through Files or Xcode's container download:

- `source/`: removable working copy, including font and image resources.
- `retained/background.png` and `background.pdf`: alternative backgrounds without PencilKit ink.
- `retained/ink.drawing`: editable PencilKit data, saved on drawing changes.
- `retained/record.json`: original quote, neighboring context, anchor, source-resource SHA-256, capture geometry, OS, timing, output dimensions, process-lifetime peak RSS observations, ink revision, launch IDs and human review.
- `retained/ink-preview.png` and `preview.html`: regenerated on export, tied to the current ink revision. Earlier exports do not update by themselves.

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

Before any preservation shortlist is accepted:

1. Complete the first three scenarios on the connected iPad with physical Pencil input, cold offline reopening, enlarged display and appearance review. The first scrolled-EPUB comparison prompted a request to explain Raster versus Fixed page, so build 2 renamed them Page image and PDF copy. That exchange is not yet a fidelity approval or offline recovery verdict.
2. Trial the chosen free SideStore route on that device. Record exact SideStore installer/app and LocalDevVPN versions, actual app identity, profile issuance/expiry and the observed refresh result, without publishing account identifiers or certificates.
3. Save an original-context fixture with extra ink and a local pending-state marker. Refresh signing on-device with the required connectivity/VPN. Confirm the same data and drawing reopen and remain editable. This prototype has no production sync queue; its local drawing is the preservation fixture, not an upload test.
4. The same-identity Xcode in-place update has preserved the first fixture. Repeat preservation checks through the chosen SideStore workflow and any Xcode fallback transition before relying on them. Do not uninstall the app.
5. Confirm offline launch within the actual remaining free provisioning lifetime. Free renewal still expires within seven days from profile issuance; this does not establish a 30-day disconnected installation.

The [SideStore amendment](https://github.com/mooneeb/bookorbit/issues/11#issuecomment-6291640322) remains conditional. Device compatibility, signing renewal, full offline launch, physical Pencil fidelity, the selected real Mac/Android browsers, and the user's acceptable zoom/failure policy are not established by a successful simulator run. The Wayfinder decision stays open until those evidence and human-review gates are met.

## API and fixture provenance

Capture uses Apple's public [WebKit snapshot](<https://developer.apple.com/documentation/webkit/wkwebview/takesnapshot(with:completionhandler:)>), [WebKit PDF](<https://developer.apple.com/documentation/webkit/wkwebview/createpdf(configuration:completionhandler:)>), and [PDF page data](https://developer.apple.com/documentation/pdfkit/pdfpage/datarepresentation) APIs, plus separately serialized PencilKit data. See [the archival investigation](../../research/annotated-view-preservation.md) for documented limits. That report's original ordinary-reading workflow has been superseded by [the live interaction decision](https://github.com/mooneeb/bookorbit/issues/6#issuecomment-6289693465); only its archival evidence is used here.

The text, SVG and generated PDF are self-authored fixtures. Source Serif 4 Regular comes from Adobe's [4.005R source](https://github.com/adobe-fonts/source-serif/tree/2823e993c53fca27c5c8749f529b56a5a7c77b6b), with its [OFL license](Fixtures/FONT-LICENSE.md). No online resources are needed at runtime.
