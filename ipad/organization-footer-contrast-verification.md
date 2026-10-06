# Organization footer action contrast repair

Issue: #2. Source comparison: `b190b2ed`.

The organization tester's retained run `run-30295-1791320921117` at `3022fa74` reports insufficient contrast for the native directory's Filters and Done buttons. The full Authors screenshot `4FFC4173-EE8D-4419-A1CC-D220B4EF6403.png` shows both blue body labels on the system background. Complete issue descriptions `E51F0B2E-807C-4CE7-9EB5-5670D0A20BA8.txt` and `2163B323-2063-4AAD-BA23-0490DA83EB45.txt` identify `organizationFilters` and `organizationDone` respectively.

This repair agent independently opened the actual full Authors, Series, restricted Authors, restricted Series and Authors server-error screenshots and read all ten matching Filters/Done contrast descriptions. The same two actions failed contrast in all five captured states. These are real native artifacts from the cached iOS 26.0 iPad simulator; they do not establish physical-device coverage.

The directory footer now uses the plain button style and the semantic label foreground against its existing semantic system background. Both controls retain their body font, 44-point minimum height, accessibility identifiers and existing filter-opening and dismissal actions. The style applies only to this two-action footer.

Targeted Swift formatting, strict format lint, source parsing, Markdown formatting and `git diff --check` passed. Tests and unfiltered accessibility audits remain unchanged. A heavy build or runtime suite was not run by this repair agent because the organization tester owns the coordinated full native and browser verification. The corrected complete audits, actual screenshots and behavior checks are pending; this note records a source repair, not runtime verification.
