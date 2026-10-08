# Author and series verification

Implementation checkpoint: `98cc85a0`. Testing uses the actual production native app, authenticated BookOrbit HTTP routes, delivered PDF bytes and the existing web app. Core routes, authorization and storage are real. The organization proxy substitutes only an explicitly controlled 503 failure; it forwards all other requests to the real isolated server.

Run the maintained journeys with the cached simulator:

```sh
IPAD_TEST_DESTINATION='platform=iOS Simulator,id=2D308564-4246-4C75-B67B-DCFC2AD4BE7B' \
IPAD_TEST_ONLY='BookOrbitUITests/OrganizationJourneyTests' \
pnpm exec node scripts/ipad/run-harness.mjs --ui --web --organization-proof
```

The ordinary production cross-client gate also includes these native, public HTTP and browser tests. A focused result does not replace that aggregate gate.

The fixture adds 55 authors and 55 series to the existing 50,000 books without changing any book title or total. The first author and series each contain 45 books. The series owns volumes 1 and 3 through 46 out of 47, leaving the independently asserted gaps 2 and 47. Existing January 2026 acquisition dates make the recent-books filter deterministically empty in the pinned October 2026 environment. All test expectations use literal fixture records and public responses; the database is used only to construct the fixture.

| Named test                                                                                                             | Observable behavior                                                                                                                                                                                                         |
| ---------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `IPAD-E01-A01/A05-organization: authorized directories page, search, sort and filter without exposing another library` | Exact authorized 40/15 directory pages, search, name direction, library, sort-name/photo/book-count/recent and series-gap/author/completion filters; bounded responses; rejected invalid parameters and inaccessible roles. |
| `IPAD-E01-A01/A05-organization: profiles and forty-book pages lead only to authorized files`                           | Literal author facts, 40/5 author and series book pages, numeric volume order, series gaps and actual authorized PDF delivery; denied or empty unauthorized responses.                                                      |
| `testIPADE01A01AuthorDirectoryPagingAndFilters`                                                                        | Actual sidebar, native paging, descending sort, canceled/applied/reset filter drafts, recent empty state, exact search and rotation.                                                                                        |
| `testIPADE01A01AuthorProfileBookPagingAndPDF`                                                                          | Actual native author facts, book paging, permitted detail and PDF reader, genuine horizontal curl to passage 2, acknowledged public position and a hidden metadata editor for a read-only role.                             |
| `testIPADE01A01SeriesDirectoryFiltersAndBookPaging`                                                                    | Native series counts/gaps, author and completion filters, profile and numeric volume paging, correct authorized PDF detail.                                                                                                 |
| `testIPADE01A05OrganizationRestrictedAndRetry`                                                                         | Empty native directories for the inaccessible role, visible controlled server error, and actual retry recovery.                                                                                                             |
| `IPAD-E01-A01-organization-web`                                                                                        | Existing web directories and profiles agree with native records; independently rendered PDF passage 2 resumes after a native organization route, then survives close, reload and reopen.                                    |
| `IPAD-E01-A05-organization-web`                                                                                        | Existing web directories and delivered-file routes enforce the inaccessible role.                                                                                                                                           |

Native journeys run with animations enabled and perform full, unfiltered accessibility audits on reachable directories, filter drafts, profiles, the reader, restricted views and the error view. Browser passage assertions additionally recognize actual screenshot pixels with Apple's Vision framework. Screenshot attachments alone are not treated as visual-regression comparisons or passing behavior.

Results and the actual image inspection inventory are recorded below after execution. These focused journeys do not establish human-reviewed visual baselines, the complete two-size/appearance/Dynamic Type matrix, measured performance budgets, physical VoiceOver or the issue's whole integrated walkthrough.

## Execution record

The first setup attempt stopped before HTTP or native execution because the isolated worktree lacked the existing `packages/plugin-api/node_modules` symlink. Its log is retained at `/tmp/bookorbit-organization-qa-first.log`. Reusing the already installed dependency directory corrected the environment without downloading anything. The subsequent run retains its full log at `/tmp/bookorbit-organization-qa-linked-dependencies.log` and starts from the same implementation checkpoint.

`run-9282-1791319798731` passes all eleven HTTP journeys, including both new organization journeys, and compiles the production app and UI tests with strict Swift 6 concurrency. All four native journeys execute and fail in their first full accessibility audit. The native summary records zero skips, expected failures or runtime warnings. No browser test executes because the harness preserves the native failure gate. Paging, filter interactions, the organization reader handoff and retry behavior beyond those first audits remain unverified at this checkpoint.

The complete log is also retained in the run folder as `run.log`, with `native.xcresult`, `native-summary.json`, the exported `native-attachments/manifest.json`, actual full-screen screenshots, precise failing-element screenshots and complete audit descriptions. No animation-idle stall occurred in this batch.

| Confirmed bug                                   | Independent native reproduction                                        | Actual exported audit attachment           |
| ----------------------------------------------- | ---------------------------------------------------------------------- | ------------------------------------------ |
| Filters cannot change its font size             | Author directory: `organizationFilters`, 60.5 by 36 points             | `7DF9442A-A624-4B83-9CB2-16C6266614B2.txt` |
| Page/result summary cannot change its font size | Author profile: `Page 1, 45 results`, 121.5 by 18 points               | `5C117DA5-56AC-44D4-8A45-10A40EF2057A.txt` |
| Done cannot change its font size                | Series directory: `Done`, 56.5 by 36 points                            | `B8553C57-CFBC-43DE-8B66-D6BD3E7452E8.txt` |
| Empty-state advice has insufficient contrast    | Restricted author directory: `Check the spelling or try a new search.` | `987B4AE1-082B-44F9-98B9-ED84CC5851D9.txt` |

Each defect was reported to the implementing coordinator for an independently assigned repair. The tester changes no production source and suppresses no audit issue. A corrected source commit requires another real native execution before it can be accepted.

The following image review opens all sixteen actual exported PNGs, including every full state, failure duplicate, audit screen and failing-element crop. Configuration for every row: cached iPad Pro 11-inch M5, iOS 26.0 build 23A343, full portrait window at 834 by 1,210 points, English, light appearance, default Dynamic Type and animations enabled. The modal directory/profile measures 580 by 650 points. Text and book rows are legible at the captured size; list rows partially outside the scroll viewport remain scrollable and do not overlap the fixed footer. No additional clipping or overlap was identified. The fixed font and contrast findings remain failures even where the default-size capture looks legible.

All filenames in the inventory refer to `/tmp/bookorbit-organization-qa-98cc85a0/test-results/ipad/run-9282-1791319798731/native-attachments/`.

| Named test and captured state                                                            | Opened actual PNG                          | Review                                                                                                     |
| ---------------------------------------------------------------------------------------- | ------------------------------------------ | ---------------------------------------------------------------------------------------------------------- |
| `testIPADE01A01AuthorDirectoryPagingAndFilters`: failure full screen                     | `9C664CE1-6C94-4C9B-8468-C52485AA22E8.png` | Authors, 55 results and Filters: default-size layout legible; unsupported Filters Dynamic Type retained.   |
| `testIPADE01A01AuthorDirectoryPagingAndFilters`: IPAD-E01-A01-authors-first-page         | `E2510ADD-3E91-4F24-9FAA-F1F4E7042778.png` | Authors, 55 results and Filters: default-size layout legible; unsupported Filters Dynamic Type retained.   |
| `testIPADE01A01AuthorDirectoryPagingAndFilters`: audit full screen                       | `F1B44701-083C-4B0A-8874-92ACE8706F45.png` | Authors, 55 results and Filters: default-size layout legible; unsupported Filters Dynamic Type retained.   |
| `testIPADE01A01AuthorDirectoryPagingAndFilters`: failing-element crop                    | `D5E22156-A749-45B9-AEB8-783E47CE8464.png` | Authors, 55 results and Filters: default-size layout legible; unsupported Filters Dynamic Type retained.   |
| `testIPADE01A01AuthorProfileBookPagingAndPDF`: failure full screen                       | `189547C5-82BB-4E3F-88ED-E69456D39438.png` | Author facts and 45-book page: profile and footer legible; unsupported page-summary Dynamic Type retained. |
| `testIPADE01A01AuthorProfileBookPagingAndPDF`: IPAD-E01-A01-author-profile-and-book-page | `BD7005B7-59AD-4F26-A1ED-53903B208F61.png` | Author facts and 45-book page: profile and footer legible; unsupported page-summary Dynamic Type retained. |
| `testIPADE01A01AuthorProfileBookPagingAndPDF`: audit full screen                         | `26BA1441-268F-4AA5-B931-AA8AB1318987.png` | Author facts and 45-book page: profile and footer legible; unsupported page-summary Dynamic Type retained. |
| `testIPADE01A01AuthorProfileBookPagingAndPDF`: failing-element crop                      | `9436D08B-BAE8-441E-9C7D-39C96FA5DE57.png` | Author facts and 45-book page: profile and footer legible; unsupported page-summary Dynamic Type retained. |
| `testIPADE01A01SeriesDirectoryFiltersAndBookPaging`: failure full screen                 | `835F87C3-45D4-423B-BA5C-24BCA993744A.png` | Series counts, missing volumes and next title legible; unsupported Done Dynamic Type retained.             |
| `testIPADE01A01SeriesDirectoryFiltersAndBookPaging`: IPAD-E01-A01-series-first-page      | `910AD36D-09D7-4EBF-91C1-A89895FDDF8F.png` | Series counts, missing volumes and next title legible; unsupported Done Dynamic Type retained.             |
| `testIPADE01A01SeriesDirectoryFiltersAndBookPaging`: audit full screen                   | `BE62DE80-CB62-4D68-9929-93FBBA22E300.png` | Series counts, missing volumes and next title legible; unsupported Done Dynamic Type retained.             |
| `testIPADE01A01SeriesDirectoryFiltersAndBookPaging`: failing-element crop                | `16C99355-7808-4886-93BF-0CC2FDE22C5E.png` | Series counts, missing volumes and next title legible; unsupported Done Dynamic Type retained.             |
| `testIPADE01A05OrganizationRestrictedAndRetry`: failure full screen                      | `775B9967-F511-46B5-A64A-B322576263F0.png` | Restricted directory correctly empty; gray search advice has confirmed insufficient contrast.              |
| `testIPADE01A05OrganizationRestrictedAndRetry`: IPAD-E01-A05-browseAuthors-restricted    | `AE2F9912-6E34-4078-BC66-6D530F2B9570.png` | Restricted directory correctly empty; gray search advice has confirmed insufficient contrast.              |
| `testIPADE01A05OrganizationRestrictedAndRetry`: audit full screen                        | `6A1BB19E-F9AF-449E-AFD6-0E8100017FA4.png` | Restricted directory correctly empty; gray search advice has confirmed insufficient contrast.              |
| `testIPADE01A05OrganizationRestrictedAndRetry`: failing-element crop                     | `CD6CC0A0-DB49-4FF7-A545-A1B9F8D3F8FF.png` | Restricted directory correctly empty; gray search advice has confirmed insufficient contrast.              |
