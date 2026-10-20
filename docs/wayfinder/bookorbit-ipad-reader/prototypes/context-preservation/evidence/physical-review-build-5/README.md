# Final physical behavior review

The user confirmed both remaining checks after the controlled update to build 5:

- Update preservation: **Everything was kept and editing works**.
- Original/revised page comparison: **Yes, the original page and ink stayed together**.

Together with the nine successful [build 4 reviews](../physical-review-build-4/README.md), **all eleven prototype behaviors are accepted**. This completes the human review of the preserved-page walkthroughs. [The final record](final-human-review.json) distinguishes chat verdicts from raw device UI state.

## Physical evidence and provenance

A read-only iPad snapshot retains `maintenance/` and `replacement/` files without modification. The maintenance drawing advanced from revision 2 to revision 4 after the user tried editing, the app recorded a new process launch, and its original sentence and local marker remain present. The user's confirmation supplies the physical erase/Undo result.

The replacement walkthrough recorded `visual-comparison-opened`. Its physical [comparison metadata](replacement/visual-comparison.json) contains the original useful sentence, the revised sentence, original anchor and original-background/drawing hashes, and reports no old ink moved to the revised sample. The original drawing hash still matches the saved editable file. The previous unable-to-judge review remains in `before-visual-comparison-review.json`.

The app's raw finished flags were still false when read. The maintenance success answer was saved; the comparison's updated checkbox/answer fields were not submitted in the app. The explicit answers in this conversation are the final human verdicts. No response, checkbox or finished flag was written back to the iPad to make it appear complete.

## Accepted scope

Both page-image and PDF-copy backgrounds are acceptable through the tested 1x, 2x and 4x views for these EPUB and PDF fixtures. The user accepted source-free offline reading/editing, missing-picture refusal with retained ink, browser viewing of exported excerpts, original context preserved beside changed sample words, and normal in-place app-update preservation with working ink editing.

These are local preserved-page results. They do not validate arbitrary book formats, ordinary EPUB text-following reflow, normal browser-reader overlays, production sync, complete revised-book import/relink, a new provisioning renewal, or every storage failure. Browser-version fields remain incomplete, especially Android Chrome.

## Remaining prerequisite

[Validate free signing renewal and note preservation on the intended iPad](https://github.com/mooneeb/bookorbit/issues/20) now owns the manual signing prerequisite. The normal Xcode updates reused the same free profile, so successful updates do not prove SideStore/LocalDevVPN compatibility or a genuinely renewed profile. That task is a native blocker of the still-open [original-context preservation decision](https://github.com/mooneeb/bookorbit/issues/15). The eleven successful behavior checks do not need repeating merely to undertake signing validation.
