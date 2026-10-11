# E04 cross-client browser verification

The browser suite drives the existing Vue application, authenticates through its sign-in form, and uses public authenticated HTTP plus independently parsed delivered PDFs for persistence and artifact assertions. It runs after the corresponding native journeys against the same isolated migrated PostgreSQL database and temporary content. No library, server route, synchronization, permission check, or web screen is mocked.

Run the integrated harness with `node scripts/ipad/run-harness.mjs --reading-sharing --ui --web --case=A01`. Omit `--case` for all five journeys. The harness owns process startup, migrations, fixtures, controlled providers, native execution, and teardown. E04 uses API port 16502 and web port 16504 independently of other tickets. `IPAD_WEB_URL` overrides the browser URL. All implementation and execution use the isolated `BO-5-track-reading-share` worktree.

`node_modules/.bin/playwright test -c scripts/ipad/e04-web.config.mjs --list` lists the exact browser journeys without starting a browser. To reproduce one journey against a retained harness server, pass its actual `IPAD_E04_NATIVE_STATE_FILE`, `IPAD_E04_RECEIVER_URL`, `IPAD_TEST_RUN`, and `IPAD_WEB_URL`, then run the same config with `IPAD_E04_CASE=A01`. The handoff must come from actual native UI execution in that server's run. The browser fails when it is absent. Inventing a handoff or deriving expected values from the API is not native cross-client evidence.

| QA  | Browser test ID                               | Observable assertions                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| --- | --------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 1   | `IPAD-E04-A01-web-record-and-statistics`      | Native status, rating, personal note, iOS and manual sessions appear on the web; reconnect preserves identities and totals; the independent 600-second reading plus 300-second listening example yields 900 seconds, two sessions, the native-edited annual goal, and the earned achievement.                                                                                                                                                                                                                                        |
| 2   | `IPAD-E04-A02-web-privacy-insights`           | Another permitted account sees only library/content-eligible detailed records; private note/highlight text is excluded; changing to summary removes detail; withdrawal denies existing view sessions; restricted public book/file/insights actions are denied and controls are hidden.                                                                                                                                                                                                                                               |
| 3   | `IPAD-E04-A03-web-delivery-settings-outcomes` | Native KOReader and OPDS credentials, Kobo device and successful activity, email provider and Kindle recipient, and SMTP-accepted job history appear on current web screens. Feature-owned native/HTTP tests inspect independent catalog, Kobo, and mail artifacts and protocol exchange.                                                                                                                                                                                                                                            |
| 4   | `IPAD-E04-A04-web-current-pdf-redelivery`     | The ink item created and moved through actual native UI reaches real source publication; the web PDF reader selects and deletes that same item; Basic-authenticated OPDS acquisition delivers byte-identical current source content before and after publication; independent PDF annotations and Poppler rendering show the native mark and its committed deletion; reconnect keeps the deletion and logical page.                                                                                                                  |
| 5   | `IPAD-E04-A05-web-external-settings-outcomes` | Native Hardcover, StoryGraph, and Readwise settings appear on the web; independent protocol receipts contain the expected eligible remote records/highlights; excluded private text stays absent; Readwise authentication failure and retry are visible and reconnect preserves settings without creating duplicate highlights. The separate native Hardcover import account shows its imported status and one stable remote reading-history identity on the web. Feature tests own transport/mapping/timeout/missed-event recovery. |

The harness saves receiver `GET /native-handoffs` as `IPAD_E04_NATIVE_STATE_FILE`. Native test authors publish expected literals to `POST /native-handoff`. The receiver merges separate feature contributions, keeping the native record and statistics accounts separate. The browser consumes these fields:

```json
{
  "A01": {
    "testId": "IPAD-E04-A01",
    "case": "A01",
    "username": "ipad-e04-record",
    "record": {
      "username": "ipad-e04-record",
      "bookId": 1,
      "fileId": 1,
      "readStatus": "reading",
      "rating": 4,
      "personalNote": "E04 native personal note",
      "nativeSession": {
        "source": "ios",
        "sessionType": "read",
        "minimumSeconds": 10
      },
      "manualSession": { "source": "manual", "durationSeconds": 300 }
    },
    "statistics": {
      "username": "ipad-e04-statistics",
      "totalSeconds": 900,
      "totalSessions": 2,
      "completedBooks": 1,
      "goalBooks": 24,
      "source": "ios",
      "sourceSeconds": 900,
      "earnedAchievementKey": "books_finished_1"
    }
  }
}
```

Every other case has the same `testId`, `case`, and `username` envelope. A02 supplies `viewerUsername`, `userId`, `permittedBookIds`, `excludedBookIds`, `excludedFileIds`, `excludedBookTitles`, `privatePersonalNote`, and `privateHighlight`. A03 supplies `catalog` with KOReader/OPDS usernames and passwords; `kobo` with `deviceName` and `expectedActivity` event names; and `email` with `providerName`, `recipientName`, `recipientAddress`, and `bookId`. A04 supplies `bookId`, `fileId`, `ink` with the native-created `annotationId`, `clientId` and `version`, and native-configured `catalog` with `opdsUsername`, `opdsPassword`, and `bookId`. A05 supplies `hardcover` and `storygraph` with `enabled` and `remoteBookIds`, `readwise` with `enabled` and `expectedHighlightTexts`, `hardcover.import` with the separate native import `username`, `bookId`, `status`, `externalReadId`, `startedOn`, and `endedOn`, and `excludedTexts`. Credentials are local fixture values and must never be replaced by live secrets.

Browser configuration reuses the documented representative annotation matrix: `pro13-portrait-light`, `pro11-landscape-dark`, `pro11-portrait-large`, and `pro13-narrow-dark`. Each run pins Chromium, en-US, UTC, viewport, theme and Reduce Motion. It waits for observable UI/network state and font readiness; animations remain enabled in transition assertions and screenshots. Browser CSS layouts do not emulate native Dynamic Type. Large Dynamic Type assertions belong to the native configurations with those profile names. Browser control checks verify visible enabled controls, keyboard focus, and viewport reachability. They complement native accessibility audits and do not claim a complete browser accessibility audit.

Each meaningful browser state writes an actual PNG and a JSON report below `test-results/ipad/<runId>/e04-browser/<test>/visual/`. Delivered PDFs and their independently rendered PNGs are attached beside those files. Named state images include reading records/session history, worked-example charts/goals/achievements, sharing confirmation/detail/summary/denial, catalog/device/mail settings and outcomes, PDF deletion menu/reconnect, and provider settings/error/retry/reconnect.

Playwright also writes `test-results/ipad/<runId>/e04-browser-summary.json`. The harness reads its result counts and requires every selected browser journey to pass with zero skipped, unexpected, or flaky results. Test discovery alone does not satisfy that runtime gate.

Visual comparisons reuse `compareReadingSharingVisual()` and the reviewed `ipad/VisualBaselines/E04/reviews.json` manifest. A baseline entry requires its test ID, state, web surface, profile, image file, SHA-256, `reviewedBy`, and `reviewedAt`. Only explicitly justified irrelevant-pixel masks are allowed. The comparator preserves expected, actual, diff and review JSON, verifies checksums, and fails meaningful pixel or dimension changes. New baselines are never auto-accepted. The default browser gate also fails missing human-reviewed baselines after the functional journey has captured its states. `--functional-only` permits useful functional/screenshot execution while recording the missing visual approval; it cannot establish completion.

Current acceptance status is recorded in the [evidence ledger](e04-acceptance-ledger.md). The genuine native Record handoff from `run-10682-1791721014425` verifies actor 6/book 1/file 1, native personal fields, manual 300s and iOS 16s sessions, and actor isolation through visible web/public API. The narrow `IPAD-E04-A01-web-record-history` continuation passes in 3.6s in `test-results/ipad/e04-resume-a01-record-history-ready/`; reload preserves IDs/statistics and both actual 1024x1366 images are nonblank and inspected. Prior locator timeouts, the interrupted Record attempt and the earlier blank reconnect capture remain retained. FullA01 Statistics/goals/achievements still require a genuine native Statistics contribution, and the native Record selector remains failed with 21 unfiltered audit findings.

Email has produced actual accepted source-equal MIME PDFs with independently parsed private-content exclusion, but native retry-feedback criteria and A03.email handoff remain unverified. Privacy has completed Private/Summary Save and 503 retry functional checkpoints but remains blocked at Sessions visibility, with no A02 handoff. Their dependent browser branches remain unrun. Other previously unrun native/browser/profile checks remain unrun; no human visual baseline approval is claimed.

After each actual run, open the images and any expected/diff images, and record the test ID, state, profile, artifact path, findings, and rerun result in the ledger or linked durable report. Check clipping, overlap, contrast, typography, control reachability, reader page placement, ink alignment, menus and error states. File existence alone does not count as visual inspection.

Physical reader firmware/PDF rendering, actual Kindle/vendor delivery, live external credentials, real Pencil input, VoiceOver usability, and the integrated human walkthrough require their documented device/service/human checks. The protocol and browser coverage prove only their automated downstream boundaries. These residual checks and human baseline approval remain completion gates for issue #5.
