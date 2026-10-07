# Durable audiobook bookmark precision

The independent six-hour AAC public oracle reproduced a distinct bookmark defect after the playback precision repair passed. Authenticated bookmark creation at 16,384,001 and 18,000,001 milliseconds returned 16,384,002 and 18,000,002 milliseconds, and durable listing returned those same changed positions. The original exact assertions remain unchanged.

Change only the shared `bookmarks.position_seconds` column from PostgreSQL `real` to `double precision`, using a Drizzle Kit generated migration following playback migration 0103. The column stores absolute audiobook positions in seconds. EPUB CFI and fixed-page bookmarks retain their existing fields and null audio position. The nullable column, existing position uniqueness index, client IDs, user ownership, idempotent creation, and committed-deletion tombstones keep their current behavior. Service code and native bookmark feature work are unchanged.

Widening preserves previously stored Float32 values but cannot recover precision already lost. No claim is made about exactness for arbitrary JavaScript integer magnitudes beyond the reproduced realistic audiobook durations and positions.

Original public evidence remains in `/tmp/bookorbit-production-audio-qa-9d73f6d0/test-results/ipad/run-13476-1791363480123/audio-fixture/production-audio-bookmark-precision-observations.json`, with the immutable RED log `/tmp/bookorbit-production-audio-precision-candidate-gate.log`. The independently inspected and fully decoded six-hour AAC has duration 21,600,000 ms, 1,362,027 bytes, and SHA-256 `0de77f5f49701cd7907ab31c70c25769d189bf6288cd389f1ebd0fdb25a781cc`; its actual authenticated delivery matches the byte count and hash.

The High tester owns migration of an isolated test database, the unchanged exact creation/list oracle for all three requested positions, playback regressions, and actual native journeys. This repair does not migrate a production database. Source checks do not establish runtime acceptance.

Drizzle Kit generated `0104_audiobook_bookmark_precision.sql`, its snapshot, and journal entry. The generated SQL alters only bookmark position storage; the snapshot changes only that column and its generation IDs. All 57 existing bookmark and audiobook tests pass across nine files, covering service, DTO, response, repository, synchronization, controller, and module behavior.
