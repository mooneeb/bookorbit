# Dashboard Shelves accessibility repair

The dashboard's Shelves button failed the unfiltered native accessibility audit in `DashboardJourneyTests/testIPADE01Dashboard01DefaultsLocalRelaunchAndIsolation()` in `run-67869-1791322890598`. The issue states that the user cannot change its font size. Its accessibility node identifies `dashboardSettings`, label `Shelves`, and a 73.5 by 36 point frame inside the Home navigation bar.

The dedicated repair agent independently read the complete issue metadata and hierarchy, and opened the owned dashboard screenshot, failure screenshot and exact Shelves element crop. These are exported under `/tmp/bookorbit-dashboard-qa-c3fea03d/test-results/ipad/run-67869-1791322890598/native-attachments/`:

- `B2800D68-DF50-4E47-9CC5-988113A2EEC2.txt`: complete element issue and navigation-bar ancestry.
- `C32ABAD7-06BA-485B-A024-883188A000F3.txt`: complete issue description.
- `51A2AAEC-E1A2-4B62-BBB0-8D5939DCDFD7.txt`: owned default-dashboard hierarchy.
- `2B3C4BD4-1664-4028-B2AA-C9BDFE3322DD.png`: owned default-dashboard screenshot.
- `FB6ABC60-3BFE-46F4-9E56-5715A2E219FD.png`: screenshot attached to the audit failure.
- `1FAF4734-B18C-43BE-823E-E7F96B240BAA.png`: exact failing control crop.

Move Shelves into the dashboard's bottom safe-area inset so its `.body` text can scale independently of the navigation-bar presentation. Give the control its own minimum 44 by 44 point target and use the system label color on the system background. Preserve its label, `dashboardSettings` identifier, loading and saving restrictions, and existing settings sheet action. This source repair touches only the settings control in `DashboardView.swift`.

Strict Swift formatting and lint, Swift syntax parsing, and `git diff --check` pass. No heavy build or runtime test was run by this repair agent. The independent dashboard tester must rerun the unchanged public native journey and full accessibility audit, verify that Shelves still opens its settings sheet, and export corrected screenshots and hierarchy for inspection. Runtime acceptance remains pending; this document does not claim a passing dashboard batch or a completed issue.
