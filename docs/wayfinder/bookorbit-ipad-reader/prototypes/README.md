# Reading and Pencil interaction lab

Throwaway logic prototype for [Validate the reading and Pencil interaction model](https://github.com/mooneeb/bookorbit/issues/6), part of the [personal iPad reader map](https://github.com/mooneeb/bookorbit/issues/1).

Open `reader-interaction.prototype.html` by double-clicking it. Nothing needs to be installed. Everything stays in memory and resets on reload. This file belongs on the throwaway branch, outside production reader code.

## Question

Does immediate Pencil contact make switching between reading and page writing feel natural, with an explicit return to Read protecting against page turns? Compare the alternative requiring Write first. Check selection, linked typed/ink notes, original annotated views, erasing/Undo, tool gestures, and offline status together.

## Try it

- Start with the EPUB reflow walkthrough. Make ink, return to reading, enlarge text, and write again. Both original views stay under the same passage. Opening an earlier view then choosing Write edits its ink in that original layout.
- Try linked notes. Selection creates a passage anchor; a typed note accepts keyboard or simulated Scribble text, while an ink note keeps strokes separately.
- Try PDF offline in landscape and portrait. Zoom/rotation preserve page coordinates. Reconnection acknowledges pending changes in the simulation.
- Try accidental marks. Require Write first, then erase, Undo, and open the squeeze palette.
- Free play is always available. A mouse acts as a Pencil by default; change it to Finger to try horizontal page swipes. Touch is treated as finger input and a detected pen as Pencil input. Buttons provide accessible substitutes for every simulated action.

Proposed behavior to react to: Pencil contact enters page writing, fingers cannot turn pages until Read is chosen, long-press selection happens during normal reading, linked notes protect the underlying page while open, and edits are kept when a note closes. These choices are not settled until the live user reaction is recorded on the issue.

## Limits

This is an interaction/state demo, with synthetic book layouts and simulated sync. It neither renders real EPUB/PDF files nor validates capture fidelity, source replacement, conflict handling, background sync, or server contracts. Existing decisions about retaining original note context still apply.

The gesture buttons are illustrative, subject to supported native APIs and system preferences. Real-device work must check Pencil pressure/tilt, Scribble, hover, barrel roll, squeeze, double-tap, haptics, palm rejection, latency, selection, multitouch pan/zoom, rotation, and accessibility. No Apple Pencil capability has been proven by this HTML demo. Finger pan/zoom uses the Zoom / fit button here.

The pure `ReaderModel` script contains the proposed state transitions; the second script and HTML are the disposable shell. No production engine, native app boundary, data schema, or synchronization algorithm is selected by this prototype.
