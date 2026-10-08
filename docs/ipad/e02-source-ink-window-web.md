# E02 shared source ink window regression

`IPAD-E02-A03-source-window-web` is one public browser regression for shared source PDF ink beyond 1,000 live groups on the same page. The reviewed defect retained baked appearances while dropping the oldest selection metadata through a 1,000-item client slice. This component supplies repeatable acceptance assertions for the bounded source window correction. It does not modify the existing private collection driver.

Run only in the isolated annotation harness after the runtime owner grants an exclusive source file 1 write lease and releases the backend 101-group contract test:

```sh
IPAD_TEST_RUN=e02-source-window-web ./node_modules/.bin/playwright test --config scripts/ipad/source-ink-window-web.config.mjs
```

The setup requires fewer than 100 pre-existing shared groups on PDF page 0. This explicit isolated-fixture condition keeps all unrelated groups reachable in the first window during cleanup. It creates 1,101 independently identified shared groups using authenticated owner source operations, at most 100 operations per batch. Source revision and page fingerprint come from the real inspection route before each batch. These are protocol stroke fixtures, not physical Pencil input. Core routes, permissions, canonical persistence and PDF publication are real.

The fixture has a separate finite setup budget of seven minutes and 30-second request limits. The browser journey retains its own 180-second budget. An independently created API context remains alive after browser cancellation; cleanup has a three-minute budget and at most 20 batches. The fixture owns a preallocated set of 1,102 random client UUIDs, including the remote addition, so cleanup can discover a committed create even if its response was interrupted. Cleanup deletes only those UUIDs using authoritative current versions and source fingerprints. It verifies the original live total and every unrelated first-window ID/version. It never queries or mutates private annotations.

Before seeding, the fixture captures public reading progress, downloads the original source and requests the harness's explicit source snapshot. Teardown independently attempts UUID cleanup, exact source restoration and exact progress restoration; it records failures and never suppresses them. The cleanup JSON preserves owned UUIDs, baseline source SHA and original logical position for bounded recovery. Source restoration uses the owner-only controlled fixture endpoint and is safe only under the exclusive source lease. It must not overlap another source writer or snapshot user.

The visible browser journey signs in and opens the public PDF page-1 deep link. It requires the oldest fixture group to be selectable in the first window after more than 1,000 newer groups exist. Right-click Delete must publish a canonical deletion and remove the group from the delivered PDF. Toolbar Undo must send a new operation with the committed deletion version and restore the group and red appearance. The source-ink footer, identified by `source-ink-pagination`, drives Next through the eleventh 100-row window and Previous back to the first. Each response and visible selection layer must remain bounded at 100 groups while the book stays on page 1. A remote green group is then created, reached in the final window, and the oldest group remains reachable on return.

Delivered PDFs are inspected for public embedded ink identities and page geometry, and independently rendered with `pdftoppm`. Literal red/white pixel assertions verify delete and inverse appearances. Browser screenshots capture the oldest context menu, versioned Undo, eleventh window and remote final window using the existing annotation visual helper. That helper preserves differences and never creates approved baselines automatically. The final Tester must open and inspect these actual images after running the component. No screenshot from this unrun component has been approved.

## Builder validation and handoff

The Builder ran only Node syntax checks, Prettier and Playwright test discovery. Discovery found one named test. No live seeding, source mutation, browser acceptance run or full suite was performed, as root reserved the source lease for the backend contract and the integrated final Tester. T3 `preview_status` and `preview_open` were available and opened the actual login page; that establishes preview availability only.

The reviewed old-client truncation is the supplied regression premise. Actual browser GREEN, failure-safe timeout cleanup, artifact/screenshot inspection and human-reviewed visual comparison remain final Tester gates. Hardware input and broader viewport/accessibility matrices are outside this single regression component.

Harness inclusion is required: run this standalone configuration once, serially after the source-window backend contract and existing source writers have completed cleanup. The new file is not matched by the existing E02 cross-client configuration, so merely running that configuration does not execute this regression. Root or the harness owner must add the serial invocation to the integrated run without assigning another concurrent source writer.
