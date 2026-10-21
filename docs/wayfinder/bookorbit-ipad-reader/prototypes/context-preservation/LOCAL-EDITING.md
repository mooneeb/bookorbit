# Edit one wrapped line without changing another

Build 11 investigates the user's requirement: **Only the words on the line I edited.** The appearance direction is a reshaped copy per line, for both underlines and circles. This round asks whether independent native drawings can keep each line's edits separate through native erase, Undo, Redo and a chapter reload. It does not settle what happens when an already edited piece later splits or joins another line.

Open **Erase only one line of an underline**. **Erase only one line of a circle** is a separate walkthrough in All walkthroughs. Each starts with its own first-sentence selection and hand-drawn mark, with separate notes, progress, checks, answer and reset. Neither needs any previous walkthrough. The previous appearance choices and preserved-page notes stay saved.

Each walkthrough contains five steps:

1. With writing off, select the first whole sentence and tap Link selected words. Turn writing on, draw only the requested underline or outline, then turn writing off.
2. Tap **Wrap and prepare editable lines**. This copies the mark independently onto each current line. Line 1 is selected. Turn writing on, use the native pixel eraser to erase a small gap on line 1, then turn writing off. Line 2 must remain whole.
3. While still on line 1, tap Undo and then Redo. Undo must close the gap; Redo must restore it only on line 1. Leave the gap visible.
4. Tap **Edit next line** to select line 2. Erase a small part there and Undo it. Line 2 must be whole again, while line 1 keeps its saved gap. Switching lines starts a fresh Undo history.
5. Tap **Reload and check the saved marks**. This reloads native drawing files as well as the chapter. Check the gap and unchanged second line. Select line 1, erase another small part, then Undo. The new erasure must be undone while the earlier saved gap remains. Reloading starts a fresh Undo history.

The final question names these expected outcomes. It offers a positive result, an editing/isolation failure and inability to complete the check. Every step has its own tester-controlled checkbox. All ink stays visible with writing off, and the selected line and its quoted words appear above the page.

## Deliberate limits

Keep the starting iPad orientation during this check. The native copies are associated with exact line-range CFIs and quoted words, using the actual EPUB geometry. The prototype detects changed line breaks and pauses editing with an instruction to return to the original orientation. It does not silently assign an edited copy to new words. General reflow of edited pieces is an unresolved next question, not a promised behavior of this narrow walkthrough.

Only the selected line is editable. Other lines are native-rendered previews. Edit next line switches the actual native canvas to that line's drawing, clears its previous Undo history and turns writing off. This makes the local-editing rule explicit without relying on unavailable stroke-identity APIs. It does not establish acceptance of manual line switching as the eventual reader interaction.

The original whole-sentence drawing is retained unchanged. Each materialized copy gets its own native drawing, CFI, exact quote and fixed text reference frame. Later erasing never refits the remaining ink to new drawing bounds. Native PencilKit retains the drawing's strokes, masks and other editable data. This is a prototype representation, not the production note schema.

The EPUB source is unchanged. No production reader, server, sync contract or database changed. See [build 11 evidence](evidence/reflow-build-11/README.md) for simulator probes and physical preparation. A synthetic delegate edit does not validate the physical Pencil eraser or native Undo/Redo; those require the live walkthrough.
