# Fork-only data lives in its own tables with its own migration history

This repository is a fork that keeps merging upstream releases. Data introduced by the fork (Ink Annotations, Sketches, and a record of which Annotations came from the iPad App) lives in fork-only tables, managed by a separate Drizzle config with its own migrations folder and migrations table, and referring to upstream tables only by foreign key. Upstream tables, constraints, and migration history are never modified. Drizzle only applies migrations newer than the last one applied, so fork migrations interleaved with upstream's could make later upstream migrations be silently skipped. Changing upstream constraints would also cause merge conflicts.

## Consequences

Annotations created on the iPad App keep origin `web` on the upstream row, and the fork table records that they came from the iPad. Running migrations means running both Drizzle configs.
