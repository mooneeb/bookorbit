# Compare marks when a sentence wraps

Build 10 answers the live request: **Show me the alternatives before I decide.** The original single-word size-change example passed, but a sentence-spanning mark failed when the words wrapped. This round asks which appearance is worth investigating further. It does not settle direct editing of adapted pieces or automatic recognition of a mark's meaning.

Open **Compare underlines when a sentence wraps**. The separate **Compare circles when a sentence wraps** is available through All walkthroughs. Both start with their own fresh selection and Pencil mark. Neither needs an earlier walkthrough. They reuse the same read-only chapter, but have separate notes, progress, answers and reset controls. The other nine reflow walkthroughs and all earlier preserved-page notes remain available.

## Underlines

1. Select the first whole sentence with writing off, tap Link selected words, turn writing on, and draw only an underline. Turn writing off. In this walkthrough, those strokes are explicitly assigned the underline role.
2. **Wrap and show original shape** keeps the original drawing together. Inspect which words it actually marks.
3. **Show an underline beneath each line** copies the original drawing once per current line and stretches each copy to that line. Inspect placement, thickness and changes to the pen shape. These copies use the actual native drawing, not a preassigned SVG or typed underline.
4. **Return to original layout and ink** restores native editing of the original. Erase a small part and Undo, then turn writing off. The final screen has both comparison buttons and explicit choices, including that neither works.

## Circles

Start independently by selecting the first whole sentence and drawing only an outline around it. The guided steps compare:

- The original shape kept together after wrapping.
- A reshaped copy of the hand-drawn outline around each line.
- One reshaped copy around the union of the sentence's line rectangles.
- Newly drawn neat rounded outlines around each line. These use the first original stroke's ink and regular thickness; they replace the irregular shape and pressure in the displayed derivative. The original is kept.

The last step returns to the original layout for an erase/Undo check. The final screen lets the tester revisit every wrapped view and choose a named appearance, reject all, or report that they could not judge. Copy-based circles can cross letters or include unrelated words. Those failures are visible evidence, not suppressed by hiding the mark.

Blue boxes show the selected words for reference. Judge the actual pen mark or outline around them.

## Original ink and comparison limits

The canonical `<group>.drawing` remains authoritative; a separate pre-reflow original is retained. Affine copies and generated neat outlines are display derivatives under separate `comparison-*.drawing` names. A derived display does not replace the canonical note. Returning to the original mode restores its native canvas. Adapted copies are read-only in this round, and the UI states this. Choosing an appearance does not accept detached editing as the eventual reader behavior: direct on-page erase, lasso, Undo and new strokes after adaptation remain separate gates.

The existing EPUB is unchanged, with SHA256 `c5a447b71601559c898fa711bf69f45110fee59a18e029a2d8062d05352aa0a2`. Both comparisons select actual DOM ranges and resolve Foliate CFIs. Current range fragments are merged by visual line, with at most twelve lines and the complete sentence required on the current page. Copying is not splitting an original stroke. The mode and each source-to-piece transform are recorded in `mark-comparison.json`. Neat outlines record their generated construction separately. Role assignment comes from the standalone walkthrough, not a classifier.

`ReflowReview.markLayout` is optional so existing saved reviews still decode. The actual build 10 controller was exercised with a copy of the build 9 physical single-word fixture: its group, source fingerprint, answer, checks and drawing hashes survived. This simulator compatibility check does not replace physical update or Pencil checks.

See the [build 10 evidence](evidence/reflow-build-10/README.md). Physical comparison verdicts remain pending. No production reader, sync contract, server or database changed.
