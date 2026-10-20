# Personal BookOrbit iPad reader: planning evidence

Canonical map: [Find the design for a personal BookOrbit iPad reader](https://github.com/mooneeb/bookorbit/issues/1). Questions, decisions, status, and dependencies live in its GitHub issues.

## Intake and language

- [Accepted brief](brief.md)
- [Reading-note glossary](../../../GLOSSARY.md)

## Current interaction review

- [Resolved reading and Pencil interactions](https://github.com/mooneeb/bookorbit/issues/6#issuecomment-6289693465)
- [Text-anchored EPUB ink feasibility investigation](https://github.com/mooneeb/bookorbit/issues/16)
- [Actual EPUB reflow validation](https://github.com/mooneeb/bookorbit/issues/17)

The completed review changes the earlier frozen-layout reading policy. Historical preservation reports remain evidence for retaining original context after source replacement, not proof of text-following page ink. Follow the current review and live issues for product requirements.

## Original-context preservation prototype

- [Native capture-and-reopen walkthrough](prototypes/context-preservation/README.md)
- [Simulator and physical evidence, with remaining review gates](prototypes/context-preservation/evidence/README.md)
- [Validate preservation of original annotation context on EPUB and PDF](https://github.com/mooneeb/bookorbit/issues/15)

The prototype now has eleven independent, guided walkthroughs that separate page clarity from offline recovery, browser viewing, failed saves, original words and app-update preservation. The earlier combined review was rejected as confusing. Each walkthrough has a complete task and specific per-step questions. It now opens on the intended Air M2 running iPadOS 26.6.1 through free Xcode signing. A first manually inked EPUB capture and a normal in-place update preserved the saved backgrounds, drawing and original context. Each clarity step names one saved format and zoom level rather than asking a generic verdict. The build 4 physical review accepted page clarity at all tested sizes, EPUB/PDF source-free offline editing, failure recovery and the named browser previews. The original/revised comparison could not be judged and has been replaced with a visual page comparison. Its re-review, the final app-update check, exact browser versions and signing renewal remain open.

## Current browser contract

- [Resolved browser note behavior](https://github.com/mooneeb/bookorbit/issues/7#issuecomment-6290292381)
- [Native-to-browser inline ink compatibility investigation](https://github.com/mooneeb/bookorbit/issues/18)
- [MacBook and Android browser ink validation](https://github.com/mooneeb/bookorbit/issues/19)

Page ink must appear directly inside both browser readers. Browser previews alone do not satisfy this requirement. The remaining investigations and prototypes must establish compatibility while preserving editable ink on iPad.

## Installation and test targets

- [Resolved personal installation, runtime and maintenance policy](https://github.com/mooneeb/bookorbit/issues/11#issuecomment-6291346758)
- [SideStore preferred for free on-device renewal, with Xcode fallback](https://github.com/mooneeb/bookorbit/issues/11#issuecomment-6291640322)

Use the confirmed current iPadOS baseline and selected Mac/Android browsers. Prefer SideStore for routine on-device refresh after validation; retain Xcode for build/bootstrap and fallback. Free signing requires renewal within seven days of profile issuance, so fully disconnected use is bounded by the remaining signing lifetime. Xcode bootstrap and a normal same-identity update have run on the iPad; SideStore compatibility, fresh signing renewal, workflow-transition preservation and reader compatibility still need actual validation.

## Research evidence

- [Native-to-browser inline ink compatibility](research/browser-inline-ink-compatibility.md)
- [Text-anchored EPUB ink through reflow](research/text-anchored-ink-reflow.md)

- [BookOrbit sync foundations for a personal iPad reader](research/bookorbit-sync-foundations.md)
- [iPad reader engines and annotation anchors](research/reader-engine-feasibility.md)
- [Preserving original annotated EPUB and PDF views](research/annotated-view-preservation.md)
- [Native iPad Pencil capabilities and personal installation](research/native-pencil-capabilities.md)
