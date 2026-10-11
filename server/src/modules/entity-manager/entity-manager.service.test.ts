import { BadRequestException, NotFoundException } from '@nestjs/common';

import type { ClusterEntity, DismissedPairInfo, EntityType } from '@bookorbit/types';
import type { RequestUser } from '../../common/types/request-user';
import { EntityManagerService } from './entity-manager.service';
import { DuplicateComputeService } from './duplicate-compute.service';
import { EntityManagerRepository } from './entity-manager.repository';
import { PgDialect } from 'drizzle-orm/pg-core';
import type { SQL } from 'drizzle-orm';
import type { EntityStrategy, RawCandidatePair } from './strategies/entity-strategy.interface';
import { EMPTY_CONTENT_FILTER_RULES } from '@bookorbit/types';

function mockStrategy(overrides: Partial<EntityStrategy> & { entityType: EntityType; isInline: boolean }): EntityStrategy {
  return {
    findCandidatePairs: vi.fn().mockResolvedValue([]),
    browse: vi.fn().mockResolvedValue({ items: [], total: 0 }),
    merge: vi.fn().mockResolvedValue({ affectedBookIds: [] }),
    rename: vi.fn().mockResolvedValue({ oldName: 'Old', affectedBookIds: [], wasImplicitMerge: false }),
    deleteEntity: vi.fn().mockResolvedValue({ name: 'Test', affectedBookIds: [] }),
    split: vi.fn().mockResolvedValue({ originalName: 'Test', newEntities: [], affectedBookIds: [] }),
    findAffectedBookIds: vi.fn().mockResolvedValue([]),
    getBookCount: vi.fn().mockResolvedValue(0),
    getBookTitles: vi.fn().mockResolvedValue([]),
    findEntityById: vi.fn().mockImplementation((id: number | string) => Promise.resolve({ id, name: typeof id === 'string' ? id : `Entity ${id}` })),
    assertMutationScope: vi.fn().mockResolvedValue(undefined),
    ...overrides,
  };
}

function makeService() {
  const candidates = new Map<EntityType, RawCandidatePair[]>();
  const setCandidates = (entityType: EntityType, pairs: RawCandidatePair[]) => candidates.set(entityType, pairs);
  const repo = {
    filterBookIdsByScope: vi.fn().mockImplementation((ids: number[]) => Promise.resolve(ids)),
    getDismissedPairSet: vi.fn().mockResolvedValue(new Set<string>()),
    getInlineDismissedPairSet: vi.fn().mockResolvedValue(new Set<string>()),
    insertDismissedPair: vi.fn().mockResolvedValue(undefined),
    deleteDismissedPair: vi.fn().mockResolvedValue(undefined),
    deleteDismissedPairsForEntity: vi.fn().mockResolvedValue(undefined),
    insertInlineDismissedPair: vi.fn().mockResolvedValue(undefined),
    deleteInlineDismissedPair: vi.fn().mockResolvedValue(undefined),
    deleteInlineDismissedPairsForValue: vi.fn().mockResolvedValue(undefined),
    findDismissedPairs: vi.fn().mockResolvedValue([]),
    findInlineDismissedPairs: vi.fn().mockResolvedValue([]),
    findDismissedPairsPage: vi.fn().mockResolvedValue({ items: [], total: 0 }),
    findClusterEntities: vi
      .fn()
      .mockImplementation((_type: EntityType, ids: (number | string)[]) =>
        Promise.resolve(ids.map((id) => ({ id, name: typeof id === 'string' ? id : `Entity ${id}`, bookCount: 1, bookTitles: [] }))),
      ),
  };

  const libraryService = {
    findAccessibleLibraryIds: vi.fn().mockResolvedValue([1, 2]),
  };

  const fileWriteService = {
    writeToFile: vi.fn().mockResolvedValue(undefined),
    scheduleWrite: vi.fn(),
  };
  const metadataScoreService = {
    calculateAndSaveMany: vi.fn().mockResolvedValue(undefined),
  };

  const duplicateCompute = {
    withCandidateBatches: vi
      .fn()
      .mockImplementation(
        async (
          type: EntityType,
          _similarity: number,
          scope: { libraryIds: number[] },
          consume: (pairs: RawCandidatePair[]) => void,
          afterRead: (replay: (consumer: (pairs: RawCandidatePair[]) => void) => Promise<void>) => Promise<unknown>,
        ) => {
          const pairs = scope.libraryIds.length > 0 ? (candidates.get(type) ?? []) : [];
          const read = (consumer: (batch: RawCandidatePair[]) => void) => {
            for (let offset = 0; offset < pairs.length; offset += 2) consumer(pairs.slice(offset, offset + 2));
            return Promise.resolve();
          };
          await read(consume);
          return afterRead(read);
        },
      ),
    countScopedCandidates: vi.fn().mockResolvedValue(0),
    getStatus: vi.fn().mockResolvedValue(null),
    triggerCompute: vi.fn(),
    invalidateCandidatesForEntities: vi.fn().mockResolvedValue(undefined),
  };

  const authorStrategy = mockStrategy({ entityType: 'author', isInline: false });
  const genreStrategy = mockStrategy({ entityType: 'genre', isInline: false });
  const tagStrategy = mockStrategy({ entityType: 'tag', isInline: false });
  const narratorStrategy = mockStrategy({ entityType: 'narrator', isInline: false });
  const publisherStrategy = mockStrategy({ entityType: 'publisher', isInline: true });
  const languageStrategy = mockStrategy({ entityType: 'language', isInline: true });
  const seriesStrategy = mockStrategy({ entityType: 'series', isInline: false });

  const service = new EntityManagerService(
    repo as any,
    libraryService as any,
    fileWriteService as any,
    metadataScoreService as any,
    duplicateCompute as any,
    authorStrategy as any,
    genreStrategy as any,
    tagStrategy as any,
    narratorStrategy as any,
    publisherStrategy as any,
    languageStrategy as any,
    seriesStrategy as any,
  );

  return {
    service,
    setCandidates,
    repo,
    libraryService,
    fileWriteService,
    metadataScoreService,
    duplicateCompute,
    strategies: {
      author: authorStrategy,
      genre: genreStrategy,
      tag: tagStrategy,
      narrator: narratorStrategy,
      publisher: publisherStrategy,
      language: languageStrategy,
      series: seriesStrategy,
    },
  };
}

const mockUser: RequestUser = { id: 1, username: 'test', isSuperuser: false, permissions: [], contentFilters: EMPTY_CONTENT_FILTER_RULES };

describe('EntityManagerService', () => {
  describe('getStrategy', () => {
    it('returns strategy for valid entity type', () => {
      const { service } = makeService();
      expect(service.getStrategy('author')).toBeDefined();
      expect(service.getStrategy('genre')).toBeDefined();
      expect(service.getStrategy('publisher')).toBeDefined();
      expect(service.getStrategy('series')).toBeDefined();
    });

    it('throws for unknown entity type', () => {
      const { service } = makeService();
      expect(() => service.getStrategy('unknown' as EntityType)).toThrow(BadRequestException);
    });
  });

  describe('scanDuplicates', () => {
    it('diagnoses a nonempty 50000-member cached component through cursor replay and bounded page enrichment', async () => {
      const { service, duplicateCompute, repo } = makeService();
      const dialect = new PgDialect();
      let cursor = 0;
      let maximumParams = 0;
      let fetches = 0;
      let declarations = 0;
      const execute = vi.fn((statement: SQL) => {
        const query = dialect.sqlToQuery(statement);
        maximumParams = Math.max(maximumParams, query.params.length);
        if (query.sql.startsWith('DECLARE')) {
          cursor = 0;
          declarations++;
        }
        if (query.sql.startsWith('FETCH')) {
          fetches++;
          const count = Math.min(500, Math.max(0, 49999 - cursor));
          const rows = Array.from({ length: count }, (_, index) => ({
            idA: cursor + index + 1,
            idB: cursor + index + 2,
            nameA: '',
            nameB: '',
            simScore: 0.99,
          }));
          cursor += count;
          return Promise.resolve({ rows });
        }
        if (query.sql.includes('WITH scoped AS MATERIALIZED')) {
          const identities = [...new Set(query.params.filter((value): value is number => typeof value === 'number'))];
          return Promise.resolve({
            rows: identities.map((id) => ({ id, name: `EntityScaling-${String(id).padStart(5, '0')}`, bookCount: 1, bookTitles: ['Book'] })),
          });
        }
        return Promise.resolve({ rows: [] });
      });
      const db = { execute, transaction: vi.fn((work: (tx: { execute: typeof execute }) => Promise<unknown>) => work({ execute })) };
      const actualCompute = new DuplicateComputeService(db as never);
      const actualRepository = new EntityManagerRepository(db as never);
      duplicateCompute.withCandidateBatches.mockImplementation(actualCompute.withCandidateBatches.bind(actualCompute));
      duplicateCompute.getStatus.mockResolvedValue({ isComputing: false, computedAt: new Date(), threshold: 0.1 } as never);
      repo.findClusterEntities.mockImplementation(actualRepository.findClusterEntities.bind(actualRepository));

      const scan = await service.scanDuplicates('genre', mockUser, undefined, 0.98, 1, 20);
      const first = scan.clusters[0]!;
      expect(scan).toMatchObject({ totalEntities: 50000, total: 1 });
      expect(first).toMatchObject({ entityTotal: 50000, pairTotal: 49999, nextPage: 2 });
      expect(first.entities).toHaveLength(10);
      expect(first.pairDetails).toHaveLength(10);
      expect(Buffer.byteLength(JSON.stringify(scan))).toBeLessThan(1024 * 1024);
      const last = await service.getDuplicateClusterPage('genre', mockUser, first.clusterId, 5000, 10);
      expect(last).toMatchObject({ entityTotal: 50000, pairTotal: 49999, nextPage: null });
      expect(last.entities).toHaveLength(10);
      expect(last.pairDetails).toHaveLength(9);
      expect(Buffer.byteLength(JSON.stringify(last))).toBeLessThan(1024 * 1024);
      expect(maximumParams).toBeLessThanOrEqual(30);
      expect(declarations).toBe(4);
      expect(fetches).toBe(404);
      expect(duplicateCompute.triggerCompute).not.toHaveBeenCalled();
    });

    it('returns empty clusters when no pairs found', async () => {
      const { service } = makeService();
      await expect(service.scanDuplicates('author', mockUser)).resolves.toEqual({
        entityType: 'author',
        clusters: [],
        totalEntities: 0,
        total: 0,
        page: 1,
        pageSize: 20,
      });
    });

    it('filters by library when libraryId provided for inline entities', async () => {
      const { service, libraryService, duplicateCompute } = makeService();
      libraryService.findAccessibleLibraryIds.mockResolvedValue([1, 2, 3]);
      await service.scanDuplicates('publisher', mockUser, 2);
      expect(duplicateCompute.withCandidateBatches).toHaveBeenCalledWith(
        'publisher',
        0.5,
        { libraryIds: [2], contentFilters: EMPTY_CONTENT_FILTER_RULES },
        expect.any(Function),
        expect.any(Function),
      );
    });

    it('throws when library not accessible', async () => {
      const { service } = makeService();
      await expect(service.scanDuplicates('publisher', mockUser, 99)).rejects.toThrow(BadRequestException);
    });

    it('uses custom minSimilarity for inline entities', async () => {
      const { service, duplicateCompute } = makeService();
      await service.scanDuplicates('publisher', mockUser, undefined, 0.8);
      expect(duplicateCompute.withCandidateBatches).toHaveBeenCalledWith(
        'publisher',
        0.8,
        { libraryIds: [1, 2], contentFilters: EMPTY_CONTENT_FILTER_RULES },
        expect.any(Function),
        expect.any(Function),
      );
    });

    it('builds clusters from overlapping inline pairs across batches', async () => {
      const { service, setCandidates } = makeService();
      setCandidates('publisher', [
        { idA: 'A', idB: 'B', nameA: 'A', nameB: 'B', simScore: 0.9 },
        { idA: 'C', idB: 'D', nameA: 'C', nameB: 'D', simScore: 0.8 },
        { idA: 'B', idB: 'C', nameA: 'B', nameB: 'C', simScore: 0.85 },
      ]);
      const result = await service.scanDuplicates('publisher', mockUser);
      expect(result.clusters).toHaveLength(1);
      expect(result.clusters[0]!.entities.map((entity) => entity.id)).toEqual(['A', 'B', 'C', 'D']);
      expect(result.clusters[0]!.averageSimilarity).toBe(0.85);
      expect(result.totalEntities).toBe(4);
    });

    it('separates non-overlapping inline pairs into different clusters', async () => {
      const { service, setCandidates } = makeService();
      setCandidates('publisher', [
        { idA: 'A', idB: 'B', nameA: 'A', nameB: 'B', simScore: 0.9 },
        { idA: 'C', idB: 'D', nameA: 'C', nameB: 'D', simScore: 0.8 },
      ]);
      expect((await service.scanDuplicates('publisher', mockUser)).clusters).toHaveLength(2);
    });

    it('suggests target as entity with highest book count', async () => {
      const { service, setCandidates, repo } = makeService();
      setCandidates('author', [{ idA: 1, idB: 2, nameA: '', nameB: '', simScore: 0.9 }]);
      repo.findClusterEntities.mockResolvedValue([
        { id: 1, name: 'First', bookCount: 3, bookTitles: [] },
        { id: 2, name: 'Second', bookCount: 10, bookTitles: [] },
      ]);
      expect((await service.scanDuplicates('author', mockUser)).clusters[0]!.suggestedTargetId).toBe(2);
    });

    it('skips clusters where entities are not found', async () => {
      const { service, setCandidates, repo } = makeService();
      setCandidates('author', [{ idA: 1, idB: 2, nameA: '', nameB: '', simScore: 0.9 }]);
      repo.findClusterEntities.mockResolvedValue([]);
      expect((await service.scanDuplicates('author', mockUser)).clusters).toHaveLength(0);
    });

    it('sorts inline clusters by average similarity descending', async () => {
      const { service, setCandidates } = makeService();
      setCandidates('publisher', [
        { idA: 'A', idB: 'B', nameA: 'A', nameB: 'B', simScore: 0.7 },
        { idA: 'C', idB: 'D', nameA: 'C', nameB: 'D', simScore: 0.95 },
      ]);
      const result = await service.scanDuplicates('publisher', mockUser);
      expect(result.clusters.map((cluster) => cluster.averageSimilarity)).toEqual([0.95, 0.7]);
    });

    it('paginates clusters and returns stable totals and distinct pages', async () => {
      const { service, setCandidates } = makeService();
      setCandidates('publisher', [
        { idA: 'A', idB: 'B', nameA: 'A', nameB: 'B', simScore: 0.9 },
        { idA: 'C', idB: 'D', nameA: 'C', nameB: 'D', simScore: 0.8 },
        { idA: 'E', idB: 'F', nameA: 'E', nameB: 'F', simScore: 0.7 },
      ]);
      const first = await service.scanDuplicates('publisher', mockUser, undefined, undefined, 1, 2);
      const second = await service.scanDuplicates('publisher', mockUser, undefined, undefined, 2, 2);
      expect(first).toMatchObject({ total: 3, page: 1, pageSize: 2 });
      expect(first.clusters).toHaveLength(2);
      expect(second).toMatchObject({ total: 3, page: 2, pageSize: 2 });
      expect(second.clusters).toHaveLength(1);
      expect(first.clusters.map((cluster) => cluster.clusterId)).not.toContain(second.clusters[0]!.clusterId);
      await expect(service.scanDuplicates('publisher', mockUser, undefined, undefined, 2, 2)).resolves.toEqual(second);
    });

    it('clamps out-of-bounds page to last valid page', async () => {
      const { service, setCandidates } = makeService();
      setCandidates('publisher', [{ idA: 'A', idB: 'B', nameA: 'A', nameB: 'B', simScore: 0.9 }]);
      const result = await service.scanDuplicates('publisher', mockUser, undefined, undefined, 99, 20);
      expect(result.page).toBe(1);
      expect(result.clusters).toHaveLength(1);
    });

    it('builds non-inline clusters from stored candidate batches', async () => {
      const { service, setCandidates } = makeService();
      setCandidates('author', [
        { idA: 1, idB: 2, nameA: '', nameB: '', simScore: 0.92 },
        { idA: 2, idB: 3, nameA: '', nameB: '', simScore: 0.88 },
      ]);
      const result = await service.scanDuplicates('author', mockUser);
      expect(result.clusters).toHaveLength(1);
      expect(result.clusters[0]!.entities.map((entity) => entity.id)).toEqual([1, 2, 3]);
      expect(result.clusters[0]!.pairDetails.map((pair) => pair.similarity)).toEqual([0.92, 0.88]);
    });

    it('uses only the explicitly requested accessible library for stored candidates and enrichment', async () => {
      const { service, setCandidates, duplicateCompute, libraryService, repo } = makeService();
      libraryService.findAccessibleLibraryIds.mockResolvedValue([4, 7]);
      setCandidates('author', [{ idA: 1, idB: 2, nameA: '', nameB: '', simScore: 0.9 }]);
      await service.scanDuplicates('author', mockUser, 7);
      const scope = { libraryIds: [7], contentFilters: EMPTY_CONTENT_FILTER_RULES };
      expect(duplicateCompute.withCandidateBatches).toHaveBeenCalledWith('author', 0.5, scope, expect.any(Function), expect.any(Function));
      expect(repo.findClusterEntities).toHaveBeenCalledWith('author', [1, 2], scope);
    });

    it('returns no candidates when the user has no accessible libraries', async () => {
      const { service, setCandidates, duplicateCompute, libraryService } = makeService();
      libraryService.findAccessibleLibraryIds.mockResolvedValue([]);
      setCandidates('author', [{ idA: 1, idB: 2, nameA: '', nameB: '', simScore: 0.9 }]);
      await expect(service.scanDuplicates('author', mockUser)).resolves.toMatchObject({ clusters: [], total: 0, totalEntities: 0 });
      expect(duplicateCompute.triggerCompute).not.toHaveBeenCalled();
    });

    it('triggers duplicate compute with the requested threshold when no status exists', async () => {
      const { service, duplicateCompute, strategies } = makeService();
      await service.scanDuplicates('author', mockUser, undefined, 0.73);
      expect(duplicateCompute.triggerCompute).toHaveBeenCalledWith('author', strategies.author, 0.73);
    });

    it('triggers duplicate compute when stored threshold is higher than requested', async () => {
      const { service, duplicateCompute, strategies } = makeService();
      duplicateCompute.getStatus.mockResolvedValue({ isComputing: false, computedAt: new Date('2024-01-01'), threshold: 0.9 } as never);
      await service.scanDuplicates('author', mockUser, undefined, 0.7);
      expect(duplicateCompute.triggerCompute).toHaveBeenCalledWith('author', strategies.author, 0.7);
    });

    it('does not trigger duplicate compute when stored threshold already covers the request', async () => {
      const { service, duplicateCompute } = makeService();
      duplicateCompute.getStatus.mockResolvedValue({ isComputing: false, computedAt: new Date('2024-01-01'), threshold: 0.6 } as never);
      await service.scanDuplicates('author', mockUser, undefined, 0.7);
      expect(duplicateCompute.triggerCompute).not.toHaveBeenCalled();
    });

    it('uses entity names when computing reasons for stored pairs', async () => {
      const { service, setCandidates, repo } = makeService();
      setCandidates('author', [{ idA: 1, idB: 2, nameA: '', nameB: '', simScore: 0.75 }]);
      repo.findClusterEntities.mockResolvedValue([
        { id: 1, name: 'young adult', bookCount: 1, bookTitles: [] },
        { id: 2, name: 'Adult Young', bookCount: 1, bookTitles: [] },
      ]);
      expect((await service.scanDuplicates('author', mockUser)).clusters[0]!.pairDetails[0]!.reasons).toContain('Same normalized tokens');
    });
  });

  describe('getDuplicateClusterPage', () => {
    it('exposes remaining members and pairs without accumulating the first page', async () => {
      const { service, setCandidates } = makeService();
      setCandidates(
        'publisher',
        Array.from({ length: 11 }, (_, index) => ({
          idA: `A${String(index).padStart(2, '0')}`,
          idB: `A${String(index + 1).padStart(2, '0')}`,
          nameA: '',
          nameB: '',
          simScore: 0.9,
        })),
      );
      const cluster = (await service.scanDuplicates('publisher', mockUser)).clusters[0]!;
      expect(cluster).toMatchObject({ entityTotal: 12, pairTotal: 11, nextPage: 2, detailsPageSize: 10 });
      expect(cluster.entities).toHaveLength(10);
      const second = await service.getDuplicateClusterPage('publisher', mockUser, cluster.clusterId, 2, 10);
      expect(second).toMatchObject({ entityTotal: 12, pairTotal: 11, page: 2, pageSize: 10, nextPage: null });
      expect(second.entities.map((entity) => entity.id)).toEqual(['A10', 'A11']);
      expect(second.pairDetails).toEqual([
        { idA: 'A10', idB: 'A11', nameA: 'A10', nameB: 'A11', similarity: 0.9, reasons: ['Very high name similarity'] },
      ]);
    });

    it('rejects an invalid cluster cursor', async () => {
      const { service } = makeService();
      await expect(service.getDuplicateClusterPage('publisher', mockUser, 'invalid', 1, 10)).rejects.toThrow(BadRequestException);
    });
  });

  describe('getDuplicateScanStatus', () => {
    it('returns idle when no status row exists', async () => {
      const { service, duplicateCompute } = makeService();
      duplicateCompute.getStatus.mockResolvedValue(null);

      await expect(service.getDuplicateScanStatus('author')).resolves.toEqual({
        entityType: 'author',
        state: 'idle',
        computedAt: null,
        totalPairs: null,
        threshold: null,
        progressPct: null,
      });
    });

    it('returns computing with progress percentage', async () => {
      const { service, duplicateCompute } = makeService();
      duplicateCompute.getStatus.mockResolvedValue({
        entityType: 'author',
        isComputing: true,
        computedAt: null,
        totalPairs: null,
        threshold: 0.7,
        totalCount: 20,
        processedCount: 5,
        errorMessage: null,
      });

      await expect(service.getDuplicateScanStatus('author')).resolves.toEqual({
        entityType: 'author',
        state: 'computing',
        computedAt: null,
        totalPairs: null,
        threshold: 0.7,
        progressPct: 25,
      });
    });

    it('returns done when computation completed', async () => {
      const { service, duplicateCompute } = makeService();
      duplicateCompute.getStatus.mockResolvedValue({
        entityType: 'author',
        isComputing: false,
        computedAt: new Date('2024-01-01T00:00:00.000Z'),
        totalPairs: 12,
        threshold: 0.8,
        totalCount: 20,
        processedCount: 20,
        errorMessage: null,
      });

      await expect(service.getDuplicateScanStatus('author')).resolves.toEqual({
        entityType: 'author',
        state: 'done',
        computedAt: '2024-01-01T00:00:00.000Z',
        totalPairs: 12,
        threshold: 0.8,
        progressPct: null,
      });
    });

    it('returns error when the last compute failed', async () => {
      const { service, duplicateCompute } = makeService();
      duplicateCompute.getStatus.mockResolvedValue({
        entityType: 'author',
        isComputing: false,
        computedAt: null,
        totalPairs: null,
        threshold: 0.7,
        totalCount: 20,
        processedCount: 4,
        errorMessage: 'boom',
      });

      await expect(service.getDuplicateScanStatus('author')).resolves.toEqual({
        entityType: 'author',
        state: 'error',
        computedAt: null,
        totalPairs: null,
        threshold: 0.7,
        progressPct: null,
      });
    });

    it('returns the visible pair count for the current user', async () => {
      const { service, duplicateCompute } = makeService();
      duplicateCompute.getStatus.mockResolvedValue({
        entityType: 'author',
        isComputing: false,
        computedAt: new Date('2024-01-01'),
        totalPairs: 12,
        threshold: 0.8,
        totalCount: 20,
        processedCount: 20,
        errorMessage: null,
      });
      duplicateCompute.countScopedCandidates.mockResolvedValue(2);
      expect(await service.getDuplicateScanStatus('author', mockUser)).toMatchObject({ state: 'done', totalPairs: 2 });
      expect(duplicateCompute.countScopedCandidates).toHaveBeenCalledWith('author', {
        libraryIds: [1, 2],
        contentFilters: EMPTY_CONTENT_FILTER_RULES,
      });
    });

    it('returns done immediately for inline entity types', async () => {
      const { service, duplicateCompute } = makeService();

      await expect(service.getDuplicateScanStatus('publisher')).resolves.toEqual({
        entityType: 'publisher',
        state: 'done',
        computedAt: null,
        totalPairs: null,
        threshold: null,
        progressPct: null,
      });
      expect(duplicateCompute.getStatus).not.toHaveBeenCalled();
    });
  });

  describe('refreshDuplicates', () => {
    it('calls triggerCompute for non-inline entities and returns status', async () => {
      const { service, duplicateCompute, strategies } = makeService();
      duplicateCompute.getStatus.mockResolvedValue({
        entityType: 'author',
        isComputing: true,
        computedAt: null,
        totalPairs: null,
        threshold: 0.72,
        totalCount: 10,
        processedCount: 1,
        errorMessage: null,
      });

      const result = await service.refreshDuplicates('author', 0.72);

      expect(duplicateCompute.triggerCompute).toHaveBeenCalledWith('author', strategies.author, 0.72);
      expect(result).toEqual({
        entityType: 'author',
        state: 'computing',
        computedAt: null,
        totalPairs: null,
        threshold: 0.72,
        progressPct: 10,
      });
    });

    it('does not call triggerCompute for inline entities', async () => {
      const { service, duplicateCompute } = makeService();

      const result = await service.refreshDuplicates('publisher', 0.72);

      expect(duplicateCompute.triggerCompute).not.toHaveBeenCalled();
      expect(result).toEqual({
        entityType: 'publisher',
        state: 'done',
        computedAt: null,
        totalPairs: null,
        threshold: null,
        progressPct: null,
      });
    });
  });

  describe('browse', () => {
    it('delegates to strategy with default params', async () => {
      const { service, strategies } = makeService();
      (strategies.author.browse as any).mockResolvedValue({
        items: [{ id: 1, name: 'Author', bookCount: 5 }],
        total: 1,
      });

      const result = await service.browse('author', mockUser, {});

      expect(strategies.author.browse).toHaveBeenCalledWith({
        libraryIds: [1, 2],
        search: undefined,
        page: 1,
        pageSize: 25,
        sortBy: 'name',
        sortOrder: 'asc',
        bookCount: 'any',
        contentFilters: EMPTY_CONTENT_FILTER_RULES,
      });
      expect(result.items).toHaveLength(1);
      expect(result.total).toBe(1);
      expect(result.page).toBe(1);
      expect(result.pageSize).toBe(25);
    });

    it('passes custom params', async () => {
      const { service, strategies } = makeService();
      (strategies.tag.browse as any).mockResolvedValue({ items: [], total: 0 });

      await service.browse('tag', mockUser, {
        search: 'fic',
        page: 2,
        pageSize: 50,
        sortBy: 'bookCount',
        sortOrder: 'desc',
        bookCount: 'empty',
      });

      expect(strategies.tag.browse).toHaveBeenCalledWith({
        libraryIds: [1, 2],
        search: 'fic',
        page: 2,
        pageSize: 50,
        sortBy: 'bookCount',
        sortOrder: 'desc',
        bookCount: 'empty',
        contentFilters: EMPTY_CONTENT_FILTER_RULES,
      });
    });

    it('does not pass empty book count filtering to inline strategies', async () => {
      const { service, strategies } = makeService();
      (strategies.publisher.browse as any).mockResolvedValue({ items: [], total: 0 });

      await service.browse('publisher', mockUser, { bookCount: 'empty' });

      expect(strategies.publisher.browse).toHaveBeenCalledWith(expect.objectContaining({ bookCount: 'any' }));
    });
  });

  describe('merge', () => {
    it('calls strategy merge and cleans up dismissed pairs for first-class', async () => {
      const { service, strategies, repo, duplicateCompute, metadataScoreService } = makeService();
      (strategies.author.merge as any).mockResolvedValue({
        affectedBookIds: [10, 20],
        imagePromoted: true,
        fieldsResolved: ['sortName'],
      });

      const result = await service.merge('author', mockUser, 1, [2, 3], false);

      expect(strategies.author.merge).toHaveBeenCalledWith(
        expect.objectContaining({
          targetId: 1,
          sourceIds: [2, 3],
          userId: 1,
          libraryIds: [1, 2],
          contentFilters: EMPTY_CONTENT_FILTER_RULES,
        }),
      );
      expect(repo.deleteDismissedPairsForEntity).toHaveBeenCalledTimes(2);
      expect(repo.deleteDismissedPairsForEntity).toHaveBeenCalledWith('author', 2);
      expect(repo.deleteDismissedPairsForEntity).toHaveBeenCalledWith('author', 3);
      expect(duplicateCompute.invalidateCandidatesForEntities).toHaveBeenCalledTimes(1);
      expect(duplicateCompute.invalidateCandidatesForEntities).toHaveBeenCalledWith('author', [2, 3]);
      expect(metadataScoreService.calculateAndSaveMany).toHaveBeenCalledWith([10, 20]);
      expect(result).toEqual({
        targetId: 1,
        mergedIds: [2, 3],
        affectedBookCount: 2,
        imagePromoted: true,
        fieldsResolved: ['sortName'],
      });
    });

    it('streams the captured books after transactional scoring with at most five file writes at once', async () => {
      const { service, strategies, fileWriteService, metadataScoreService, repo } = makeService();
      const executor = { execute: vi.fn() };
      const dispose = vi.fn().mockResolvedValue(undefined);
      let writing = 0;
      let peakWriting = 0;
      let written = 0;
      fileWriteService.writeToFile.mockImplementation(async () => {
        writing++;
        peakWriting = Math.max(peakWriting, writing);
        await Promise.resolve();
        writing--;
        written++;
      });
      vi.mocked(strategies.author.merge).mockImplementation(async (input) => {
        await input.onBooksChanged!([1, 2], executor);
        return {
          affectedBookIds: [],
          affectedBookCount: 1201,
          affectedBookBatches: async function* () {
            for (let offset = 0; offset < 1201; offset += 500)
              yield await Promise.resolve(Array.from({ length: Math.min(500, 1201 - offset) }, (_, index) => offset + index + 1));
          },
          disposeAffectedBooks: dispose,
        };
      });

      const result = await service.merge('author', mockUser, 1, [2], true);

      expect(result.affectedBookCount).toBe(1201);
      expect(metadataScoreService.calculateAndSaveMany).toHaveBeenCalledExactlyOnceWith([1, 2], executor);
      expect(repo.filterBookIdsByScope).toHaveBeenCalledTimes(3);
      expect(written).toBe(1201);
      expect(peakWriting).toBe(5);
      expect(fileWriteService.scheduleWrite).not.toHaveBeenCalled();
      expect(dispose).toHaveBeenCalledOnce();
    });

    it('writes captured books even when the edit removes a genre required by the content filter', async () => {
      const { service, strategies, fileWriteService, repo } = makeService();
      const dispose = vi.fn().mockResolvedValue(undefined);
      const filteredUser = { ...mockUser, contentFilters: { ...EMPTY_CONTENT_FILTER_RULES, includeGenreIds: [8] } };
      repo.filterBookIdsByScope.mockImplementation((ids: number[], scope: { libraryIds: number[]; contentFilters?: unknown }) =>
        Promise.resolve(scope.libraryIds.includes(1) && !scope.contentFilters ? ids : []),
      );
      (strategies.genre.merge as ReturnType<typeof vi.fn>).mockResolvedValue({
        affectedBookIds: [],
        affectedBookCount: 1,
        affectedBookBatches: async function* () {
          yield await Promise.resolve([7]);
        },
        disposeAffectedBooks: dispose,
      });
      await service.merge('genre', filteredUser, 9, [8], true);
      expect(fileWriteService.writeToFile).toHaveBeenCalledExactlyOnceWith(7, 'auto', filteredUser.id);
      expect(dispose).toHaveBeenCalledOnce();
    });

    it('skips file writes when access to the captured library is revoked after commit', async () => {
      const { service, strategies, fileWriteService, libraryService, repo } = makeService();
      const dispose = vi.fn().mockResolvedValue(undefined);
      libraryService.findAccessibleLibraryIds.mockResolvedValueOnce([1, 2]).mockResolvedValue([]);
      repo.filterBookIdsByScope.mockImplementation((ids: number[], scope: { libraryIds: number[] }) =>
        Promise.resolve(scope.libraryIds.includes(1) ? ids : []),
      );
      vi.mocked(strategies.genre.merge).mockResolvedValue({
        affectedBookIds: [],
        affectedBookCount: 1,
        affectedBookBatches: async function* () {
          yield await Promise.resolve([7]);
        },
        disposeAffectedBooks: dispose,
      });
      const result = await service.merge('genre', mockUser, 9, [8], true);
      expect(result.affectedBookCount).toBe(1);
      expect(fileWriteService.writeToFile).not.toHaveBeenCalled();
      expect(repo.filterBookIdsByScope).toHaveBeenCalledWith([7], { libraryIds: [] });
      expect(dispose).toHaveBeenCalledOnce();
    });

    it('disposes captured book batches when a file write fails after commit', async () => {
      const { service, strategies, fileWriteService } = makeService();
      const dispose = vi.fn().mockResolvedValue(undefined);
      fileWriteService.writeToFile.mockRejectedValue(new Error('Write failed'));
      (strategies.author.merge as ReturnType<typeof vi.fn>).mockResolvedValue({
        affectedBookIds: [],
        affectedBookCount: 1,
        affectedBookBatches: async function* () {
          yield await Promise.resolve([7]);
        },
        disposeAffectedBooks: dispose,
      });
      await expect(service.merge('author', mockUser, 1, [2], true)).rejects.toThrow('Write failed');
      expect(dispose).toHaveBeenCalledOnce();
    });

    it('propagates score persistence failures', async () => {
      const { service, strategies, metadataScoreService } = makeService();
      (strategies.author.merge as any).mockResolvedValue({ affectedBookIds: [10] });
      metadataScoreService.calculateAndSaveMany.mockRejectedValue(new Error('score failed'));

      await expect(service.merge('author', mockUser, 1, [2], false)).rejects.toThrow('score failed');
    });

    it('invalidates candidate rows once for all merged source IDs', async () => {
      const { service, strategies, duplicateCompute } = makeService();
      (strategies.author.merge as any).mockResolvedValue({ affectedBookIds: [] });

      await service.merge('author', mockUser, 1, [2, 3, 4], false);

      expect(duplicateCompute.invalidateCandidatesForEntities).toHaveBeenCalledTimes(1);
      expect(duplicateCompute.invalidateCandidatesForEntities).toHaveBeenCalledWith('author', [2, 3, 4]);
    });

    it('cleans up inline dismissed pairs for inline entities', async () => {
      const { service, strategies, repo, duplicateCompute } = makeService();
      (strategies.publisher.merge as any).mockResolvedValue({ affectedBookIds: [5] });

      await service.merge('publisher', mockUser, 'Pub A', ['Pub B'], false);

      expect(repo.deleteInlineDismissedPairsForValue).toHaveBeenCalledWith('publisher', 'Pub B');
      expect(repo.deleteDismissedPairsForEntity).not.toHaveBeenCalled();
      expect(duplicateCompute.invalidateCandidatesForEntities).not.toHaveBeenCalled();
    });

    it('schedules file writes when writeFiles is true', async () => {
      const { service, strategies, fileWriteService } = makeService();
      (strategies.genre.merge as any).mockResolvedValue({ affectedBookIds: [10, 20, 10] });

      await service.merge('genre', mockUser, 1, [2], true);

      expect(fileWriteService.scheduleWrite).toHaveBeenCalledTimes(2);
      expect(fileWriteService.scheduleWrite).toHaveBeenCalledWith(10, 'auto', 1);
      expect(fileWriteService.scheduleWrite).toHaveBeenCalledWith(20, 'auto', 1);
    });

    it('does not schedule file writes when writeFiles is false', async () => {
      const { service, strategies, fileWriteService } = makeService();
      (strategies.genre.merge as any).mockResolvedValue({ affectedBookIds: [10] });

      await service.merge('genre', mockUser, 1, [2], false);

      expect(fileWriteService.scheduleWrite).not.toHaveBeenCalled();
    });
  });

  describe('rename', () => {
    it('calls strategy rename and returns result', async () => {
      const { service, strategies } = makeService();
      (strategies.tag.rename as any).mockResolvedValue({
        oldName: 'OldTag',
        affectedBookIds: [5, 6],
        wasImplicitMerge: false,
      });

      const result = await service.rename('tag', mockUser, 1, ' NewTag ', false);

      expect(strategies.tag.rename).toHaveBeenCalledWith(
        expect.objectContaining({
          entityId: 1,
          newName: ' NewTag ',
          userId: 1,
          libraryIds: [1, 2],
          contentFilters: EMPTY_CONTENT_FILTER_RULES,
        }),
      );
      expect(result).toEqual({
        entityId: 1,
        oldName: 'OldTag',
        newName: 'NewTag',
        affectedBookCount: 2,
        wasImplicitMerge: false,
        mergedEntityId: undefined,
      });
    });

    it('schedules file writes when writeFiles is true', async () => {
      const { service, strategies, fileWriteService } = makeService();
      (strategies.tag.rename as any).mockResolvedValue({
        oldName: 'Old',
        affectedBookIds: [1],
        wasImplicitMerge: false,
      });

      await service.rename('tag', mockUser, 1, 'New', true);
      expect(fileWriteService.scheduleWrite).toHaveBeenCalledWith(1, 'auto', 1);
    });
  });

  describe('deleteEntity', () => {
    it('calls strategy delete and cleans dismissed pairs for hard delete', async () => {
      const { service, strategies, repo } = makeService();
      (strategies.genre.deleteEntity as any).mockResolvedValue({ name: 'Fantasy', affectedBookIds: [1, 2] });

      const result = await service.deleteEntity('genre', mockUser, 5, 'hard', false);

      expect(strategies.genre.deleteEntity).toHaveBeenCalledWith(
        expect.objectContaining({
          entityId: 5,
          mode: 'hard',
          libraryIds: [1, 2],
          contentFilters: EMPTY_CONTENT_FILTER_RULES,
        }),
      );
      expect(repo.deleteDismissedPairsForEntity).toHaveBeenCalledWith('genre', 5);
      expect(result).toEqual({ entityId: 5, name: 'Fantasy', affectedBookCount: 2, mode: 'hard' });
    });

    it('does not clean dismissed pairs for soft delete', async () => {
      const { service, strategies, repo } = makeService();
      (strategies.genre.deleteEntity as any).mockResolvedValue({ name: 'Fantasy', affectedBookIds: [] });
      (strategies.genre.getBookCount as any).mockResolvedValue(2);

      await service.deleteEntity('genre', mockUser, 5, 'soft', false);

      expect(strategies.genre.deleteEntity).toHaveBeenCalledWith(
        expect.objectContaining({
          entityId: 5,
          mode: 'soft',
          libraryIds: [1, 2],
          contentFilters: EMPTY_CONTENT_FILTER_RULES,
        }),
      );
      expect(repo.deleteDismissedPairsForEntity).not.toHaveBeenCalled();
    });

    it('uses hard delete for zero-book first-class entities requested as soft delete', async () => {
      const { service, strategies, repo, duplicateCompute } = makeService();
      (strategies.author.deleteEntity as any).mockResolvedValue({ name: 'Unused', affectedBookIds: [] });
      (strategies.author.getBookCount as any).mockResolvedValue(0);

      const result = await service.deleteEntity('author', mockUser, 5, 'soft', false);

      expect(strategies.author.deleteEntity).toHaveBeenCalledWith(
        expect.objectContaining({
          entityId: 5,
          mode: 'hard',
          libraryIds: [1, 2],
          contentFilters: EMPTY_CONTENT_FILTER_RULES,
        }),
      );
      expect(repo.deleteDismissedPairsForEntity).toHaveBeenCalledWith('author', 5);
      expect(duplicateCompute.invalidateCandidatesForEntities).toHaveBeenCalledWith('author', [5]);
      expect(result.mode).toBe('hard');
    });

    it('cleans inline dismissed pairs for inline entities', async () => {
      const { service, strategies, repo } = makeService();
      (strategies.language.deleteEntity as any).mockResolvedValue({ name: 'English', affectedBookIds: [3] });

      await service.deleteEntity('language', mockUser, 'English', 'inline', false);

      expect(repo.deleteInlineDismissedPairsForValue).toHaveBeenCalledWith('language', 'English');
      expect(repo.deleteDismissedPairsForEntity).not.toHaveBeenCalled();
    });

    it('schedules file writes when writeFiles is true', async () => {
      const { service, strategies, fileWriteService } = makeService();
      (strategies.genre.deleteEntity as any).mockResolvedValue({ name: 'Fantasy', affectedBookIds: [10] });

      await service.deleteEntity('genre', mockUser, 5, 'hard', true);

      expect(fileWriteService.scheduleWrite).toHaveBeenCalledWith(10, 'auto', 1);
    });
  });

  describe('bulkDelete', () => {
    it('deletes multiple entities and returns results', async () => {
      const { service, strategies } = makeService();
      (strategies.tag.deleteEntity as any).mockResolvedValue({ name: 'Tag', affectedBookIds: [] });

      const result = await service.bulkDelete('tag', mockUser, [1, 2, 3], 'hard', false);

      expect(result.results).toHaveLength(3);
      expect(result.errors).toHaveLength(0);
    });

    it('collects errors for individual failures', async () => {
      const { service, strategies } = makeService();
      (strategies.tag.deleteEntity as ReturnType<typeof vi.fn>)
        .mockResolvedValueOnce({ name: 'Tag1', affectedBookIds: [] })
        .mockRejectedValueOnce(new Error('Not found'))
        .mockResolvedValueOnce({ name: 'Tag3', affectedBookIds: [] });

      const result = await service.bulkDelete('tag', mockUser, [1, 2, 3], 'hard', false);

      expect(result.results).toHaveLength(2);
      expect(result.errors).toHaveLength(1);
      expect(result.errors[0]!.entityId).toBe(2);
    });
  });

  describe('split', () => {
    it('calls strategy split and cleans dismissed pairs', async () => {
      const { service, strategies, repo } = makeService();
      (strategies.author.split as any).mockResolvedValue({
        originalName: 'Author',
        newEntities: [
          { id: 10, name: 'Author A' },
          { id: 11, name: 'Author B' },
        ],
        affectedBookIds: [1, 2],
      });

      const result = await service.split('author', mockUser, 5, ['Author A', 'Author B'], false);

      expect(strategies.author.split).toHaveBeenCalledWith(
        expect.objectContaining({
          entityId: 5,
          newNames: ['Author A', 'Author B'],
          libraryIds: [1, 2],
          contentFilters: EMPTY_CONTENT_FILTER_RULES,
        }),
      );
      expect(repo.deleteDismissedPairsForEntity).toHaveBeenCalledWith('author', 5);
      expect(result).toEqual({
        originalId: 5,
        originalName: 'Author',
        newEntities: [
          { id: 10, name: 'Author A' },
          { id: 11, name: 'Author B' },
        ],
        affectedBookCount: 2,
      });
    });

    it('throws for inline entity types', async () => {
      const { service } = makeService();
      await expect(service.split('publisher', mockUser, 1, ['A', 'B'], false)).rejects.toThrow(BadRequestException);
    });

    it('throws when fewer than 2 new names', async () => {
      const { service } = makeService();
      await expect(service.split('author', mockUser, 1, ['Only one'], false)).rejects.toThrow(BadRequestException);
    });

    it('schedules file writes when writeFiles is true', async () => {
      const { service, strategies, fileWriteService } = makeService();
      (strategies.genre.split as any).mockResolvedValue({
        originalName: 'Genre',
        newEntities: [{ id: 10, name: 'A' }],
        affectedBookIds: [1, 2],
      });

      await service.split('genre', mockUser, 5, ['A', 'B'], true);

      expect(fileWriteService.scheduleWrite).toHaveBeenCalledTimes(2);
    });
  });

  describe('dismissPair', () => {
    it('inserts first-class dismissed pair', async () => {
      const { service, repo } = makeService();
      await service.dismissPair('author', mockUser, 1, 2, 'not same');

      expect(repo.insertDismissedPair).toHaveBeenCalledWith('author', 1, 2, 'not same', 1);
    });

    it('inserts inline dismissed pair', async () => {
      const { service, repo } = makeService();
      await service.dismissPair('publisher', mockUser, 'Pub A', 'Pub B', 'different');

      expect(repo.insertInlineDismissedPair).toHaveBeenCalledWith('publisher', 'Pub A', 'Pub B', 'different', 1);
    });
  });

  describe('undismissPair', () => {
    it('deletes first-class dismissed pair', async () => {
      const { service, repo } = makeService();
      await service.undismissPair('genre', mockUser, 1, 2);

      expect(repo.deleteDismissedPair).toHaveBeenCalledWith('genre', 1, 2);
    });

    it('deletes inline dismissed pair', async () => {
      const { service, repo } = makeService();
      await service.undismissPair('language', mockUser, 'en', 'eng');

      expect(repo.deleteInlineDismissedPair).toHaveBeenCalledWith('language', 'en', 'eng');
    });
  });

  describe('getDismissedPairs', () => {
    it('returns scoped named dismissed pairs for first-class entities', async () => {
      const { service, repo } = makeService();
      const pair: DismissedPairInfo = {
        id: 1,
        entityType: 'genre',
        idA: 10,
        idB: 20,
        nameA: 'Genre 10',
        nameB: 'Genre 20',
        reason: 'test',
        dismissedAt: '2024-01-01T00:00:00.000Z',
      };
      repo.findDismissedPairsPage.mockResolvedValue({ items: [pair], total: 1 });
      await expect(service.getDismissedPairs('genre', mockUser)).resolves.toEqual([pair]);
      expect(repo.findDismissedPairsPage).toHaveBeenCalledWith('genre', { libraryIds: [1, 2], contentFilters: EMPTY_CONTENT_FILTER_RULES }, 1, 100);
    });

    it('preserves the total and requested page when returning a bounded dismissed page', async () => {
      const { service, repo } = makeService();
      const pair: DismissedPairInfo = {
        id: 21,
        entityType: 'genre',
        idA: 30,
        idB: 40,
        nameA: 'Later A',
        nameB: 'Later B',
        reason: null,
        dismissedAt: '2024-06-01T00:00:00.000Z',
      };
      repo.findDismissedPairsPage.mockResolvedValue({ items: [pair], total: 21 });
      await expect(service.getDismissedPairsPage('genre', mockUser, 2, 20)).resolves.toEqual({ items: [pair], total: 21, page: 2, pageSize: 20 });
    });

    it('returns inline dismissed pairs directly', async () => {
      const { service, repo } = makeService();
      const pair: DismissedPairInfo = {
        id: 1,
        entityType: 'publisher',
        idA: 'Pub A',
        idB: 'Pub B',
        nameA: 'Pub A',
        nameB: 'Pub B',
        reason: null,
        dismissedAt: '2024-06-01T00:00:00.000Z',
      };
      repo.findDismissedPairsPage.mockResolvedValue({ items: [pair], total: 1 });
      await expect(service.getDismissedPairs('publisher', mockUser)).resolves.toEqual([pair]);
    });
  });

  describe('getEntityInfo', () => {
    it('returns entity info with book count and titles', async () => {
      const { service, strategies } = makeService();
      (strategies.author.findEntityById as any).mockResolvedValue({ id: 1, name: 'Author A' });
      (strategies.author.getBookCount as any).mockResolvedValue(5);
      (strategies.author.getBookTitles as any).mockResolvedValue(['Book 1', 'Book 2']);

      const result = await service.getEntityInfo('author', mockUser, 1);

      expect(result).toEqual({ id: 1, name: 'Author A', bookCount: 5, bookTitles: ['Book 1', 'Book 2'] });
      expect(strategies.author.getBookCount).toHaveBeenCalledWith(1, {
        libraryIds: [1, 2],
        contentFilters: EMPTY_CONTENT_FILTER_RULES,
      });
      expect(strategies.author.getBookTitles).toHaveBeenCalledWith(1, 5, {
        libraryIds: [1, 2],
        contentFilters: EMPTY_CONTENT_FILTER_RULES,
      });
    });

    it('throws NotFoundException when entity not found', async () => {
      const { service, strategies } = makeService();
      (strategies.author.findEntityById as any).mockResolvedValue(null);

      await expect(service.getEntityInfo('author', mockUser, 999)).rejects.toThrow(NotFoundException);
    });

    it('does not expose an entity that has books only outside the accessible scope', async () => {
      const { service, strategies } = makeService();
      (strategies.author.findEntityById as any).mockResolvedValue({ id: 1, name: 'Hidden Author' });
      (strategies.author.getBookCount as any).mockResolvedValueOnce(4).mockResolvedValueOnce(0);

      await expect(service.getEntityInfo('author', mockUser, 1)).rejects.toThrow(NotFoundException);

      expect(strategies.author.getBookTitles).toHaveBeenCalledWith(1, 5, {
        libraryIds: [1, 2],
        contentFilters: EMPTY_CONTENT_FILTER_RULES,
      });
    });
  });

  describe('computeReasons (via scan)', () => {
    it.each([
      ['Science Fiction', 'Fiction', 0.72, 'Name containment'],
      ['Test', 'Tset', 0.9, 'Very high name similarity'],
      ['young adult', 'Adult Young', 0.75, 'Same normalized tokens'],
    ] as const)('explains the names %s and %s', async (nameA, nameB, simScore, reason) => {
      const { service, setCandidates, repo } = makeService();
      setCandidates('publisher', [{ idA: nameA, idB: nameB, nameA, nameB, simScore }]);
      const entities: ClusterEntity[] = [
        { id: nameA, name: nameA, bookCount: 1, bookTitles: [] },
        { id: nameB, name: nameB, bookCount: 1, bookTitles: [] },
      ];
      repo.findClusterEntities.mockResolvedValue(entities);
      expect((await service.scanDuplicates('publisher', mockUser)).clusters[0]!.pairDetails[0]!.reasons).toContain(reason);
    });
  });
});
