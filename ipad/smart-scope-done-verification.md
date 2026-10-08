# Smart scope directory Done contrast

Issue: [#2](https://github.com/mooneeb/bookorbit/issues/2).

## Observed failure

The autonomous scope batch at production `8ee493e3` and QA `c0c1a54c`
reported `Contrast failed` for the native Smart scopes directory's Done button
in `testIPADE01A01ScopeDirectoryPagesOwnedSearchAndPDF`. The complete issue
identifies the button at `{{143, 877}, {40.5, 20.5}}`.

I independently opened the actual failed screenshot and read both the complete
audit issue and the hierarchy. The screenshot shows the enabled Done action as
blue text on the sheet's light footer. The hierarchy binds the finding to that
footer action rather than a background library control.

Evidence in
`/tmp/bookorbit-scope-qa-8ee493e3/test-results/ipad/run-90599-1791324257085/native-attachments/`:

- Screenshot: `823F47BE-7770-442A-A8F9-3D8F99CE1C7A.png`.
- Complete audit issue: `F48933CA-1140-4529-9B97-5B843A708E87.txt`.
- Hierarchy: `13BDEDE9-4777-4639-9001-5B2309AF5DE9.txt`.

The full batch retained 12 passing public HTTP checks and five failing native
tests, with no skips or expected failures. The browser gate did not run. Those
totals do not establish that the other four native failures have this cause.

## First repair remained RED

The first source repair, `cade0114`, used the platform's semantic label color
with a plain button style and a minimum 44-point frame outside the Button.
The corrected full native batch still reported `Contrast failed` on Done.
I independently opened its actual screenshot and read its complete finding and
hierarchy: the text is visibly black, but the accessibility node remains
`{{144.8, 876.8}, {40.5, 20.5}}`. The outer frame did not enlarge the reported
button label's bounds.

Evidence in
`/tmp/bookorbit-scope-qa-8ee493e3/test-results/ipad/run-12921-1791325526211/native-attachments/`:

- Screenshot: `CE55EA89-A4BC-42A1-ABC7-293D3E08F5ED.png`.
- Complete audit issue: `B29C3E96-B518-4E45-A453-AE146C47CB3C.txt`.
- Hierarchy: `B840909E-0225-48EE-9EBD-2FBDB853CEAE.txt`.

## Revised source repair and current verification

The revised Done button has an explicit Text label with the body font, semantic
label color, minimum 44-point width and height, and rectangular content shape
inside the Button. This makes the enlarged label part of the actionable control.
Its dismiss action, label, footer position, and inherited saving restriction
remain the same. No other scope control, search field, permission rule, or test
audit was changed.

Strict Swift formatting lint, Swift frontend parsing, and `git diff --check`
passed for the repair. These are source checks. No build or runtime test was
run by this repair agent because the shared heavy-check queue belongs to the
feature testers.

The original tester must rerun the full unfiltered native audit on this revised
source. Independent inspection of its actual corrected screenshot and audit is
still pending. This revision is not yet verified at runtime; the first repair's
runtime failure remains retained above.
