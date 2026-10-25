# Standalone EPUB and PDF profile acceptance

Future acceptance for [Define supported EPUB and PDF publication profiles](https://github.com/mooneeb/bookorbit/issues/23) and the [complete support proposal](../decisions/publication-profiles.md). All eleven individual choices are accepted; the issue holds final shared-understanding status. These cases are requirements, not a new prototype or completed production runs.

Each case starts with its own fixture, notes/bookmarks and account-scoped state. No earlier walkthrough supplies setup or checkmarks. A parametrized case runs separately from fresh state for every named variant. The test preparer records a run ID, source digest, profile/layout/resources, known reference words/images/order, and actual app/server/OS/browser versions. Use controlled test copies, with later private actual-library copies under the accepted final-journey plan. Keep personal originals intact.

Each checkbox records an attempted action. Finish each case with its own **Pass**, **Fail** or **Blocked** verdict, naming the failing step and observed result. All required variants must pass. Partial reading can explain a limitation but cannot pass a broken required profile. These cases complement the [reader journeys](reader-walkthroughs.md), [controls/bookmarks](reading-controls.md) and technical matrices linked below.

## Read and annotate a reflowable EPUB

**Question:** Can each required EPUB version support the complete selected-word note flow?

**Setup:** Fresh downloaded EPUB 2 and EPUB 3 fixtures, tested as separate runs. Each has known chapters, supplied contents/links, local pictures and a repeated sentence containing “useful observation”. This run starts with no note on its reference sentence.

- [ ] Open the book, follow its supplied contents to the named chapter, search for the reference sentence and check the intended occurrence.
- [ ] Select the specified words, create a note containing typed text and a distinct Pencil drawing, save locally and close it.
- [ ] Change text size, margins and page-turn/scroll mode. Reopen the note from the marked words; the quote, typed text and ink remain the same.
- [ ] Reopen offline, edit the ink and try Undo. Reconnect, wait for Synced and open the same note in each selected browser; return to the correct source words.

**Pass:** Each version independently preserves readable content, navigation and exact-range mixed-note identity through layout changes, offline editing and browser arrival. An EPUB 3 result does not substitute for EPUB 2.

## Read horizontal RTL and mixed-direction text

**Question:** Do shaping, reading order and selected words remain correct in required horizontal languages?

**Setup:** Fresh downloaded fixtures with known English, Arabic/Urdu and mixed-direction paragraphs, punctuation, numbers, combining marks and repeated words. Expected logical quotations and reading sequences are recorded by the preparer. Each run creates its own mixed note.

- [ ] Read the named paragraphs visually and with VoiceOver. Follow the supplied navigation forward/back in the declared spine order.
- [ ] Search for the specified mixed phrase, select it and create a typed/ink note. Confirm the quoted characters and occurrence against the reference.
- [ ] Change font size, orientation and reflowable reading mode. Reopen the marked range and inspect shaping, punctuation, selected words and ink.
- [ ] Reopen offline, then sync and open the note in each selected browser. It must identify the same logical words rather than a visually reordered string.

**Pass:** Required text is readable and meaningful, navigation follows the book, and the same logical range survives every view. Vertical writing is not inferred from this result.

## Keep a note on the correct fixed EPUB page

**Question:** Does a fixed-page note return to its actual words on either side of a spread?

**Setup:** Fresh text-bearing fixed-layout fixtures, with distinct left/right pages that intentionally repeat the same phrase. Run standard EPUB 3 metadata and recognized legacy Apple/Kobo hint fixtures separately, including LTR/RTL progression. Begin with no notes. The preparer supplies correct page-side/order and reference-layout images.

- [ ] Open single-page view, navigate forward/back and zoom. Designed text/image positions remain intact; inapplicable reflow controls explain why they are unavailable.
- [ ] Open a paired spread and select the reference phrase on the specified side, including the second loaded page. Create and close a mixed text/ink note there.
- [ ] Open the note from its list and from its words, including when the opposite side of that same spread is already visible. It must reach the actual source page and selected occurrence.
- [ ] Switch orientation, single/spread view and zoom. Reopen offline, edit the ink and Undo; then sync and check the same range in each selected browser.

**Pass:** Page order, authored side placement, designed layout and exact-note identity remain correct. Same-looking words on the other page never receive this note. A generic page render without working selection does not pass.

## Bookmark an image-only EPUB page

**Question:** Can a page without selectable words be saved and reopened as the same bookmark?

**Setup:** Fresh image-only fixed-layout EPUB with several distinct pages, an authored description on one image and no selectable visible words on the reference page. Run LTR/RTL and one-resource double-page-image variants separately. Start with no bookmarks.

- [ ] Read/zoom the reference page. Confirm the unavailable-text message and any supplied description; drawing directly on the EPUB page or making a text note from pictured words is unavailable.
- [ ] Disconnect, bookmark the page, rename its label, move elsewhere and reopen through the bookmark list.
- [ ] Change single/spread view and orientation, then close/reopen offline. The bookmark still opens the actual resource/page, including the correct side of a spread.
- [ ] Reconnect and find/open the same bookmark in each selected browser. Remove it and use Undo; the agreed local/synced states and single active entry remain correct.
- [ ] In this run's test copy, remove the source book. The retained bookmark keeps its label/original location with an unavailable explanation, without requiring a saved full page or creating a reading note.

**Pass:** A source-bound page bookmark works without inventing selectable text, OCR or EPUB page ink, and retains the existing bookmark lifecycle/recovery rules.

## Read with bundled and obfuscated EPUB fonts

**Question:** Do the required local font paths preserve the intended readable text?

**Setup:** Fresh known-good ordinary-font, IDPF-obfuscated-font and Adobe-obfuscated-font fixtures, each run separately. References contain distinctive glyphs, horizontal non-Latin text and a specified exact quote. Include fixed/reflowable variants within their supported profiles.

- [ ] Open the book using publisher styling and compare the reference glyphs/positions. Record whether the intended font or a disclosed substitute is actually used.
- [ ] Search/select the reference words, create a text-linked note and verify its quote. Reopen after a layout/view change appropriate to this profile.
- [ ] Close/reopen offline and compare glyphs, text, layout and note association again. No network font request is needed.

**Pass:** Known-good required fixtures exercise their actual font/decoding paths with correct words and usable layout. Substitution is not a passing decoder result; font obfuscation does not add DRM support.

## Understand a font substitution or failure

**Question:** Is a substituted font clearly disclosed, and is unreadable content kept from appearing successful?

**Setup:** Independent prepared fixtures with an unusable font: one has a safe readable fallback, another produces missing letters or broken fixed-page positions. Each run begins with its own valid saved note and known original context. These are test files, not modified personal books.

- [ ] Open the readable-fallback fixture. Find the warning and compare the words, shaping and layout against the reference; the source and note binding remain unchanged.
- [ ] Reopen offline and return to publisher styling. The warning remains accurate; a recovery substitute is not misrepresented as the publisher's font or a changed app default.
- [ ] Open the failure variant. Missing letters, overlap or lost mathematical meaning must be identified as unavailable/failed content, not an acceptable substitute.
- [ ] Reopen the pre-existing note/context. A failed new capture cannot replace it with blank/broken context or publish an incomplete note.

**Pass:** Only a disclosed readable, usable substitute is accepted. Broken content and capture remain explicit failures while earlier local/server work stays intact.

## Read and annotate a static table

**Question:** Does a table retain its meaning, reachability and selected-word identity?

**Setup:** Fresh EPUB with a wide data table, supplied header associations and a repeated reference phrase in different cells. Start without annotations. The preparer records the intended cell/header relationships.

- [ ] Reach every column/cell at normal and larger text sizes without losing native navigation. The table is not silently clipped or replaced with invented prose.
- [ ] Use VoiceOver to read the specified data and supplied header relationships in meaningful order.
- [ ] Select the phrase in the specified cell, create a mixed note, change layout and reopen that note from its selected words.
- [ ] Reopen offline, then sync and inspect the words/note in each selected browser. The same phrase in another cell remains a different range.

**Pass:** Table content and authored semantics remain usable, with exact source selection and preserved notes. Painting all cells alone is insufficient.

## Read an SVG diagram and its authored description

**Question:** Are visible vector content, actual source words and descriptions distinguished correctly?

**Setup:** Fresh EPUB variants with inline SVG, referenced SVG-as-image and standalone SVG pages, each run independently. Include actual SVG text, outlined/raster letters and authored title/description. The preparer marks which reference text is genuinely selectable in its processing context.

- [ ] Open and zoom/read the diagram; labels and all required edges remain reachable in the relevant layout.
- [ ] With VoiceOver, find the supplied name/description as authored. Missing descriptions must not be invented by OCR or transcription.
- [ ] On an eligible actual-text label, create/reopen a text-linked note and verify the exact source quote. On outlined/image-only labels, confirm a description is not turned into fake selected words.
- [ ] Reopen offline and check rendering, description and any valid note. For eligible text variants, sync and check the same selection in each selected browser.

**Pass:** Required diagrams and authored alternatives remain meaningful; valid text anchors survive, and image/path processing never manufactures a text note.

## Read mathematical notation without changing its meaning

**Question:** Do representative static equations remain visually and accessibly meaningful?

**Setup:** Fresh EPUB with Presentation MathML fractions, scripts and a small matrix, authored semantics/alternatives and a defined eligible text label. Include a nearby prose phrase for a separate note reference. Expected visual and spoken meaning are recorded.

- [ ] Read equations at normal/larger text and narrow width. Required symbols/parts remain reachable and their mathematical meaning stays intact.
- [ ] Use VoiceOver to read the supplied semantics/alternatives in the expected meaningful order.
- [ ] Select the eligible source label/prose words, create a note and reopen after layout changes. A non-verifiable formula range must not be replaced with an invented linear quote.
- [ ] Reopen offline and check equation/alternative/note availability; sync the valid note and inspect its correct words in each selected browser.

**Pass:** Required static equations and supplied accessibility remain usable without publisher scripting, and any note uses a real verified range. Correct-looking pixels alone do not pass mathematical accessibility.

## Read a PDF with embedded and non-Latin text

**Question:** Do visible PDF words, selected quotes and page ink agree?

**Setup:** Fresh PDF with embedded/subset fonts, English and horizontal non-Latin text, supplied outline/internal links and known reference words. Include mixed page sizes, nonzero crop origins and intrinsic rotation. This run creates its own page ink and text-linked note.

- [ ] Open the supplied outline/link and return. Search/select the reference words and compare the exact extracted quote with the visible reference.
- [ ] Create a typed note on those words and page ink marking the same place, including a margin comment. Disable writing; ink remains visible.
- [ ] Change fit, zoom, viewer rotation and reading mode. The page, words and full ink extent remain reachable and aligned.
- [ ] Reopen offline, erase/Undo a mark, then sync. Each selected browser displays the correct page ink and source-linked note.

**Pass:** Required fonts/text, navigation, exact quote, page geometry and editable ink work together. A readable raster alone does not establish source-text selection.

## Read and write on scanned or mixed PDF pages

**Question:** Does page ink work on scans while text availability stays honest per page?

**Setup:** Fresh PDF containing an image-only scan, a scan with an existing usable text layer and an ordinary text page. The preparer records which text is genuinely available. Begin with no reading notes.

- [ ] Read/zoom each page. Image-only text is identified as unavailable; supplied available text is exposed rather than treating every scan identically.
- [ ] On the image-only page, create page ink, save locally and disable writing. No new OCR or invented selected-word note is required.
- [ ] On a page with verified usable source text, search/select the reference words and create its own mixed note.
- [ ] Reopen offline, edit/Undo the page ink, then sync. Each selected browser shows the same ink and valid text-linked note; text availability remains accurately described.

**Pass:** Scans remain visually readable and editable with page ink, while only real usable source text supports exact-word notes. Incidental platform recognition alone is not an anchor guarantee.

## Read existing PDF marks and comments without importing them

**Question:** Can existing source annotations and their comment text be read while BookOrbit notes stay independent?

**Setup:** Fresh PDF containing known visible highlight, ink and sticky-note appearances with associated comments, plus an intentionally non-displayed annotation. Record the original source digest and expected comments. Start with no BookOrbit reading annotations.

- [ ] Open the reference page and compare visible source marks against the reference. Respect the intended source visibility rather than displaying a hidden annotation as ordinary visible ink.
- [ ] Discover/read each available comment, including with VoiceOver, and return to the intended page with correct focus.
- [ ] Create your own BookOrbit page ink and text-linked note. Edit/Undo them while source marks/comments remain read-only and separate.
- [ ] Reopen offline, then sync and inspect browser reading/notes. Source marks are not duplicated as imported editable notes or flattened into BookOrbit ink.
- [ ] Check the fixture record: viewing/comment discovery/sidecar editing has not rewritten the original PDF bytes.

**Pass:** Required source appearances and associated comment text are readable, discoverable and preserved, while only BookOrbit notes enter its editable/synced note lifecycle. Unsupported rich threads/attachments need explicit limits rather than a universal fidelity claim.

## Follow available PDF text with VoiceOver

**Question:** Is available text read in meaningful order independently of drawing order or tag presence?

**Setup:** Fresh tagged and untagged PDFs tested separately, with known two-column reading order, headings/links and available text. The tagged fixture's logical order intentionally differs from painting order. Each run creates its own note and records expected meaningful speech order.

- [ ] On the intended iPad/OS with VoiceOver, read the reference paragraphs. They must not interleave unrelated columns or omit available text.
- [ ] Navigate authored headings/links where available, move between pages and return to the intended reading place.
- [ ] Open the run's reading note, reach typed text and the ink's accessible identification, then return to reading with usable focus.
- [ ] Use larger interface text to reach native reading and note controls. Record actual speech/order/focus failures rather than inferring success from extracted text or a tags flag.

**Pass:** Each required known fixture offers complete, meaningful available-text reading and control/note navigation. An image-only announcement or partial label cannot pass a text-bearing accessibility failure.

## Read static fallback content with clear missing-feature information

**Question:** Can usable static content remain available without concealing blocked or missing material?

**Setup:** Independent EPUB/PDF fixtures with unavailable media/interactive content, script/network-dependent content, and a bounded local static fallback. Run each separately with its own note/context. The test environment observes requests without enabling publication scripts or remote-resource loading.

- [ ] Open the book and read the notice identifying the unavailable feature or affected section/page. Static content and supported local fallback remain readable where usable.
- [ ] Navigate to the missing feature and back. No script, form submission or unsolicited remote resource is enabled to make the notice disappear.
- [ ] Download/reopen offline. A partial view is labelled partial, with omitted content still identified; it is not represented as a complete Ready offline publication.
- [ ] Reopen this run's existing note/context. Notes on original content do not silently move to a different fallback resource, and failed new context capture preserves earlier valid work.

**Pass:** Partial reading is useful and explicit, local fallback has verified provenance, and blocked/omitted material never masquerades as present or completely offline. Failure of a mandatory static profile remains a failure.

## Understand unsupported layout and interactive profiles

**Question:** Does an out-of-profile book explain its limits without corrupting reading state?

**Setup:** Independent test books for mixed reflowable/fixed EPUB, vertical-writing EPUB and an unsupported interactive document feature. Include one isolatable readable static portion and one variant that cannot be read faithfully. Each run starts with its own valid retained note/bookmark.

- [ ] Open the book and find the specific layout/feature explanation; no unsupported mode is silently advertised as working.
- [ ] Read only an actually usable isolated portion when available. If faithful reading is impossible, the refusal is clear and retains a way back.
- [ ] Try its supplied destination/bookmark. The app cannot report reaching a target when another section/page is shown instead.
- [ ] Reopen the original retained note/context and bookmark list. Nothing was relocated, erased or falsely marked complete merely because the book cannot fully open.

**Pass:** Partial or refused outcomes match actual usability, with explicit reasons and retained work. No automatic conversion, protection bypass, mixed-layout support or vertical-profile promise is inferred.

## Keep a failed source-bound jump honest

**Question:** Can an unreadable page/section be reported without opening the wrong target as a success?

**Setup:** Fresh EPUB with two same-looking reference passages in different resources and a prepared broken target; include an independent fixed-spread opposite-side variant. Create this run's note/bookmark and valid saved context before inducing the controlled test failure. Original identity remains recorded.

- [ ] Open the valid note/bookmark and confirm its exact target and side before the failure is introduced.
- [ ] Trigger the prepared unreadable-target condition and open the same note/bookmark again.
- [ ] Confirm the specific failure, preserved origin/way back and access to saved note/context; the next loadable chapter or other spread page is not presented as the requested target.
- [ ] Restore the exact test source/resources through the supported retry process. Reopen, verify the original target and edit/Undo its ink without changing note identity.

**Pass:** Source-bound navigation either reaches the verified target or returns a clear failure with recovery; silently skipped sections and stale active-side reports cannot produce false success.

## Technical and cross-device gates

These are additional future checks, not hidden steps supplied by another walkthrough. Each automated/fault run creates and verifies its own state. The linked authoritative matrices retain their numeric conditions and existing acceptance obligations.

| Gate                               | Required observations                                                                                                                                                                                                                                                                                                                                                               |
| ---------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Layout detection and locators      | Standard/legacy/conflicting metadata; explicit mixed-spine declarations; repeated resource hrefs with distinct spine occurrences; same-spread side changes and relocation; correct native/browser source document/range; resource/page bookmarks and resume; original-source unavailable/reimport behavior.                                                                         |
| Text and static structures         | Untrimmed quotes, UTF-16 boundaries, bidi/combining marks and repeated text; canonical XML/body-tree stability, SVG contexts, table associations, MathML semantics; no description-to-visible-word invention or silent selector rewriting.                                                                                                                                          |
| Fonts and fallback resources       | Known-good decoder fixtures versus safe/unsafe substitution; immutable source bytes; unknown font algorithms; fallback-chain cycles/missing resources/unsupported alternatives; actual rendered resource provenance and explicit unavailable outcomes.                                                                                                                              |
| Containment and bounds             | No publication scripts or unsolicited remote requests; malformed/protected/oversized input, archive/member/expanded/image/DOM/deadline failures; PDF page/file/geometry bounds; cancellation and memory recovery with native controls and protected work usable. Apply the [storage limits and measurements](../decisions/storage-recovery.md#initial-negotiated-resource-limits).  |
| New bookmark locator compatibility | Explicit capability/schema/DTO/shared/native fixtures, migration and old-client/importer handling; one canonical resource target; durable retries/receipts, concurrent labels, removal-versus-offline edits, Undo, source removal/verified reconnection and app/server recovery. Reuse the [bookmark contract](../decisions/reader-controls.md#bookmark-sync-removal-and-recovery). |
| PDF source content                 | Annotation visibility/appearance/comment distinctions; no original rewrite or accidental editable import; permitted text access, existing OCR layers, tagged/untagged order, unsupported cross-document links with preserved origin. No signature verification claim from a visible signature.                                                                                      |
| Save/sync/context faults           | Complete matching archive/preview/context publication, missing capture resources, interrupted saving/loading, WebKit termination and safe retry; source replacement/merge and account isolation; protected drafts and prior server revision; unsaved browser edits. Use the [sync acceptance cases](../decisions/offline-sync.md#required-validation-scenarios).                    |
| Declared environment and scale     | Intended Air M2/current iPadOS and each recorded Mac/Android browser with versions captured again; representative private copies plus fixtures; twenty offline books and existing server dataset/working-set/latency conditions; existing signing/update and restore gates. No new count cap or copied earlier fixture pass.                                                        |

Record required-profile coverage separately from optional/out-of-profile outcomes and minor cosmetic defects. Complete-journey readiness and the thirty-minute sessions remain with [Agree the complete reading journey and build-readiness criteria](https://github.com/mooneeb/bookorbit/issues/13). No runtime check above is marked passed by publishing this plan.
