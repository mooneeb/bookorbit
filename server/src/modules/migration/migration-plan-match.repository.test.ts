import { NotFoundException } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { PgDialect } from 'drizzle-orm/pg-core';

import { DB } from '../../db';
import * as schema from '../../db/schema';
import { MigrationPlanMatchRepository } from './migration-plan-match.repository';
import { MigrationRepository } from './migration.repository';
import type { PlannedBookMatch } from './planner/planner.types';

const match = (index: number): PlannedBookMatch => ({ sourceBookId: `source-${index}`, targetBookId: index + 1, strategy: 'isbn' });

async function createRepository(db: unknown) {
  const module = await Test.createTestingModule({ providers: [MigrationRepository, { provide: DB, useValue: db }] }).compile();
  return module.get(MigrationRepository);
}

function transactionFixture(total: number, batched = false) {
  const writes: string[] = [];
  const values = vi.fn().mockImplementation(() => ({
    onConflictDoNothing: vi.fn().mockImplementation(() => {
      writes.push('matches');
      return Promise.resolve();
    }),
  }));
  const deleteWhere = vi.fn().mockResolvedValue(undefined);
  const select = vi.fn().mockImplementation((fields: Record<string, unknown>) => ({
    from: vi.fn().mockReturnValue({
      where: vi.fn().mockImplementation(() => {
        if ('userId' in fields) return { limit: vi.fn().mockReturnValue({ for: vi.fn().mockResolvedValue([{ userId: 7, batched }]) }) };
        if ('nextPosition' in fields) return Promise.resolve([{ nextPosition: batched ? total - 1 : 0 }]);
        if ('total' in fields) return Promise.resolve([{ total }]);
        return {
          orderBy: vi.fn().mockReturnValue({
            limit: vi.fn().mockReturnValue({ offset: vi.fn().mockResolvedValue(Array.from({ length: Math.min(total, 40) }, (_, i) => match(i))) }),
          }),
        };
      }),
    }),
  }));
  const set = vi.fn().mockReturnValue({
    where: vi.fn().mockReturnValue({
      returning: vi.fn().mockImplementation(() => {
        writes.push('artifact');
        return Promise.resolve([{ id: 9 }]);
      }),
    }),
  });
  const tx = {
    select,
    insert: vi.fn().mockReturnValue({ values }),
    delete: vi.fn().mockReturnValue({ where: deleteWhere }),
    update: vi.fn().mockReturnValue({ set }),
  };
  const db = { transaction: vi.fn().mockImplementation(async (callback: (value: typeof tx) => Promise<unknown>) => callback(tx)) };
  return { db, tx, values, set, writes, deleteWhere };
}

describe('MigrationPlanMatchRepository', () => {
  it('stores all 105 matches in bounded writes and commits only a 40-match preview atomically', async () => {
    const fixture = transactionFixture(105);
    const repo = await createRepository(fixture.db);
    await repo.updatePlanArtifact(9, { plan: { matchedBooks: Array.from({ length: 105 }, (_, i) => match(i)) }, summary: { matchedBooks: 105 } });

    expect(fixture.values.mock.calls.map(([rows]) => rows.length)).toEqual([100, 5]);
    expect(fixture.tx.insert).toHaveBeenCalledWith(schema.migrationPlanBookMatches);
    expect(fixture.values.mock.calls.flatMap(([rows]) => rows)).toHaveLength(105);
    expect(fixture.values.mock.calls.flatMap(([rows]) => rows).every((row) => row.artifactId === 9 && row.userId === 7)).toBe(true);
    expect(fixture.set).toHaveBeenCalledWith(
      expect.objectContaining({
        plan: expect.objectContaining({
          matchedBooksBatched: true,
          matchedBooks: Array.from({ length: 40 }, (_, i) => match(i)),
          previewPagination: { matchedBooks: { total: 105, limit: 40, nextOffset: 40 } },
        }),
        summary: { matchedBooks: 105 },
      }),
    );
    expect(fixture.writes).toEqual(['matches', 'matches', 'artifact']);
    expect(new PgDialect().sqlToQuery(fixture.deleteWhere.mock.calls[0][0]).params).toEqual([9, 7]);
  });

  it('appends a duplicate winner without replacing existing durable matches', async () => {
    const fixture = transactionFixture(106, true);
    const repo = await createRepository(fixture.db);
    await repo.updatePlanArtifact(9, {
      plan: { matchedBooks: Array.from({ length: 40 }, (_, i) => match(i)), matchedBooksBatched: true },
      summary: {},
      matchedBookAdditions: [match(105)],
    });

    expect(fixture.tx.delete).not.toHaveBeenCalled();
    expect(fixture.values).toHaveBeenCalledWith([{ artifactId: 9, userId: 7, position: 105, ...match(105) }]);
    expect(fixture.set.mock.calls[0][0].summary).toEqual({ matchedBooks: 106 });
    expect(fixture.set.mock.calls[0][0]).not.toHaveProperty('matchedBookAdditions');
  });

  it('does not publish the preview if a durable match write fails', async () => {
    const fixture = transactionFixture(105);
    fixture.values.mockImplementation(() => ({ onConflictDoNothing: vi.fn().mockRejectedValue(new Error('database unavailable')) }));
    const repo = await createRepository(fixture.db);
    await expect(repo.updatePlanArtifact(9, { plan: { matchedBooks: [match(0)] }, summary: {} })).rejects.toThrow('database unavailable');
    expect(fixture.db.transaction).toHaveBeenCalledOnce();
    expect(fixture.tx.update).not.toHaveBeenCalled();
  });

  it('rejects a removed artifact before writing matches or publishing its preview', async () => {
    const fixture = transactionFixture(105);
    fixture.tx.select.mockReturnValue({
      from: vi.fn().mockReturnValue({
        where: vi.fn().mockReturnValue({ limit: vi.fn().mockReturnValue({ for: vi.fn().mockResolvedValue([]) }) }),
      }),
    });
    const repo = await createRepository(fixture.db);

    await expect(repo.updatePlanArtifact(9, { plan: { matchedBooks: [match(0)] }, summary: {} })).rejects.toThrow(
      new NotFoundException('Migration plan artifact not found: 9'),
    );
    expect(fixture.tx.delete).not.toHaveBeenCalled();
    expect(fixture.tx.insert).not.toHaveBeenCalled();
    expect(fixture.tx.update).not.toHaveBeenCalled();
    expect(fixture.writes).toEqual([]);
  });

  it('rejects unbounded subset lookups before querying the database', async () => {
    const select = vi.fn();
    const repo = new MigrationPlanMatchRepository({ select } as never);
    await expect(
      repo.forSourceBooks(
        9,
        Array.from({ length: 101 }, (_, i) => `source-${i}`),
      ),
    ).rejects.toThrow('at most 100');
    expect(select).not.toHaveBeenCalled();
  });

  it('retrieves a bounded source subset from durable rows under the artifact owner', async () => {
    const limit = vi.fn().mockResolvedValue([match(104)]);
    const where = vi.fn().mockReturnValue({ orderBy: vi.fn().mockReturnValue({ limit }) });
    const select = vi
      .fn()
      .mockReturnValueOnce({
        from: vi.fn().mockReturnValue({ where: vi.fn().mockReturnValue({ limit: vi.fn().mockResolvedValue([{ userId: 7, batched: true }]) }) }),
      })
      .mockReturnValueOnce({ from: vi.fn().mockReturnValue({ where }) });
    const repo = new MigrationPlanMatchRepository({ select } as never);
    await expect(repo.forSourceBooks(9, ['source-104'])).resolves.toEqual([match(104)]);
    const query = new PgDialect().sqlToQuery(where.mock.calls[0][0]);
    expect(query.params).toEqual([9, 7, 'source-104']);
    expect(limit).toHaveBeenCalledWith(1);
  });

  it('limits legacy JSON pages and retains completed artifact compatibility without writes', async () => {
    const select = vi.fn().mockReturnValue({
      from: vi.fn().mockReturnValue({ where: vi.fn().mockReturnValue({ limit: vi.fn().mockResolvedValue([{ userId: 7, batched: false }]) }) }),
    });
    const execute = vi.fn().mockResolvedValue({ rows: [{ total: 105, items: [match(104)] }] });
    const repo = new MigrationPlanMatchRepository({ select, execute } as never);
    await expect(repo.page(9, 104, 10_000)).resolves.toEqual({ total: 105, items: [match(104)] });
    const query = new PgDialect().sqlToQuery(execute.mock.calls[0][0]);
    expect(query.sql).toContain('generate_series');
    expect(query.sql).toContain('created_by_user_id');
    expect(query.params).toEqual([104, 203, 9, 7]);
  });
});
