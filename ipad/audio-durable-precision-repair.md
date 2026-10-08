# Durable audiobook playback precision

Canonical playback positions are integer milliseconds. PostgreSQL `real` stored the seconds as Float32, so a six-hour AAC write at 16,384,001 ms acknowledged that input but durable GET and an identical operation replay returned 16,384,002 ms at the same revision. The first acknowledgment echoed the input, while reopen and replay read persisted seconds.

Change only `audiobook_progress.position_seconds` to PostgreSQL `double precision`. The existing seconds representation, integer-millisecond API conversion, user ownership, compare-and-set revisions, operation identity, and manifest validation stay intact. Generate the migration and snapshot with Drizzle Kit. No service response substitution or precision tolerance is introduced.

The migration preserves existing stored values. Precision already lost by Float32 cannot be reconstructed: widening an old rounded position does not recover the reader's original millisecond input. A subsequent accepted canonical save records the new position with double precision. Other reader and bookmark position columns are outside this independently reproduced defect.

The original public HTTP evidence is retained in `/tmp/bookorbit-production-audio-qa-9d73f6d0/test-results/ipad/run-1516-1791362808312/audio-fixture/production-audio-durable-precision-observations.json`. Its independently inspected and fully decoded six-hour AAC has SHA-256 `0de77f5f49701cd7907ab31c70c25769d189bf6288cd389f1ebd0fdb25a781cc` and 1,362,027 bytes, also verified against the actual full authenticated stream.

Acceptance requires the unchanged exact requested positions, initial acknowledgment, durable GET, and identical-operation replay to agree after migrating an isolated test database, then the actual production native journeys. Source checks do not establish that runtime acceptance. No production database is migrated during this repair.

Drizzle Kit generated `0103_audiobook_playback_precision.sql`, its snapshot, and journal entry from the schema diff. The SQL contains only the playback position type alteration; the snapshot changes only that column and its generation IDs. Existing audiobook service and DTO checks pass all 14 tests, and full server TypeScript checking passes. The High tester owns isolated migration and the unchanged original HTTP/native verification.
