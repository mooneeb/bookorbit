# Standalone reader acceptance walkthroughs

Working collection for [Agree the complete reading journey and build-readiness criteria](https://github.com/mooneeb/bookorbit/issues/13). These are future checks of the implemented app. None is marked passed by this document. Start with the [specification](../specification.md); authoritative policies remain in its linked decisions.

## Run one walkthrough

Each walkthrough answers one stated question. Its setup provides everything it needs; completing a previous walkthrough is never a prerequisite. The test runner prepares fresh, separately named book copies and account-scoped data for each run. The human creates the handwriting called for here. Repeating or restarting a walkthrough resets only that run's test data, preserving its earlier evidence. Use a test deployment and copies of sources for replacement/removal checks.

Record app/build, server/capability version, device/OS/browser, account alias, fixture/source digest and run identity. Technical evidence records note IDs, revision and asset hashes privately without putting personal books or notes into public logs. A checked box means the action was tried. The final result is separately **Pass**, **Fail** or **Blocked**, with the observed result and failing step. Blocked is never counted as passed. No automatic check fills in the human's handwriting/readability verdict.

The future test interface must show the walkthrough title, its single question, current action, expected result, attempted-action checkbox and specific final verdict. It must allow revisiting the tested views. Buttons describe the action and object, such as Make text larger or Reopen this note. It must not ask a generic Keep/Change question without saying what is being judged.

## Read an EPUB note after an offline reading session

**Question:** Do the same selected words reopen the same readable, editable mixed note on iPad and in each supported browser?

**Setup:** Fresh account-scoped EPUB copy with selectable text and a recorded full source digest; iPad/Pencil and one supported browser signed into that same account. Repeat the browser portion for Mac Chrome, Mac Vivaldi and Android Chrome. This run starts with no note on its chosen range.

- [ ] Find the book, explicitly download it and wait for Ready offline. Disconnect the iPad from the server.
- [ ] Open the downloaded book, select a sentence and create a note. Type a short explanation, enable writing and draw a distinctive word/sketch in the note canvas. Disable writing and confirm the local save state.
- [ ] Close the note and continue reading. Change text size and viewport/orientation; reopen from the selected words. The note and handwriting stay intact, with a highlight/marker on the same occurrence.
- [ ] Fully close and reopen the app while offline. Open the book and note again, edit ink, erase a small mark and Undo. The saved note remains editable.
- [ ] Reconnect and leave the app open. Wait for Synced. In the visible browser, find the one note in global Annotations and the book's notes list without reloading; both open the same note at its original source.
- [ ] In the browser, enlarge text and narrow the reading area. The same words reopen the same readable handwriting. Return to iPad and check that its editable original remains available.

**Pass:** All actions preserve the selected occurrence, mixed contents and original editability; both browser lists and the reader converge within the accepted connected-state target after server publication. State any delay or unreadable/incorrect association explicitly.

Trace: [Note model](../decisions/note-model.md), [offline sync](../decisions/offline-sync.md), [native stack](../decisions/native-stack.md).

## Read PDF page ink after an offline reading session

**Question:** Does page handwriting remain visible, aligned, reachable and editable through reading, zoom, rotation and browser arrival?

**Setup:** Fresh PDF copy with known printed reference text, nonzero crop origin and intrinsic rotation, plus enough canvas margin for a handwritten word beyond the page edge. Record its page geometry. Use the iPad and each supported browser with the same account; this page starts without ink.

- [ ] Explicitly download the PDF, wait for Ready offline and disconnect the iPad. Open the reference page.
- [ ] Enable writing. Mark a printed reference word and write a distinctive comment that extends beyond the page edge. Disable writing. All ink stays visible; Pencil and finger navigate with writing off.
- [ ] Zoom to Fit, 2x and 4x, rotate the viewer and return to the original orientation. Pan to the full outside comment at every view. Printed reference and ink keep their relationship.
- [ ] With writing on, navigate with a finger, return to the page, erase a small ink mark and Undo. Close/reopen the app offline and verify the saved state again.
- [ ] Reconnect, allow foreground sync, and inspect the page in the visible browser without reloading. Repeat Fit/2x/4x, rotation and panning to outside ink. Scroll and select printed text with the ink visible.
- [ ] Find the one page-ink entry in both note lists. Reopen the iPad original, edit, erase and Undo after the browser check.

**Pass:** Ink remains visible during reading, aligned with the original PDF, readable and reachable throughout its full extent, and editable on iPad. The browser preview never replaces the native original. A blurred or clipped outside word is a failure, even if page-centre marks are correct. Viewing a 2x PNG at 4x does not establish additional image detail.

Trace: [PDF placement](../decisions/note-model.md#pdf-notes-and-page-ink), [native PDF workspace](../decisions/native-stack.md), [preview bounds](../decisions/storage-recovery.md).

## Reselect words without duplicating a note

**Question:** Does selecting the same exact range reopen its note while overlapping ranges and repeated words remain distinct?

**Setup:** Fresh EPUB copy with a repeated phrase in two locations, no notes, and a small reference quote identifying each occurrence. Start signed in on iPad; browser verification uses the same account/source.

- [ ] At the first occurrence, select two words and create a mixed note with a unique label.
- [ ] Close it, reselect the exact same range and reopen. The label and drawing return; there is one note for that range.
- [ ] Select only one of those words and create another labelled note. Both notes remain independent despite overlap.
- [ ] At the other occurrence of the same phrase, create a third note. Reflow and reopen all three from their ranges and lists.
- [ ] Remove only the first note's highlight colour. Its note marker/list entry still opens the original note. Sync and repeat identity checks in the browser.

**Pass:** Exactly one active note occupies each distinct verified range; none is deduplicated by quote alone, split by display layout or deleted by removing colour.

Trace: [Exact-range identity](../decisions/note-model.md).

## Use the Apple Pencil tools and writing toggle

**Question:** Do writing, navigation and tool gestures follow the supported native Apple behavior and current system preferences?

**Setup:** Fresh downloaded PDF copy and a separately initialized EPUB ink-note canvas, with no prior marks. Use the physical iPad/Pencil, record the relevant Apple squeeze/double-tap/hover preferences and restore any test setting changes afterward. No other walkthrough supplies drawings.

- [ ] With writing off, use Pencil and finger to navigate. Enable writing, draw with Pencil and navigate with a finger. Disable writing and verify PDF ink stays visible.
- [ ] Use squeeze and move across the system tool picker. Compare the action with the current Apple setting. Exercise double-tap according to its selected system action.
- [ ] Try supported pressure, tilt, barrel roll and hover/tool preview using applicable native tools. Check feedback where enabled/supported. Do not require a visual effect from a tool that does not use that input.
- [ ] Erase, Undo and Redo using native available controls. Move away/back and reopen the locally saved note; the final stroke data, including pressure updates, is preserved.
- [ ] Repeat the tool/input checks in the fresh EPUB note canvas. The book's reflowing text is not a freehand canvas.

**Pass:** Actual drawing and navigation follow the explicit toggle, tool behavior respects Apple settings, and all persisted supported ink data remains editable. Any unavailable API/system behavior is reported precisely rather than imitated with an app-only gesture preference.

Trace: [Native input and ink](../decisions/native-stack.md), [accepted interaction](https://github.com/mooneeb/bookorbit/issues/6#issuecomment-6289693465).

## Enter typed text with Scribble while keeping ink

**Question:** Can Scribble update the typed part of one mixed note while its editable handwriting remains intact?

**Setup:** Fresh EPUB copy and a new text-linked note created during this run. Use standard iPad text input with Scribble enabled and an available keyboard.

- [ ] Select words and open a new note. Draw a unique sketch in its ink canvas and confirm local saving.
- [ ] Focus the typed editor and use Scribble to enter and correct a sentence. Add/correct a word with the keyboard.
- [ ] Close/reopen the note offline. The typed sentence and sketch are together; ink letters have not been converted or replaced.
- [ ] Reconnect, sync and inspect both parts in the browser. Edit typed text there, return to iPad and confirm the drawing remains editable with erase/Undo.

**Pass:** Scribble behaves as native text entry, one note retains both parts, and typed changes never flatten or overwrite the drawing.

Trace: [Mixed-note contract](../decisions/note-model.md), [part merging](../decisions/offline-sync.md).

## Keep an unsaved browser draft when ink arrives

**Question:** Does automatic browser refresh preserve unsaved text while showing a complete incoming ink revision?

**Setup:** This run creates and syncs a fresh mixed EPUB note, then opens it in a supported browser and on iPad. Record the starting body/ink revisions. Repeat for the selected browsers independently.

- [ ] Edit typed text in the browser and leave it unsaved. Keep the tab visible.
- [ ] On iPad, add a distinctive ink mark to the same note and sync. Observe the browser's ink/status update without reloading or navigating away.
- [ ] Confirm the unsaved text, selection/scroll and observed body base survive. Save the browser draft and verify that independent body/ink changes combine.
- [ ] Hide the tab, make another iPad change, then return. The tab checks again without replacing a dirty draft.

**Pass:** The current preview and lists update within the agreed healthy visible-connection target after publication; the browser preserves the draft and revision checks. A body conflict must enter review instead of silently overwriting text.

Trace: [Browser freshness and drafts](../decisions/offline-sync.md#browser-freshness-and-drafts).

## Read with VoiceOver and larger interface text

**Question:** Can available book text, notes and controls be used accessibly in both formats?

**Setup:** Fresh text EPUB, text PDF and image-only page fixtures with clearly identified availability; fresh text-linked and PDF ink notes seeded for this run with selected words and optional typed descriptions. Use the physical iPad with VoiceOver and larger interface text enabled.

- [ ] Find/open each text book, navigate its content and controls, select available words and open its reading note. Check names, reading/focus order and return to the original reading location.
- [ ] Identify handwriting through its linked words/page and optional typed description. Reach close, writing, text editing, save/sync and note-list controls without an unnamed image/control blocking the flow.
- [ ] Enlarge interface text and change orientation. Required actions remain reachable and readable; book reflow retains its note association.
- [ ] Open the image-only page. It remains visually readable and announces unavailable book text; it does not pretend to have transcribed words.

**Pass:** All required available text and actions are accessible, larger UI text remains usable and the image-only limitation is clear. No automatic handwriting or book-page OCR is assumed.

Trace: [Native accessibility scope](../decisions/native-stack.md).

## Keep a note with its original source after replacement

**Question:** Does a changed file preserve the original note/context without silently moving its placement?

**Setup:** Fresh copied book/source and a revised copy with known changed words/pages. Create and sync a labelled note with original context during this run; do this independently for EPUB and PDF. No personal library file is overwritten.

- [ ] Replace the test source with the revised copy using the authorized management action. Reopen the old note in both iPad and browser.
- [ ] Verify its original quote/page, editable original and saved context. A changed-source state is visible; old PDF ink is not drawn on a same-numbered revised page.
- [ ] Decline relocation/rebinding. The old note remains understandable and available from both lists.
- [ ] Repeat with metadata-only/repackaged changed bytes. The app verifies placement rather than assuming either identical or visibly changed text from the hash alone.

**Pass:** Every old note keeps verified original context until a separately verified, explicit association is approved. An unresolved in-book anchor remains accessible through its note/context.

Trace: [Replaced sources](../decisions/note-model.md#replaced-or-missing-source-content).

## Remove and reimport a book without losing its notes

**Question:** Do notes survive removal and reconnect only by choice after a verified identical reimport?

**Setup:** Fresh test book with a byte-for-byte saved source copy and a note created/synced during this run. Use an authorized test operator; repeat independently for EPUB and PDF.

- [ ] Remove the test book. Find the note in global Annotations labelled Book removed, and open its saved quote/page and handwriting.
- [ ] Confirm its native original remains editable and no complete deleted edition is promised by the retained context.
- [ ] Reimport the exact source copy. Decline the offered reconnection once; the retained note remains available without an automatic new binding.
- [ ] Accept a subsequently offered verified reconnection. The existing association/note identities return to current navigation without duplication.

**Pass:** Removal preserves the reader's note/context; complete-content verification and explicit choice control reconnection.

Trace: [Retained association and reimport](../decisions/note-model.md).

## Resume from a chosen competing reading position

**Question:** Can the reader choose between independent stopping places without an open page jumping?

**Setup:** Fresh source copy with at least three recognizable locations and initial synced position. Open it on iPad and browser in this run. Test EPUB and PDF separately, using the same verified source for each comparison.

- [ ] Disconnect iPad, read forward and stop at location A. In the browser, reread an earlier location B and stop there.
- [ ] Reconnect iPad while its page remains open. It stays at A. Preserve both stopping places rather than choosing by percentage, device clock or arrival order.
- [ ] Close and resume. Identify both alternatives and choose B. Resume there; choosing an earlier place is valid.
- [ ] Continue reading, close/reopen and check the new stopping place. Reopening/choosing did not itself create another reading event or retry side effect.

**Pass:** Independent positions remain recognizable until resolved; the chosen source-bound place controls the next resume and the open page stays put.

Trace: [Reading position](../decisions/offline-sync.md#reading-position).

## Keep notes separate across a book's formats

**Question:** Does a combined book-notes list open each note at its own original file/context?

**Setup:** One fresh catalog book with distinct EPUB and PDF sources. During this run create an EPUB text-linked note and PDF page ink, each with a recognizable label; sync both.

- [ ] Open the book's combined notes list on iPad and browser. Both notes are present with understandable source/page or selected-word labels.
- [ ] Open each entry. EPUB returns to its exact words; PDF opens its original page/ink. No automatic matching puts either note on the other format.
- [ ] Make one source unavailable in the test setup and reopen its note. Its saved context remains accessible; the other file is not used as a guessed substitute.

**Pass:** One list exposes both notes while source-specific placement and retained context remain correct.

Trace: [Cross-format placement](../decisions/note-model.md).

## Read comfortably for thirty minutes in each format

**Question:** Can the reader use the required controls and notes comfortably through sustained actual reading?

**Setup:** Fresh private copies of one EPUB and one PDF chosen from the reader's actual library, within the eventual supported profiles. Prepare this run's own signed-in account, downloads and note state. The test operator records the chosen sources privately. Neither book nor its handwritten contents is published. Control inventory and profile coverage must first be settled in the two linked decisions below.

- [ ] Read the EPUB for at least thirty minutes. Navigate normally, make/reopen typed and ink notes, change supported reading preferences and continue from the saved place after reopening.
- [ ] In a separate fresh session, read the PDF for at least thirty minutes. Navigate normally, write on a page, disable writing, revisit the visible ink, zoom/pan and continue after reopening.
- [ ] Include offline reading and a later connected foreground sync in each session. Check that the actual book and notes remain usable throughout; another walkthrough's success does not stand in for this session.
- [ ] Record confusing actions, lost reading places, unreadable text/ink, inaccessible controls, input/navigation mistakes and unexpected pauses. Minor cosmetic issues are recorded separately from required behavior failures.

**Pass:** Both sustained sessions meet the agreed control/content requirements and the human reports that reading and taking notes are usable. Every required workflow passes; no known data-loss, privacy, anchoring, recovery or required-accessibility failure remains. Documented minor cosmetic issues may remain under the accepted rule. A technical metric alone cannot supply the human usability verdict.

Trace: [Accepted complete-journey review choices](https://github.com/mooneeb/bookorbit/issues/13#issuecomment-6374170330).

## Review status

These walkthroughs have not been run against production code. The reader-control inventory is pending in [Choose everyday reading controls and preference behavior](https://github.com/mooneeb/bookorbit/issues/22), and content coverage is pending in [Define supported EPUB and PDF publication profiles](https://github.com/mooneeb/bookorbit/issues/23). Incorporate those answers and the technical conflict/failure, management, installation, recovery and scale scenarios before declaring the handoff complete. The current steps do not silently decide missing reading controls or profiles.
