# Dashboard settings Cancel Dynamic Type

Issue: [#2](https://github.com/mooneeb/bookorbit/issues/2).

## Observed failure

The dashboard tester's unfiltered native accessibility audit in
`run-5320-1791325089554` reported that the user could not change the font size of
the dashboard settings editor's Cancel button. The complete issue identifies a
68.5 by 36 point button inside the `Dashboard shelves` navigation bar.

The repair agent independently opened both the complete failed screenshot and
the exact control crop, and read the complete audit issue. The screenshot shows
the enabled Cancel action beside Edit and Save after the synchronized shelf
draft and failed-save assertions had executed. The evidence does not establish
a problem with Save, Edit, or the shelf type label.

Evidence in
`/tmp/bookorbit-dashboard-qa-c3fea03d/test-results/ipad/run-5320-1791325089554/native-attachments/`:

- Failed screenshot: `785AB482-274B-4C49-83FA-F0C7B3A7D9A3.png`.
- Exact Cancel control crop: `845B92EE-C795-4DB7-B160-81CDE6277C04.png`.
- Complete audit issue and element ancestry:
  `9C3A90A1-E108-4189-BC42-9ABFF3A5316E.txt`.

## Source repair and verification boundary

Move Cancel into the settings editor's bottom safe-area inset, following the
existing dashboard Shelves control. Use explicit scalable body text, a minimum
44 by 44 point label target, a plain button style, and system label and background
colors. Preserve the existing dismiss action and the saving restriction. The
editor continues to own its shelf, layout, and sync drafts until Save succeeds;
Cancel still dismisses without publishing those drafts. Save and Edit keep their
existing actions, toolbar positions, and saving restrictions, and interactive
dismissal remains disabled while saving.

Strict Swift formatting lint, Swift frontend parsing, and `git diff --check`
passed for the source repair. No heavy build or runtime test was run by this
repair agent because the original dashboard tester owns the shared verification
queue. No test, audit filter, retry, skip, or failure expectation was changed.

The original dashboard tester must rerun the unchanged full native journey and
unfiltered accessibility audit, verify failed-save draft retention and real
cancellation, and export the corrected screenshot and hierarchy. Independent
inspection of actual corrected artifacts remains pending. This document does
not claim runtime acceptance, a passing dashboard batch, or issue completion.
