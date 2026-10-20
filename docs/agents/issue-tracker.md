# Issue tracker: GitHub

Repository: [mooneeb/bookorbit](https://github.com/mooneeb/bookorbit). Use `gh` with `--repo mooneeb/bookorbit` for issue work in this checkout.

The canonical planning artifacts are GitHub issues. Local `.scratch/` Wayfinder files are migration snapshots; read current bodies, comments, states, assignments, and dependencies from GitHub.

Current map: [Find the design for a personal BookOrbit iPad reader](https://github.com/mooneeb/bookorbit/issues/1).

## Issue operations

- Create an issue with `gh issue create --repo mooneeb/bookorbit --title "..." --body-file <path>` and the appropriate labels. Use a file for multiline content.
- Read an issue with `gh issue view <url> --comments`.
- Resolve a decision by posting its resolution as a comment, then closing it as completed. Keep the question in the issue body.
- Refer to issues by their linked titles in human-facing text.

## Wayfinding operations

- Map: one open issue labelled `wayfinder:map`. Keep Destination, Notes, Decisions so far, Not yet specified, and Out of scope. Decisions so far links resolved tickets and their resolution comments; open tickets are found through native sub-issues.
- Child ticket: create an issue labelled `wayfinder:research`, `wayfinder:prototype`, `wayfinder:grilling`, or `wayfinder:task`, then attach it to the map with `POST /repos/mooneeb/bookorbit/issues/<map-number>/sub_issues` and JSON `{"sub_issue_id": <child-database-id>}`.
- Blocking: use native dependencies with `POST /repos/mooneeb/bookorbit/issues/<child-number>/dependencies/blocked_by` and JSON `{"issue_id": <blocker-database-id>}`. Numeric database IDs differ from issue numbers and node IDs.
- Frontier: list the map's sub-issues, keep open unassigned children with no open blockers, and preserve sub-issue order. Read dependency lists or `issue_dependencies_summary.blocked_by`; the latter counts open blockers.
- Claim before work with `gh issue edit <url> --add-assignee @me`. Resolved tickets may retain their assignee as history.
- Resolve by posting the answer, closing the issue, and appending one linked gist to the map. Use a resolution-comment permalink when available.
- Create new tickets before wiring their dependencies. Research evidence belongs in linked repository assets; human decisions require the live exchange specified by Wayfinder.

## Scope

This fork owns the personal iPad planning effort. Repository source links in the published research are pinned to the audited baseline. Preserve the project's AGENTS.md conventions and the selected skill's session boundaries.
