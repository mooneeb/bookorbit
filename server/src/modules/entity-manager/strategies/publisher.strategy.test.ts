import { BadRequestException } from '@nestjs/common';
import type { SQL } from 'drizzle-orm';
import { PgDialect } from 'drizzle-orm/pg-core';

import { PublisherStrategy } from './publisher.strategy';

class TestablePublisherStrategy extends PublisherStrategy {
  exposeIdentityCondition(alias: string, value: string) {
    return this.buildIdentityEqualsCondition(alias, value);
  }
}

function makeStrategy(db: Record<string, unknown> = {}) {
  return new PublisherStrategy(db as never);
}

function makeRenameDb(bookIds: number[], exists = false) {
  const dialect = new PgDialect();
  const execute = vi.fn((statement: SQL) => {
    const query = dialect.sqlToQuery(statement);
    if (query.sql.includes('AS outside')) return { rows: [{ outside: false }] };
    if (query.sql.includes('SELECT EXISTS')) return { rows: [{ exists }] };
    if (query.sql.includes('count(*)::int AS count FROM entity_mutation_books')) return { rows: [{ count: bookIds.length }] };
    if (query.sql.includes('AS "bookId" FROM entity_mutation_books'))
      return {
        rows: bookIds
          .filter((id) => id > Number(query.params[0]))
          .slice(0, 500)
          .map((bookId) => ({ bookId })),
      };
    return { rows: [] };
  });
  const tx = { execute };
  const transaction = vi.fn(async (callback: (txArg: typeof tx) => Promise<unknown>) => callback(tx));
  return { dialect, execute, transaction };
}

function flattenSql(value: unknown): string {
  if (typeof value === 'string') return value;
  if (Array.isArray(value)) return value.map(flattenSql).join(' ');
  if (!value || typeof value !== 'object') return '';

  const record = value as { queryChunks?: unknown[]; value?: unknown };
  return [flattenSql(record.value), flattenSql(record.queryChunks)].join(' ');
}

describe('PublisherStrategy', () => {
  describe('rename', () => {
    it('normalizes publisher names before updating metadata', async () => {
      const { dialect, execute, transaction } = makeRenameDb([10, 11]);
      const strategy = makeStrategy({ transaction });

      const result = await strategy.rename({
        entityId: 'Orbit  Books',
        newName: '  Orbit\t\nBooks  ',
        userId: 1,
        libraryIds: [7],
      });

      expect(result).toEqual({
        oldName: 'Orbit  Books',
        affectedBookIds: [10, 11],
        affectedBookCount: 2,
        wasImplicitMerge: false,
        mergedEntityId: undefined,
      });

      expect(transaction).toHaveBeenCalledTimes(1);
      const updateQuery = execute.mock.calls
        .map(([statement]) => dialect.sqlToQuery(statement))
        .find((query) => query.sql.includes('UPDATE book_metadata'));
      expect(updateQuery?.params).toContain('Orbit Books');
      expect(updateQuery?.params).not.toContain('  Orbit\t\nBooks  ');
    });

    it('uses normalized identity when detecting implicit publisher merges', async () => {
      const { dialect, execute, transaction } = makeRenameDb([20], true);
      const strategy = makeStrategy({ transaction });

      const result = await strategy.rename({
        entityId: 'Orbit  Books',
        newName: 'Orbit Books',
        userId: 1,
        libraryIds: [7],
      });

      expect(result).toMatchObject({
        affectedBookIds: [20],
        affectedBookCount: 1,
        wasImplicitMerge: true,
        mergedEntityId: 'Orbit Books',
      });

      expect(transaction).toHaveBeenCalledTimes(1);
      const existingQuery = execute.mock.calls.map(([statement]) => dialect.sqlToQuery(statement)).find((query) => query.sql.includes('AS "exists"'));
      expect(existingQuery?.sql).toContain('regexp_replace');
      expect(existingQuery?.sql).toContain('chr(160)');
      expect(existingQuery?.params).toContain('orbit books');
    });

    it('rejects whitespace-only publisher names after normalization', async () => {
      const execute = vi.fn();
      const strategy = makeStrategy({ execute });

      await expect(
        strategy.rename({
          entityId: 'Orbit Books',
          newName: ' \t\n\u00a0 ',
          userId: 1,
          libraryIds: [7],
        }),
      ).rejects.toBeInstanceOf(BadRequestException);

      expect(execute).not.toHaveBeenCalled();
    });
  });

  describe('buildIdentityEqualsCondition', () => {
    it('returns a false condition when the normalized lookup key is empty', () => {
      const strategy = new TestablePublisherStrategy({} as never);

      const condition = strategy.exposeIdentityCondition('bm', ' \t\n\u00a0 ');

      expect(flattenSql(condition)).toContain('false');
    });
  });
});
