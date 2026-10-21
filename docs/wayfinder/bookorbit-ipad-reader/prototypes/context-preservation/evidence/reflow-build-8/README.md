# Reflow build 8: simulator evidence and failed physical load

For [Validate text-following ink through actual EPUB reflow](https://github.com/mooneeb/bookorbit/issues/17). See the [walkthrough guide and explicit candidate limits](../../REFLOW.md).

Both unsigned simulator and iPad builds compile with deployment target iPadOS 26.0 using Xcode 27. The intended physical target remains the iPad Air 13-inch (M2), iPadOS 26.6.1. The simulator is an iPad Air 13-inch (M3), iOS 26.0. Neither this build nor this probe resolves the human decision.

## What the probe establishes

The [summary](summary.json), [geometry history](simulator/geometry-history.json) and [raw review state](simulator/review.json) record an actual Foliate EPUB ZIP load in WKWebView. The separately labelled launch probe programmatically selected the **second** useful through a DOM Range and obtained a renderer-generated CFI. It used three synthetic native PKStroke objects, not a physical handwritten important or an agent-supplied user verdict.

Across larger/smaller text, narrow/wide width, scrolled/paginated flow and a resource unload/reload, that CFI resolved to the selected word. The target's measured rectangles changed with the actual layout. All canonical drawing hashes stayed identical across the recorded geometry packets; there was one active resource. The summary gives the packet count for the final run. All tried checkboxes remain false, and no human answer is stored.

The [initial diagnostic crash](initial-crash.json) is retained as a failed attempt: after the layout sequence, Foundation aborted while serializing a transient number into diagnostic JSON. Saved canonical ink survived. The bridge now normalizes non-finite progress values to null, rejects non-finite range rectangles and validates native diagnostic JSON before writing. The separate probe deliberately injects NaN/Infinity progress values after chapter navigation to exercise that failure path. Its retest outcome is recorded separately from the physical review.

The [larger-text composite](simulator/probe-bigger.png), [narrow-page composite](simulator/probe-narrow.png), [smaller-text composite](simulator/probe-smaller.png) and [returned paginated composite](simulator/probe-paginated.png) combine the native WebKit snapshot with the actual projected native drawing. They are simulator geometry evidence. They do not prove literal multi-line stroke reflow, pressure fidelity, old/new editing or physical input routing.

The first browser inspector attempt and its retry both returned `Preview automation snapshot timed out after 15000ms.` No browser result is inferred from those failures. Browser inline-reader acceptance remains a separate ticket.

## Device preparation

[Preparation metadata](ipad-preparation.json) records a private backup of the installed build 7 scratch notes before any update, an unsigned build 8 IPA staged in Files, and an unchanged scratch-file comparison after staging. Staging a file is not an installation or a newly issued profile. Raw backups, device/Team identifiers and device-tool logs remain private.

The user imported build 8 through SideStore with the existing identifier. The [post-install check](ipad-installation.json) independently confirms build 8 on the intended iPadOS 26.6.1 device. Its reader-specific signed export contains the corrected JavaScript and original EPUB, and its code signature verifies. The profile includes this iPad, matches the original application identifier and is valid from 21 October 2026 at 07:11:11 UTC to 28 October at 07:11:11 UTC. Its signed entitlements match the profile. The earlier private Team reference is unavailable, so no independent comparison to the prior Team is claimed.

Before opening the reader, a fresh private snapshot contained 176 scratch files. The earlier temporary 176-file baseline no longer exists, so a full pre-install hash comparison is unavailable. All 21 files compared against published older fixtures match, including eight editable drawings, original backgrounds and previews, and the maintenance note's record and local marker. This narrower comparison does not establish equality of every file. No restore or note change was performed.

The [native launch record](native-launch.json) confirms the app opened with the first reflow walkthrough requested and no automated probe enabled. The new reflow folder was absent in the pre-launch snapshot. Physical authoring and the live verdict are still pending. The earlier preserved-page notes and the new reflow walkthroughs use separate folders.

The user subsequently reported a white page saying Not found and a JavaScript exception. The physical sample did not load: its saved review has no source hash, no ink groups and no geometry. A successful process launch did not establish a successful sample load. See the [build 9 correction and regression evidence](../reflow-build-9/README.md). No physical reflow acceptance is claimed for build 8.

## Remaining gates

The nine independent walkthroughs collect the physical exact-example result, actual line-wrap failures, orientation/margins, finger/Pencil navigation, old-stroke erase/lasso/Undo, newly added strokes, the acceptability of explicit group selection, crowded labels, offline cold reopen and real signing-update preservation. Their answers must come from the user.

The experimental placement rule moves and uniformly scales a complete drawing with the selected range's first fragment. It supplies no automatic role inference, independent connector routing, stroke splitting or collision resolution. Undo history is scoped to a stable editing layout/group. When the selected group is offscreen, the writing overlay blocks Pencil navigation and requires selecting words on the current page before starting another group. These limits are visible proposals to judge, not accepted product constraints.

No production app, home-server behavior, database, API or deployment changed. No prototype tests were added. Native builds, Swift format/lint, JavaScript syntax, EPUB ZIP/XML checks, fixture/evidence hashes, IPA metadata, privacy checks and the repository's commit/push checks cover preparation; physical Pencil acceptance is still pending.
