# Native dashboard shelf rows

The independent dashboard tester reproduced the row configuration bug in
`DashboardJourneyTests.testIPADE01Dashboard06RequestedShelfRowsAreVisible`.
The public configuration requests three rows with two books per row. Its
authenticated batch request correctly asks for six books, but the native Home
sheet renders the returned books in one horizontal band.

The repair agent independently opened the actual RED screenshot
`/tmp/bookorbit-dashboard-qa-c3fea03d/test-results/ipad/run-67869-1791322890598/native-attachments/DFD2C192-2375-4B8F-BE76-3C0963CE868B.png`
and read the accompanying public request snapshot
`/tmp/bookorbit-dashboard-qa-c3fea03d/test-results/ipad/run-67869-1791322890598/native-attachments/5A6D4060-80D9-4619-94B8-59062230E034.json`.
The snapshot records shelf `rows`, type `recently-added`, and `limit: 6`.

`DashboardView` now divides the returned books into one, two, or three contiguous
bands, retaining the existing order within each band. The bands share horizontal
scrolling and take their height from their contents. The enclosing Home sheet
continues to scroll vertically so later bands remain reachable in a narrow sheet
and with larger text. No fixed row height is introduced. Existing authorized
book buttons, covers, shelf loading and failure states, and the bounded batch
request are retained.

Strict Swift formatting lint, Swift source parsing, and `git diff --check` pass
for this source checkpoint. A full native build and corrected public UI journey
remain pending with the independent tester. The tester will verify that the
second row starts below the first row and vertically scroll to reach the third
row, while retaining the complete accessibility audit. This checkpoint does not
claim a runtime pass or completion of the dashboard feature.
