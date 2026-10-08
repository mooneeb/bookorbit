# Organization profile sort control

The autonomous organization tester's genuine RED, `run-30295-1791320921117`, identifies the visible `Sort books` label in the author profile's navigation bar as a SwiftUI accessibility node whose font size cannot change. The audit attachment is `6D352DDF-DDD3-417F-B6BD-3CFF56CF3D30.txt` under `/tmp/bookorbit-organization-qa-98cc85a0/test-results/ipad/run-30295-1791320921117/native-attachments/`.

The repair agent opened the actual full profile image `524556A6-4C71-48BC-85B3-D8BD1C157BD7.png` and label crop `883CD3BB-89F9-46AD-BEB2-A0384122FFEF.png`. The image shows the real author biography, related books, paging footer, native Back action, and `Sort books` toolbar control. The audit reports that label at `{{602.5, 296.8}, {82.5, 20.5}}`. These are inspected failure artifacts, not an approved visual baseline.

Only the existing profile sort menu moves into a body-font footer with a 44-point minimum target and adaptive label/background colors. The visible label, author and series sort options, descending toggle, server query behavior, and native Back navigation are preserved. The directory sort control, paging summary, other accessibility findings, and tests are outside this repair.

Strict Swift formatting/lint, Swift 6 syntax parsing, and `git diff --check` passed. Corrected runtime verification remains pending the autonomous organization tester's next full unfiltered audit and actual profile screenshots. No audit suppression or passing native result is claimed.
