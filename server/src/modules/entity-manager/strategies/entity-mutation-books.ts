import { createReadStream } from 'node:fs';
import { mkdtemp, open, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createInterface } from 'node:readline';
import { ForbiddenException, InternalServerErrorException } from '@nestjs/common';
import { and, sql, type SQL } from 'drizzle-orm';
import type { NodePgDatabase } from 'drizzle-orm/node-postgres';

import * as schema from '../../../db/schema';
import { books, entityFileWrites, entityFileWriteBooks } from '../../../db/schema';
import { buildEntityBookScopeClauses } from './entity-book-scope';
import type { EntityBookScope, EntityMutationBooks, StrategyAffectedBooks } from './entity-strategy.interface';

type Db = NodePgDatabase<typeof schema>;
const PAGE_SIZE = 500;

export async function mutateEntityBooks(
  db: Db,
  input: EntityMutationBooks,
  scope: EntityBookScope,
  selectBooks: SQL,
  mutate: (tx: Db) => Promise<void>,
  prepare?: (tx: Db) => Promise<void>,
): Promise<StrategyAffectedBooks> {
  const directory = input.spoolBookIds ? await mkdtemp(join(tmpdir(), 'bookorbit-entity-')) : undefined;
  const path = directory ? join(directory, 'books.jsonl') : undefined;
  const spool = path ? await open(path, 'wx', 0o600) : undefined;
  const dispose = async () => {
    if (directory) await rm(directory, { recursive: true, force: true });
  };
  try {
    const result = await db.transaction(async (transaction) => {
      const tx = transaction as unknown as Db;
      await prepare?.(tx);
      await tx.execute(sql`CREATE TEMP TABLE entity_mutation_books (book_id integer PRIMARY KEY) ON COMMIT DROP`);
      await tx.execute(sql`INSERT INTO entity_mutation_books (book_id) ${selectBooks} ON CONFLICT DO NOTHING`);
      await tx.execute(sql`WITH locked AS MATERIALIZED (SELECT id FROM books WHERE id IN (SELECT book_id FROM entity_mutation_books) ORDER BY id FOR UPDATE)
        SELECT count(*) FROM locked`);
      await tx.execute(sql`WITH locked AS MATERIALIZED (SELECT book_id FROM book_metadata WHERE book_id IN (SELECT book_id FROM entity_mutation_books) ORDER BY book_id FOR UPDATE)
        SELECT count(*) FROM locked`);
      const access = await tx.execute<{ outside: boolean }>(sql`SELECT EXISTS (
        SELECT 1 FROM entity_mutation_books JOIN ${books} ON ${books.id} = entity_mutation_books.book_id
        WHERE (${and(...buildEntityBookScopeClauses(tx, scope))}) IS NOT TRUE LIMIT 1
      ) AS outside`);
      if (access.rows[0]?.outside) throw new ForbiddenException('An affected book is outside the accessible scope');
      const count = await tx.execute<{ count: number }>(sql`SELECT count(*)::int AS count FROM entity_mutation_books`);
      const affectedBookCount = count.rows[0]?.count ?? 0;
      if (!input.onBooksChanged && affectedBookCount > PAGE_SIZE)
        throw new InternalServerErrorException('Bulk entity edits require a book change processor');
      if (input.fileWriteRecovery) {
        await tx.insert(entityFileWrites).values({
          id: input.fileWriteRecovery.operationId,
          userId: input.fileWriteRecovery.userId,
          entityType: input.fileWriteRecovery.entityType,
        });
        await tx.execute(sql`INSERT INTO ${entityFileWriteBooks} (operation_id, book_id)
          SELECT ${input.fileWriteRecovery.operationId}::uuid, book_id FROM entity_mutation_books`);
      }
      await mutate(tx);
      let cursor = 0;
      const affectedBookIds: number[] = [];
      // The snapshot preserves access before an edit changes fields used by content filters.
      while (true) {
        const page = await tx.execute<{ bookId: number }>(sql`
          SELECT entity_mutation_books.book_id AS "bookId" FROM entity_mutation_books
          JOIN ${books} ON ${books.id} = entity_mutation_books.book_id
          WHERE entity_mutation_books.book_id > ${cursor} AND ${and(...buildEntityBookScopeClauses(tx, { libraryIds: scope.libraryIds }))}
          ORDER BY entity_mutation_books.book_id LIMIT ${PAGE_SIZE}`);
        if (page.rows.length === 0) break;
        const ids = page.rows.map((row) => row.bookId);
        if (input.onBooksChanged) await input.onBooksChanged(ids, tx);
        else affectedBookIds.push(...ids);
        if (spool) await spool.writeFile(`${JSON.stringify(ids)}\n`);
        cursor = ids[ids.length - 1]!;
      }
      return { affectedBookIds, affectedBookCount };
    });
    await spool?.close();
    return {
      ...result,
      ...(path
        ? {
            affectedBookBatches: async function* () {
              const stream = createReadStream(path, { encoding: 'utf8' });
              const lines = createInterface({ input: stream, crlfDelay: Infinity });
              try {
                for await (const line of lines) yield JSON.parse(line) as number[];
              } finally {
                lines.close();
                stream.destroy();
              }
            },
            disposeAffectedBooks: dispose,
          }
        : {}),
    };
  } catch (error) {
    await spool?.close();
    await dispose();
    throw error;
  }
}
