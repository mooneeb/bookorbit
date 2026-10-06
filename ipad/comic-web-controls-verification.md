# Comic web page controls

The independent comic browser test retained a real authenticated fixture from
`run-50879-1791321935136`. The native comic matrix passed five tests, and the
browser resume journey passed in 9.8 seconds. The page-controls journey failed
in 20.4 seconds at `comic-cross-client.test.mjs:80`: the visible first-page
button had no accessible name. The full error context lists four unnamed
footer buttons between reader settings and notifications.

Both actual RED screenshots were opened independently:

- `/tmp/bookorbit-comic-qa-8f548c03/test-results/ipad/run-50879-1791321935136/browser-controls-red/comic-cross-client-IPAD-E0-763ef-avigate-actual-comic-pixels/IPAD-E01-A05-comic-visible-page-controls.png`
- `/tmp/bookorbit-comic-qa-8f548c03/test-results/ipad/run-50879-1791321935136/browser-controls-red/comic-cross-client-IPAD-E0-763ef-avigate-actual-comic-pixels/test-failed-1.png`

They show the delivered comic page 2 and all four footer navigation icons.
The source repair gives each button an `aria-label` from existing translated
first, previous, next, and last page messages. Existing method references,
navigation behavior, and previous/next boundary disabling are unchanged.

Prettier, targeted client ESLint, and `git diff --check` passed before the
repair commit. A full client typecheck was deferred because the independent
tester owned the heavy-check lock and retained fixture. Its corrected web
build passed in 4.08 seconds; the existing chunk-size warning remains recorded
in `browser-controls-build.log`.

The independent tester applied the repair as QA commit `5dec52bc`, rebuilt the
web client, and reran both unchanged public browser journeys on the retained
native fixture. `browser-controls-green.log` records two passes: reopening the
native saved page and reopening it after a reload took 9.9 seconds; the named
controls, first/last boundary disabling, and ArrowRight navigation took 9.2
seconds. The rerun used one worker and zero retries. No additional native run
was needed for this web-only source repair.

All ten actual GREEN PNGs and eight OCR reports under
`/tmp/bookorbit-comic-qa-8f548c03/test-results/ipad/run-50879-1791321935136/browser/`
were independently opened or read. The controls images show the actual initial
page 2, previous page 1, next page 2, last page 3, first page 1, and keyboard page
2, plus the visible toolbar. The three resume images show the same delivered
page 2 before and after reload, including the toolbar. The OCR reports confirm
the literal delivered page number at every captured navigation state.

The separately retained authenticated public response
`browser-final-public-progress.json` records page 2 and percentage `66.666664`,
with CFI and all six obsolete Kobo/KOReader companions null. Narration is null
in this final response because the final native failure journey deliberately
reset that fixture; this response does not prove narration preservation.

The accessible-name repair is verified through the unchanged browser controls
journey and independently inspected actual artifacts. This note does not mark
the wider issue complete.
