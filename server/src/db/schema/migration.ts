import { check, foreignKey, index, integer, jsonb, pgTable, serial, text, timestamp, unique, uniqueIndex, varchar } from 'drizzle-orm/pg-core';
import { sql } from 'drizzle-orm';

import { users } from './auth';

export const migrationSources = pgTable(
  'migration_sources',
  {
    id: serial('id').primaryKey(),
    type: varchar('type', { length: 50 }).notNull(),
    name: varchar('name', { length: 255 }).notNull(),
    connectionConfig: jsonb('connection_config').notNull(),
    capabilities: jsonb('capabilities'),
    lastValidatedAt: timestamp('last_validated_at', { withTimezone: true }),
    createdByUserId: integer('created_by_user_id').references(() => users.id, { onDelete: 'set null' }),
    createdAt: timestamp('created_at', { withTimezone: true }).defaultNow().notNull(),
    updatedAt: timestamp('updated_at', { withTimezone: true })
      .defaultNow()
      .notNull()
      .$onUpdateFn(() => new Date()),
  },
  (t) => [
    uniqueIndex('migration_sources_type_name_uidx').on(t.type, t.name),
    index('migration_sources_created_by_user_id_idx').on(t.createdByUserId),
  ],
);

export const migrationProfiles = pgTable(
  'migration_profiles',
  {
    id: serial('id').primaryKey(),
    sourceId: integer('source_id')
      .notNull()
      .references(() => migrationSources.id, { onDelete: 'cascade' }),
    name: varchar('name', { length: 255 }).notNull(),
    version: integer('version').notNull().default(1),
    userMappings: jsonb('user_mappings').notNull(),
    pathMappings: jsonb('path_mappings')
      .notNull()
      .default(sql`'[]'::jsonb`),
    scope: jsonb('scope')
      .notNull()
      .default(sql`'{}'::jsonb`),
    createdByUserId: integer('created_by_user_id').references(() => users.id, { onDelete: 'set null' }),
    createdAt: timestamp('created_at', { withTimezone: true }).defaultNow().notNull(),
    updatedAt: timestamp('updated_at', { withTimezone: true })
      .defaultNow()
      .notNull()
      .$onUpdateFn(() => new Date()),
  },
  (t) => [
    uniqueIndex('migration_profiles_source_name_version_uidx').on(t.sourceId, t.name, t.version),
    unique('migration_profiles_id_source_id_unique').on(t.id, t.sourceId),
    index('migration_profiles_source_id_idx').on(t.sourceId),
    check('migration_profiles_version_positive_chk', sql`${t.version} >= 1`),
  ],
);

export const migrationPlanArtifacts = pgTable(
  'migration_plan_artifacts',
  {
    id: serial('id').primaryKey(),
    sourceId: integer('source_id')
      .notNull()
      .references(() => migrationSources.id, { onDelete: 'cascade' }),
    profileId: integer('profile_id')
      .notNull()
      .references(() => migrationProfiles.id, { onDelete: 'cascade' }),
    sourceSnapshotHash: varchar('source_snapshot_hash', { length: 128 }).notNull(),
    profileHash: varchar('profile_hash', { length: 128 }).notNull(),
    planHash: varchar('plan_hash', { length: 128 }).notNull(),
    plan: jsonb('plan').notNull(),
    sourceData: jsonb('source_data'),
    summary: jsonb('summary').notNull(),
    createdByUserId: integer('created_by_user_id').references(() => users.id, { onDelete: 'set null' }),
    createdAt: timestamp('created_at', { withTimezone: true }).defaultNow().notNull(),
    updatedAt: timestamp('updated_at', { withTimezone: true })
      .defaultNow()
      .notNull()
      .$onUpdateFn(() => new Date()),
  },
  (t) => [
    index('migration_plan_artifacts_plan_hash_idx').on(t.planHash),
    unique('migration_plan_artifacts_id_source_profile_unique').on(t.id, t.sourceId, t.profileId),
    unique('migration_plan_artifacts_id_owner_unique').on(t.id, t.createdByUserId),
    index('migration_plan_artifacts_source_id_idx').on(t.sourceId),
    index('migration_plan_artifacts_profile_id_idx').on(t.profileId),
    foreignKey({
      columns: [t.profileId, t.sourceId],
      foreignColumns: [migrationProfiles.id, migrationProfiles.sourceId],
      name: 'migration_plan_artifacts_profile_source_fk',
    }),
  ],
);

export const migrationRuns = pgTable(
  'migration_runs',
  {
    id: serial('id').primaryKey(),
    sourceId: integer('source_id')
      .notNull()
      .references(() => migrationSources.id, { onDelete: 'cascade' }),
    profileId: integer('profile_id')
      .notNull()
      .references(() => migrationProfiles.id, { onDelete: 'cascade' }),
    planArtifactId: integer('plan_artifact_id').references(() => migrationPlanArtifacts.id, { onDelete: 'set null' }),
    targetKey: varchar('target_key', { length: 100 }).notNull().default('bookorbit'),
    state: varchar('state', { length: 32 }).notNull().default('draft'),
    currentStage: varchar('current_stage', { length: 64 }),
    triggeredByUserId: integer('triggered_by_user_id').references(() => users.id, { onDelete: 'set null' }),
    startedAt: timestamp('started_at', { withTimezone: true }),
    endedAt: timestamp('ended_at', { withTimezone: true }),
    errorMessage: text('error_message'),
    createdAt: timestamp('created_at', { withTimezone: true }).defaultNow().notNull(),
    updatedAt: timestamp('updated_at', { withTimezone: true })
      .defaultNow()
      .notNull()
      .$onUpdateFn(() => new Date()),
  },
  (t) => [
    index('migration_runs_source_target_state_idx').on(t.sourceId, t.targetKey, t.state),
    index('migration_runs_state_idx').on(t.state),
    foreignKey({
      columns: [t.profileId, t.sourceId],
      foreignColumns: [migrationProfiles.id, migrationProfiles.sourceId],
      name: 'migration_runs_profile_source_fk',
    }),
    foreignKey({
      columns: [t.planArtifactId, t.sourceId, t.profileId],
      foreignColumns: [migrationPlanArtifacts.id, migrationPlanArtifacts.sourceId, migrationPlanArtifacts.profileId],
      name: 'migration_runs_plan_artifact_source_profile_fk',
    }),
    check('migration_runs_state_chk', sql`"state" IN ('draft', 'preflight_failed', 'dry_run_ready', 'running', 'failed', 'completed')`),
    check('migration_runs_started_before_ended_chk', sql`${t.endedAt} is null or ${t.startedAt} is null or ${t.endedAt} >= ${t.startedAt}`),
  ],
);

export const migrationRunMetrics = pgTable(
  'migration_run_metrics',
  {
    id: serial('id').primaryKey(),
    runId: integer('run_id')
      .notNull()
      .references(() => migrationRuns.id, { onDelete: 'cascade' }),
    stage: varchar('stage', { length: 64 }).notNull(),
    entityType: varchar('entity_type', { length: 64 }).notNull(),
    processed: integer('processed').notNull().default(0),
    imported: integer('imported').notNull().default(0),
    skipped: integer('skipped').notNull().default(0),
    unresolved: integer('unresolved').notNull().default(0),
    failed: integer('failed').notNull().default(0),
    createdAt: timestamp('created_at', { withTimezone: true }).defaultNow().notNull(),
    updatedAt: timestamp('updated_at', { withTimezone: true })
      .defaultNow()
      .notNull()
      .$onUpdateFn(() => new Date()),
  },
  (t) => [
    uniqueIndex('migration_run_metrics_run_stage_entity_uidx').on(t.runId, t.stage, t.entityType),
    index('migration_run_metrics_run_id_idx').on(t.runId),
    check('migration_run_metrics_processed_nonnegative_chk', sql`${t.processed} >= 0`),
    check('migration_run_metrics_imported_nonnegative_chk', sql`${t.imported} >= 0`),
    check('migration_run_metrics_skipped_nonnegative_chk', sql`${t.skipped} >= 0`),
    check('migration_run_metrics_unresolved_nonnegative_chk', sql`${t.unresolved} >= 0`),
    check('migration_run_metrics_failed_nonnegative_chk', sql`${t.failed} >= 0`),
  ],
);

export const migrationPlanSourceBatches = pgTable(
  'migration_plan_source_batches',
  {
    id: serial('id').primaryKey(),
    artifactId: integer('artifact_id')
      .notNull()
      .references(() => migrationPlanArtifacts.id, { onDelete: 'cascade' }),
    batchIndex: integer('batch_index').notNull(),
    bookOverlays: integer('book_overlays').notNull().default(1),
    sourceData: jsonb('source_data').notNull(),
  },
  (t) => [uniqueIndex('migration_plan_source_batches_artifact_index_uidx').on(t.artifactId, t.batchIndex)],
);

export const migrationPlanBookMatches = pgTable(
  'migration_plan_book_matches',
  {
    id: serial('id').primaryKey(),
    artifactId: integer('artifact_id').notNull(),
    userId: integer('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    position: integer('position').notNull(),
    sourceBookId: text('source_book_id').notNull(),
    targetBookId: integer('target_book_id').notNull(),
    strategy: varchar('strategy', { length: 32 }).notNull(),
  },
  (t) => [
    foreignKey({
      columns: [t.artifactId, t.userId],
      foreignColumns: [migrationPlanArtifacts.id, migrationPlanArtifacts.createdByUserId],
      name: 'migration_plan_book_matches_artifact_owner_fk',
    }).onDelete('cascade'),
    uniqueIndex('migration_plan_book_matches_source_uidx').on(t.artifactId, t.userId, t.sourceBookId),
    uniqueIndex('migration_plan_book_matches_position_uidx').on(t.artifactId, t.userId, t.position),
    index('migration_plan_book_matches_user_idx').on(t.userId),
    check('migration_plan_book_matches_position_chk', sql`${t.position} >= 0`),
    check('migration_plan_book_matches_strategy_chk', sql`${t.strategy} IN ('isbn', 'asin', 'file_hash', 'path_mapping', 'title_author')`),
  ],
);

export const migrationPlanSourceBooks = pgTable(
  'migration_plan_source_books',
  {
    id: serial('id').primaryKey(),
    artifactId: integer('artifact_id').notNull(),
    userId: integer('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    sourceBookId: text('source_book_id').notNull(),
    title: text('title'),
    author: text('author'),
    filePath: text('file_path'),
    targetBookId: integer('target_book_id'),
    strategy: varchar('strategy', { length: 32 }),
    unresolvedReason: text('unresolved_reason'),
  },
  (t) => [
    foreignKey({
      columns: [t.artifactId, t.userId],
      foreignColumns: [migrationPlanArtifacts.id, migrationPlanArtifacts.createdByUserId],
      name: 'migration_plan_source_books_artifact_owner_fk',
    }).onDelete('cascade'),
    uniqueIndex('migration_plan_source_books_source_uidx').on(t.artifactId, t.userId, t.sourceBookId),
    index('migration_plan_source_books_target_idx').on(t.artifactId, t.userId, t.targetBookId),
  ],
);

export const migrationPlanPreviewCounts = pgTable(
  'migration_plan_preview_counts',
  {
    id: serial('id').primaryKey(),
    artifactId: integer('artifact_id').notNull(),
    userId: integer('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    sourceBookId: text('source_book_id').notNull(),
    sourceUserId: text('source_user_id').notNull(),
    statuses: integer('statuses').notNull().default(0),
    fileProgress: integer('file_progress').notNull().default(0),
    readingSessions: integer('reading_sessions').notNull().default(0),
    bookmarks: integer('bookmarks').notNull().default(0),
    annotations: integer('annotations').notNull().default(0),
    shelves: integer('shelves').notNull().default(0),
  },
  (t) => [
    foreignKey({
      columns: [t.artifactId, t.userId],
      foreignColumns: [migrationPlanArtifacts.id, migrationPlanArtifacts.createdByUserId],
      name: 'migration_plan_preview_counts_artifact_owner_fk',
    }).onDelete('cascade'),
    uniqueIndex('migration_plan_preview_counts_source_uidx').on(t.artifactId, t.userId, t.sourceBookId, t.sourceUserId),
  ],
);

export const migrationRunBatchCheckpoints = pgTable(
  'migration_run_batch_checkpoints',
  {
    id: serial('id').primaryKey(),
    runId: integer('run_id')
      .notNull()
      .references(() => migrationRuns.id, { onDelete: 'cascade' }),
    stage: varchar('stage', { length: 64 }).notNull(),
    batchIndex: integer('batch_index').notNull(),
    metrics: jsonb('metrics').notNull(),
    updatedAt: timestamp('updated_at', { withTimezone: true }).defaultNow().notNull(),
  },
  (t) => [uniqueIndex('migration_run_batch_checkpoints_run_stage_uidx').on(t.runId, t.stage)],
);

export type MigrationSource = typeof migrationSources.$inferSelect;
export type NewMigrationSource = typeof migrationSources.$inferInsert;

export type MigrationProfile = typeof migrationProfiles.$inferSelect;
export type NewMigrationProfile = typeof migrationProfiles.$inferInsert;

export type MigrationPlanArtifact = typeof migrationPlanArtifacts.$inferSelect;
export type NewMigrationPlanArtifact = typeof migrationPlanArtifacts.$inferInsert;

export type MigrationRun = typeof migrationRuns.$inferSelect;
export type NewMigrationRun = typeof migrationRuns.$inferInsert;
