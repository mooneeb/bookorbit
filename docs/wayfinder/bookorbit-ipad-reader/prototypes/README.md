# Isolated reading and note scenarios

Throwaway logic prototype for [Validate the reading and Pencil interaction model](https://github.com/mooneeb/bookorbit/issues/6), part of the [personal iPad reader map](https://github.com/mooneeb/bookorbit/issues/1).

Open `reader-interaction.prototype.html` by double-clicking it. Nothing needs installation. Progress stays in memory while the page is open; reloading starts over. Source lives on the throwaway prototype branch, outside production readers.

## Aim and review process

Decide whether the proposed reading and note flows make sense to the reader. The overview explains the purpose and offers one starting action. Only one scenario is shown at a time. There is no global reader, shared settings panel, or raw state dashboard.

Each scenario contains its own starting book or note, one aim, the controls it needs, three explicit actions and expected results, three manual checkboxes, and a reaction. Use mouse clicks to stand in for Pencil actions. No actual handwriting is required.

Checkboxes mean the reader tried and checked the result, including a result they dislike. They are never ticked automatically. A separate Keep/Change reaction records approval or objections. The writing-entry comparison records a preference between its two options. Checks unlock only after their corresponding action has been performed.

Scenarios keep independent state when revisited. Restart resets only the current scenario. All ten scenarios are complete when every checklist is ticked and every reaction is recorded. The final summary supplies review text to copy into the conversation; it does not send anything or close the GitHub ticket.

## Scenarios

1. Write over a page, return to reading, and reopen the same ink.
2. Select a passage, create a separate ink note, then close and reopen it.
3. Enter editable text through simulated Scribble, then close and reopen the note.
4. Reflow EPUB text, revisit the original annotated page, and create/compare ink in the new layout.
5. Keep fixed PDF ink aligned during zoom, rotation, and fit.
6. Compare immediate Pencil entry with requiring Write first.
7. Protect against finger page turns while writing, then resume reading navigation.
8. Open a palette through simulated squeeze, choose a highlighter, and use it.
9. Select an eraser through simulated double-tap, erase ink, and restore it with Undo.
10. Read a downloaded book offline, write a note, then see pending sync acknowledged on reconnection.

Scenarios are review fixtures, each initialized with its own required content. None depends on completing an earlier scenario or inherits another scenario's ink, layout, connection, tools, note text, or verdict.

## Scope

This is a simulated interaction review using synthetic book layouts and supplied ink. It does not render actual EPUB/PDF files, capture retained pages, contact BookOrbit, or persist notes. It selects no production reader engine, native app architecture, schema, or sync algorithm.

Native Pencil pressure, tilt, Scribble recognition, hover, barrel roll, squeeze settings and availability, double-tap settings, haptics, palm rejection, latency, native accessibility, and actual multitouch pan/zoom need device validation. The gesture scenarios state their specific assumptions. Sync is an acknowledgement simulation; conflict, deletion, suspension, replacement, and capture-fidelity decisions remain in their existing tickets.

The first script is the pure scenario state model; the second is the disposable interface. No production behavior is accepted until the user has reacted to the scenarios and the decision is recorded on GitHub.
