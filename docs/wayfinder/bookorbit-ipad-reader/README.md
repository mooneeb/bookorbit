# Personal BookOrbit iPad reader: planning evidence

Canonical map: [Find the design for a personal BookOrbit iPad reader](https://github.com/mooneeb/bookorbit/issues/1). Questions, decisions, status, and dependencies live in its GitHub issues.

## Intake and language

- [Accepted brief](brief.md)
- [Reading-note glossary](../../../GLOSSARY.md)

## Current interaction review

The current [accepted format split](https://github.com/mooneeb/bookorbit/issues/17#issuecomment-6321857426) uses freehand page ink for PDFs and typed/ink notes linked to exact selected words for EPUBs. It supersedes the earlier requirement to reshape arbitrary EPUB page ink through reflow. Existing-reader research remains a comparison, rather than acceptance of a new implementation.

- [Resolved reading and Pencil interactions](https://github.com/mooneeb/bookorbit/issues/6#issuecomment-6289693465)
- [Text-anchored EPUB ink feasibility investigation](https://github.com/mooneeb/bookorbit/issues/16)
- [Actual EPUB reflow validation](https://github.com/mooneeb/bookorbit/issues/17)

The completed reviews and scope decision are linked above. Historical preservation reports remain evidence for retaining original context after source replacement, not proof of text-following page ink. Follow the current format decision and live issues for product requirements.

## Original-context preservation prototype

- [Native capture-and-reopen walkthrough](prototypes/context-preservation/README.md)
- [Simulator and physical evidence, with remaining review gates](prototypes/context-preservation/evidence/README.md)
- [Validate preservation of original annotation context on EPUB and PDF](https://github.com/mooneeb/bookorbit/issues/15)

The prototype now has eleven independent, guided walkthroughs that separate page clarity from offline recovery, browser viewing, failed saves, original words and app-update preservation. The earlier combined review was rejected as confusing. Each walkthrough has a complete task and specific per-step questions. It now opens on the intended Air M2 running iPadOS 26.6.1 through free Xcode signing. A first manually inked EPUB capture and a normal in-place update preserved the saved backgrounds, drawing and original context. Each clarity step names one saved format and zoom level rather than asking a generic verdict. The build 4 physical review accepted page clarity at all tested sizes, EPUB/PDF source-free offline editing, failure recovery and the named browser previews. The final build 5 review also accepted the corrected original/revised page comparison and post-update editing, completing all eleven prototype behavior verdicts. The remaining [free-signing renewal task](https://github.com/mooneeb/bookorbit/issues/20) blocks closure of the broader preservation decision. Exact browser versions at review remain a provenance limit.

## Current browser contract

- [Browser compatibility walkthroughs](prototypes/browser-compatibility/README.md): actual Foliate/EmbedPDF readers with native ink fixtures, isolated review steps and pending live browser/iPad verdicts.

- [Resolved browser note behavior](https://github.com/mooneeb/bookorbit/issues/7#issuecomment-6290292381)
- [Native-to-browser inline ink compatibility investigation](https://github.com/mooneeb/bookorbit/issues/18)
- [MacBook and Android browser ink validation](https://github.com/mooneeb/bookorbit/issues/19)

PDF page ink must appear directly inside the browser reader. EPUB uses notes attached to exact selected words under the current format decision. Browser note lists, typed-note editing, recoverable Trash and automatic arrival remain required. The remaining investigations and prototypes must establish compatibility while preserving editable ink on iPad.

## Installation and test targets

- [Resolved personal installation, runtime and maintenance policy](https://github.com/mooneeb/bookorbit/issues/11#issuecomment-6291346758)
- [SideStore preferred for free on-device renewal, with Xcode fallback](https://github.com/mooneeb/bookorbit/issues/11#issuecomment-6291640322)

Use the confirmed current iPadOS baseline and selected Mac/Android browsers. Prefer SideStore for routine on-device refresh after validation; retain Xcode for build/bootstrap and fallback. Free signing requires renewal within seven days of profile issuance, so fully disconnected use is bounded by the remaining signing lifetime. Xcode bootstrap and a normal same-identity update have run on the iPad; SideStore compatibility, fresh signing renewal, workflow-transition preservation and reader compatibility still need actual validation.

## Research evidence

- [Existing readers with freehand writing directly over EPUB pages](research/direct-epub-page-handwriting.md)
- [Native-to-browser inline ink compatibility](research/browser-inline-ink-compatibility.md)
- [Text-anchored EPUB ink through reflow](research/text-anchored-ink-reflow.md)

- [BookOrbit sync foundations for a personal iPad reader](research/bookorbit-sync-foundations.md)
- [iPad reader engines and annotation anchors](research/reader-engine-feasibility.md)
- [Preserving original annotated EPUB and PDF views](research/annotated-view-preservation.md)
- [Native iPad Pencil capabilities and personal installation](research/native-pencil-capabilities.md)
