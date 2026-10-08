# Dashboard batch-error accessibility investigation

Issue: #2. Investigation source: `e796cd84`. Actual failed runtime source and QA: `806ab571ad81bac51185ca23f39c1a8fa7649f6e`.

The dashboard tester's retained run `run-22650-1791326305853` fails `DashboardJourneyTests/testIPADE01Dashboard04LoadFailureRetryAndDemoControls()` at the complete accessibility audit of the batch-failure state. The audit description in `936CEF39-F4C2-43EC-B86D-7A7850869A58.txt` says:

> This element appears to display text that should be represented using the accessibility API.
> No associated element

The report contains no associated element, text value, rectangle, or path. It therefore does not identify the error title, server message, Retry action, or any other specific view as the cause. This finding remains unresolved. No production repair is justified by the retained evidence alone.

## Independent comparison

This investigation independently opened both complete native screenshots `B7FAC3F0-FDF1-4355-9A90-73796FBE77B8.png` and `FAF6C0F5-19FF-4C00-BF03-02844BE1F342.png`, read the complete audit issue, and read the complete application hierarchy `ECE249B3-594E-490F-B08E-8C59F2E3C4C3.txt`. The screenshots are byte-identical. These artifacts remain in:

`/tmp/bookorbit-dashboard-qa-c3fea03d/test-results/ipad/run-22650-1791326305853/native-attachments/`

Every visible foreground dashboard string has a corresponding named accessibility element in the retained hierarchy. The following frames use the hierarchy's point coordinates:

| Visible foreground text                                     | Accessibility element                                   | Frame                                 |
| ----------------------------------------------------------- | ------------------------------------------------------- | ------------------------------------- |
| Home                                                        | Navigation bar and StaticText                           | `(147, 342.5, 94.5, 41)` for the text |
| Could not load dashboard                                    | StaticText with the exact label                         | `(305, 407.5, 225.5, 20.5)`           |
| The server could not complete the request (503). Try again. | StaticText with the complete exact label                | `(190.2, 440, 453.5, 20.5)`           |
| Try again                                                   | Button with the exact label                             | `(382.5, 472.5, 69.5, 20.5)`          |
| Done                                                        | Button with the exact label                             | `(143, 881, 72.5, 44)`                |
| Refresh                                                     | Button labelled Refresh, identifier `dashboardRefresh`  | `(500.5, 881, 91, 44)`                |
| Shelves                                                     | Button labelled Shelves, identifier `dashboardSettings` | `(599.5, 881, 91.5, 44)`              |

The dimmed underlying Library and sidebar remain visible around the sheet. Their visible labels are also represented in the hierarchy: Libraries, Home, All books, Authors, Series, Large library, Collections, New collection, Sign out, Books, Search books, 50,000 books, Title, Library book 00001, Library book 00009, Library book 00010, Library book 00011, Page 1, and Next. Some background text is partly covered by the sheet. The dump includes background elements, but does not establish their modal accessibility focus or hittability. The nil-element report does not establish that background text caused this finding either. System status-bar text is visible in the screenshot and absent from this application hierarchy; the report does not attribute the issue to it.

The owning source uses a SwiftUI `Label`, `Text(error)`, and the existing retry `Button` in `DashboardView`. The 503 message is the standard `ServerProfile` HTTP error description. The screenshot and hierarchy agree on the complete message, so truncation or omission of that text is not demonstrated. The Retry frame is only 20.5 points high in this hierarchy, but this report is not a hit-region finding. That observation is recorded without treating it as the cause of the assigned nil-element finding.

| Artifact                                   | SHA-256                                                            |
| ------------------------------------------ | ------------------------------------------------------------------ |
| `936CEF39-F4C2-43EC-B86D-7A7850869A58.txt` | `9f91ea4b1d8ba3b5f8681d80119f151399db84ee57492839b71142dba303b965` |
| `B7FAC3F0-FDF1-4355-9A90-73796FBE77B8.png` | `f2c21b72a25e78c71d074900dc6d13cb9de9403fa445a579a186efa4ce245d82` |
| `FAF6C0F5-19FF-4C00-BF03-02844BE1F342.png` | `f2c21b72a25e78c71d074900dc6d13cb9de9403fa445a579a186efa4ce245d82` |
| `ECE249B3-594E-490F-B08E-8C59F2E3C4C3.txt` | `186bf96ad670f8bf356390814d08acac2cbebd1a65778f1e345387de7f3473f7` |

## Next autonomous diagnostic

The dashboard tester can localize the remaining finding without the owner or iPad by retaining complete simulator screenshots, complete hierarchy dumps, all audit issue descriptions, and foreground/background element hittability in these states:

1. The Library immediately before opening Home.
2. Home after a healthy load, with the same underlying Library position.
3. Home after the same injected batch failure.
4. Home after the actual Try again action successfully recovers.
5. The Library after dismissing Home, followed by the failed Home state after reopening.

Record each diagnostic state's complete audit, then keep the journey failed if any audit reports a finding. Temporarily continuing after failure solely to collect all diagnostic findings does not make them acceptable. Do not filter audit types, return true for reported issues, exclude nil-element findings, or use expected failures. Preserve the original failed journey independently of diagnostic attempts.

Comparing the healthy, failed, recovered, and dismissed states can establish whether the finding follows the error content, the sheet presentation, or text in the underlying Library. If the report still lacks a location, compare portrait and landscape with the same data and full audits. A matching error-message label alone does not establish that the entire screen is accessible, and the audit failure must remain open until localized and verified.

## Validation and limits

The independent artifact inspection, foreground/background text comparison, SHA-256 hashes, Markdown formatting, and `git diff --check` are the checks for this investigation. No production source or test assertion changed. No simulator build, harness run, user interaction, iPad check, download, or visual-baseline approval occurred. The parent coordinates runtime diagnostics under the single heavy-check lock. This documentation establishes neither runtime GREEN nor completion of the assigned accessibility finding.
