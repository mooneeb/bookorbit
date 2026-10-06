# Dashboard shelf type accessibility area

Issue: #2. Source comparison: `726b7434`.

The independent dashboard tester's retained native run `run-67869-1791322890598` reached the synchronized-save failure state after checking the held request, acknowledged save, retained draft and unchanged public server state. The full unfiltered audit in `testIPADE01Dashboard02SynchronizedSaveWaitsAndRetries` then reported that the visible `Recently added` shelf-type accessibility node was too small to interact with.

This repair agent independently read the complete issue attachment `33591C27-C9A3-461B-AE32-AE1614F50745.txt` and opened the actual full save-failure draft screenshot `D7AFAC76-B97C-4F30-8924-B32E2CAE71FE.png` and its element crop `490A906A-65AB-4530-9357-371283E4BBA6.png`. All are retained under `/tmp/bookorbit-dashboard-qa-c3fea03d/test-results/ipad/run-67869-1791322890598/native-attachments/`. The issue identifies a `StaticText` at `{{167.0, 693.0}, {107.0, 18.0}}` inside the shelf's actual 540 by 195.5-point collection cell. The associated full hierarchy is `44FFD44C-3049-492D-ADA7-590622FA8615.txt`.

The shelf type is an existing read-only label, not a type picker. Only that label changes: it uses the semantic body font and foreground, allows multiline growth and creates a combined accessibility element over its own full-width, minimum 44-point frame. Existing type values and visible labels, shelf selection, editable draft fields, save acknowledgement, failure feedback and actions remain intact. The dashboard toolbar control, row rendering and other settings controls are outside this repair.

Targeted Swift formatting, strict format lint, Swift syntax parsing and `git diff --check` passed. Tests and their full accessibility audits remain unchanged. A heavy build and native runtime suite are coordinated by the dashboard tester, so this source checkpoint does not claim corrected runtime verification or an approved visual baseline. The tester must rerun the actual save-failure journey and full audit, and the repair agent must inspect the corrected artifacts before this defect is verified.
