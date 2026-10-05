# Interim review for issue #2

Comparison point: `8fecae94e65204618fc4db846da19c4e0007e4aa`, the commit at task start. Two independent agents reviewed `4d017f73` against that point. Follow-up independent reviews inspected the session fixes and final simulator-execution delta after `fd834c3f`. Both axes found no new material issue in the recovery delta and verified the final HTTP/native results and evidence. The complete [issue #2](https://github.com/mooneeb/bookorbit/issues/2) remains in progress.

## Standards

No hard documented-standard violations were found.

- Possible Duplicated Code: expired-session recovery, logout and password change each removed credentials and cleared session state, with differing cancellation behavior. The shared `invalidateSession()` now owns those operations. Resolved.
- Separate correctness finding: concurrent refresh waiters returned decoded credentials before generation validation and Keychain persistence. The shared task now validates and persists before returning to any waiter; task identity protects newer refreshes from old cleanup. Resolved.
- Follow-up correctness finding: an old resume request could invalidate newer credentials, or foreground validation could restore an account after sign-out/reconnection. Resume now checks its captured session generation. Foreground validation checks API and operation identity and serializes its own requests. The follow-up review found no remaining material race in these changes. Resolved.

## Spec

- P1, open: "Dashboard shelves, large-library grid/list/table search/filter/sort, authors/series ... collections, smart scopes, saved views, and sharing rules" and metadata/cover workflows are partial. Native browsing currently has list/grid, search, three sorts and static book/file details.
- P1, open: "Baseline ebook/PDF/comic/audio reading ... are usable online" and the default genuine book-style page turn are absent from the native client. Reader controls, preferences, bookmarks/progress, background audio, bridging, Read Along and TTS remain to implement.
- P1, open: "Every acceptance criterion and every numbered human QA step maps to named automated tests" and human-reviewed visual comparisons are incomplete. Both native entry journeys and the library accessibility audit now pass; screenshots remain captures, and visual regression baselines, the representative matrix, controlled failure coverage and measured budgets remain outstanding. Bounded HTTP payloads do not prove native rendering or memory performance.
- P1, open: "Native installation ... and a real reachable home-server connection" and "A human completes the entire ticket walkthrough" still require AltStore/device/network evidence and the integrated human journey. Localhost supports the automated fixture.
- P2, resolved: "secure credentials" and "local persistence ... together" were undermined by concurrent refresh success before persistence. The shared completion and invalidation changes above address this finding; actual native local/OIDC relaunch and session-revocation/recovery journeys now pass.

No material scope creep was found. Standards: 0 hard violations, 1 resolved heuristic, and resolved correctness findings. Spec: 5 findings, 4 open and 1 resolved. The missing native reading and complete end-to-end journey block issue completion.
