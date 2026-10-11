import { BadRequestException, ForbiddenException, NotFoundException } from '@nestjs/common';
import { vi } from 'vitest';

import { AuthorStrategy } from './author.strategy';
import { getTableName, type SQL } from 'drizzle-orm';
import { PgDialect } from 'drizzle-orm/pg-core';
import { authors } from '../../../db/schema';

vi.mock('../../../db/book-author-sort-key', () => ({
  refreshPrimaryAuthorSortNamesForBookSelection: vi.fn().mockResolvedValue(undefined),
}));

import { refreshPrimaryAuthorSortNamesForBookSelection } from '../../../db/book-author-sort-key';

function makeStrategy(db: Record<string, unknown> = {}, deps: Record<string, unknown> = {}) {
  const authorsRepo = {
    updateAuthorById: vi.fn().mockResolvedValue(undefined),
    mergeAuthors: vi.fn().mockResolvedValue(undefined),
    deleteAuthors: vi.fn().mockResolvedValue(undefined),
    ...(deps.authorsRepo as object | undefined),
  };
  const authorImageStorage = {
    promoteImage: vi.fn().mockResolvedValue(false),
    deleteAuthorDir: vi.fn().mockResolvedValue(undefined),
    ...(deps.authorImageStorage as object | undefined),
  };
  const enrichmentOrchestrator = {
    schedule: vi.fn().mockResolvedValue(undefined),
    ...(deps.enrichmentOrchestrator as object | undefined),
  };
  const resolvedDb = { execute: vi.fn().mockResolvedValue({ rows: [] }), ...db };
  return new AuthorStrategy(resolvedDb as never, authorsRepo as never, authorImageStorage as never, enrichmentOrchestrator as never);
}

function makeSelectChain(rows: unknown[]) {
  const limit = vi.fn().mockResolvedValue(rows);
  const where = vi.fn().mockReturnValue({ limit });
  const from = vi.fn().mockReturnValue({ where });
  const select = vi.fn().mockReturnValue({ from });
  return { select, from, where, limit };
}

describe('AuthorStrategy', () => {
  function thenableRows(rows: unknown[]) {
    const promise = Promise.resolve(rows);
    return { then: promise.then.bind(promise) };
  }

  describe('findCandidatePairs', () => {
    it('runs two executes inside a transaction', async () => {
      const rows = [{ idA: 1, idB: 2, nameA: 'Tolkien', nameB: 'Tolkein', simScore: 0.9 }];
      const execute = vi.fn().mockResolvedValueOnce(undefined).mockResolvedValueOnce({ rows });
      const transaction = vi.fn().mockImplementation(async (cb: (tx: { execute: typeof execute }) => Promise<unknown>) => cb({ execute }));
      const strategy = makeStrategy({ transaction });

      await expect(strategy.findCandidatePairs([], 0.5)).resolves.toEqual(rows);

      expect(transaction).toHaveBeenCalledTimes(1);
      expect(execute).toHaveBeenCalledTimes(2);
    });

    it('includes a library filter fragment when libraryIds are provided', async () => {
      const execute = vi.fn().mockResolvedValueOnce(undefined).mockResolvedValueOnce({ rows: [] });
      const transaction = vi.fn().mockImplementation(async (cb: (tx: { execute: typeof execute }) => Promise<unknown>) => cb({ execute }));
      const strategy = makeStrategy({ transaction });

      await strategy.findCandidatePairs([10, 20], 0.6);

      const querySql = execute.mock.calls[1]![0];
      const flat = flattenSql(querySql).replace(/\s+/g, ' ');
      expect(flat).toContain('library_id IN');
    });

    it('runs without a library filter when libraryIds is empty', async () => {
      const execute = vi.fn().mockResolvedValueOnce(undefined).mockResolvedValueOnce({ rows: [] });
      const transaction = vi.fn().mockImplementation(async (cb: (tx: { execute: typeof execute }) => Promise<unknown>) => cb({ execute }));
      const strategy = makeStrategy({ transaction });

      await strategy.findCandidatePairs([], 0.5);

      expect(transaction).toHaveBeenCalledTimes(1);
      expect(execute).toHaveBeenCalledTimes(2);
    });

    it('clamps similarity threshold to [0.1, 1]', async () => {
      const execute = vi.fn().mockResolvedValueOnce(undefined).mockResolvedValueOnce({ rows: [] });
      const transaction = vi.fn().mockImplementation(async (cb: (tx: { execute: typeof execute }) => Promise<unknown>) => cb({ execute }));
      const strategy = makeStrategy({ transaction });

      await strategy.findCandidatePairs([], 5);

      const setConfigSql = execute.mock.calls[0]![0];
      const params = extractSqlParams(setConfigSql);
      expect(params).toContain('1');
    });
  });

  describe('getAllEntityIds', () => {
    it('returns ids from rows', async () => {
      const execute = vi.fn().mockResolvedValue({ rows: [{ id: 1 }, { id: 2 }] });
      const strategy = makeStrategy({ execute });

      await expect(strategy.getAllEntityIds()).resolves.toEqual([1, 2]);
    });

    it('returns empty array when no authors exist', async () => {
      const execute = vi.fn().mockResolvedValue({ rows: [] });
      const strategy = makeStrategy({ execute });

      await expect(strategy.getAllEntityIds()).resolves.toEqual([]);
    });
  });

  describe('computeCandidatePairsForBatch', () => {
    it('runs two executes inside a transaction for a non-empty batch', async () => {
      const rows = [{ idA: 3, idB: 5, nameA: 'A', nameB: 'B', simScore: 0.8 }];
      const execute = vi.fn().mockResolvedValueOnce(undefined).mockResolvedValueOnce({ rows });
      const transaction = vi.fn().mockImplementation(async (cb: (tx: { execute: typeof execute }) => Promise<unknown>) => cb({ execute }));
      const strategy = makeStrategy({ transaction });

      await expect(strategy.computeCandidatePairsForBatch([3, 5], 0.7)).resolves.toEqual(rows);

      expect(execute).toHaveBeenCalledTimes(2);
    });
  });

  describe('browse', () => {
    function makeBrowseDb(countRows: unknown[], itemRows: unknown[], hasLibraryIds = false) {
      const countWhere = vi.fn().mockResolvedValue(countRows);
      const countFrom = vi.fn().mockReturnValue({ where: countWhere });

      const itemOffset = vi.fn().mockResolvedValue(itemRows);
      const itemLimit = vi.fn().mockReturnValue({ offset: itemOffset });
      const itemOrderBy = vi.fn().mockReturnValue({ limit: itemLimit });
      const itemDynamic = { having: vi.fn(), orderBy: itemOrderBy, ...thenableRows(itemRows) };
      const itemDynamicFactory = vi.fn().mockReturnValue(itemDynamic);
      const itemGroupBy = vi.fn().mockReturnValue({ $dynamic: itemDynamicFactory });
      const itemWhere = vi.fn().mockReturnValue({ groupBy: itemGroupBy });
      const itemLeftJoin = vi.fn().mockReturnValue({ where: itemWhere });
      const itemFrom = vi.fn().mockReturnValue({ leftJoin: itemLeftJoin, where: itemWhere });

      const subqueryWhere = vi.fn().mockReturnValue('SUBQUERY_PLACEHOLDER');
      const subqueryFrom = vi.fn().mockReturnValue({ where: subqueryWhere });

      const relationWhere = vi.fn().mockReturnValue({ _isRelationSubquery: true });
      const relationFrom = vi.fn().mockReturnValue({ where: relationWhere });

      let callCount = 0;
      const select = vi.fn().mockImplementation(() => {
        callCount++;
        if (callCount === 1 && hasLibraryIds) return { from: subqueryFrom };
        if ((hasLibraryIds && (callCount === 2 || callCount === 3)) || (!hasLibraryIds && callCount === 1)) {
          return { from: relationFrom };
        }
        if ((callCount === 2 && !hasLibraryIds) || (callCount === 4 && hasLibraryIds)) return { from: countFrom };
        return { from: itemFrom };
      });

      return { select, countWhere, itemWhere, itemLeftJoin };
    }

    it('returns items and total from two parallel selects', async () => {
      const itemRows = [
        { id: 1, name: 'Tolkien', sortName: 'Tolkien, J.R.R.', hasPhoto: true, bookCount: 5 },
        { id: 2, name: 'Lewis', sortName: null, hasPhoto: false, bookCount: 3 },
      ];
      const { select } = makeBrowseDb([{ total: 2 }], itemRows, false);
      const strategy = makeStrategy({ select });

      const result = await strategy.browse({ libraryIds: [], page: 1, pageSize: 25, sortBy: 'name', sortOrder: 'asc', bookCount: 'any' });

      expect(result.total).toBe(2);
      expect(result.items).toHaveLength(2);
      expect(result.items[0]).toMatchObject({ id: 1, name: 'Tolkien', bookCount: 5 });
      expect(select).toHaveBeenCalledTimes(3);
    });

    it('uses a subquery leftJoin condition when libraryIds are provided', async () => {
      const { select, itemLeftJoin } = makeBrowseDb([{ total: 0 }], [], true);
      const strategy = makeStrategy({ select });

      await strategy.browse({ libraryIds: [5], page: 1, pageSize: 10, sortBy: 'name', sortOrder: 'asc', bookCount: 'any' });

      expect(itemLeftJoin).toHaveBeenCalledTimes(1);
      expect(select).toHaveBeenCalledTimes(5);
    });

    it('joins without a subquery filter when libraryIds is empty', async () => {
      const { select, itemLeftJoin } = makeBrowseDb([{ total: 0 }], [], false);
      const strategy = makeStrategy({ select });

      await strategy.browse({ libraryIds: [], page: 1, pageSize: 10, sortBy: 'name', sortOrder: 'asc', bookCount: 'any' });

      expect(itemLeftJoin).toHaveBeenCalledTimes(1);
      expect(select).toHaveBeenCalledTimes(3);
    });

    it('returns zero total when countResult is empty', async () => {
      const { select } = makeBrowseDb([], [], false);
      const strategy = makeStrategy({ select });

      const result = await strategy.browse({ libraryIds: [], page: 1, pageSize: 10, sortBy: 'name', sortOrder: 'asc', bookCount: 'any' });

      expect(result.total).toBe(0);
    });
  });

  function mutationFixture(
    input: Partial<typeof authors.$inferSelect>[] = [
      { id: 1, name: 'Old' },
      { id: 2, name: 'Target' },
    ],
    ids: number[] = [10, 20],
    outside = false,
  ) {
    const dialect = new PgDialect();
    const rows = input.map((row) => ({ sortName: null, description: null, hasPhoto: false, ...row }));
    const filter = (condition: SQL) => {
      const query = dialect.sqlToQuery(condition);
      const last = query.params.at(-1);
      return typeof last === 'string'
        ? rows.filter((row) => row.name?.replace(/\s+/g, ' ').trim().toLowerCase() === last)
        : rows.filter((row) => query.params.includes(row.id));
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
        if (getTableName(table) !== 'authors') return;
        const deleted = new Set(filter(condition));
        for (let index = rows.length - 1; index >= 0; index--) if (deleted.has(rows[index]!)) rows.splice(index, 1);
      }),
    }));
    const insertValues = vi.fn((values: { name: string }) => {
      const row = { id: 100 + rows.length, sortName: null, description: null, hasPhoto: false, ...values };
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
    const transaction = vi.fn(async (callback: (tx: typeof db) => Promise<unknown>) => callback(db));
    const image = { promoteImage: vi.fn().mockResolvedValue(false), deleteAuthorDir: vi.fn().mockResolvedValue(undefined) };
    const enrichment = { schedule: vi.fn().mockResolvedValue(undefined) };
    return {
      strategy: makeStrategy({ ...db, transaction }, { authorImageStorage: image, enrichmentOrchestrator: enrichment }),
      rows,
      image,
      enrichment,
      transaction,
      updateSet,
      deleteFrom,
      insertValues,
      execute,
    };
  }

  describe('merge', () => {
    it('rejects merging authors used outside the accessible scope before image or DB changes', async () => {
      const fixture = mutationFixture(undefined, undefined, true);
      await expect(fixture.strategy.merge({ targetId: 2, sourceIds: [1], userId: 5, libraryIds: [7] })).rejects.toBeInstanceOf(ForbiddenException);
      expect(fixture.transaction).not.toHaveBeenCalled();
      expect(fixture.image.promoteImage).not.toHaveBeenCalled();
    });

    it.each([1, 2])('rejects a missing source or target author id=%s', async (missingId) => {
      const fixture = mutationFixture([{ id: 3 - missingId, name: 'Remaining' }]);
      await expect(fixture.strategy.merge({ targetId: 2, sourceIds: [1], userId: 5, libraryIds: [7] })).rejects.toBeInstanceOf(NotFoundException);
      expect(fixture.image.promoteImage).not.toHaveBeenCalled();
    });

    it.each(['sortName', 'description'] as const)('resolves a missing target %s from the source in the transaction', async (field) => {
      const fixture = mutationFixture([
        { id: 1, name: 'Old', [field]: 'Source value' },
        { id: 2, name: 'Target' },
      ]);
      const result = await fixture.strategy.merge({ targetId: 2, sourceIds: [1], userId: 5, libraryIds: [7] });
      expect(result.fieldsResolved).toContain(field);
      expect(fixture.rows.find((row) => row.id === 2)?.[field]).toBe('Source value');
      expect(result.affectedBookIds).toEqual([10, 20]);
      expect(result.affectedBookCount).toBe(2);
    });

    it('preserves populated target metadata and photo', async () => {
      const fixture = mutationFixture([
        { id: 1, name: 'Old', sortName: 'Source', description: 'Source' },
        { id: 2, name: 'Target', sortName: 'Target sort', description: 'Target description', hasPhoto: true },
      ]);
      const result = await fixture.strategy.merge({ targetId: 2, sourceIds: [1], userId: 5, libraryIds: [7] });
      expect(result.fieldsResolved).toEqual([]);
      expect(fixture.rows[0]).toMatchObject({ id: 2, sortName: 'Target sort', description: 'Target description', hasPhoto: true });
      expect(fixture.image.promoteImage).not.toHaveBeenCalled();
    });

    it('promotes a missing photo, removes source directories, and schedules target enrichment', async () => {
      const fixture = mutationFixture();
      fixture.image.promoteImage.mockResolvedValue(true);
      const result = await fixture.strategy.merge({ targetId: 2, sourceIds: [1], userId: 5, libraryIds: [7] });
      expect(result.imagePromoted).toBe(true);
      expect(result.fieldsResolved).toContain('photo');
      expect(fixture.rows[0]?.hasPhoto).toBe(true);
      expect(fixture.image.promoteImage).toHaveBeenCalledExactlyOnceWith(1, 2);
      expect(fixture.image.deleteAuthorDir).toHaveBeenCalledExactlyOnceWith(1);
      expect(fixture.enrichment.schedule).toHaveBeenCalledExactlyOnceWith(2, 'author_merge_target');
    });
  });

  describe('rename', () => {
    it('rejects a missing entity and blank names', async () => {
      const fixture = mutationFixture();
      await expect(fixture.strategy.rename({ entityId: 99, newName: 'New', userId: 5, libraryIds: [7] })).rejects.toBeInstanceOf(NotFoundException);
      await expect(fixture.strategy.rename({ entityId: 1, newName: ' \t\n ', userId: 5, libraryIds: [7] })).rejects.toBeInstanceOf(
        BadRequestException,
      );
    });

    it('performs an implicit merge with a normalized existing name and keeps the old name', async () => {
      const fixture = mutationFixture();
      const result = await fixture.strategy.rename({ entityId: 1, newName: ' Target ', userId: 5, libraryIds: [7] });
      expect(result).toMatchObject({ oldName: 'Old', wasImplicitMerge: true, mergedEntityId: 2, affectedBookCount: 2 });
      expect(fixture.rows.map((row) => row.id)).toEqual([2]);
    });

    it('chooses a non-current normalized merge target when the current author appears first', async () => {
      const fixture = mutationFixture([
        { id: 1, name: 'New  Name' },
        { id: 99, name: 'New Name' },
      ]);
      const result = await fixture.strategy.rename({ entityId: 1, newName: 'New Name', userId: 5, libraryIds: [7] });
      expect(result).toMatchObject({ wasImplicitMerge: true, mergedEntityId: 99 });
    });

    it('normalizes and updates a distinct name without an implicit merge', async () => {
      const fixture = mutationFixture();
      const result = await fixture.strategy.rename({ entityId: 1, newName: ' New   Name ', userId: 5, libraryIds: [7] });
      expect(result).toMatchObject({ oldName: 'Old', wasImplicitMerge: false, affectedBookIds: [10, 20], affectedBookCount: 2 });
      expect(fixture.rows.find((row) => row.id === 1)?.name).toBe('New Name');
    });
  });

  describe('deleteEntity', () => {
    it('rejects a missing entity', async () => {
      const fixture = mutationFixture();
      await expect(fixture.strategy.deleteEntity({ entityId: 99, mode: 'hard', libraryIds: [7] })).rejects.toBeInstanceOf(NotFoundException);
    });

    it.each(['soft', 'hard'] as const)('deletes relations in %s mode and refreshes only captured books', async (mode) => {
      const fixture = mutationFixture();
      const result = await fixture.strategy.deleteEntity({ entityId: 1, mode, libraryIds: [7] });
      expect(result).toEqual({ name: 'Old', affectedBookIds: [10, 20], affectedBookCount: 2 });
      expect(fixture.rows.some((row) => row.id === 1)).toBe(mode === 'soft');
      expect(refreshPrimaryAuthorSortNamesForBookSelection).toHaveBeenCalledWith(expect.anything(), expect.anything());
      if (mode === 'hard') expect(fixture.image.deleteAuthorDir).toHaveBeenCalledWith(1);
      else expect(fixture.image.deleteAuthorDir).not.toHaveBeenCalled();
    });
  });

  describe('split', () => {
    it('rejects a missing entity', async () => {
      const fixture = mutationFixture();
      await expect(fixture.strategy.split({ entityId: 99, newNames: ['A', 'B'], libraryIds: [7] })).rejects.toBeInstanceOf(NotFoundException);
    });

    it('creates normalized names, removes the source, and preserves the affected count', async () => {
      const fixture = mutationFixture();
      const result = await fixture.strategy.split({ entityId: 1, newNames: [' New   A ', 'New\tB'], libraryIds: [7] });
      expect(result.originalName).toBe('Old');
      expect(result.newEntities.map((row) => row.name)).toEqual(['New A', 'New B']);
      expect(result.affectedBookIds).toEqual([10, 20]);
      expect(result.affectedBookCount).toBe(2);
      expect(fixture.rows.some((row) => row.id === 1)).toBe(false);
      expect(fixture.image.deleteAuthorDir).toHaveBeenCalledWith(1);
    });

    it('reuses a normalized existing author and deduplicates repeated names', async () => {
      const fixture = mutationFixture();
      const result = await fixture.strategy.split({ entityId: 1, newNames: ['Target', ' Target '], libraryIds: [7] });
      expect(result.newEntities).toEqual([{ id: 2, name: 'Target' }]);
      expect(fixture.insertValues).not.toHaveBeenCalled();
    });

    it('does not reuse the source author as a normalized split target', async () => {
      const fixture = mutationFixture();
      const result = await fixture.strategy.split({ entityId: 1, newNames: ['Old'], libraryIds: [7] });
      expect(result.newEntities[0]).toMatchObject({ name: 'Old' });
      expect(result.newEntities[0]?.id).not.toBe(1);
      expect(fixture.insertValues).toHaveBeenCalledWith({ name: 'Old' });
    });
  });

  describe('findAffectedBookIds', () => {
    it('returns empty array for empty ids', async () => {
      const select = vi.fn();
      const strategy = makeStrategy({ select });

      await expect(strategy.findAffectedBookIds([])).resolves.toEqual([]);

      expect(select).not.toHaveBeenCalled();
    });

    it('queries selectDistinct and maps bookId', async () => {
      const where = vi.fn().mockResolvedValue([{ bookId: 10 }, { bookId: 20 }]);
      const from = vi.fn().mockReturnValue({ where });
      const selectDistinct = vi.fn().mockReturnValue({ from });

      const strategy = makeStrategy({ selectDistinct });

      await expect(strategy.findAffectedBookIds([1, 2])).resolves.toEqual([10, 20]);
    });
  });

  describe('getBookCount', () => {
    it('returns count from database', async () => {
      const where = vi.fn().mockResolvedValue([{ count: 7 }]);
      const from = vi.fn().mockReturnValue({ where });
      const select = vi.fn().mockReturnValue({ from });

      const strategy = makeStrategy({ select });

      await expect(strategy.getBookCount(1)).resolves.toBe(7);
    });

    it('returns 0 when no row is returned', async () => {
      const where = vi.fn().mockResolvedValue([]);
      const from = vi.fn().mockReturnValue({ where });
      const select = vi.fn().mockReturnValue({ from });

      const strategy = makeStrategy({ select });

      await expect(strategy.getBookCount(1)).resolves.toBe(0);
    });

    it('joins books and applies the requested library scope', async () => {
      const where = vi.fn().mockResolvedValue([{ count: 2 }]);
      const innerJoin = vi.fn().mockReturnValue({ where });
      const from = vi.fn().mockReturnValue({ innerJoin });
      const select = vi.fn().mockReturnValue({ from });
      const strategy = makeStrategy({ select });

      await expect(strategy.getBookCount(1, { libraryIds: [7, 9] })).resolves.toBe(2);

      expect(innerJoin).toHaveBeenCalledTimes(1);
      expect(flattenSql(where.mock.calls[0]![0])).toMatch(/\bin\b/);
    });
  });

  describe('getBookTitles', () => {
    it('returns titles from joined query', async () => {
      const limit = vi.fn().mockResolvedValue([{ title: 'The Hobbit' }, { title: 'LOTR' }]);
      const orderBy = vi.fn().mockReturnValue({ limit });
      const where = vi.fn().mockReturnValue({ orderBy });
      const leftJoin = vi.fn().mockReturnValue({ where });
      const innerJoin = vi.fn().mockReturnValue({ leftJoin });
      const from = vi.fn().mockReturnValue({ innerJoin });
      const select = vi.fn().mockReturnValue({ from });

      const strategy = makeStrategy({ select });

      await expect(strategy.getBookTitles(1, 5)).resolves.toEqual(['The Hobbit', 'LOTR']);
    });

    it('applies the same library scope when loading preview titles', async () => {
      const limit = vi.fn().mockResolvedValue([{ title: 'Visible Book' }]);
      const orderBy = vi.fn().mockReturnValue({ limit });
      const where = vi.fn().mockReturnValue({ orderBy });
      const leftJoin = vi.fn().mockReturnValue({ where });
      const innerJoin = vi.fn().mockReturnValue({ leftJoin });
      const from = vi.fn().mockReturnValue({ innerJoin });
      const select = vi.fn().mockReturnValue({ from });
      const strategy = makeStrategy({ select });

      await expect(strategy.getBookTitles(1, 5, { libraryIds: [7] })).resolves.toEqual(['Visible Book']);

      expect(flattenSql(where.mock.calls[0]![0])).toMatch(/\bin\b/);
    });
  });

  describe('findEntityById', () => {
    it('returns author when found', async () => {
      const { select } = makeSelectChain([{ id: 42, name: 'Tolkien' }]);
      const strategy = makeStrategy({ select });

      await expect(strategy.findEntityById(42)).resolves.toEqual({ id: 42, name: 'Tolkien' });
    });

    it('returns null when author is not found', async () => {
      const { select } = makeSelectChain([]);
      const strategy = makeStrategy({ select });

      await expect(strategy.findEntityById(99)).resolves.toBeNull();
    });
  });
});

function flattenSql(value: unknown): string {
  if (typeof value === 'string') return value;
  if (Array.isArray(value)) return value.map(flattenSql).join(' ');
  if (!value || typeof value !== 'object') return '';

  const record = value as { queryChunks?: unknown[]; value?: unknown };
  return [flattenSql(record.value), flattenSql(record.queryChunks)].join(' ');
}

function extractSqlParams(value: unknown): unknown[] {
  if (typeof value === 'number' || typeof value === 'string' || value === null || typeof value === 'boolean') return [value];
  if (!value || typeof value !== 'object') return [];

  const record = value as { queryChunks?: unknown[] };
  return Array.isArray(record.queryChunks) ? record.queryChunks.flatMap(extractSqlParams) : [];
}
