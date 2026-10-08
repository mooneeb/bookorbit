# Dashboard card clipping accessibility

Issue: #2. Source comparison: `e796cd84`. This is a source repair awaiting
independent native runtime verification.

## Retained runtime failure

The complete unfiltered audit at `806ab571` in
`run-22650-1791326305853` reported three card-title Contrast failures. The
retained artifacts are under
`/tmp/bookorbit-dashboard-qa-c3fea03d/test-results/ipad/run-22650-1791326305853/native-attachments/`.
The issue records, corresponding full screenshots and crops, and complete
hierarchies were independently read or opened:

| Journey           | Complete issue                             | Full screenshot                            | Element crop                               | Hierarchy                                  |
| ----------------- | ------------------------------------------ | ------------------------------------------ | ------------------------------------------ | ------------------------------------------ |
| Defaults          | `6011A95E-3221-4B8F-987E-7CE3B853FA41.txt` | `F8E15160-201A-46DA-8842-BC816A285049.png` | `6CAA66F4-A569-41C5-AB95-FE23FCC9C1AF.png` | `A6F52680-E7DB-4FFA-AAB8-803F1EF45E4F.txt` |
| Seven shelf types | `B23B3E88-1A19-4D8A-B386-D337B2D388B7.txt` | `AB8F8EEC-A9D5-485D-87C9-61E81A3C45AC.png` | `48E15AB0-D9CE-423B-A24C-365B305E90B2.png` | `AA078960-B811-48B5-AC6E-C5DEA2F55246.txt` |
| Three book rows   | `535AEFB2-26F6-4DAE-A2FC-CCA32836CD7F.txt` | `13C23810-6BFE-4567-B67E-E3E2106F88BA.png` | `410FD5FE-9B25-4FD0-863B-D861DD868AAE.png` | `E9108CC1-6B02-4621-9898-14FC04266885.txt` |

- Defaults exposed `Library book 49996` at x=687 with width=159, beyond its
  horizontal shelf viewport ending at x=675. The crop contains no title text.
- Seven shelf types exposed `Library book 00005` at y=1030.5, below the dashboard
  sheet ending at y=925 and its bottom action area. The crop contains background.
- Three rows exposed `Library book 49999` at y=271.5. The full screenshot and crop
  show this title beneath the navigation bar blur at the top of the sheet.
  The later retained hierarchy differs slightly after scroll settling, and is
  preserved separately from the audit's recorded frame.

These observations establish an accessibility clipping defect in the nested
dashboard scroll areas. They do not establish a low-contrast visible title
color defect. No title color was changed.

## Source repair

The existing visual card, touch button, lazy row layout, bounded shelf results,
cover loading, and book-selection closure remain in use. Each card has one
native accessibility button carrying its title, every author, and optional
reading progress. The duplicate visual-button accessibility children are
replaced by that complete action.

The dashboard and horizontal shelf report their window-coordinate viewport,
excluding their safe-area overlap. The native element computes its frame on
accessibility requests from its current UIKit bounds intersected with both
viewports, then converts that intersection into screen coordinates. It remains
accessible whenever any portion of the card intersects the viewport. A fully
offscreen card has no accessibility element until scrolling reveals it.
Activation calls the same book-selection closure. Both native scroll containers
remain available for accessibility scrolling.

Geometry is stored once per dashboard and shelf, without a per-book frame map,
full-library query, image-cache expansion, or per-scroll application loop.

## Verification

- `xcrun swift-format format --in-place` and strict lint passed for the changed
  source.
- Swift frontend parsing passed.
- A strict Swift 6, complete-concurrency, warnings-as-errors typecheck passed for
  the new helper against the real generated contracts and `FieldUpdate`, with
  temporary dependency stubs outside the worktree.
- The first helper typecheck omitted the existing `FieldUpdate` dependency and
  failed with missing-type errors. Adding that real source file corrected the
  check; no production contract was changed.
- Strict Swift 6 full-file typechecking passed against the real dashboard model,
  generated contracts, `FieldUpdate`, and permission helpers, with temporary API,
  cover-loader, and unrelated destination-view stubs outside the worktree.
  The compiler log is `/tmp/bookorbit-dashboard-card-accessibility-full-file-typecheck.log`.
- The final diff check passed.
- No native build, simulator journey, web run, API test, download, installation,
  iPad interaction, baseline approval, or audit suppression was performed by
  this repair agent. Independent runtime verification must confirm visible
  title discovery, complete card labels, opening books, scrolling cards back
  into accessibility focus, and the complete unfiltered audit.

Runtime GREEN has not been established. The shelf-header font and the separate
nil-element error finding belong to other repair tasks.
