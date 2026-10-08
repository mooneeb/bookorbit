# Dashboard Done Dynamic Type repair

Issue: [#2](https://github.com/mooneeb/bookorbit/issues/2).

## Observed failure

The corrected dashboard batch at QA checkpoint `3e0130df` still failed the
unfiltered native accessibility audit in `run-5320-1791325089554`. The complete
issue identifies Home's Done button at `{{141, 289}, {56.5, 36}}` inside the
navigation bar and states that the user cannot change its font size.

The dedicated repair agent independently opened the actual failed screenshot
and exact control crop, read the complete issue and navigation-bar ancestry,
and inspected the native batch summary. Evidence is preserved under
`/tmp/bookorbit-dashboard-qa-c3fea03d/test-results/ipad/run-5320-1791325089554/`:

- `native-attachments/7BF80C18-07A6-4281-BF08-2188CD5DC8AB.png`: failed Home
  screenshot.
- `native-attachments/58E6F171-6980-4A07-B3A9-63BD31B5B573.png`: exact Done
  control crop.
- `native-attachments/A68BADB3-99A4-4DB7-A842-7878DB11D837.txt`: complete audit
  issue and element hierarchy.
- `native-summary.json`: six native failures, zero passes, zero skips, zero
  expected failures, and no runtime warnings.

Those batch totals do not establish that every failure has this single cause.

## Source repair and verification

Move only Home's Done button to the left of the existing bottom safe-area
inset. Use explicit `.body` text, a plain button style, the semantic system
label color, and an individual minimum 44-point width and height. Keep its real
dismiss action and availability during loading or saving. Refresh and the
settings editor's Cancel button belong to separate repairs.

Strict Swift formatting lint, Swift frontend parsing, and `git diff --check`
passed for the source repair. No heavy build or runtime test was run by this
repair agent because the shared queue belongs to the feature testers. No test
or accessibility audit was changed.

The original dashboard tester must rerun the full unchanged native journeys
and unfiltered accessibility audits, confirm that Done still dismisses Home,
and export corrected screenshots and hierarchy. Independent inspection of
those corrected artifacts remains pending. This repair is not yet verified
at runtime.
