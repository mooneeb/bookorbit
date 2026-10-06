# Home Refresh Dynamic Type repair

The independent dashboard tester reproduced a Dynamic Type failure for the real
Home Refresh action in `run-5320-1791325089554` at repaired dashboard source
`3e0130df`. The complete, unfiltered accessibility finding identifies a
`Refresh` button with a 75 by 36 point frame inside the Home navigation bar.
The configured-row public request, distinct second-row geometry and reachable
third-row assertions passed before this audit finding. This repair does not
change those checks or claim a passing dashboard journey.

The repair agent independently read the complete audit and opened both the
actual full screenshot and the exact Refresh crop. The retained evidence is in
`/tmp/bookorbit-dashboard-qa-c3fea03d/test-results/ipad/run-5320-1791325089554/native-attachments/`:

| Evidence                    | File                                       | SHA-256                                                            |
| --------------------------- | ------------------------------------------ | ------------------------------------------------------------------ |
| Complete audit              | `CB5405A6-D159-4899-930D-C621C3A76681.txt` | `dbf133f51e39ee0553d260614a1a7bacbf2e77cd8a70b537a85ef038fbf76937` |
| Actual full Home screenshot | `79CC9070-BE1A-489E-940D-B34AEE7774B1.png` | `f38b03a155008902d3f9a1d9437503f52c921f3f20f1b430b75b40a042c95a30` |
| Exact Refresh crop          | `C1694D11-B92A-47E0-BAFD-9AF97BC572D0.png` | `11952bd49028ce903561523195c2961f3e2ab9408111bdf831774eb73c963d06` |

Move only Refresh into the existing bottom safe-area inset. Its body text scales,
its individual hit target has a minimum width and height of 44 points, and its
plain button uses the system label foreground over the system background.
Preserve the actual asynchronous `model.load()` action, loading and saving
restrictions, and visible Refresh label. Add the `dashboardRefresh` identifier.
The Home Done and settings Cancel controls belong to separate repairs.

Targeted Swift formatting, strict format lint, Swift syntax parsing, Prettier
and `git diff --check` passed. No heavy build or runtime test was run by this
repair agent because those checks are serialized through the independent
tester. The tester must rerun the whole maintained dashboard class, including
the existing real Refresh fault/recovery interactions and all full unfiltered
accessibility audits. The repair agent must inspect the corrected actual
screenshots and complete audit evidence before calling this defect verified.
Runtime acceptance and human-approved visual baselines remain pending.
