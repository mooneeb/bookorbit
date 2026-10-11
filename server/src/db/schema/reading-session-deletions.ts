import { index, integer, pgTable, primaryKey, timestamp, varchar } from 'drizzle-orm/pg-core';
import { books } from './books';
import { users } from './auth';

export const readingSessionDeletions = pgTable(
  'reading_session_deletions',
  {
    userId: integer('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    sessionId: varchar('session_id', { length: 64 }).notNull(),
    bookId: integer('book_id')
      .notNull()
      .references(() => books.id, { onDelete: 'cascade' }),
    deletedAt: timestamp('deleted_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (table) => [primaryKey({ columns: [table.userId, table.sessionId] }), index('reading_session_deletions_book_idx').on(table.bookId)],
);
