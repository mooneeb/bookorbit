import { sql } from 'drizzle-orm';
import { check, customType, index, integer, pgTable, serial, text, timestamp, uniqueIndex, varchar } from 'drizzle-orm/pg-core';

import { users } from '../../schema/auth';
import { bookFiles, books } from '../../schema/books';
import { annotations } from '../../schema/reader';

const bytea = customType<{ data: Buffer; driverData: Buffer }>({
  dataType: () => 'bytea',
});

export const INK_KINDS = ['page', 'sketch'] as const;
export type InkKind = (typeof INK_KINDS)[number];

const inkKindsSql = sql.raw(INK_KINDS.map((kind) => `'${kind}'`).join(', '));

export const forkInk = pgTable(
  'fork_ink',
  {
    id: serial('id').primaryKey(),
    userId: integer('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    // Set null, not cascade, so user ink is never destroyed with its Annotation. The FK action
    // does not bump updated_at; a null annotation_id counts as deleted.
    annotationId: integer('annotation_id').references(() => annotations.id, { onDelete: 'set null' }),
    bookId: integer('book_id')
      .notNull()
      .references(() => books.id, { onDelete: 'cascade' }),
    kind: varchar('kind', { length: 10 }).$type<InkKind>().notNull(),
    // Set null, not cascade: scanner and upload paths delete book_files rows routinely.
    bookFileId: integer('book_file_id').references(() => bookFiles.id, { onDelete: 'set null' }),
    pageIndex: integer('page_index'),
    drawingData: bytea('drawing_data').notNull(),
    svg: text('svg').notNull(),
    recognizedText: text('recognized_text'),
    version: integer('version').notNull().default(1),
    deviceCreatedAt: timestamp('device_created_at', { withTimezone: true }).notNull(),
    deviceUpdatedAt: timestamp('device_updated_at', { withTimezone: true }).notNull(),
    deletedAt: timestamp('deleted_at', { withTimezone: true }),
    createdAt: timestamp('created_at', { withTimezone: true }).defaultNow().notNull(),
    updatedAt: timestamp('updated_at', { withTimezone: true })
      .defaultNow()
      .notNull()
      .$onUpdateFn(() => new Date()),
  },
  (t) => [
    index('fork_ink_user_book_updated_idx').on(t.userId, t.bookId, t.updatedAt, t.id),
    index('fork_ink_annotation_id_idx').on(t.annotationId),
    index('fork_ink_book_id_idx').on(t.bookId),
    index('fork_ink_book_file_id_idx').on(t.bookFileId),
    uniqueIndex('fork_ink_annotation_kind_active_uidx')
      .on(t.annotationId, t.kind)
      .where(sql`${t.deletedAt} is null and ${t.annotationId} is not null`),
    uniqueIndex('fork_ink_page_active_uidx')
      .on(t.userId, t.bookFileId, t.pageIndex)
      .where(sql`${t.kind} = 'page' and ${t.deletedAt} is null and ${t.annotationId} is not null and ${t.bookFileId} is not null`),
    check('fork_ink_kind_chk', sql`${t.kind} in (${inkKindsSql})`),
    check(
      'fork_ink_kind_position_chk',
      sql`(${t.kind} = 'page' and ${t.pageIndex} is not null) or (${t.kind} = 'sketch' and ${t.bookFileId} is null and ${t.pageIndex} is null)`,
    ),
    check('fork_ink_page_index_chk', sql`${t.pageIndex} is null or ${t.pageIndex} >= 0`),
    check('fork_ink_version_chk', sql`${t.version} >= 1`),
  ],
);

export type ForkInkRow = typeof forkInk.$inferSelect;
export type NewForkInk = typeof forkInk.$inferInsert;

// Upstream Annotation rows created on the iPad App keep origin 'web'; this records where they came from.
export const forkIpadAnnotations = pgTable(
  'fork_ipad_annotations',
  {
    annotationId: integer('annotation_id')
      .primaryKey()
      .references(() => annotations.id, { onDelete: 'cascade' }),
    userId: integer('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    createdAt: timestamp('created_at', { withTimezone: true }).defaultNow().notNull(),
  },
  (t) => [index('fork_ipad_annotations_user_id_idx').on(t.userId)],
);

export type ForkIpadAnnotationRow = typeof forkIpadAnnotations.$inferSelect;
export type NewForkIpadAnnotation = typeof forkIpadAnnotations.$inferInsert;
