# Direct freehand handwriting on EPUB pages

Research date: **2026-10-21**. Primary-source comparison for [Validate text-following ink through actual EPUB reflow](https://github.com/mooneeb/bookorbit/issues/17) and [Find the design for a personal BookOrbit iPad reader](https://github.com/mooneeb/bookorbit/issues/1).

## Question and answer

The question is whether existing readers let someone handwrite **directly over an EPUB reading page**, including margins, circles and arrows, as they can on a PDF. Attached note canvases and pen gestures that merely create ordinary text highlights do not answer that question.

**Yes. Direct freehand EPUB page writing is an existing feature, including the noter iPad app with Apple Pencil and several dedicated pen readers. Kobo also documents direct ebook page writing in its iPad app.** The harder, separate question is what happens after the EPUB changes layout. The evidence shows several compromises: preserve the original layout behind a marker, prevent layout changes, or put handwriting in a box around which text flows. An inspectable open-source KOReader plugin implements text-following ink using a narrower word-anchor rule than BookOrbit's attempted multi-line stroke reshaping.

This prior-art comparison does not reverse the [accepted hybrid decision](https://github.com/mooneeb/bookorbit/issues/17#issuecomment-6321857426): PDF page ink; EPUB annotations anchored to selected words, with attached typed or editable ink notes. Discovering alternatives is evidence for a possible future decision, not authorization to resume the abandoned page-ink experiment.

## Evidence labels and limits

- **Documented:** a first-party manual, support page or release note describes the feature. This is not our own runtime verification.
- **Source observation:** behavior inspected in a specific public implementation, without executing it on the intended device.
- **Advertised:** a product page claims a feature, but a release description or controlled demonstration does not establish the detailed behavior.
- **Unverified:** the inspected sources do not establish it. This does not mean impossible or absent.

No app was purchased, installed or tested for this report. No physical iPad, account, certificate or home-server operation was performed. Dedicated reader firmware, iPad apps and browser readers must not be treated as interchangeable implementations.

## Evidence matrix

| Reader                                           | Actual handwriting directly over an EPUB page?                                                                                                                                                              | What happens when text/layout changes?                                                                                                                                                                                                                              | Persistence, editing and portability evidence                                                                                                                                                                                                                                                                                                                 |
| ------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **noter: EPUB reader & annotator, iPad**         | **Yes, explicit developer statement:** write, circle, draw and doodle directly on EPUB pages with Apple Pencil. This is separate from attached annotations and notebooks.                                   | Developer says page ink is saved across layout configurations. The exact remapping/restoration policy is **unverified**.                                                                                                                                            | Developer lists write-on-page ink export to PDF, Calibre/OPDS import and iCloud sync. Listing showed **2.5.0**, April 26, and iPadOS 18.6 minimum. No hands-on quality result is claimed. [App Store][noter-app], [developer portfolio][noter-dev]                                                                                                            |
| **Kobo Books for iPad**                          | **Yes for Kobo ebook pages, documented.** Apple Pencil can write margin notes and circles. EPUB import is separately supported; the cited pages do not explicitly guarantee markup for every imported EPUB. | iPad-specific font-size, margin and orientation behavior is **unverified** in the inspected instructions. Do not infer it from the eReader implementation.                                                                                                          | Saved markups appear in the book's annotations list and can be revisited/deleted. Guides conflict about cross-device transfer. [iPad guide][kobo-ipad], [launch description][kobo-launch], [EPUB import][kobo-import]                                                                                                                                         |
| **Kobo Sage, Elipsa, Elipsa 2E, Libra Colour**   | **Yes, documented** for `.epub` and `.kepub`; writing anywhere on the screen is autosaved.                                                                                                                  | After a font-size change, handwriting can become a margin marker/preview. **Revert to these settings** returns to the annotated layout. This does not claim arbitrary ink remains over its words after reflow.                                                      | Device guide says EPUB ink cannot be exported and warns of loss on sign-out/reset. Its no-transfer statement conflicts with the iPad guide. Exact current sync scope requires checking. [Kobo Stylus guide][kobo-device]                                                                                                                                      |
| **BOOX NeoReader on handwriting-capable models** | **Yes, documented.** BOOX explicitly includes reflowable EPUB in direct in-book notes without conversion or sticky notes.                                                                                   | Exact arbitrary-ink behavior after font, margins, orientation or viewport changes is **unverified** by the inspected first-party material. Do not equate “supports EPUB and handwriting” with a reflow guarantee.                                                   | Handwriting has its own contents list, PNG/PDF export, and BOOX reading-data sync. A separate Smart Scribe feature converts pen marks into semantic text annotations. [Format support][boox-formats], [current guide][boox-notes]                                                                                                                             |
| **Supernote EPUB reader**                        | **Yes, documented:** handwrite or draw anywhere in an EPUB/PDF.                                                                                                                                             | The official **V2.7 manual** prohibits changing EPUB display settings after handwritten annotations exist. This is a documented historical layout lock, not proof about every 2026 model/firmware.                                                                  | The guide documents annotation erasers and revisiting annotated pages. Its described annotation export concerns PDF. A universal editable EPUB ink interchange format is not established. [Annotation guide][supernote-annotations], [V2.7 manual][supernote-v27]                                                                                             |
| **Tomelet**                                      | **Yes, documented/advertised:** direct page ink is listed alongside EPUB support.                                                                                                                           | Marketing explicitly claims ink follows text through font/screen changes. However **1.0.3, 2026-10-05**, says pen drawings remain accessible after layout changes **with margin markers by default**. That is not proof of always-visible, shape-preserving reflow. | Direct drawing is a shipped feature; the exact reflow policy remains uncertain. Official releases list Android, Mac, Linux and Windows. The linked Apple listing rendered Mac-only; iPad availability was not verified. [Pen feature page][tomelet-ink], [1.0.3 release][tomelet-103], [current Windows release][tomelet-130], [Apple listing][tomelet-apple] |
| **KOReader + Ink Away plugin**                   | **Yes, documented open-source implementation.** Its README distinguishes ink on books from the text-highlighter feature.                                                                                    | Source confirms individual drawing operations follow a nearby word, without reshaping a sentence-spanning stroke around new line breaks.                                                                                                                            | MIT plugin with persistent book ink, editing tools and export. This is a KOReader plugin, not a ready-made native iPad PencilKit component. [Pinned README][inkaway-readme], [placement engine][inkaway-place]                                                                                                                                                |

## iPad and documentation caveats

**noter** is the strongest explicit iPad EPUB example found. Its developer says page ink is saved across layout configurations, but does not explain remapping versus restoring earlier layouts. Version **2.5.0** mentions fixes for disappearing ink. No runtime quality result is claimed. [App Store][noter-app], [developer portfolio][noter-dev]

Kobo's app guide says iPad markups appear on stylus eReaders; its device guide says handwriting does not transfer to apps/other eReaders. The different directions or feature generations might explain this, but that is inference. Bidirectional ink sync is not established. [App guide][kobo-ipad], [device guide][kobo-device]

BOOX's **V4.1** guide distinguishes genuine handwriting from Smart Scribe gestures that become ordinary text annotations. Tomelet's marketing promises text-following ink, while its **1.0.3** release documents margin markers after layout changes. Neither claim should be silently substituted for verified continuously visible freehand reflow. Live Tomelet releases reached **1.3.0** by October 21. [BOOX guide][boox-notes], [Tomelet feature claim][tomelet-ink], [release behavior][tomelet-103], [current release][tomelet-130]

## Features that look similar but do not meet this question

- **Kindle Scribe Active Canvas:** handwriting lives in an inserted/resizable canvas, and book text flows around it. Amazon says it remains anchored through typography changes, but this is a different design from leaving arbitrary circles/arrows directly over the original text. EPUB personal documents enter through **Send to Kindle conversion**; it is not evidence of a general EPUB ink-interchange implementation. PDF direct writing and certain write-on books are separate cases. [Amazon overview][kindle-overview], [canvas instructions][kindle-canvas], [format table][kindle-formats]
- **Snapplify:** its official iOS/Android/Mac/Windows instructions allow freehand drawings on ebook pages, but explicitly say those drawings **cannot be saved**. Useful as a temporary presentation overlay, not persistent personal annotations. The page does not establish all EPUB layout modes. [Freehand instructions][snapplify]

## Additional verified options

**PocketBook InkPad Eo xReader:** the official **1.2.2 manual**, pp. 33-39, documents EPUB layout controls and direct stylus drawing in the ebook, separately from split-view notepads. Ink alignment after layout changes and exact close/reopen behavior are unverified. **reMarkable** documents EPUB annotation layers and typography controls, but the inspected current sources do not establish arbitrary-ink reflow fidelity; **3.28, September 2026**, changed its EPUB reading experience. [PocketBook manual][pocketbook-manual], [reMarkable layers][remarkable-layers], [EPUB guide][remarkable-ebooks], [release notes][remarkable-releases]

**KOReader stylus-annotations plugin:** its README documents drawing on EPUB/FB2, but explicitly warns of strokes shifting in reflowable documents. [Plugin README][stylus-readme]

## Open-source source audit: Ink Away

Inspected revision: **`0c4a45a613a96cfb6ae87d8356695f93af71687f`, 2026-10-19**. The repository had stable **4.2.0, October 16**, and prerelease **4.2.2, October 19**. Source observations are pinned to that revision, not inferred from a product slogan. [README][inkaway-readme], [releases][inkaway-releases]

`Place.anchor` chooses a word near each drawing operation and records its text pointers and offsets. Underlines can use the word's bottom edge; margin ink can retain its distance from a screen edge; split words have a segment identifier. `Place.place` then **translates the whole saved operation** to the new word position. Its EPUB path does not scale, split or reshape that operation to fit newly wrapped lines. [Placement source][inkaway-place]

This is actual inspectable text-following page ink. **Inference from that rule:** a short mark can follow its anchor's position, but a single circle or underline spanning a sentence is not thereby guaranteed to fit the sentence after it wraps. Several independent handwritten strokes may acquire different anchors. This is a different trade-off from build 13's regenerated underline fragments. [Placement source][inkaway-place]

Book ink is saved as original drawing operations plus anchors in an `inkaway.lua` sidecar, with load/save and backup paths. The dedicated tests cover anchor movement and persistence using a **stand-in document with known word boxes**, not a physical iPad handwriting study. No tests or app were run for this report. [Storage source][inkaway-storage], [test source][inkaway-tests]

## What this establishes for BookOrbit

Direct writing over an EPUB page is feasible and already exists. **Persistence** and **correct behavior after reflow** are separate requirements. A system can preserve every stroke while using a marker or locked layout to avoid misrepresenting it. An attached ink note can preserve the handwritten letter shapes while the selected words reflow independently. None of those should be described as arbitrary page ink continuously tracking all of its intended words.

The newly accepted hybrid design therefore remains a sensible scoped decision, not a consequence of EPUB handwriting being impossible. Reopening page ink would require a new, explicit behavior decision and a focused comparison using real handwritten annotations, including the wrap-to-wide failure the user observed in build 13. This report does not authorize another prototype installation.

[kobo-ipad]: https://help.kobo.com/hc/en-us/articles/12466604902935-Use-Apple-Pencil-to-create-markups-in-the-Kobo-Books-app-iOS
[kobo-import]: https://help.kobo.com/hc/en-us/articles/360060463753-Import-items-from-your-iOS-or-macOS-device-onto-your-Kobo-Books-app
[kobo-launch]: https://www.kobo.com/blog/kobos-spring-2023-update-on-new-features-and-fixes
[kobo-device]: https://help.kobo.com/hc/en-us/articles/1500001927562-Write-notes-in-your-book-with-Kobo-Stylus
[boox-formats]: https://shop.boox.com/blogs/news/what-makes-boox-a-powerful-note-taker
[boox-notes]: https://booxsupport.zendesk.com/hc/en-us/articles/8569296110100-Take-Notes-on-Books
[supernote-annotations]: https://support.supernote.com/en_US/organizing/contents-bookmarks-and-annotations
[supernote-v27]: https://ib.supernote.com/V2.7_EN.pdf
[pocketbook-manual]: https://support.pocketbook-int.com/fw/1042/u/1.2.2/manual/User_Manual_InkPad_Eo_EN.pdf
[remarkable-layers]: https://support.remarkable.com/s/article/Layers
[remarkable-ebooks]: https://support.remarkable.com/articles/Knowledge/Ebooks
[remarkable-releases]: https://support.remarkable.com/articles/Knowledge/Release-notes-overview
[tomelet-ink]: https://tomelet.app/stylus-notes/
[tomelet-103]: https://github.com/tomelet-org/tomelet-downloads/releases/tag/app-v1.0.3%2B34
[tomelet-130]: https://github.com/tomelet-org/tomelet-downloads/releases/tag/app-v1.3.0%2B98
[tomelet-apple]: https://apps.apple.com/us/app/tomelet-epub-pdf-reader/id6814121149
[kindle-overview]: https://www.aboutamazon.com/news/devices/kindle-scribe
[kindle-canvas]: https://digprjsurvey.amazon.co.uk/csad/help/node/T0MT2p2D8t046zUxih
[kindle-formats]: https://digprjsurvey.amazon.com/csad/help/node/TNtSm13k3txFI4EvDV
[snapplify]: https://help.snapplify.com/support/solutions/articles/80001028222-drawing-freehand-in-your-ebooks
[inkaway-readme]: https://github.com/EmirErtorer/ink-away.koplugin/blob/0c4a45a613a96cfb6ae87d8356695f93af71687f/README.md
[inkaway-place]: https://github.com/EmirErtorer/ink-away.koplugin/blob/0c4a45a613a96cfb6ae87d8356695f93af71687f/ink/reader/place.lua
[inkaway-storage]: https://github.com/EmirErtorer/ink-away.koplugin/blob/0c4a45a613a96cfb6ae87d8356695f93af71687f/ink/reader/bookink.lua
[inkaway-tests]: https://github.com/EmirErtorer/ink-away.koplugin/blob/0c4a45a613a96cfb6ae87d8356695f93af71687f/tests/bookink.lua
[inkaway-releases]: https://github.com/EmirErtorer/ink-away.koplugin/releases
[stylus-readme]: https://github.com/kerivin/stylus-annotations.koplugin
[noter-app]: https://apps.apple.com/ca/app/noter-epub-reader-annotator/id6760678747
[noter-dev]: https://ca.linkedin.com/in/raj-green
