import { index, integer, pgTable, primaryKey, timestamp, uuid, varchar } from 'drizzle-orm/pg-core';
import { users } from './auth';
import { books } from './books';

export const entityFileWrites = pgTable(
  'entity_file_writes',
  {
    id: uuid('id').primaryKey(),
    userId: integer('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    entityType: varchar('entity_type', { length: 30 }).notNull(),
    createdAt: timestamp('created_at', { withTimezone: true }).defaultNow().notNull(),
  },
  (t) => [index('entity_file_writes_user_type_idx').on(t.userId, t.entityType, t.createdAt)],
);

export const entityFileWriteBooks = pgTable(
  'entity_file_write_books',
  {
    operationId: uuid('operation_id')
      .notNull()
      .references(() => entityFileWrites.id, { onDelete: 'cascade' }),
    attemptedAt: timestamp('attempted_at', { withTimezone: true }),
    bookId: integer('book_id')
      .notNull()
      .references(() => books.id, { onDelete: 'cascade' }),
  },
  (t) => [
    primaryKey({ columns: [t.operationId, t.bookId] }),
    index('entity_file_write_books_pending_idx').on(t.operationId, t.attemptedAt, t.bookId),
  ],
);
