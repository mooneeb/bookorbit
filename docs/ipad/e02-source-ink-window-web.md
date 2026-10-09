# E02 shared source ink window regression

`IPAD-E02-A03-source-window-web` is one public browser regression for shared source PDF ink beyond 1,000 live groups on the same page. The reviewed defect retained baked appearances while dropping the oldest selection metadata through a 1,000-item client slice. This component supplies repeatable acceptance assertions for the bounded source window correction. It does not modify the existing private collection driver.

Run only in the isolated annotation harness after the runtime owner grants an exclusive source file 1 write lease and releases the backend 101-group contract test:

```sh
IPAD_TEST_RUN=e02-source-window-web ./node_modules/.bin/playwright test --config scripts/ipad/source-ink-window-web.config.mjs
```

The self-contained integrated command creates the isolated fixture and runs this configuration serially after the authenticated source-window contract, six main browser journeys and two private collection journeys:

```sh
node scripts/ipad/run-harness.mjs --annotations --web
```

The setup requires fewer than 100 pre-existing shared groups on PDF page 0. This explicit isolated-fixture condition keeps all unrelated groups reachable in the first window during cleanup. It creates 1,101 independently identified shared groups using authenticated owner source operations, at most 100 operations per batch. Source revision and page fingerprint come from the real inspection route before each batch. These are protocol stroke fixtures, not physical Pencil input. Core routes, permissions, canonical persistence and PDF publication are real.

The fixture has a separate finite setup budget of seven minutes and 30-second request limits. The browser journey retains its own 180-second budget. An independently created API context remains alive after browser cancellation; cleanup has a three-minute budget and at most 20 batches. The fixture owns a preallocated set of 1,102 random client UUIDs, including the remote addition, so cleanup can discover a committed create even if its response was interrupted. Cleanup deletes only those UUIDs using authoritative current versions and source fingerprints. It verifies the original live total and every unrelated first-window ID/version. It never queries or mutates private annotations.

Before seeding, the fixture captures public reading progress, downloads the original source and requests the harness's explicit source snapshot. Teardown independently attempts UUID cleanup, exact source restoration and exact progress restoration; it records failures and never suppresses them. The cleanup JSON preserves owned UUIDs, baseline source SHA and original logical position for bounded recovery. Source restoration uses the owner-only controlled fixture endpoint and is safe only under the exclusive source lease. It must not overlap another source writer or snapshot user.

The visible browser journey signs in and opens the public PDF page-1 deep link. It requires the oldest fixture group to be selectable in the first window after more than 1,000 newer groups exist. Right-click Delete must publish a canonical deletion and remove the group from the delivered PDF. Toolbar Undo must send a new operation with the committed deletion version and restore the group and red appearance. The source-ink footer, identified by `source-ink-pagination`, drives Next through the eleventh 100-row window and Previous back to the first. Each response and visible selection layer must remain bounded at 100 groups while the book stays on page 1. A remote green group is then created, reached in the final window, and the oldest group remains reachable on return.

Delivered PDFs are inspected for public embedded ink identities and page geometry, and independently rendered with `pdftoppm`. Literal red/white pixel assertions verify delete and inverse appearances. Browser screenshots capture the oldest context menu, versioned Undo, eleventh window and remote final window using the existing annotation visual helper. That helper preserves differences and never creates approved baselines automatically. Screenshot inspection is separate from human baseline approval; no baseline has been approved automatically.

## Builder validation and handoff

The Builder ran only Node syntax checks, Prettier and Playwright test discovery. Discovery found one named test. No live seeding, source mutation, browser acceptance run or full suite was performed, as root reserved the source lease for the backend contract and the integrated final Tester. T3 `preview_status` and `preview_open` were available and opened the actual login page; that establishes preview availability only.

The reviewed old-client truncation was the supplied regression premise at the Builder handoff. The final execution below supplies actual browser GREEN. Forced timeout cleanup and human-reviewed visual comparison remain separate evidence gates. Hardware input and broader viewport/accessibility matrices are outside this single regression component.

The harness now invokes this dedicated configuration once, serially after the source-window backend contract and existing source writers complete cleanup. Running only the main cross-client Playwright configuration still excludes this regression; use the integrated command above or its explicit standalone configuration under an exclusive lease. The source-window report is stored in a separate `-source-window` directory.

## Final fresh integrated execution

On candidate `4a75ab220a0647bf1803748c6d25e1af4a1603c5`, `run-41109-1791495583976-source-window` passed the dense source journey in 21.7 seconds; the complete phase including its 1,101-group fixture and cleanup took 1.3 minutes. The [actual source-window report](../../test-results/ipad/run-41109-1791495583976-source-window/browser-report/index.html) records one pass, no failures or skips. This was the final serial phase of the fresh 32-check HTTP/browser run, which completed in 214.757 seconds with `cleaned=true`.

Actual UI assertions selected the oldest group beyond 1,000 newer groups, published deletion and its explicit versioned inverse, traversed the eleventh hundred-row source window and displayed the remote green addition while keeping the oldest group reachable. Public embedded IDs, complete PDF geometry and independent Poppler pixel assertions passed. The [cleanup record](../../test-results/ipad/run-41109-1791495583976-source-window/browser/source-ink-window-web-IPAD-2962e-e-thousand-same-page-groups/source-window-fixture-cleanup.json) contains all 1,102 owned UUIDs, no errors, baseline source SHA-256 `22786bf43be70d665893d6e1320895efc0c2bcf28bdef9ea9490b8c6c9074e37` and captured progress `{percentage: 0, pageNumber: null, cfi: null}`. Successful teardown assertions restored source bytes, logical position and the original live identities. This run does not inject a timeout to validate the cancellation path.

Earlier fresh integrations at `44423e4ed49dd71d470a5bca231febb0f5384234` and `c3742ee8` stopped in preceding browser/collection phases, so neither reached this dense browser journey. Their failures remain preserved; no skipped dense execution was counted as a pass. The final [collection-fix review](../../test-results/ipad/run-41109-1791495583976/reviews/bookorbit-issue-3-collectionfix-code-review.md) is preserved with this run.

The [independent final report](../../test-results/ipad/run-41109-1791495583976/final-integrated-validation-report.md) confirms inspection of all four actual dense browser captures and the independent source PDF renders. Across the integrated run, it inspected 48 unique PNGs and parsed all 27 complete delivered PDF artifacts. Global teardown independently left no owned database or sessions, no listeners on ports 16482/16484/16485, no runner process and no `bookorbit-ipad-*` temporary content folders.

### Medium visual follow-up

The immediate [versioned Undo browser capture](../../test-results/ipad/run-41109-1791495583976-source-window/browser/source-ink-window-web-IPAD-2962e-e-thousand-same-page-groups/IPAD-E02-A03-source-window-versioned-undo.png) shows unrelated gray/blue groups painted red. The corresponding [exported restored PDF render](../../test-results/ipad/run-41109-1791495583976-source-window/browser/source-ink-window-web-IPAD-2962e-e-thousand-same-page-groups/source-window-oldest-restored.png) preserves those colors, and the later [eleventh-window browser capture](../../test-results/ipad/run-41109-1791495583976-source-window/browser/source-ink-window-web-IPAD-2962e-e-thousand-same-page-groups/IPAD-E02-A03-source-window-eleventh-window.png) shows the correct colors again. The observation is limited to the immediate capture; duration, reproducibility and persistence are unverified. No delivered source corruption was found. This Medium follow-up is nonblocking and does not change the passing assertions into an approved visual baseline.

The observed reproduction is the completed dense journey: retain the original blue group, create 1,101 same-page groups with the oldest red and remaining fixture groups gray, then right-click Delete and versioned Undo for the oldest group. The image establishes the immediate paint discrepancy; it does not establish whether recovery requires pagination. Three follow-up acceptance checks are recorded by the Tester:

1. The first settled browser render after Undo preserves the unrelated blue and gray groups and matches the independently rendered delivered PDF.
2. Create, Delete, Restore and Undo preserve colors at multiple zoom levels without requiring pagination or reopening; inspect any exposed intermediate paint.
3. Keep the existing source identity, version, publication and unrelated-group invariants while confirming oldest red deletion/restoration and remote green addition in browser and delivered PDF.

Native runtime is now available: A02 two-group publication and main A03 transform/published-Undo passed on native `0ce6d2e4`; lasso subset/transforms/copy/versioned inverse with newer separate ink and same-item newer-edit refusal passed on `2d30eb9e`, all with server fixture repair `eb18c746`. This is four of six named source methods passed across two pins. Unknown-write/restart and precommit cancellation remain failed on positional accessibility queries and await matching repaired products. The [current native acceptance evidence](e02-web-acceptance.md#native-acceptance-evidence) records exact pins, results, cleanup, successful fresh baseline reader reopening and the preserved wider-interval performance RED. The revised two-second Page 2 timing boundary still requires execution. This dense protocol/browser journey does not substitute for those native checks.

Concurrent native/browser sessions, XCTest performance and the remaining full/narrow-window, large-text, Reduce Motion and accessibility matrix still need actual execution. Physical Pencil/Scribble, the human walkthrough and human-reviewed visual baselines remain nonblocking residuals, pending and never PASS.
