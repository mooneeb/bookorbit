import { bigint, integer, jsonb, pgTable, primaryKey, serial, timestamp, uniqueIndex, index, uuid, varchar } from 'drizzle-orm/pg-core';
import type { NativeAnnotationOperation, NativeAnnotationOperationResult } from '@bookorbit/types';
import { sql } from 'drizzle-orm';
import { users } from './auth';
import { books } from './books';
import { annotations } from './reader';

export const nativeAnnotationOperations = pgTable(
  'native_annotation_operations',
  {
    userId: integer('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    operationId: uuid('operation_id').notNull(),
    deviceId: varchar('device_id', { length: 100 }).notNull(),
    request: jsonb('request').$type<NativeAnnotationOperation>().notNull(),
    result: jsonb('result').$type<NativeAnnotationOperationResult>().notNull(),
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [
    primaryKey({ columns: [t.userId, t.operationId] }),
    index('native_annotation_operations_user_device_idx').on(t.userId, t.deviceId),
    index('native_annotation_operations_base_idx')
      .on(t.userId, sql`(${t.result}->'annotation'->>'clientId')`, sql`((${t.result}->'annotation'->>'version')::integer)`)
      .where(sql`${t.result}->>'status' = 'applied'`),
    index('native_annotation_operations_source_base_idx')
      .on(sql`(${t.result}->'annotation'->>'clientId')`, sql`((${t.result}->'annotation'->>'version')::integer)`)
      .where(sql`${t.result}->>'status' = 'applied' and ${t.result}->'annotation'->>'kind' = 'pdf_ink'`),
  ],
);

export const nativeAnnotationDrafts = pgTable(
  'native_annotation_drafts',
  {
    id: serial('id').primaryKey(),
    userId: integer('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    bookId: integer('book_id')
      .notNull()
      .references(() => books.id, { onDelete: 'cascade' }),
    annotationId: integer('annotation_id').references(() => annotations.id, { onDelete: 'set null' }),
    operationId: uuid('operation_id').notNull(),
    reason: varchar('reason', { length: 100 }).notNull(),
    payload: jsonb('payload').$type<NativeAnnotationOperation>().notNull(),
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [
    uniqueIndex('native_annotation_drafts_user_operation_uidx').on(t.userId, t.operationId),
    index('native_annotation_drafts_user_book_id_idx').on(t.userId, t.bookId, t.id),
    index('native_annotation_drafts_user_id_idx').on(t.userId, t.id),
  ],
);

export const nativeAnnotationAcks = pgTable(
  'native_annotation_acks',
  {
    userId: integer('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    deviceId: varchar('device_id', { length: 100 }).notNull(),
    bookId: integer('book_id')
      .notNull()
      .references(() => books.id, { onDelete: 'cascade' }),
    cursor: bigint('cursor', { mode: 'number' }).notNull().default(0),
    updatedAt: timestamp('updated_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [primaryKey({ columns: [t.userId, t.deviceId, t.bookId] })],
);
