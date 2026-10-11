import { Readable } from 'node:stream';
import { BadRequestException, ForbiddenException, Logger, NotFoundException } from '@nestjs/common';
import { Test, type TestingModule } from '@nestjs/testing';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import type { RequestUser } from '../../../common/types/request-user';
import type { MigrationRun } from '../../../db/schema';
import { MigrationRepository } from '../migration.repository';
import { MigrationReportRepository, type DuplicateArrayField, type PlanArrayField } from './migration-report.repository';
import { MigrationReportingService } from './migration-reporting.service';

const owner = { id: 9, isSuperuser: false } as RequestUser;
const otherUser = { id: 10, isSuperuser: false } as RequestUser;
const superuser = { id: 10, isSuperuser: true } as RequestUser;
const zeroTotals = { processed: 0, imported: 0, skipped: 0, unresolved: 0, failed: 0 };
const previewCounts = { statuses: 1, fileProgress: 2, readingSessions: 6, bookmarks: 3, annotations: 4, shelves: 5 };

function makeRun(overrides: Partial<MigrationRun> = {}): MigrationRun {
  return {
    id: 7,
    sourceId: 1,
    profileId: 2,
    planArtifactId: 99,
    triggeredByUserId: owner.id,
    state: 'running',
    currentStage: 'user_state',
    targetKey: 'default',
    startedAt: new Date('2026-01-01T00:00:00.000Z'),
    endedAt: null,
    errorMessage: null,
    createdAt: new Date('2026-01-01T00:00:00.000Z'),
    updatedAt: new Date('2026-01-02T00:00:00.000Z'),
    ...overrides,
  };
}

function makeArtifact(overrides: Partial<NonNullable<Awaited<ReturnType<MigrationReportRepository['findArtifact']>>>> = {}) {
  return {
    id: 99,
    createdByUserId: owner.id,
    plan: {},
    summary: {},
    planFields: ['matchedBooks', 'unresolvedBooks', 'duplicateBookMatches', 'userPreview'] as PlanArrayField[],
    hasUserPreview: true,
    hasSummaryPreview: false,
    ...overrides,
  };
}

function makeRepositoryMocks() {
  return {
    repo: {
      findRunById: vi.fn().mockResolvedValue(makeRun()),
      listRunMetrics: vi.fn().mockResolvedValue([]),
      findBookTitlesByIds: vi.fn().mockResolvedValue(new Map()),
    },
    reports: {
      findArtifact: vi.fn().mockResolvedValue(makeArtifact()),
      planPage: vi.fn().mockResolvedValue({ total: 0, items: [] }),
      sourceBooks: vi.fn().mockResolvedValue(new Map()),
      duplicateGroup: vi.fn().mockResolvedValue(null),
      duplicatePage: vi.fn().mockResolvedValue([]),
    },
  };
}

async function readStream(content: Readable) {
  const chunks: Buffer[] = [];
  for await (const chunk of content) chunks.push(Buffer.from(chunk));
  return Buffer.concat(chunks).toString('utf8');
}

describe('MigrationReportingService', () => {
  let module: TestingModule;
  let service: MigrationReportingService;
  let repo: ReturnType<typeof makeRepositoryMocks>['repo'];
  let reports: ReturnType<typeof makeRepositoryMocks>['reports'];

  beforeEach(async () => {
    ({ repo, reports } = makeRepositoryMocks());
    module = await Test.createTestingModule({
      providers: [
        MigrationReportingService,
        { provide: MigrationRepository, useValue: repo },
        { provide: MigrationReportRepository, useValue: reports },
      ],
    }).compile();
    service = module.get(MigrationReportingService);
  });

  afterEach(async () => {
    vi.restoreAllMocks();
    await module.close();
  });

  function setPages(pages: Partial<Record<PlanArrayField | 'perUserPreview', unknown[]>>) {
    reports.planPage.mockImplementation((_id: number, field: PlanArrayField | 'perUserPreview', offset: number, limit: number) => {
      const rows = pages[field] ?? [];
      return Promise.resolve({ total: rows.length, items: rows.slice(offset, offset + limit) });
    });
  }

  function setSourceBooks(books: Map<string, { title: string | null; author: string | null; filePath: string | null }>) {
    reports.sourceBooks.mockImplementation((_id: number, ids: string[]) =>
      Promise.resolve(new Map(ids.flatMap((id) => (books.has(id) ? [[id, books.get(id)!] as const] : [])))),
    );
  }

  function setDuplicateGroup(sourceBookIds: string[], strategies = sourceBookIds.map(() => 'isbn')) {
    reports.duplicateGroup.mockResolvedValue({
      base: { targetBookId: 101, reason: 'duplicate_target_match' },
      total: sourceBookIds.length,
      fields: ['sourceBookIds', 'strategies'],
    });
    reports.duplicatePage.mockImplementation((_id: number, _targetId: number, field: DuplicateArrayField, offset: number, limit: number) => {
      const rows = field === 'sourceBookIds' ? sourceBookIds : field === 'strategies' ? strategies : [];
      return Promise.resolve(rows.slice(offset, offset + limit));
    });
    return {
      targetBookId: 101,
      sourceBookIds: sourceBookIds.slice(0, 40),
      strategies: strategies.slice(0, 40),
      candidatePagination: { total: sourceBookIds.length, limit: 40, nextOffset: sourceBookIds.length > 40 ? 40 : null },
    };
  }

  it('rejects missing runs before reading report data', async () => {
    repo.findRunById.mockResolvedValue(null);
    await expect(service.getRunProgress(404, owner)).rejects.toBeInstanceOf(NotFoundException);
    await expect(service.getRunReport(404, owner)).rejects.toBeInstanceOf(NotFoundException);
    await expect(service.getRunDetails(404, 'matched', 0, 40, owner)).rejects.toBeInstanceOf(NotFoundException);
    await expect(service.exportRunReport(404, 'json', owner)).rejects.toBeInstanceOf(NotFoundException);
    expect(repo.listRunMetrics).not.toHaveBeenCalled();
    expect(reports.findArtifact).not.toHaveBeenCalled();
  });

  it('aggregates progress metrics and omits internal ownership fields', async () => {
    repo.listRunMetrics.mockResolvedValue([
      { processed: 3, imported: 2, skipped: 1, unresolved: 0, failed: 0 },
      { processed: 4, imported: 3, skipped: 0, unresolved: 1, failed: 1 },
    ]);
    const result = await service.getRunProgress(7, owner);
    expect(result.totals).toEqual({ processed: 7, imported: 5, skipped: 1, unresolved: 1, failed: 1 });
    expect(result.run.id).toBe(7);
    expect(result.run).not.toHaveProperty('triggeredByUserId');
    expect(reports.findArtifact).not.toHaveBeenCalled();
  });

  it('returns zero totals for empty metrics', async () => {
    expect((await service.getRunProgress(7, owner)).totals).toEqual(zeroTotals);
  });

  it('rejects another user for every run reporting operation', async () => {
    await expect(service.getRunProgress(7, otherUser)).rejects.toBeInstanceOf(ForbiddenException);
    await expect(service.getRunReport(7, otherUser)).rejects.toBeInstanceOf(ForbiddenException);
    await expect(service.getRunDetails(7, 'matched', 0, 40, otherUser)).rejects.toBeInstanceOf(ForbiddenException);
    await expect(service.exportRunReport(7, 'csv', otherUser)).rejects.toBeInstanceOf(ForbiddenException);
    expect(repo.listRunMetrics).not.toHaveBeenCalled();
    expect(reports.findArtifact).not.toHaveBeenCalled();
  });

  it('rejects another user for plan and duplicate candidate pages', async () => {
    await expect(service.getPlanMatches(99, 'matched', 0, 40, otherUser)).rejects.toBeInstanceOf(ForbiddenException);
    await expect(service.getDuplicateCandidates(99, 101, 0, 40, otherUser)).rejects.toBeInstanceOf(ForbiddenException);
    expect(reports.planPage).not.toHaveBeenCalled();
    expect(reports.duplicateGroup).not.toHaveBeenCalled();
  });

  it('checks plan ownership even when the run is owned by the requester', async () => {
    reports.findArtifact.mockResolvedValue(makeArtifact({ createdByUserId: otherUser.id }));
    await expect(service.getRunReport(7, owner)).rejects.toBeInstanceOf(ForbiddenException);
    expect(reports.planPage).not.toHaveBeenCalled();
  });

  it('allows superusers to report on another user run and plan', async () => {
    expect((await service.getRunReport(7, superuser)).run.id).toBe(7);
    expect((await service.getPlanMatches(99, 'matched', 0, 40, superuser)).artifactId).toBe(99);
  });

  it('rejects a missing plan artifact', async () => {
    reports.findArtifact.mockResolvedValue(null);
    await expect(service.getRunReport(7, owner)).rejects.toBeInstanceOf(NotFoundException);
    await expect(service.getPlanMatches(99, 'matched', 0, 40, owner)).rejects.toBeInstanceOf(NotFoundException);
  });

  it('builds normalized detail previews with source and target titles and summary user fallback', async () => {
    repo.listRunMetrics.mockResolvedValue([{ processed: 5, imported: 4, skipped: 0, unresolved: 1, failed: 0 }]);
    reports.findArtifact.mockResolvedValue(makeArtifact({ hasUserPreview: false, hasSummaryPreview: true }));
    setPages({
      matchedBooks: [{ sourceBookId: 's1', targetBookId: 100, strategy: 'isbn' }],
      unresolvedBooks: [{ sourceBookId: 'sx', reason: 'unresolved_title' }],
      duplicateBookMatches: [setDuplicateGroup(['s1', 's2'], ['isbn', 'path_mapping'])],
      perUserPreview: [{ sourceUserId: 'u1', targetUserId: 9, username: 'alice', counts: previewCounts }],
    });
    setSourceBooks(new Map([['s1', { title: 'Source One', author: 'Author One', filePath: null }]]));
    repo.findBookTitlesByIds.mockResolvedValue(
      new Map([
        [100, 'Target One'],
        [101, 'Target Two'],
      ]),
    );
    const result = await service.getRunReport(7, owner);
    expect(result.totals).toEqual({ processed: 5, imported: 4, skipped: 0, unresolved: 1, failed: 0 });
    expect(result.details.matchedBooks).toEqual([
      { sourceBookId: 's1', sourceTitle: 'Source One', sourceAuthor: 'Author One', targetBookId: 100, targetTitle: 'Target One', strategy: 'isbn' },
    ]);
    expect(result.details.unresolvedBooks).toEqual([{ sourceBookId: 'sx', title: null, author: null, reason: 'unresolved_title' }]);
    expect(result.details.duplicateBookMatches).toEqual([
      {
        targetBookId: 101,
        targetTitle: 'Target Two',
        sourceBookIds: ['s1', 's2'],
        sourceTitles: ['Source One', null],
        strategies: ['isbn', 'path_mapping'],
        reason: 'duplicate_target_match',
        candidatePagination: { total: 2, limit: 40, nextOffset: null },
      },
    ]);
    expect(result.details.userPreview).toEqual([{ sourceUserId: 'u1', targetUserId: 9, username: 'alice', counts: previewCounts }]);
    expect(result.summary).toEqual({ perUserPreview: result.details.userPreview });
  });

  it('bounds embedded plan, summary, and detail previews to 40 rows', async () => {
    const matches = Array.from({ length: 105 }, (_, index) => ({ sourceBookId: `s${index}`, targetBookId: index, strategy: 'isbn' }));
    const users = Array.from({ length: 105 }, (_, index) => ({
      sourceUserId: `u${index}`,
      targetUserId: index,
      username: `user${index}`,
      counts: {},
    }));
    reports.findArtifact.mockResolvedValue(
      makeArtifact({ plan: { version: 1 }, planFields: ['matchedBooks', 'userMappings'], hasUserPreview: false, hasSummaryPreview: true }),
    );
    setPages({ matchedBooks: matches, userMappings: users, perUserPreview: users });
    const result = await service.getRunReport(7, owner);
    expect(result.details.matchedBooks).toHaveLength(40);
    expect(result.details.userPreview).toHaveLength(40);
    expect(result.detailsPagination.matchedBooks).toEqual({ total: 105, limit: 40, nextOffset: 40 });
    expect(result.detailsPagination.userPreview).toEqual({ total: 105, limit: 40, nextOffset: 40 });
    expect(result.plan).toMatchObject({
      version: 1,
      matchedBooks: matches.slice(0, 40),
      userMappings: users.slice(0, 40),
      previewPagination: result.detailsPagination,
    });
    expect(result.summary).toEqual({ perUserPreview: result.details.userPreview });
    expect(reports.planPage.mock.calls.every(([, , offset, limit]) => offset === 0 && limit === 40)).toBe(true);
    expect(reports.sourceBooks.mock.calls.every(([, ids]) => ids.length <= 40)).toBe(true);
  });

  it('returns empty details for a run without a plan artifact', async () => {
    repo.findRunById.mockResolvedValue(makeRun({ planArtifactId: null }));
    const result = await service.getRunReport(7, owner);
    expect(result.plan).toBeNull();
    expect(result.summary).toBeNull();
    expect(result.details).toEqual({ matchedBooks: [], unresolvedBooks: [], duplicateBookMatches: [], userPreview: [] });
    expect(result.detailsPagination.matchedBooks).toEqual({ total: 0, limit: 40, nextOffset: null });
    expect(reports.findArtifact).not.toHaveBeenCalled();
    expect(reports.planPage).not.toHaveBeenCalled();
  });

  it('enriches unresolved titles from source books and preserves explicit plan titles', async () => {
    setPages({
      unresolvedBooks: [
        { sourceBookId: 'sx', title: null, reason: 'no_isbn_match' },
        { sourceBookId: 'sy', title: 'Plan Title', reason: 'no_isbn_match' },
      ],
    });
    setSourceBooks(
      new Map([
        ['sx', { title: 'Enriched Title', author: 'EA', filePath: null }],
        ['sy', { title: 'Source Title', author: 'SA', filePath: null }],
      ]),
    );
    const result = await service.getRunDetails(7, 'unresolved', 0, 40, owner);
    expect(result.items).toEqual([
      { sourceBookId: 'sx', title: 'Enriched Title', author: 'EA', reason: 'no_isbn_match' },
      { sourceBookId: 'sy', title: 'Plan Title', author: 'SA', reason: 'no_isbn_match' },
    ]);
  });

  it('prefers plan user previews over summary previews and normalizes missing counts', async () => {
    reports.findArtifact.mockResolvedValue(makeArtifact({ hasSummaryPreview: true }));
    setPages({
      userPreview: [{ sourceUserId: 'u1', targetUserId: 9, username: 'alice', counts: { bookmarks: 3 } }],
      perUserPreview: [{ sourceUserId: 'u2', targetUserId: 10, username: 'bob' }],
    });
    const result = await service.getRunDetails(7, 'users', 0, 40, owner);
    expect(result.items).toEqual([
      {
        sourceUserId: 'u1',
        targetUserId: 9,
        username: 'alice',
        counts: { statuses: 0, fileProgress: 0, readingSessions: 0, bookmarks: 3, annotations: 0, shelves: 0 },
      },
    ]);
    expect(reports.planPage).toHaveBeenCalledWith(99, 'userPreview', 0, 40);
  });

  it('skips malformed matched, unresolved, duplicate, and user detail rows', async () => {
    setPages({
      matchedBooks: [
        { sourceBookId: 's1', targetBookId: 10, strategy: 'isbn' },
        { sourceBookId: null, targetBookId: 10, strategy: 'isbn' },
        { sourceBookId: 's2', targetBookId: null, strategy: 'isbn' },
        { sourceBookId: 's3', targetBookId: 10, strategy: null },
      ],
      unresolvedBooks: [
        { sourceBookId: 'sx', reason: 'no_isbn_match' },
        { sourceBookId: null, reason: 'no_isbn_match' },
        { sourceBookId: 'sy', reason: null },
      ],
      duplicateBookMatches: [
        { targetBookId: 5, sourceBookIds: ['s1', 's2'], strategies: ['isbn', 'title_author'] },
        { targetBookId: null, sourceBookIds: ['s3'], strategies: ['isbn'] },
        { targetBookId: 6, sourceBookIds: [], strategies: [] },
      ],
      userPreview: [
        { sourceUserId: 'u1', targetUserId: 9, username: 'alice' },
        { sourceUserId: null, targetUserId: 9, username: 'alice' },
        { sourceUserId: 'u2', targetUserId: null, username: 'bob' },
        { sourceUserId: 'u3', targetUserId: 10, username: null },
      ],
    });
    const result = await service.getRunReport(7, owner);
    expect(result.details.matchedBooks).toMatchObject([{ sourceBookId: 's1' }]);
    expect(result.details.unresolvedBooks).toMatchObject([{ sourceBookId: 'sx' }]);
    expect(result.details.duplicateBookMatches).toMatchObject([{ targetBookId: 5 }]);
    expect(result.details.userPreview).toMatchObject([{ sourceUserId: 'u1' }]);
  });

  it('clamps detail pages to 100 rows and returns advancing offsets', async () => {
    setPages({ matchedBooks: Array.from({ length: 205 }, (_, index) => ({ sourceBookId: `s${index}`, targetBookId: index, strategy: 'isbn' })) });
    const first = await service.getRunDetails(7, 'matched', -1, 500, owner);
    const second = await service.getRunDetails(7, 'matched', first.nextOffset!, 100, owner);
    const last = await service.getRunDetails(7, 'matched', second.nextOffset!, 100, owner);
    expect(first).toMatchObject({ runId: 7, kind: 'matched', offset: 0, limit: 100, total: 205, nextOffset: 100 });
    expect(first.items).toHaveLength(100);
    expect(second.nextOffset).toBe(200);
    expect(second.items).toHaveLength(100);
    expect(last.nextOffset).toBeNull();
    expect(last.items).toHaveLength(5);
    expect(reports.sourceBooks.mock.calls.every(([, ids]) => ids.length <= 100)).toBe(true);
  });

  it('bounds and truncates plan pagination while retaining raw match fields', async () => {
    const matches = Array.from({ length: 105 }, (_, index) => ({ sourceBookId: `s${index}`, targetBookId: index, strategy: 'isbn', confidence: 1 }));
    setPages({ matchedBooks: matches });
    const result = await service.getPlanMatches(99, 'matched', 3.9, 200, owner);
    const minimal = await service.getPlanMatches(99, 'matched', -1, 0, owner);
    expect(result).toEqual({ artifactId: 99, kind: 'matched', offset: 3, limit: 100, total: 105, nextOffset: 103, items: matches.slice(3, 103) });
    expect(minimal).toMatchObject({ offset: 0, limit: 1, nextOffset: 1 });
    expect(minimal.items).toEqual(matches.slice(0, 1));
  });

  it.each(['invalid', '__proto__', 'constructor'])('rejects invalid detail kind %s', async (kind) => {
    await expect(service.getRunDetails(7, kind, 0, 40, owner)).rejects.toBeInstanceOf(BadRequestException);
    await expect(service.getPlanMatches(99, kind, 0, 40, owner)).rejects.toBeInstanceOf(BadRequestException);
    expect(reports.planPage).not.toHaveBeenCalled();
  });

  it('pages duplicate candidates with source data, candidate fallback, and strategy precedence', async () => {
    reports.duplicateGroup.mockResolvedValue({ base: { targetBookId: 101 }, total: 4, fields: ['sourceBookIds'] });
    const pages = {
      sourceBookIds: ['s1', 's2', 's3', 's4'],
      strategies: ['isbn', 'path_mapping', null, null],
      matches: [{ strategy: 'asin' }, {}, {}, {}],
      sourceCandidates: [
        { title: 'Old Title', author: 'Old Author', filePath: '/old' },
        { title: 'Fallback Title', author: 'Fallback Author', filePath: '/fallback' },
        { strategy: 'isbn' },
        {},
      ],
    };
    reports.duplicatePage.mockImplementation((_id: number, _target: number, field: DuplicateArrayField, offset: number, limit: number) =>
      Promise.resolve(pages[field].slice(offset, offset + limit)),
    );
    setSourceBooks(new Map([['s1', { title: 'Source Title', author: 'Source Author', filePath: '/source' }]]));
    const result = await service.getDuplicateCandidates(99, 101, 0, 2, owner);
    const last = await service.getDuplicateCandidates(99, 101, result.nextOffset!, 2, owner);
    expect(result).toEqual({
      artifactId: 99,
      targetBookId: 101,
      offset: 0,
      limit: 2,
      total: 4,
      nextOffset: 2,
      items: [
        { sourceBookId: 's1', title: 'Source Title', author: 'Source Author', filePath: '/source', strategy: 'asin' },
        { sourceBookId: 's2', title: 'Fallback Title', author: 'Fallback Author', filePath: '/fallback', strategy: 'path_mapping' },
      ],
    });
    expect(last.items).toMatchObject([
      { sourceBookId: 's3', strategy: 'isbn' },
      { sourceBookId: 's4', strategy: 'title_author' },
    ]);
    expect(last.nextOffset).toBeNull();
    expect(reports.sourceBooks).toHaveBeenCalledWith(99, ['s1', 's2']);
  });

  it('rejects an absent duplicate match group', async () => {
    await expect(service.getDuplicateCandidates(99, 101, 0, 40, owner)).rejects.toBeInstanceOf(NotFoundException);
    expect(reports.duplicatePage).not.toHaveBeenCalled();
  });

  it('streams every JSON plan and detail row in batches of at most 100', async () => {
    const matches = Array.from({ length: 205 }, (_, index) => ({ sourceBookId: `s${index}`, targetBookId: index, strategy: 'isbn' }));
    const duplicateIds = matches.slice(0, 105).map((row) => row.sourceBookId);
    const users = Array.from({ length: 105 }, (_, index) => ({
      sourceUserId: `u${index}`,
      targetUserId: index,
      username: `user${index}`,
      counts: previewCounts,
    }));
    reports.findArtifact.mockResolvedValue(
      makeArtifact({
        plan: { version: 1 },
        planFields: ['matchedBooks', 'duplicateBookMatches', 'userMappings'],
        summary: { matchedBooks: 205 },
        hasUserPreview: false,
        hasSummaryPreview: true,
      }),
    );
    setPages({ matchedBooks: matches, duplicateBookMatches: [setDuplicateGroup(duplicateIds)], userMappings: users, perUserPreview: users });
    setSourceBooks(new Map(matches.map((row) => [row.sourceBookId, { title: `Title ${row.sourceBookId}`, author: 'Author', filePath: null }])));
    const exported = await service.exportRunReport(7, undefined, owner);
    expect(exported).toMatchObject({ format: 'json', contentType: 'application/json', fileName: 'migration-run-7-report.json' });
    expect(exported.content).toBeInstanceOf(Readable);
    expect(reports.planPage).not.toHaveBeenCalled();
    const result = JSON.parse(await readStream(exported.content));
    expect(result.plan.matchedBooks).toEqual(matches);
    expect(result.plan.userMappings).toEqual(users);
    expect(result.plan.duplicateBookMatches[0].sourceBookIds).toEqual(duplicateIds);
    expect(result.plan.duplicateBookMatches[0].strategies).toHaveLength(105);
    expect(result.summary).toEqual({ matchedBooks: 205, perUserPreview: users });
    expect(result.details.matchedBooks).toHaveLength(205);
    expect(result.details.matchedBooks.at(-1)).toMatchObject({ sourceBookId: 's204', sourceTitle: 'Title s204', sourceAuthor: 'Author' });
    expect(result.details.userPreview).toEqual(users);
    expect(result.details.duplicateBookMatches[0]).toMatchObject({
      sourceBookIds: duplicateIds,
      sourceTitles: duplicateIds.map((id) => `Title ${id}`),
      strategies: duplicateIds.map(() => 'isbn'),
    });
    expect(result.run).not.toHaveProperty('triggeredByUserId');
    expect(result.totals).toEqual(zeroTotals);
    expect(reports.planPage.mock.calls).toEqual(
      expect.arrayContaining([
        [99, 'matchedBooks', 0, 100],
        [99, 'matchedBooks', 100, 100],
        [99, 'matchedBooks', 200, 100],
      ]),
    );
    expect(reports.planPage.mock.calls.every(([, , , limit]) => limit <= 100)).toBe(true);
    expect(reports.duplicatePage.mock.calls.every(([, , , , limit]) => limit <= 100)).toBe(true);
    expect(reports.sourceBooks.mock.calls.every(([, ids]) => ids.length <= 100)).toBe(true);
  });

  it('streams CSV metrics and every detail section with commas, quotes, and newlines escaped', async () => {
    repo.listRunMetrics.mockResolvedValue([
      {
        stage: 'user_state',
        entityType: 'reading_progress',
        processed: 10,
        imported: 8,
        skipped: 1,
        unresolved: 1,
        failed: 0,
        updatedAt: new Date('2026-01-02T00:00:00.000Z'),
      },
    ]);
    setPages({
      matchedBooks: [{ sourceBookId: 's1', targetBookId: 100, strategy: 'asin' }],
      unresolvedBooks: [{ sourceBookId: 'sx', title: 'Unresolved Title', reason: 'no_asin_match' }],
      duplicateBookMatches: [setDuplicateGroup(['s1', 's2'], ['isbn', 'title_author'])],
      userPreview: [{ sourceUserId: 'u1', targetUserId: 9, username: 'user\nwith\nnewlines', counts: previewCounts }],
    });
    setSourceBooks(
      new Map([
        ['s1', { title: 'Title, "Quoted"', author: 'Author', filePath: null }],
        ['s2', { title: 'Second\nTitle', author: null, filePath: null }],
      ]),
    );
    repo.findBookTitlesByIds.mockResolvedValue(
      new Map([
        [100, 'Target'],
        [101, 'Dup Target'],
      ]),
    );
    const exported = await service.exportRunReport(7, 'CSV', owner);
    const text = await readStream(exported.content);
    expect(exported).toMatchObject({ format: 'csv', contentType: 'text/csv; charset=utf-8', fileName: 'migration-run-7-report.csv' });
    expect(text).toMatch(/^section,stage,entityType,processed,imported,skipped,unresolved,failed,/);
    expect(text).toContain('summary,,,10,8,1,1,0');
    expect(text).toContain('matchedBooks=1; unresolvedBooks=1; mappedUsers=1');
    expect(text).toContain('metrics,user_state,reading_progress,10,8,1,1,0');
    expect(text).toContain('matched_books,shared_overlays,book_match');
    expect(text).toContain('"Title, ""Quoted"""');
    expect(text).toContain('unresolved_books,,book_match');
    expect(text).toContain('Unresolved Title');
    expect(text).toContain('no_asin_match');
    expect(text).toContain('duplicate_matches,,book_match');
    expect(text).toContain('"s1|s2"');
    expect(text).toContain('"Title, ""Quoted"" | Second\nTitle"');
    expect(text).toContain('"isbn|title_author"');
    expect(text).toContain('user_preview,user_state,user_preview');
    expect(text).toContain('"user\nwith\nnewlines"');
    expect(text).toContain('statuses=1; fileProgress=2; readingSessions=6; bookmarks=3; annotations=4; shelves=5');
    expect(text).toContain('2026-01-02T00:00:00.000Z');
  });

  it('streams CSV beyond preview and page limits including every duplicate candidate', async () => {
    const matches = Array.from({ length: 205 }, (_, index) => ({ sourceBookId: `s${index}`, targetBookId: index, strategy: 'isbn' }));
    const duplicateIds = matches.slice(0, 105).map((row) => row.sourceBookId);
    setPages({ matchedBooks: matches, duplicateBookMatches: [setDuplicateGroup(duplicateIds)] });
    const exported = await service.exportRunReport(7, 'csv', owner);
    const text = await readStream(exported.content);
    expect(text.split('\n').filter((line) => line.startsWith('matched_books,'))).toHaveLength(205);
    expect(text).toContain(`"${duplicateIds.join('|')}"`);
    expect(text).toContain('matchedBooks=205; unresolvedBooks=0; mappedUsers=0');
    expect(reports.planPage.mock.calls.every(([, , , limit]) => limit <= 100)).toBe(true);
    expect(reports.duplicatePage.mock.calls).toEqual(
      expect.arrayContaining([
        [99, 101, 'sourceBookIds', 0, 100],
        [99, 101, 'sourceBookIds', 100, 100],
      ]),
    );
  });

  it.each([undefined, 'xml'])('defaults %s format to a valid empty JSON stream', async (format) => {
    repo.findRunById.mockResolvedValue(makeRun({ planArtifactId: null }));
    const exported = await service.exportRunReport(7, format, owner);
    const result = JSON.parse(await readStream(exported.content));
    expect(exported).toMatchObject({ format: 'json', contentType: 'application/json', fileName: 'migration-run-7-report.json' });
    expect(result).toMatchObject({
      plan: null,
      summary: null,
      totals: zeroTotals,
      metrics: [],
      details: { matchedBooks: [], unresolvedBooks: [], duplicateBookMatches: [], userPreview: [] },
    });
    expect(reports.planPage).not.toHaveBeenCalled();
  });

  it('streams a header and zero summary for CSV without plan details', async () => {
    repo.findRunById.mockResolvedValue(makeRun({ planArtifactId: null }));
    const exported = await service.exportRunReport(7, 'csv', owner);
    const text = await readStream(exported.content);
    expect(text.split('\n').filter(Boolean)).toHaveLength(2);
    expect(text).toContain('summary,,,0,0,0,0,0');
    expect(text).not.toContain('matched_books');
  });

  it('propagates repository errors raised while an export stream is consumed', async () => {
    const failure = new BadRequestException('Report page unavailable');
    reports.planPage.mockRejectedValue(failure);
    vi.spyOn(Logger.prototype, 'error').mockImplementation(() => undefined);
    const exported = await service.exportRunReport(7, 'json', owner);
    await expect(readStream(exported.content)).rejects.toBe(failure);
  });
});
