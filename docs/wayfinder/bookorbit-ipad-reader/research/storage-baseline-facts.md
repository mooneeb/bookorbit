# Storage, recovery and scale: inspected baseline

Checked 2026-10-23 for [Set library scale, storage, backup, and export requirements](https://github.com/mooneeb/bookorbit/issues/12). Repository pin: a46051434369d8c0e699e38f1795c1a6e3559750. Two read-only audits inspected committed source, evidence and binary headers. No deployment, backup/restore, runtime benchmark or device check was performed. These are facts and sizing anchors, not selected production budgets.

## Retained ink and context

The three physical build-4 clarity fixtures retain the following exact blob lengths. All listed PNGs are 1280 by 960 pixels for a 640 by 480-point canvas at 2x. [Committed examples][examples], [capture observations][capture-observations].

| Physical fixture    | Editable drawing bytes | Ink PNG bytes | Context PNG bytes | Context PDF bytes | Standalone HTML bytes |
| ------------------- | ---------------------: | ------------: | ----------------: | ----------------: | --------------------: |
| Single-column EPUB  |                 10,599 |        45,372 |           357,055 |            53,282 |               772,860 |
| Column EPUB         |                 18,995 |        68,522 |           397,726 |            53,880 |               931,190 |
| Cropped/rotated PDF |                 15,661 |        68,848 |            63,881 |            14,162 |               356,011 |

Physical drawings have no recorded per-file stroke counts in those fixtures. The corresponding simulator samples have four synthetic strokes each. Later browser-review post-edit records identify 12 EPUB strokes with a 330 by 400-point crop and 20 PDF strokes with a 390 by 405-point crop; their 2x validation images are 660 by 800 and 780 by 810 pixels. Those later binary assets are private, so their sizes are not established by this repository. They are not the earlier browser derivative revisions. [Simulator record][simulator-record], [post-edit provenance][live-review].

The physical review accepted 18 format/zoom combinations: two context representations, three fixture types and 1x/2x/4x views. The PNG stayed at 2x; the PDF-copy display rerendered at scale 4 for the 4x step. The later browser correction also passed reachable outside-page ink. These results do not establish arbitrary-book quality, unlimited zoom or a production raster resolution. [Preservation review][preservation-review], [display implementation][display-render], [browser limits][browser-limits].

The capture/write observations were 56.3, 53.6 and 29.4 ms. App-process lifetime peak RSS before/after was 103.8/113.8, 169.1/169.1 and 178.4/178.4 MiB. These exclude readiness/export time and separate WebKit/GPU processes, and do not measure incremental capture memory. [Recorded measurement qualifications][capture-observations].

For tightly packed four-byte RGBA pixels, calculated buffers are 1.172 MiB at 640 by 480, 4.688 MiB at 1280 by 960, and 18.750 MiB at 2560 by 1920. Two 2x buffers total 9.375 MiB. These are width-times-height calculations, excluding row padding, encoders, drawing objects, PDF/font decoding, WebKit and GPU allocations. The standalone HTML duplicates background and ink images using base64, with approximately 4/3 encoding expansion; its byte size is not the canonical storage requirement. [HTML export implementation][html-export].

## EPUB expansion and experimental guards

The committed reflow EPUB is 142,679 bytes. Bounded analysis found 15 archive members totaling 288,310 bytes: a 241,392-byte font and nine XHTML chapters of 4,903 to 4,935 bytes, totaling 44,267 bytes. Keeping original plus all raw members requires 430,989 bytes before manifests/filesystem overhead. The separate unpacked capture seed has nine files totaling 248,116 bytes; it is not the proposed production offline package. [Reflow source][reflow-epub], [capture seed][capture-seed], [proposed package contract][native-package].

The capture bench has an eight-million-pixel check, 16 MiB per written artifact and eight-second readiness timeout. The pixel guard runs after image generation/PNG encoding; the artifact guard receives already-allocated Data. The separate exporter decodes the entire drawing before checking a maximum 4096 by 4096-point crop, which at 2x can require an 8192 by 8192 image: 256 MiB for one calculated RGBA buffer. These guards do not proactively bound peak memory. [Bench limits][bench-limits], [post-render check][raster-check], [ink exporter][ink-exporter].

The inspected Foliate paths have no explicit application-level entry-count, expanded-member/aggregate-byte, decoded-image or processing-time budgets. File/ZIP loading enumerates entries and expands members to whole text/Blob values; the network member loader consumes complete response text/Blob values, and sections are parsed as complete documents. Lazy loading does not bound one giant section. The server's EPUB metadata parser buffers XML members, resource routes stream entries without an explicit expansion ceiling, and the open-publication cache is count-limited to 50 rather than byte-limited. [ZIP loader][zip-loader], [member loader][member-loader], [EPUB parser][epub-parser], [server parser][server-parser], [resource route][resource-route], [publication cache][publication-cache].

## Existing server backup and export behavior

Production has separate PostgreSQL, book and app-data stores. Database records retain filesystem paths. App data includes covers, fonts, avatars, icons, Book Dock and upload staging; delivery derivatives also have cache directories. A database-only restore does not restore this inventory. [Compose mounts][compose], [configuration][configuration], [file schema][file-schema].

No complete BookOrbit-owned backup creator, coordinated database/filesystem snapshot, backup encryption/verification pipeline, retention schedule or application restore drill was found in the searched scripts, deployment configuration, documentation and relevant tests. Migration tests called backups import another application's data. Existing identity/rollback documentation requires preserving server identity and matching application/database state, without supplying the complete recovery workflow. No BookOrbit S3/object-storage backend was found. Applicable configuration and credential-decryption keys also matter to a server restore. These are bounded negative findings, not an inspection of the running home server. [Identity guidance][server-identity], [rollback note][rollback-note], [configuration][configuration], [email encryption][email-encryption].

| Existing export              | Actual contract                                                                            | Recovery/scale limit                                                                                                                                                                   |
| ---------------------------- | ------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Annotation Markdown/CSV/JSON | Current-user-scoped selection, at most 5,000 rows, one in-memory output string             | No completeness marker/continuation; omits native drawings, preview/context manifests, complete lifecycle/revision and pending operations. Not a new ink recovery backup.              |
| Book ZIP                     | Existing files, primary/all/audio selection; LibraryDownload permission and library access | 250 books, 2,000 files, 8 GiB projected bytes, two exports per user tracked in process memory. Files are streamed, but this is not a database/personal-state backup.                   |
| Metadata CSV/JSON            | Selected/all-matching books, optional paths and rating/status/progress                     | 100,000 rows, 120 MiB estimated output; rows/output materialized. No journals or whole-book personal-note bodies. These paths lack the content-filter check used by individual access. |

Sources: [annotation owner/route][annotation-route], [annotation export selection][annotation-query], [annotation exporter][annotation-export], [book export limits][book-export-limits], [ZIP selection][zip-export], [metadata export][metadata-export], [access comparison][access-check]. Existing exports remain existing features; the accepted app-recovery-only choice does not require removing them.

## Existing high-volume seams

- Catalog defaults to 50 items, allows 200 and caps offset at 1,000,000. The browser fetches 100-book blocks with virtualization, but retains a placeholder array sized to the complete count. [Query limits][catalog-limits], [browser window][browser-window].
- Annotation Hub pages cap at 100. Per-book annotation reads return the complete collection when page is omitted. Journal lists stop at 2,000 without continuation. Notebook has user/library-scoped keyset pagination, default 40/max 100; that cursor is not the accepted deletion-aware sync feed. [Annotation DTO][annotation-dto], [per-book paging][annotation-pages], [journal types][journal-types], [Notebook types][notebook-types], [Notebook paging][notebook-paging].
- Imports cap configurable file size at 4 GiB and chunks at 16 MiB, with seven-day receiving expiry and 30-day terminal-session retention. Owner checks, retry identity, offsets and checksums are useful mechanisms, not new note-asset publication. Startup recovery loads all processing sessions without a concurrency cap. Browser uploads use whole-file multipart/XHR with three concurrent uploads. Metadata extraction skips some parsers above 128 MiB, including PDF. [Import constants][upload-limits], [upload sessions][upload-sessions], [browser uploads][browser-uploads], [extraction limit][extraction-limit].
- General bulk query selection materializes all matching IDs, while explicit-ID selection has no array-size ceiling. Some progress streams cancel at disconnection. Book moves persist summaries but mark interrupted jobs and rescan after restart. Book Dock batching accumulates final results; scans retain whole-root candidate/known-file maps. The separate administrative metadata queue does demonstrate bounded 1,000-ID scheduling and paged failure results. [Bulk DTO][bulk-dto], [bulk selection][bulk-selection], [bulk repository][bulk-repository], [move recovery][move-recovery], [Book Dock results][dock-results], [scanner][scanner], [metadata queue][metadata-queue].

The accepted contracts additionally require durable note identities/associations, source bindings, parts/lifecycle heads, conflicts/Trash, aliases, receipts/replay floors, referenced immutable assets and coordinated restore-generation rotation. A restored iPad must reauthenticate; native credentials are device-only. Original EPUB plus raw-member packages, PDFs, note/context assets and pending bodies all count toward storage. Current import/export limits do not establish production reader or recovery limits. [Note model][note-model], [sync recovery][sync-recovery], [native storage][native-storage].

[examples]: https://github.com/mooneeb/bookorbit/tree/a46051434369d8c0e699e38f1795c1a6e3559750/docs/wayfinder/bookorbit-ipad-reader/prototypes/context-preservation/evidence/physical-review-build-4/examples
[capture-observations]: https://github.com/mooneeb/bookorbit/blob/a46051434369d8c0e699e38f1795c1a6e3559750/docs/wayfinder/bookorbit-ipad-reader/prototypes/context-preservation/evidence/physical-review-build-4/README.md#L31
[simulator-record]: https://github.com/mooneeb/bookorbit/blob/a46051434369d8c0e699e38f1795c1a6e3559750/docs/wayfinder/bookorbit-ipad-reader/prototypes/context-preservation/evidence/simulator-26.0/cold-reopen-run.json#L1
[live-review]: https://github.com/mooneeb/bookorbit/blob/a46051434369d8c0e699e38f1795c1a6e3559750/docs/wayfinder/bookorbit-ipad-reader/prototypes/browser-compatibility/evidence/live-review.json#L228
[preservation-review]: https://github.com/mooneeb/bookorbit/blob/a46051434369d8c0e699e38f1795c1a6e3559750/docs/wayfinder/bookorbit-ipad-reader/prototypes/context-preservation/evidence/README.md#L15
[display-render]: https://github.com/mooneeb/bookorbit/blob/a46051434369d8c0e699e38f1795c1a6e3559750/docs/wayfinder/bookorbit-ipad-reader/prototypes/context-preservation/Sources/Experiment.swift#L996
[browser-limits]: https://github.com/mooneeb/bookorbit/blob/a46051434369d8c0e699e38f1795c1a6e3559750/docs/wayfinder/bookorbit-ipad-reader/prototypes/browser-compatibility/README.md#L65
[html-export]: https://github.com/mooneeb/bookorbit/blob/a46051434369d8c0e699e38f1795c1a6e3559750/docs/wayfinder/bookorbit-ipad-reader/prototypes/context-preservation/Sources/Experiment.swift#L1146
[reflow-epub]: https://github.com/mooneeb/bookorbit/blob/a46051434369d8c0e699e38f1795c1a6e3559750/docs/wayfinder/bookorbit-ipad-reader/prototypes/context-preservation/Fixtures/Reflow/reflow.epub
[capture-seed]: https://github.com/mooneeb/bookorbit/tree/a46051434369d8c0e699e38f1795c1a6e3559750/docs/wayfinder/bookorbit-ipad-reader/prototypes/context-preservation/Fixtures/EPUB
[native-package]: ../decisions/native-stack.md#epub-delivery-selection-and-containment
[bench-limits]: https://github.com/mooneeb/bookorbit/blob/a46051434369d8c0e699e38f1795c1a6e3559750/docs/wayfinder/bookorbit-ipad-reader/prototypes/context-preservation/Sources/Experiment.swift#L63
[raster-check]: https://github.com/mooneeb/bookorbit/blob/a46051434369d8c0e699e38f1795c1a6e3559750/docs/wayfinder/bookorbit-ipad-reader/prototypes/context-preservation/Sources/Experiment.swift#L936
[ink-exporter]: https://github.com/mooneeb/bookorbit/blob/a46051434369d8c0e699e38f1795c1a6e3559750/docs/wayfinder/bookorbit-ipad-reader/prototypes/browser-compatibility/export-ink.swift#L12
[zip-loader]: https://github.com/mooneeb/bookorbit/blob/a46051434369d8c0e699e38f1795c1a6e3559750/client/public/assets/foliate/view.js#L86
[member-loader]: https://github.com/mooneeb/bookorbit/blob/a46051434369d8c0e699e38f1795c1a6e3559750/client/public/assets/foliate/streaming-loader.js#L55
[epub-parser]: https://github.com/mooneeb/bookorbit/blob/a46051434369d8c0e699e38f1795c1a6e3559750/client/public/assets/foliate/epub.js#L863
[server-parser]: https://github.com/mooneeb/bookorbit/blob/a46051434369d8c0e699e38f1795c1a6e3559750/server/src/modules/reader/epub/epub.service.ts#L185
[resource-route]: https://github.com/mooneeb/bookorbit/blob/a46051434369d8c0e699e38f1795c1a6e3559750/server/src/modules/reader/epub/epub.service.ts#L403
[publication-cache]: https://github.com/mooneeb/bookorbit/blob/a46051434369d8c0e699e38f1795c1a6e3559750/server/src/modules/reader/epub/epub.service.ts#L497
[compose]: https://github.com/mooneeb/bookorbit/blob/a46051434369d8c0e699e38f1795c1a6e3559750/docker-compose.yml#L37
[configuration]: https://github.com/mooneeb/bookorbit/blob/a46051434369d8c0e699e38f1795c1a6e3559750/server/src/config/config.ts#L35
[file-schema]: https://github.com/mooneeb/bookorbit/blob/a46051434369d8c0e699e38f1795c1a6e3559750/server/src/db/schema/books.ts#L69
[server-identity]: https://github.com/mooneeb/bookorbit/blob/a46051434369d8c0e699e38f1795c1a6e3559750/docs/SERVER_CONNECTION_IDENTITY.md#L12
[rollback-note]: https://github.com/mooneeb/bookorbit/blob/a46051434369d8c0e699e38f1795c1a6e3559750/docs/READ_ALOUD_DELIVERY.md#L58
[email-encryption]: https://github.com/mooneeb/bookorbit/blob/a46051434369d8c0e699e38f1795c1a6e3559750/server/src/modules/email/email-encryption.service.ts#L14
[annotation-route]: https://github.com/mooneeb/bookorbit/blob/a46051434369d8c0e699e38f1795c1a6e3559750/server/src/modules/annotation/annotation-hub.controller.ts#L72
[annotation-query]: https://github.com/mooneeb/bookorbit/blob/a46051434369d8c0e699e38f1795c1a6e3559750/server/src/modules/annotation/annotation.repository.ts#L507
[annotation-export]: https://github.com/mooneeb/bookorbit/blob/a46051434369d8c0e699e38f1795c1a6e3559750/server/src/modules/annotation/annotation-export.service.ts#L43
[book-export-limits]: https://github.com/mooneeb/bookorbit/blob/a46051434369d8c0e699e38f1795c1a6e3559750/server/src/modules/book/book.service.ts#L183
[zip-export]: https://github.com/mooneeb/bookorbit/blob/a46051434369d8c0e699e38f1795c1a6e3559750/server/src/modules/book/book.service.ts#L3315
[metadata-export]: https://github.com/mooneeb/bookorbit/blob/a46051434369d8c0e699e38f1795c1a6e3559750/server/src/modules/book/book.service.ts#L712
[access-check]: https://github.com/mooneeb/bookorbit/blob/a46051434369d8c0e699e38f1795c1a6e3559750/server/src/modules/book/book.service.ts#L581
[catalog-limits]: https://github.com/mooneeb/bookorbit/blob/a46051434369d8c0e699e38f1795c1a6e3559750/server/src/modules/book/pipes/book-query.pipe.ts#L11
[browser-window]: https://github.com/mooneeb/bookorbit/blob/a46051434369d8c0e699e38f1795c1a6e3559750/client/src/features/book/composables/useBookWindow.ts#L5
[annotation-dto]: https://github.com/mooneeb/bookorbit/blob/a46051434369d8c0e699e38f1795c1a6e3559750/server/src/modules/annotation/dto/annotation-hub.dto.ts#L8
[annotation-pages]: https://github.com/mooneeb/bookorbit/blob/a46051434369d8c0e699e38f1795c1a6e3559750/server/src/modules/annotation/annotation.repository.ts#L190
[journal-types]: https://github.com/mooneeb/bookorbit/blob/a46051434369d8c0e699e38f1795c1a6e3559750/packages/types/src/book-journal.ts#L6
[notebook-types]: https://github.com/mooneeb/bookorbit/blob/a46051434369d8c0e699e38f1795c1a6e3559750/packages/types/src/notebook.ts#L19
[notebook-paging]: https://github.com/mooneeb/bookorbit/blob/a46051434369d8c0e699e38f1795c1a6e3559750/server/src/modules/notebook/notebook-sql.ts#L224
[upload-limits]: https://github.com/mooneeb/bookorbit/blob/a46051434369d8c0e699e38f1795c1a6e3559750/server/src/common/constants/upload.constants.ts#L1
[upload-sessions]: https://github.com/mooneeb/bookorbit/blob/a46051434369d8c0e699e38f1795c1a6e3559750/server/src/modules/upload/upload-session.service.ts#L97
[browser-uploads]: https://github.com/mooneeb/bookorbit/blob/a46051434369d8c0e699e38f1795c1a6e3559750/client/src/features/library/composables/useBookUpload.ts#L22
[extraction-limit]: https://github.com/mooneeb/bookorbit/blob/a46051434369d8c0e699e38f1795c1a6e3559750/server/src/modules/upload/upload-processor.service.ts#L398
[bulk-dto]: https://github.com/mooneeb/bookorbit/blob/a46051434369d8c0e699e38f1795c1a6e3559750/server/src/common/dto/bulk-selection.dto.ts#L30
[bulk-selection]: https://github.com/mooneeb/bookorbit/blob/a46051434369d8c0e699e38f1795c1a6e3559750/server/src/modules/book/book.service.ts#L605
[bulk-repository]: https://github.com/mooneeb/bookorbit/blob/a46051434369d8c0e699e38f1795c1a6e3559750/server/src/modules/book/book.repository.ts#L2073
[move-recovery]: https://github.com/mooneeb/bookorbit/blob/a46051434369d8c0e699e38f1795c1a6e3559750/server/src/modules/book-move/book-move.service.ts#L75
[dock-results]: https://github.com/mooneeb/bookorbit/blob/a46051434369d8c0e699e38f1795c1a6e3559750/server/src/modules/book-dock/book-dock-finalize.service.ts#L299
[scanner]: https://github.com/mooneeb/bookorbit/blob/a46051434369d8c0e699e38f1795c1a6e3559750/server/src/modules/scanner/scanner.service.ts#L1605
[metadata-queue]: https://github.com/mooneeb/bookorbit/blob/a46051434369d8c0e699e38f1795c1a6e3559750/server/src/modules/book-metadata-fetch/book-metadata-fetch-queue.repository.ts#L243
[note-model]: ../decisions/note-model.md
[sync-recovery]: ../decisions/offline-sync.md#change-feed-and-long-offline-recovery
[native-storage]: ../decisions/native-stack.md#persistence-lifecycle-and-diagnosis
