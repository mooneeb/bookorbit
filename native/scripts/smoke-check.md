# Physical device smoke check for issue #57

Verdict: **NEEDS_HUMAN**. This scenario requires the iPad Air M2, VoiceOver and the largest supported interface text size. Simulator rendering and adapter tests do not establish that verdict.

Use a fresh isolated HTTPS deployment at `https://bookorbit-qa.test`, the two generated QA accounts, separately scoped app/browser state, and the QA Prose fixture from `server/test/e2e/native-reader/native-reader-qa.ts`. The automated preparation command in `native/README.md` creates the data and runs adapter tests; a physical device additionally needs its own reachable, trusted HTTPS test deployment. Never use the personal production library or change production certificates for this check.

Record test time, server/app commits, capabilities, iPad model/OS, Xcode, source file UUID/SHA-256 and actual observations. Keep private contents and credentials out of evidence.

1. Build the BookOrbit scheme for the connected iPad with the free Personal Team. Preserve `dev.mooneeb.bookorbit.reader`, confirm the free AppID/app slot and record provisioning issuance/expiry. Do not revoke certificates as a routine fix.
2. Enable VoiceOver before connection. Enter the isolated origin and QA owner credentials. Verify field labels, focused-field announcements, sign-in result and meaningful order. Repeat at the largest supported interface text size in portrait and landscape.
3. Search for QA Prose and open its details. Verify that focus reaches the title and explicit Download action, and every required action remains reachable without clipped controls.
4. Return to the catalog. Verify that focus returns to the originating book.
5. Download QA Prose. Disconnect after completion, relaunch and open the downloaded book. Read the first paragraph, inspect its image/font and turn to chapter Two. Confirm no other book was downloaded.
6. Sign out, then sign in as the second owner. Verify that the first owner's downloaded catalog is absent. Confirm that B Secret remains private to the second owner.
7. Try QA Broken, QA Traversal and QA Hostile. Missing/invalid resources cannot become ready. The hostile book's static text remains readable with a partial-reading warning, without publication script, remote requests or native credential/file access.
8. Open QA Fixed and a separately prepared ordinary EPUB 2. Check page order and available text. PDF, protected, mixed-layout and vertical-writing content remain explicitly unavailable in this increment.

Record **PASS**, **FAIL** or **BLOCKED**, actual observations and a separate human readability verdict. Signing renewal, physical VoiceOver/focus, physical memory/pressure and the complete conditioned server/network benchmark remain separate unpassed acceptance gates.
