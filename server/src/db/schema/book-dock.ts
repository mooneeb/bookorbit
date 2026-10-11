import { sql } from 'drizzle-orm';
import { bigint, boolean, check, index, integer, jsonb, pgTable, serial, text, timestamp, varchar, uuid, uniqueIndex } from 'drizzle-orm/pg-core';
import type { BookDockMetadata, BookDockFinalizeFileResult, BookDockFinalizeJobRequest } from '@bookorbit/types';

import { libraries, libraryFolders } from './libraries';
import { users } from './auth';

export const bookDockFiles = pgTable(
  'book_dock_files',
  {
    id: serial('id').primaryKey(),
    fileName: varchar('file_name', { length: 500 }).notNull(),
    absolutePath: text('absolute_path').notNull().unique(),
    fileSize: bigint('file_size', { mode: 'number' }),
    format: varchar('format', { length: 20 }),
    /**
     * Set when this row owns a directory of files rather than a single loose one. The row's own
     * `absolutePath`, `format` and `fileSize` keep describing the unit's **primary** file, because
     * metadata and cover extraction on a 31-track audiobook should read exactly one of them.
     *
     * Null means no exclusive directory ownership; a row may still have unit files when
     * several books share a folder. Watched books may be nested at any depth. Imports with
     * autoFinalizeSuppressed claim their directory before copying, so discovery skips its tree.
     */
    unitDirectory: text('unit_directory').unique(),
    status: varchar('status', { length: 20 }).notNull().default('pending'),
    embeddedMetadata: jsonb('embedded_metadata').$type<BookDockMetadata>(),
    selectedMetadata: jsonb('selected_metadata').$type<BookDockMetadata>(),
    fetchedMetadata: jsonb('fetched_metadata').$type<BookDockMetadata>(),
    coverPath: text('cover_path'),
    targetLibraryId: integer('target_library_id').references(() => libraries.id, { onDelete: 'set null' }),
    targetFolderId: integer('target_folder_id').references(() => libraryFolders.id, { onDelete: 'set null' }),
    confidence: integer('confidence'),
    fetchedMetadataSources: jsonb('fetched_metadata_sources').$type<Partial<Record<keyof BookDockMetadata, string>>>(),
    errorMessage: text('error_message'),
    metadataEditedAt: timestamp('metadata_edited_at', { withTimezone: true }),
    uploadedBy: integer('uploaded_by').references(() => users.id, { onDelete: 'set null' }),
    /**
     * Another module owns finalization for this row and will call it explicitly once its own
     * checks pass. Generic auto-finalize skips it so the two paths never race for the same file.
     * The dock deliberately does not learn which module, only that it is not its call to make.
     */
    autoFinalizeSuppressed: boolean('auto_finalize_suppressed').notNull().default(false),
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
    updatedAt: timestamp('updated_at', { withTimezone: true })
      .notNull()
      .defaultNow()
      .$onUpdateFn(() => new Date()),
  },
  (t) => [
    index('book_dock_files_status_idx').on(t.status),
    index('book_dock_files_target_library_id_idx').on(t.targetLibraryId),
    index('book_dock_files_uploaded_by_idx').on(t.uploadedBy),
    check('book_dock_files_status_chk', sql`${t.status} in ('pending', 'extracting', 'fetching', 'ready', 'error')`),
    check('book_dock_files_confidence_range_chk', sql`${t.confidence} is null or (${t.confidence} >= 0 and ${t.confidence} <= 100)`),
  ],
);

export type BookDockFileRow = typeof bookDockFiles.$inferSelect;
export type NewBookDockFileRow = typeof bookDockFiles.$inferInsert;

/**
 * The files a dock unit is made of, in playback or format order. Holds **every** file including
 * the primary, so the primary's path appears here and on the anchor row too. That duplication is
 * the cheaper half of the trade: placement, rollback, discard and delete iterate one list rather
 * than a union, and the anchor stays a plain "which file do I read metadata from" pointer.
 */
export const bookDockUnitFiles = pgTable(
  'book_dock_unit_files',
  {
    id: serial('id').primaryKey(),
    dockFileId: integer('dock_file_id')
      .notNull()
      .references(() => bookDockFiles.id, { onDelete: 'cascade' }),
    absolutePath: text('absolute_path').notNull().unique(),
    fileName: varchar('file_name', { length: 500 }).notNull(),
    fileSize: bigint('file_size', { mode: 'number' }),
    format: varchar('format', { length: 20 }),
    role: varchar('role', { length: 20 }).notNull().default('content'),
    /** Content files only. Natural order within the unit, so track 10 follows track 9. */
    sortOrder: integer('sort_order'),
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [
    index('book_dock_unit_files_dock_file_id_sort_order_idx').on(t.dockFileId, t.sortOrder),
    check('book_dock_unit_files_role_chk', sql`${t.role} in ('content', 'cover', 'metadata', 'supplement')`),
  ],
);

export type BookDockUnitFileRow = typeof bookDockUnitFiles.$inferSelect;
export type NewBookDockUnitFileRow = typeof bookDockUnitFiles.$inferInsert;

export interface BookDockFinalizeIntent {
  managedRequest?: { requestId: number; userId: number };
  row: BookDockFileRow;
  libraryId: number;
  folderId: number;
  root: string;
  format: string;
  destPath: string;
  bookFolderPath?: string;
  placement: Array<{
    sourcePath: string;
    destPath: string;
    format: string | null;
    role: 'content' | 'cover' | 'metadata' | 'supplement';
    sortOrder: number | null;
  }>;
  publication: Array<{ sourcePath: string; destPath: string; stagingPath: string; hash: string }>;
}

export const bookDockFinalizations = pgTable(
  'book_dock_finalizations',
  {
    fileId: integer('file_id').primaryKey(),
    userId: integer('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    libraryId: integer('library_id')
      .notNull()
      .references(() => libraries.id, { onDelete: 'cascade' }),
    state: varchar('state', { length: 20 }).notNull().default('placing'),
    intent: jsonb('intent').$type<BookDockFinalizeIntent>().notNull(),
    bookIds: jsonb('book_ids').$type<number[]>().notNull().default([]),
    result: jsonb('result').$type<BookDockFinalizeFileResult>(),
    error: text('error'),
    updatedAt: timestamp('updated_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [
    index('book_dock_finalizations_user_id_idx').on(t.userId, t.fileId),
    index('book_dock_finalizations_state_idx').on(t.state, t.fileId),
    check('book_dock_finalizations_state_chk', sql`${t.state} in ('placing', 'committed', 'completed', 'failed')`),
  ],
);

export const bookDockFinalizeJobs = pgTable(
  'book_dock_finalize_jobs',
  {
    id: serial('id').primaryKey(),
    userId: integer('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    idempotencyKey: uuid('idempotency_key').notNull(),
    request: jsonb('request').$type<BookDockFinalizeJobRequest>().notNull(),
    state: varchar('state', { length: 20 }).notNull().default('queued'),
    cursor: integer('cursor').notNull().default(0),
    total: integer('total').notNull().default(0),
    succeeded: integer('succeeded').notNull().default(0),
    failed: integer('failed').notNull().default(0),
    error: text('error'),
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
    updatedAt: timestamp('updated_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [
    uniqueIndex('book_dock_finalize_jobs_user_key_idx').on(t.userId, t.idempotencyKey),
    index('book_dock_finalize_jobs_state_idx').on(t.state, t.id),
    check('book_dock_finalize_jobs_state_chk', sql`${t.state} in ('queued', 'running', 'completed', 'failed')`),
  ],
);

export const bookDockFinalizeJobItems = pgTable(
  'book_dock_finalize_job_items',
  {
    id: serial('id').primaryKey(),
    jobId: integer('job_id')
      .notNull()
      .references(() => bookDockFinalizeJobs.id, { onDelete: 'cascade' }),
    fileId: integer('file_id').notNull(),
    state: varchar('state', { length: 20 }).notNull().default('pending'),
    result: jsonb('result').$type<BookDockFinalizeFileResult>(),
  },
  (t) => [
    uniqueIndex('book_dock_finalize_job_items_job_file_idx').on(t.jobId, t.fileId),
    index('book_dock_finalize_job_items_pending_idx').on(t.jobId, t.state, t.id),
  ],
);
