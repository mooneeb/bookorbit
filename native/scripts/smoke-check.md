# Device smoke check for issue #25

Verdict: **Unrun** on a physical device. Simulator rendering does not pass VoiceOver, free provisioning or device usability.

Use a separately prepared, isolated HTTPS BookOrbit with two test owners, a denied account, a shared permitted library, a private library and a controlled static reflowable EPUB with at least two screen pages. Do not use the personal production library. Record server commit, app commit, iPad model, OS, Xcode, time and EPUB SHA-256 with the verdict.

1. Open `native/BookOrbit.xcodeproj`. Select the BookOrbit scheme, connected iPad and your Personal Team. Keep bundle ID `dev.mooneeb.bookorbit.reader`. Build and run. Record provisioning issuance and expiry; a free profile lasts at most seven days from issuance.
2. Enter the isolated HTTPS origin. Sign in as the first owner. Search for the controlled title. Check library pagination and open book details, then Read EPUB.
3. Read the actual first paragraph aloud. Turn forward and back. Return to details and library. A text-bearing page must remain readable and reachable.
4. Relaunch. Verify secure account restoration. Sign out and sign in as the second owner. Confirm permitted reading works and private-library results are absent. Attempt a denied book through the server adapter suite; the app must never offer an inaccessible book from its catalog.
5. Disconnect the server during resource loading and reopen. Confirm a clear failure and usable return action. No offline-ready, notes, saved progress or synced state may appear.
6. Enable VoiceOver. Read chapter headings and paragraphs in meaningful order, find both page controls, turn a page, return to details and check focus. Repeat at the largest accessibility interface text size in portrait and landscape. Record failures separately from visual rendering.
7. Try a PDF and fixed-layout/protected EPUB. Confirm unsupported reading is explicit and the library remains reachable. Test a publication containing script and remote image attempts; scripts must not run and no unsolicited remote request may leave WebKit.

Record **Pass**, **Fail** or **Blocked**, actual observations and a separate human readability verdict. Hardware signing, renewal/data continuity, focus and VoiceOver remain unpassed until actually observed. Do not revoke certificates as a routine fix.
