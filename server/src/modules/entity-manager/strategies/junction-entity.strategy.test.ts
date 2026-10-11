import { BadRequestException, ForbiddenException, NotFoundException } from '@nestjs/common';

import { TagStrategy } from './tag.strategy';
import { getTableName, type SQL } from 'drizzle-orm';
import { PgDialect } from 'drizzle-orm/pg-core';

function makeStrategy(db: Record<string, unknown> = {}) {
  return new TagStrategy({ execute: vi.fn().mockResolvedValue({ rows: [] }), ...db } as never);
}

describe('TagStrategy (JunctionEntityStrategy)', () => {
  function thenableRows(rows: unknown[]) {
    const promise = Promise.resolve(rows);
    return { then: promise.then.bind(promise) };
  }

  describe('findCandidatePairs', () => {
    it('runs inside a transaction and executes two SQL statements', async () => {
      const rows = [{ idA: 1, idB: 2, nameA: 'Fantasy', nameB: 'Fantasi', simScore: 0.9 }];
      const execute = vi.fn().mockResolvedValueOnce(undefined).mockResolvedValueOnce({ rows });
      const transaction = vi.fn().mockImplementation(async (cb: (tx: { execute: typeof execute }) => Promise<unknown>) => cb({ execute }));
      const strategy = makeStrategy({ transaction });

      await expect(strategy.findCandidatePairs([1, 2], 0.8)).resolves.toEqual(rows);

      expect(transaction).toHaveBeenCalledTimes(1);
      expect(execute).toHaveBeenCalledTimes(2);
    });

    it('omits library filter when libraryIds is empty', async () => {
      const rows: unknown[] = [];
      const execute = vi.fn().mockResolvedValueOnce(undefined).mockResolvedValueOnce({ rows });
      const transaction = vi.fn().mockImplementation(async (cb: (tx: { execute: typeof execute }) => Promise<unknown>) => cb({ execute }));
      const strategy = makeStrategy({ transaction });

      await strategy.findCandidatePairs([], 0.5);

      expect(transaction).toHaveBeenCalledTimes(1);
      expect(execute).toHaveBeenCalledTimes(2);
    });
  });

  describe('getAllEntityIds', () => {
    it('calls execute and returns ids', async () => {
      const execute = vi.fn().mockResolvedValue({ rows: [{ id: 1 }, { id: 2 }] });
      const strategy = makeStrategy({ execute });

      await expect(strategy.getAllEntityIds()).resolves.toEqual([1, 2]);

      expect(execute).toHaveBeenCalledTimes(1);
    });

    it('returns empty array when no entities exist', async () => {
      const execute = vi.fn().mockResolvedValue({ rows: [] });
      const strategy = makeStrategy({ execute });

      await expect(strategy.getAllEntityIds()).resolves.toEqual([]);
    });
  });

  describe('computeCandidatePairsForBatch', () => {
    it('runs inside a transaction and executes two SQL statements', async () => {
      const rows = [{ idA: 1, idB: 3, nameA: 'Sci-Fi', nameB: 'SciFi', simScore: 0.88 }];
      const execute = vi.fn().mockResolvedValueOnce(undefined).mockResolvedValueOnce({ rows });
      const transaction = vi.fn().mockImplementation(async (cb: (tx: { execute: typeof execute }) => Promise<unknown>) => cb({ execute }));
      const strategy = makeStrategy({ transaction });

      await expect(strategy.computeCandidatePairsForBatch([1, 3], 0.8)).resolves.toEqual(rows);

      expect(transaction).toHaveBeenCalledTimes(1);
      expect(execute).toHaveBeenCalledTimes(2);
    });
  });

  describe('browse', () => {
    it('queries count and items and returns mapped result', async () => {
      // First select call: the internal books subquery (select({id}).from(books).where(...))
      const subqueryWhere = vi.fn().mockReturnValue({ _isSubquery: true });
      const subqueryFrom = vi.fn().mockReturnValue({ where: subqueryWhere });
      const subquerySelect = { from: subqueryFrom };

      const relationWhere = vi.fn().mockReturnValue({ _isRelationSubquery: true });
      const relationFrom = vi.fn().mockReturnValue({ where: relationWhere });
      const relationSelect = { from: relationFrom };

      // Fourth select call: count query
      const countWhere = vi.fn().mockResolvedValue([{ total: 1 }]);
      const countFrom = vi.fn().mockReturnValue({ where: countWhere });
      const countSelect = { from: countFrom };

      // Fifth select call: items query
      const offset = vi.fn().mockResolvedValue([{ id: 5, name: 'Fantasy', bookCount: 12 }]);
      const limit = vi.fn().mockReturnValue({ offset });
      const orderBy = vi.fn().mockReturnValue({ limit });
      const dynamic = { having: vi.fn(), orderBy, ...thenableRows([{ id: 5, name: 'Fantasy', bookCount: 12 }]) };
      const groupBy = vi.fn().mockReturnValue({ $dynamic: vi.fn().mockReturnValue(dynamic) });
      const itemWhere = vi.fn().mockReturnValue({ groupBy });
      const itemLeftJoin = vi.fn().mockReturnValue({ where: itemWhere });
      const itemFrom = vi.fn().mockReturnValue({ leftJoin: itemLeftJoin });
      const itemSelect = { from: itemFrom };

      const select = vi
        .fn()
        .mockReturnValueOnce(subquerySelect)
        .mockReturnValueOnce(relationSelect)
        .mockReturnValueOnce(relationSelect)
        .mockReturnValueOnce(countSelect)
        .mockReturnValueOnce(itemSelect);
      const strategy = makeStrategy({ select });

      const result = await strategy.browse({ libraryIds: [1], page: 1, pageSize: 25, sortBy: 'bookCount', sortOrder: 'desc', bookCount: 'any' });

      expect(result).toEqual({ items: [{ id: 5, name: 'Fantasy', bookCount: 12 }], total: 1 });
      expect(select).toHaveBeenCalledTimes(5);
      expect(itemLeftJoin).toHaveBeenCalledTimes(1);
    });

    it('returns 0 total when count row is missing', async () => {
      const subqueryWhere = vi.fn().mockReturnValue({ _isSubquery: true });
      const subqueryFrom = vi.fn().mockReturnValue({ where: subqueryWhere });
      const subquerySelect = { from: subqueryFrom };

      const relationWhere = vi.fn().mockReturnValue({ _isRelationSubquery: true });
      const relationFrom = vi.fn().mockReturnValue({ where: relationWhere });
      const relationSelect = { from: relationFrom };

      const countWhere = vi.fn().mockResolvedValue([]);
      const countFrom = vi.fn().mockReturnValue({ where: countWhere });
      const countSelect = { from: countFrom };

      const offset = vi.fn().mockResolvedValue([]);
      const limit = vi.fn().mockReturnValue({ offset });
      const orderBy = vi.fn().mockReturnValue({ limit });
      const dynamic = { having: vi.fn(), orderBy, ...thenableRows([]) };
      const groupBy = vi.fn().mockReturnValue({ $dynamic: vi.fn().mockReturnValue(dynamic) });
      const itemWhere = vi.fn().mockReturnValue({ groupBy });
      const itemLeftJoin = vi.fn().mockReturnValue({ where: itemWhere });
      const itemFrom = vi.fn().mockReturnValue({ leftJoin: itemLeftJoin });
      const itemSelect = { from: itemFrom };

      const select = vi
        .fn()
        .mockReturnValueOnce(subquerySelect)
        .mockReturnValueOnce(relationSelect)
        .mockReturnValueOnce(relationSelect)
        .mockReturnValueOnce(countSelect)
        .mockReturnValueOnce(itemSelect);
      const strategy = makeStrategy({ select });

      const result = await strategy.browse({ libraryIds: [1], page: 1, pageSize: 25, sortBy: 'name', sortOrder: 'asc', bookCount: 'any' });

      expect(result.total).toBe(0);
    });
  });

  function mutationFixture(
    initial = [
      { id: 1, name: 'Old' },
      { id: 2, name: 'Target' },
    ],
    ids: number[] = [10, 20],
    outside = false,
  ) {
    const dialect = new PgDialect();
    const rows = initial.map((row) => ({ ...row }));
    const filter = (condition: SQL) => {
      const query = dialect.sqlToQuery(condition);
      const last = query.params.at(-1);
      return typeof last === 'string' ? rows.filter((row) => row.name === last) : rows.filter((row) => query.params.includes(row.id));
    };
    const select = vi.fn().mockReturnValue({
      from: vi.fn().mockReturnValue({
        where: vi.fn((condition: SQL) => {
          const selected = filter(condition);
          const promise = Promise.resolve(selected);
          return {
            then: promise.then.bind(promise),
            limit: vi.fn().mockResolvedValue(selected),
            orderBy: vi.fn().mockReturnValue({ for: vi.fn().mockResolvedValue(selected) }),
          };
        }),
      }),
    });
    const updateSet = vi.fn((values: object) => ({
      where: vi.fn((condition: SQL) => {
        filter(condition).forEach((row) => Object.assign(row, values));
      }),
    }));
    const update = vi.fn().mockReturnValue({ set: updateSet });
    const deleteFrom = vi.fn((table) => ({
      where: vi.fn((condition: SQL) => {
        if (getTableName(table) !== 'tags') return;
        const deleted = new Set(filter(condition));
        for (let index = rows.length - 1; index >= 0; index--) if (deleted.has(rows[index]!)) rows.splice(index, 1);
      }),
    }));
    const insertValues = vi.fn((values: { name: string }) => {
      const row = { id: 100 + rows.length, ...values };
      rows.push(row);
      return { returning: vi.fn().mockResolvedValue([{ id: row.id }]) };
    });
    const insert = vi.fn().mockReturnValue({ values: insertValues });
    const execute = vi.fn((statement: SQL) => {
      const query = dialect.sqlToQuery(statement);
      if (query.sql.includes('scoped_relation')) return { rows: outside ? [{ outside: 1 }] : [] };
      if (query.sql.includes('AS outside')) return { rows: [{ outside: false }] };
      if (query.sql.includes('count(*)::int AS count FROM entity_mutation_books')) return { rows: [{ count: ids.length }] };
      if (query.sql.includes('AS "bookId" FROM entity_mutation_books'))
        return { rows: ids.filter((id) => id > Number(query.params[0])).map((bookId) => ({ bookId })) };
      return { rows: [] };
    });
    const db = { select, update, insert, delete: deleteFrom, execute };
    const transaction = vi.fn(async (callback: (tx: typeof db) => Promise<unknown>) => {
      const before = rows.map((row) => ({ ...row }));
      try {
        return await callback(db);
      } catch (error) {
        rows.splice(0, rows.length, ...before);
        throw error;
      }
    });
    return { strategy: makeStrategy({ ...db, transaction }), rows, transaction, deleteFrom, insertValues, execute };
  }

  describe('merge', () => {
    it('rejects entity relations outside the accessible scope before mutation', async () => {
      const fixture = mutationFixture(undefined, undefined, true);
      await expect(fixture.strategy.merge({ targetId: 2, sourceIds: [1], userId: 5, libraryIds: [7] })).rejects.toBeInstanceOf(ForbiddenException);
      expect(fixture.transaction).not.toHaveBeenCalled();
    });

    it.each([1, 2])('rejects a stale source or target id=%s', async (missingId) => {
      const fixture = mutationFixture([{ id: 3 - missingId, name: 'Remaining' }]);
      await expect(fixture.strategy.merge({ targetId: 2, sourceIds: [1], userId: 5, libraryIds: [7] })).rejects.toBeInstanceOf(NotFoundException);
      expect(fixture.rows).toEqual([{ id: 3 - missingId, name: 'Remaining' }]);
    });

    it('merges source relations and returns the exact distinct affected book count', async () => {
      const fixture = mutationFixture();
      const result = await fixture.strategy.merge({ targetId: 2, sourceIds: [1], userId: 5, libraryIds: [7] });
      expect(result).toEqual({ affectedBookIds: [10, 20], affectedBookCount: 2 });
      expect(fixture.rows).toEqual([{ id: 2, name: 'Target' }]);
      expect(fixture.transaction).toHaveBeenCalledOnce();
    });

    it('merges an empty source without fabricating affected books', async () => {
      const fixture = mutationFixture(undefined, []);
      await expect(fixture.strategy.merge({ targetId: 2, sourceIds: [1], userId: 5, libraryIds: [7] })).resolves.toEqual({
        affectedBookIds: [],
        affectedBookCount: 0,
      });
      expect(fixture.rows).toEqual([{ id: 2, name: 'Target' }]);
    });
  });

  describe('rename', () => {
    it('rejects a missing entity and blank names', async () => {
      const fixture = mutationFixture();
      await expect(fixture.strategy.rename({ entityId: 99, newName: 'New', userId: 5, libraryIds: [7] })).rejects.toBeInstanceOf(NotFoundException);
      await expect(fixture.strategy.rename({ entityId: 1, newName: '  ', userId: 5, libraryIds: [7] })).rejects.toBeInstanceOf(BadRequestException);
    });

    it('performs an implicit merge when the trimmed target name already exists', async () => {
      const fixture = mutationFixture();
      const result = await fixture.strategy.rename({ entityId: 1, newName: ' Target ', userId: 5, libraryIds: [7] });
      expect(result).toMatchObject({ oldName: 'Old', wasImplicitMerge: true, mergedEntityId: 2, affectedBookIds: [10, 20], affectedBookCount: 2 });
      expect(fixture.rows).toEqual([{ id: 2, name: 'Target' }]);
    });

    it('performs a simple trimmed rename without changing the identity', async () => {
      const fixture = mutationFixture();
      const result = await fixture.strategy.rename({ entityId: 1, newName: ' New ', userId: 5, libraryIds: [7] });
      expect(result).toMatchObject({ oldName: 'Old', wasImplicitMerge: false, affectedBookIds: [10, 20], affectedBookCount: 2 });
      expect(fixture.rows.find((row) => row.id === 1)?.name).toBe('New');
    });
  });

  describe('deleteEntity', () => {
    it('rejects a missing entity', async () => {
      const fixture = mutationFixture();
      await expect(fixture.strategy.deleteEntity({ entityId: 99, mode: 'hard', libraryIds: [7] })).rejects.toBeInstanceOf(NotFoundException);
    });

    it.each(['soft', 'hard'] as const)('removes captured relations in %s mode and retains the correct entity row', async (mode) => {
      const fixture = mutationFixture();
      const result = await fixture.strategy.deleteEntity({ entityId: 1, mode, libraryIds: [7] });
      expect(result).toEqual({ name: 'Old', affectedBookIds: [10, 20], affectedBookCount: 2 });
      expect(fixture.rows.some((row) => row.id === 1)).toBe(mode === 'soft');
      expect(fixture.transaction).toHaveBeenCalledOnce();
    });
  });

  describe('split', () => {
    it('rejects a missing entity', async () => {
      const fixture = mutationFixture();
      await expect(fixture.strategy.split({ entityId: 99, newNames: ['A', 'B'], libraryIds: [7] })).rejects.toBeInstanceOf(NotFoundException);
    });

    it('creates new entities and returns their identities with the exact affected book count', async () => {
      const fixture = mutationFixture();
      const result = await fixture.strategy.split({ entityId: 1, newNames: [' New A ', 'New B'], libraryIds: [7] });
      expect(result.originalName).toBe('Old');
      expect(result.newEntities.map((row) => row.name)).toEqual(['New A', 'New B']);
      expect(result.affectedBookIds).toEqual([10, 20]);
      expect(result.affectedBookCount).toBe(2);
      expect(fixture.rows.some((row) => row.id === 1)).toBe(false);
    });

    it('reuses existing names and rejects a split back to its own source', async () => {
      const fixture = mutationFixture();
      const result = await fixture.strategy.split({ entityId: 1, newNames: ['Target'], libraryIds: [7] });
      expect(result.newEntities).toEqual([{ id: 2, name: 'Target' }]);
      expect(fixture.insertValues).not.toHaveBeenCalled();
      const invalid = mutationFixture();
      await expect(invalid.strategy.split({ entityId: 1, newNames: ['Old'], libraryIds: [7] })).rejects.toBeInstanceOf(BadRequestException);
      expect(invalid.rows).toEqual([
        { id: 1, name: 'Old' },
        { id: 2, name: 'Target' },
      ]);
    });
  });

  describe('findAffectedBookIds', () => {
    it('returns empty array without calling select when ids is empty', async () => {
      const selectDistinct = vi.fn();
      const strategy = makeStrategy({ selectDistinct });

      await expect(strategy.findAffectedBookIds([])).resolves.toEqual([]);

      expect(selectDistinct).not.toHaveBeenCalled();
    });

    it('calls selectDistinct and returns mapped book ids', async () => {
      const where = vi.fn().mockResolvedValue([{ bookId: 3 }, { bookId: 7 }]);
      const from = vi.fn().mockReturnValue({ where });
      const selectDistinct = vi.fn().mockReturnValue({ from });
      const strategy = makeStrategy({ selectDistinct });

      await expect(strategy.findAffectedBookIds([1, 2])).resolves.toEqual([3, 7]);

      expect(selectDistinct).toHaveBeenCalledTimes(1);
    });
  });

  describe('getBookCount', () => {
    it('returns count from select chain', async () => {
      const where = vi.fn().mockResolvedValue([{ count: 8 }]);
      const from = vi.fn().mockReturnValue({ where });
      const select = vi.fn().mockReturnValue({ from });
      const strategy = makeStrategy({ select });

      await expect(strategy.getBookCount(1)).resolves.toBe(8);
    });

    it('returns 0 when no row is found', async () => {
      const where = vi.fn().mockResolvedValue([]);
      const from = vi.fn().mockReturnValue({ where });
      const select = vi.fn().mockReturnValue({ from });
      const strategy = makeStrategy({ select });

      await expect(strategy.getBookCount(99)).resolves.toBe(0);
    });
  });

  describe('getBookTitles', () => {
    it('returns titles from the join-select chain', async () => {
      const limit = vi.fn().mockResolvedValue([{ title: 'Dune' }, { title: 'Foundation' }]);
      const orderBy = vi.fn().mockReturnValue({ limit });
      const where = vi.fn().mockReturnValue({ orderBy });
      const leftJoin = vi.fn().mockReturnValue({ where });
      const innerJoin = vi.fn().mockReturnValue({ leftJoin });
      const from = vi.fn().mockReturnValue({ innerJoin });
      const select = vi.fn().mockReturnValue({ from });
      const strategy = makeStrategy({ select });

      await expect(strategy.getBookTitles(1, 5)).resolves.toEqual(['Dune', 'Foundation']);
    });
  });

  describe('findEntityById', () => {
    it('returns {id, name} when a row is found', async () => {
      const limit = vi.fn().mockResolvedValue([{ id: 5, name: 'Fantasy' }]);
      const where = vi.fn().mockReturnValue({ limit });
      const from = vi.fn().mockReturnValue({ where });
      const select = vi.fn().mockReturnValue({ from });
      const strategy = makeStrategy({ select });

      await expect(strategy.findEntityById(5)).resolves.toEqual({ id: 5, name: 'Fantasy' });
    });

    it('returns null when no row is found', async () => {
      const limit = vi.fn().mockResolvedValue([]);
      const where = vi.fn().mockReturnValue({ limit });
      const from = vi.fn().mockReturnValue({ where });
      const select = vi.fn().mockReturnValue({ from });
      const strategy = makeStrategy({ select });

      await expect(strategy.findEntityById(99)).resolves.toBeNull();
    });
  });
});
