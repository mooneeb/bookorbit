# Native fixed-page reading layouts

Implementation handoff for issue #2. Runtime acceptance is pending with an independent tester.

## Implemented behavior

- PDF supports paged, continuous vertical and continuous horizontal reading. Facing-page choices use the canonical single, odd, even and responsive-auto settings. Odd pairs pages one/two; even keeps the cover separate. Auto follows the existing web rule: width at least 900 and aspect ratio at least 1.1.
- Comic supports paged, continuous vertical and long-strip reading. Long strip removes inter-page spacing. Page fit remains independently selectable, matching the web settings. Facing pages apply only in paged mode, preserve the separate cover, and support shifted alignment, a canonical bounded gap, and forced two-page display on narrower screens.
- Right-to-left comic reading reverses the displayed pair and horizontal gestures, curl spine, programmatic transitions and arrow-key navigation. Previous/Next retain their logical meanings. The existing five animations and Reduce Motion behavior remain available for paged reading.
- Direct navigation, search/contents destinations and bookmarks retain their logical file page. Mode, direction, window and orientation changes rebuild the visual surface around that page. Continuous scrolling retains the current page and its relative offset during an in-session size or measured-height change. Persisted progress continues to represent the logical page rather than a screen-dependent spread or pixel offset.
- Both readers reuse their existing real PDFKit/image controllers and acknowledged progress transport. A failed image in either displayed facing page exposes the existing Retry page control. No source PDF rotation or delivered comic bytes are changed.

## Contracts and ownership

The existing generated `PdfReaderSettings` and `CbxReaderSettings` contracts are the source of truth. The generator now derives the spread-gap bounds from the shared constants. No backend route, schema or persistence format is introduced.

Native PDF owns all five canonical PDF fields. Native comic additionally owns view mode, scrolling mode, direction, alignment, gap and force-two-page. The existing account synchronization setting controls changed-only default/per-file PATCH requests. Native animations remain local. Cancel performs no write, and Use defaults unsets only the fields this implementation owns. Concurrent web-owned comic wide-page and next-series settings are preserved.

## Resource bounds

Paged layout maps any page/spread in constant time without building an array for the publication. At most three spread controllers, containing at most six comic images, are retained by the native paging coordinator/model.

Continuous layout uses a real recycling collection view with prefetch disabled. Unknown page heights are estimated from the viewport; only current/visible/adjacent heights are measured, with at most 64 retained measurements. Finding the visible page uses binary search over the page count and the bounded measurements. It never walks all PDF pages or fetches all comic pages to build layout.

Comic continuous loading retains the actual visible set, capped at 32 pages, one neighbor at each end, and the current logical page. Transfers and off-main-actor ImageIO decoding remain sequential. Images leaving that window are released; cancelled transfers cannot insert stale images. The existing 3072-pixel thumbnail limit remains. This larger adaptive window is necessary when several short landscape pages are visible together. Native page cells have a 120-point minimum height for extremely short pages. Total scroll extent uses estimates until pages are measured, so the scrollbar is approximate for heterogeneous unvisited pages. Memory and transition budgets still need runtime measurement.

## Implementation verification

- Shared TypeScript build, generated-contract freshness, Node syntax, strict Swift formatting and Swift parsing passed.
- Production Swift 6 native build passed at `/tmp/bookorbit-fixed-reading-modes-build.log`. Existing OIDC initializer deprecation and missing AppIntents metadata warnings remain; no new compiler warning was reported.
- Source review confirmed the installed web spread plugin's actual odd/even grouping and the existing responsive PDF predicate. The installed UIKit SDK documents min/max curl spines as requiring one visible controller.
- The final build after aligning the responsive predicate also passed at `/tmp/bookorbit-fixed-reading-modes-build-final.log`. No runtime UI/API/artifact, browser, accessibility, screenshot inspection, visual baseline or physical acceptance is claimed here.

## Independent acceptance handoff

Test through public authenticated HTTP, the production native PDF/comic screens, actual web readers and delivered PDF/archive/page bytes. Cover every mode and pair alignment, left/right gestures with animations enabled, keyboard direction, first/last/incomplete spreads, direct navigation into the second page of a pair, page-failure Retry, acknowledged progress, Cancel and failed/held preference saves, relaunch and concurrent web preferences. Inspect actual screenshots and run complete unfiltered accessibility audits in portrait/landscape, narrow/wide windows, light/dark, large Dynamic Type and Reduce Motion. Include the existing PDF and comic regression journeys and genuine archive formats.

Wide-page singleton adaptation and next-series automatic advancement remain separate comic feature work. Production EPUB/fonts, audio, recorded Read Along, separate TTS and ebook/audio bridging remain issue #2 work. The issue's human-reviewed deterministic baselines, physical residuals and integrated human walkthrough are not waived by this autonomous handoff.
