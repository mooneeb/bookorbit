# Upstream integration on 2026-10-08

This integration merges `bookorbit/bookorbit:main` at
`2476195016f196c58f796071f7ba5d60bbe70bcf` into the fork's published main at
`d6d24ca1decf820119aa8b245e0ec70e17847b14`. It preserves the native reader
history delivered by PR 7 and brings in 20 upstream commits after their shared
base `8fecae94e65204618fc4db846da19c4e0007e4aa`.

Bookmark responses retain native fixed-page fields and ISO timestamps while
including upstream notes, origin, client IDs, chapter IDs and edit timestamps.
The upstream bookmark edit route uses the native reader's download permission
and mutation logging. Native EPUB and fixed-page pagination remain available.
EPUB position conversion combines bounded archive reads with upstream canonical
KEPUB mapping and format-aware cache invalidation. Book deletion and file
replacement retain upstream hash-history invalidation alongside native progress
concurrency checks.

Generated native contracts include upstream optional multi-file write targets,
write outcome counts and ISBN preview fields. Explicit bookmark projections
retain the existing native model fields. The native metadata initializer follows
the regenerated shared contract's property order.

## Migration lineage

The fork's already-published `0102` through `0105` migrations, snapshots and
timestamps remain unchanged. Both branches used those sequence numbers for
different changes. Drizzle Kit generated `0106_merge_upstream_schema` from the
merged schema relative to the fork's `0105` snapshot. It includes every schema
operation from upstream's four colliding migrations; those migrations contained
no data transformations or backfills.

This migration lineage supports fresh installations and upgrades from the fork's
published `0105` state. A database that instead applied upstream's distinct
`0102` through `0105` history is not covered by this upgrade path. No upstream
database conversion is introduced by this merge.

## Builder verification

An offline installation from the committed lockfile succeeded. Generated shared
packages and native contracts were rebuilt. Separate isolated PostgreSQL
databases verified fresh migration and upgrade from the fork's `0105`: both
applied 107 migrations and produced identical columns, indexes and constraints.
The native metadata initializer passed scoped Swift format checking.
Full server and client ESLint and typechecks passed. The production server build
reported zero TSC issues and compiled 1,326 files with SWC.
The signed arm64 production simulator build passed with Swift 6 complete strict
concurrency. Whole-module compilation used one frontend for the production
target and finished in 69.272 seconds. The minimum measured memory availability
was 42%, with 82.410 GiB disk free. Existing OIDC initializer deprecation and
AppIntents metadata warnings remain.

These checks are specific to the upstream integration. The historical results
and deferred native, accessibility and physical-device coverage in
[issue2-completion.md](issue2-completion.md) retain their original scope.
