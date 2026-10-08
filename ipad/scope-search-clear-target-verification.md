# Smart scope search clear target

Issue: [#2](https://github.com/mooneeb/bookorbit/issues/2).

## Observed failure

The autonomous scope batch at production `8ee493e3` and QA `c0c1a54c`
reported `Hit area is too small` for Clear text after entering a shared-scope
query. The complete audit issue identifies the native `_UITextFieldClearButton`
at `{{652.5, 403.5}, {20.5, 20.5}}` inside the Find a scope search field.

I independently opened the actual failed screenshot and read the complete issue
and hierarchy before changing the source. The search field contains
`Orbit shared scope`; the hierarchy binds the small control to that foreground
search field.

Evidence in
`/tmp/bookorbit-scope-qa-8ee493e3/test-results/ipad/run-90599-1791324257085/native-attachments/`:

- Screenshot: `3B47D78C-4E3D-4C44-93CB-331B03514E87.png`.
- Complete issue: `698DC11F-A933-4FB9-8B6C-827B176C3A26.txt`.
- Hierarchy: `0E485E0E-7240-488F-B35C-BEF11B7E62ED.txt`.

## Source repair and current verification

The scope directory and named-scope picker reuse the existing native
`UISearchTextField` wrapper. Scope searches disable UIKit's internal clear
control and expose a separate Clear text button with a minimum 44-point label
area and rectangular hit shape. It appears for a nonempty query and clears the
same draft binding. Searching still requires explicit submission, with the same
Find a scope prompt and native search-field semantics. The coordinator keeps
text edits synchronized and resigns the keyboard when submitting.

The wrapper accepts clear-button and accessibility-identifier configuration;
its existing organization-search defaults remain the same. Scope query loading,
permission checks, paging, and directory/picker dismissal actions are unchanged.
No test assertion or audit filter was changed.

Strict Swift formatting lint, Swift frontend parsing, Markdown formatting, and
`git diff --check` passed. These are source checks. This repair agent did not run
a build or runtime batch because the shared heavy-check queue belongs to the
feature testers.

The original scope tester will exercise clearing and resubmission, then rerun
the full unfiltered native accessibility audit. Independent inspection of the
corrected screenshot and audit remains pending; this repair is not yet verified
at runtime.
