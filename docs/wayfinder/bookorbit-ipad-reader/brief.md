# Personal BookOrbit iPad reader: accepted brief

Source: the user's wayfinder interview, 2026-10-20. These are intake constraints, not resolutions of the map's detailed decision tickets.

- Destination: a build-ready specification and settled decisions before implementation.
- Personal iPad app connected to the user's self-hosted BookOrbit, with an Apple Books-like reading and note-taking experience. A separate native app is the proposed route; source availability and reuse options remain subject to investigation.
- EPUB and PDF have equal importance. The specification must address both rather than quietly deferring either format.
- Both page ink and passage-linked notes are required. Their precise interaction and anchoring behavior remains open.
- The iPad is the main reading device and the only device requiring ink editing, using Apple Pencil Pro and supported native input features.
- Notes must automatically sync to the existing BookOrbit browser app at https://books.mooneeb.dev, accessed from a MacBook and an Android phone. Other browser behavior should remain familiar; no native Mac, Android, or iPhone app is requested.
- Downloaded books and note creation/editing must work offline, with synchronization after reconnecting.
- Personal changes to the BookOrbit backend and web app are acceptable when needed.
- Preserve editable ink and support Scribble for entering typed notes. Handwriting search and automatic transcription are not requirements in this brief.

## Vocabulary

Use the [reading-note glossary](../../../GLOSSARY.md). Scribble is a text-entry method; an ink note preserves handwriting. This distinction does not settle whether a single note may contain several kinds of content.

## Known facts from initial repository inspection

These are starting pointers, not a completed compatibility or security audit.

- The [README](https://github.com/mooneeb/bookorbit/blob/ce118e3890ea8c9019857cb7556552cdc9992f8e/README.md#bookorbit-for-iphone-and-apple-watch) links an official App Store app, but this checkout contains no Swift/Xcode application source found in the initial inspection. The official app's implementation and extension options remain unverified.
- [Native login support](https://github.com/mooneeb/bookorbit/blob/ce118e3890ea8c9019857cb7556552cdc9992f8e/server/src/modules/auth/dto/auth-client.dto.ts), [book delivery](https://github.com/mooneeb/bookorbit/blob/ce118e3890ea8c9019857cb7556552cdc9992f8e/server/src/modules/book/book.controller.ts), [annotation input](https://github.com/mooneeb/bookorbit/blob/ce118e3890ea8c9019857cb7556552cdc9992f8e/server/src/modules/annotation/dto/create-annotation.dto.ts), [book journal notes](https://github.com/mooneeb/bookorbit/blob/ce118e3890ea8c9019857cb7556552cdc9992f8e/packages/types/src/book-journal.ts), and [paginated notebook APIs](https://github.com/mooneeb/bookorbit/blob/ce118e3890ea8c9019857cb7556552cdc9992f8e/packages/types/src/notebook.ts) already exist.
- Existing note contracts inspected so far expose text and position information, not ink documents. Specialized annotation synchronization should not be assumed to be a complete offline iPad sync protocol.

## Project constraints

Follow [AGENTS.md](https://github.com/mooneeb/bookorbit/blob/ce118e3890ea8c9019857cb7556552cdc9992f8e/AGENTS.md). In particular, preserve user ownership and permissions, bounded queries and work, compatibility with large personal libraries, generated schema migrations, and the project's frontend/backend conventions.
