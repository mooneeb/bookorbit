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

The prototype now has eleven independent, guided walkthroughs that separate page clarity from offline recovery, browser viewing, failed saves, original words and app-update preservation. The earlier combined review was rejected as confusing. Each walkthrough has a complete task and specific per-step questions. It now opens on the intended Air M2 running iPadOS 26.6.1 through free Xcode signing. A first manually inked EPUB capture and a normal in-place update preserved the saved backgrounds, drawing and original context. Each clarity step names one saved format and zoom level rather than asking a generic verdict. The build 4 physical review accepted page clarity at all tested sizes, EPUB/PDF source-free offline editing, failure recovery and the named browser previews. The final build 5 review also accepted the corrected original/revised page comparison and post-update editing, completing all eleven prototype behavior verdicts. The subsequent [free-signing renewal review](https://github.com/mooneeb/bookorbit/issues/20#issuecomment-6299949060) and [preservation resolution](https://github.com/mooneeb/bookorbit/issues/15#issuecomment-6300054724) complete that earlier decision. Exact browser versions at the preservation review remain a provenance limit; the later browser proof records its own exact versions.

## Note identity and storage

- [Reading-note model and storage specification](decisions/note-model.md)
- [Choose note identity, anchoring, and storage ownership](https://github.com/mooneeb/bookorbit/issues/8): canonical live choices, final acceptance and status.

The specification captures mixed text/ink notes, exact-range identity, PDF page grouping, editable server originals and retained context after book removal. It proposes extending the existing annotation owner; the linked decision records acceptance. Sync protocol, final reader stack and backup/scale policy remain separate decisions.

## Offline sync and recovery

- [Offline note sync, conflicts and recovery proposal](decisions/offline-sync.md)
- [Choose offline sync, conflict, and deletion behavior](https://github.com/mooneeb/bookorbit/issues/9): canonical live choices, final acceptance and status.

The proposal covers durable local notes, retry identity, revision checks, text/ink merging, conflict review, deletion recovery, source-bound reading positions and browser freshness. It distinguishes server acceptance from local saving and conditional background attempts. Its network and failure behavior requires later implementation and validation.

## Browser compatibility

- [Browser compatibility walkthroughs](prototypes/browser-compatibility/README.md): actual Foliate/EmbedPDF readers with native ink fixtures and isolated review steps.
- [Completed live browser and iPad review](prototypes/browser-compatibility/evidence/live-review.json): three selected browser reviews and both matching native erase/Undo checks passed; the initial margin failure and correction remain recorded.

- [Resolved browser note behavior](https://github.com/mooneeb/bookorbit/issues/7#issuecomment-6290292381)
- [Native-to-browser inline ink compatibility investigation](https://github.com/mooneeb/bookorbit/issues/18)
- [MacBook and Android browser ink validation](https://github.com/mooneeb/bookorbit/issues/19)

PDF page ink must appear directly inside the browser reader. EPUB uses notes attached to exact selected words under the current format decision. The bounded compatibility proof preserves editable originals on iPad. Browser note lists, typed-note editing, recoverable Trash and automatic arrival remain requirements for the later production design; the prototype's in-memory typed edits and local fixture delivery do not establish those integrations.

## Installation and test targets

- [Resolved personal installation, runtime and maintenance policy](https://github.com/mooneeb/bookorbit/issues/11#issuecomment-6291346758)
- [SideStore preferred for free on-device renewal, with Xcode fallback](https://github.com/mooneeb/bookorbit/issues/11#issuecomment-6291640322)

Use the confirmed current iPadOS baseline and selected Mac/Android browsers. The [validated free signing route](https://github.com/mooneeb/bookorbit/issues/20#issuecomment-6299949060) uses manual SideStore IPA import with the fixed AppID and Append Team ID unchecked; retain Xcode for build/bootstrap and fallback. Free signing requires renewal within seven days of profile issuance, so fully disconnected use is bounded by the remaining signing lifetime. The tested renewal and update preserved editable notes. Ordinary reader badge refresh remains unvalidated.

## Research evidence

- [Existing readers with freehand writing directly over EPUB pages](research/direct-epub-page-handwriting.md)
- [Native-to-browser inline ink compatibility](research/browser-inline-ink-compatibility.md)
- [Text-anchored EPUB ink through reflow](research/text-anchored-ink-reflow.md)

- [BookOrbit sync foundations for a personal iPad reader](research/bookorbit-sync-foundations.md)
- [iPad reader engines and annotation anchors](research/reader-engine-feasibility.md)
- [Preserving original annotated EPUB and PDF views](research/annotated-view-preservation.md)
- [Native iPad Pencil capabilities and personal installation](research/native-pencil-capabilities.md)
