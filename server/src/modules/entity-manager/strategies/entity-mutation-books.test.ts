import { ForbiddenException, InternalServerErrorException } from '@nestjs/common';
import { PgDialect } from 'drizzle-orm/pg-core';
import { sql, type SQL } from 'drizzle-orm';

import { mutateEntityBooks } from './entity-mutation-books';

const dialect = new PgDialect();

function makeDb(count: number, outside = false) {
  let committed = false;
  const execute = vi.fn((statement: SQL) => {
    const query = dialect.sqlToQuery(statement);
    if (query.sql.includes('AS outside')) return { rows: [{ outside }] };
    if (query.sql.includes('count(*)::int AS count FROM entity_mutation_books')) return { rows: [{ count }] };
    if (query.sql.includes('AS "bookId"')) {
      const cursor = Number(query.params[0]);
      return { rows: Array.from({ length: Math.min(500, Math.max(0, count - cursor)) }, (_, index) => ({ bookId: cursor + index + 1 })) };
    }
    return { rows: [] };
  });
  const tx = { execute };
  const transaction = vi.fn(async (callback: (executor: typeof tx) => Promise<unknown>) => {
    const result = await callback(tx);
    committed = true;
    return result;
  });
  return { db: { transaction } as never, tx, execute, isCommitted: () => committed };
}

it('processes a 50000-book snapshot in bounded batches with an exact count', async () => {
  const { db, tx, isCommitted } = makeDb(50000);
  let processed = 0;
  const onBooksChanged = vi.fn((ids: number[], executor: unknown) => {
    expect(isCommitted()).toBe(false);
    expect(executor).toBe(tx);
    expect(ids.length).toBeLessThanOrEqual(500);
    expect(ids[0]).toBe(processed + 1);
    processed += ids.length;
    return Promise.resolve();
  });
  const mutate = vi.fn().mockResolvedValue(undefined);
  const result = await mutateEntityBooks(db, { onBooksChanged }, { libraryIds: [3] }, sql`SELECT id FROM books`, mutate);
  expect(result).toEqual({ affectedBookIds: [], affectedBookCount: 50000 });
  expect(processed).toBe(50000);
  expect(onBooksChanged).toHaveBeenCalledTimes(100);
  expect(mutate).toHaveBeenCalledExactlyOnceWith(tx);
  expect(isCommitted()).toBe(true);
});

it('rejects an out-of-scope snapshot before mutating books', async () => {
  const { db, isCommitted } = makeDb(3, true);
  const mutate = vi.fn();
  await expect(mutateEntityBooks(db, {}, { libraryIds: [3] }, sql`SELECT id FROM books`, mutate)).rejects.toBeInstanceOf(ForbiddenException);
  expect(mutate).not.toHaveBeenCalled();
  expect(isCommitted()).toBe(false);
});

it('does not commit when transactional score processing fails', async () => {
  const { db, isCommitted } = makeDb(501);
  const mutate = vi.fn().mockResolvedValue(undefined);
  const onBooksChanged = vi.fn().mockResolvedValueOnce(undefined).mockRejectedValueOnce(new Error('Score failed'));
  await expect(mutateEntityBooks(db, { onBooksChanged }, { libraryIds: [3] }, sql`SELECT id FROM books`, mutate)).rejects.toThrow('Score failed');
  expect(isCommitted()).toBe(false);
});

it('replays the exact snapshot from disk after commit and removes its spool', async () => {
  const { db, isCommitted } = makeDb(1201);
  const result = await mutateEntityBooks(
    db,
    { onBooksChanged: vi.fn().mockResolvedValue(undefined), spoolBookIds: true },
    { libraryIds: [3] },
    sql`SELECT id FROM books`,
    vi.fn().mockResolvedValue(undefined),
  );
  expect(isCommitted()).toBe(true);
  let processed = 0;
  const lengths: number[] = [];
  try {
    for await (const ids of result.affectedBookBatches!()) {
      expect(ids[0]).toBe(processed + 1);
      processed += ids.length;
      lengths.push(ids.length);
    }
    expect(processed).toBe(1201);
    expect(lengths).toEqual([500, 500, 201]);
  } finally {
    await result.disposeAffectedBooks!();
  }
  await expect(result.affectedBookBatches!()[Symbol.asyncIterator]().next()).rejects.toMatchObject({ code: 'ENOENT' });
});

it('rejects large edits without a bounded book processor before mutation', async () => {
  const { db } = makeDb(501);
  const mutate = vi.fn();
  await expect(mutateEntityBooks(db, {}, { libraryIds: [3] }, sql`SELECT id FROM books`, mutate)).rejects.toBeInstanceOf(
    InternalServerErrorException,
  );
  expect(mutate).not.toHaveBeenCalled();
});
