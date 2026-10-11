import { BadRequestException } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { PgDialect } from 'drizzle-orm/pg-core';

import { DB } from '../../../db';
import type { SourceBook, SourceExportData } from '../adapters/source-adapter.types';
import { SourceAdapterRegistry } from '../adapters/source-adapter.registry';
import { MigrationReportRepository } from '../reporting/migration-report.repository';
import { MigrationPlanningRepository } from './migration-planning.repository';
import { MatchingService } from './matching.service';
import { MigrationPlannerService } from './planner.service';
import type { MigrationPlanningStore } from './planner.types';

const zeroCounts = { statuses: 0, fileProgress: 0, readingSessions: 0, bookmarks: 0, annotations: 0, shelves: 0 };
const book = (id: string) => ({ sourceBookId: id, title: id, author: 'Author', filePath: `/${id}.epub` }) as SourceBook;
const batch = (books: SourceBook[], statuses: SourceExportData['userBookStatuses'] = []): SourceExportData => ({
  books,
  users: [],
  userBookStatuses: statuses,
  userFileProgress: [],
  readingSessions: [],
  bookmarks: [],
  annotations: [],
  shelves: [],
  shelfBooks: [],
});

describe('bounded persisted migration planning', () => {
  it('looks up and writes at most 100 candidates, deduplicates repeated state batches, and returns no library arrays', async () => {
    const books = Array.from({ length: 101 }, (_, index) => book(`b${index}`));
    const status = { sourceBookId: 'b0', sourceUserId: 'u1', status: 'reading', percentage: 1, startedAt: null, finishedAt: null, updatedAt: null };
    const seen = new Set<string>();
    const store: MigrationPlanningStore = {
      knownSourceBookIds: vi.fn((ids: string[]) => Promise.resolve(new Set(ids.filter((id) => seen.has(id))))),
      appendCandidates: vi.fn((rows: SourceBook[]) => {
        for (const row of rows) seen.add(row.sourceBookId);
        return Promise.resolve();
      }),
      appendPreviewCounts: vi.fn().mockResolvedValue(undefined),
      totals: vi.fn().mockResolvedValue({
        summary: { matchedBooks: 99, unresolvedBooks: 0, duplicateBookMatches: 1, unresolvedByReason: {} },
        users: [{ sourceUserId: 'u1', counts: { ...zeroCounts, statuses: 2 } }],
      }),
    };
    const adapter = {
      snapshot: vi.fn().mockResolvedValue({ counts: { books: 101 } }),
      exportData: vi.fn(),
      async *exportDataBatches() {
        yield await Promise.resolve(batch(books, [status]));
        yield await Promise.resolve(batch([books[0]], [status]));
      },
    };
    const matching = {
      matchBooks: vi.fn((rows: SourceBook[]) =>
        Promise.resolve({
          matches: rows.map((row) => ({ sourceBookId: row.sourceBookId, targetBookId: Number(row.sourceBookId.slice(1)) + 1, strategy: 'isbn' })),
          unresolved: [],
        }),
      ),
    };
    const module = await Test.createTestingModule({
      providers: [
        MigrationPlannerService,
        { provide: SourceAdapterRegistry, useValue: { get: () => adapter } },
        { provide: MatchingService, useValue: matching },
      ],
    }).compile();
    const onSourceBatch = vi.fn().mockResolvedValue(undefined);
    const result = await module.get(MigrationPlannerService).buildPlan({
      source: { type: 'booklore', connectionConfig: { host: 'localhost', user: 'root', password: '', database: 'booklore' } } as never,
      profile: { userMappings: [{ sourceUserId: 'u1', targetUserId: 7 }], pathMappings: [], scope: {} } as never,
      actorUserId: 7,
      planningStore: store,
      onSourceBatch,
    });
    expect(vi.mocked(store.knownSourceBookIds).mock.calls.map(([rows]) => rows.length)).toEqual([100, 1, 1]);
    expect(vi.mocked(store.appendCandidates).mock.calls.map(([rows]) => rows.length)).toEqual([100, 1]);
    expect(matching.matchBooks).toHaveBeenCalledTimes(2);
    expect(onSourceBatch).toHaveBeenCalledTimes(2);
    expect(store.appendPreviewCounts).toHaveBeenCalledTimes(2);
    expect(result.plan).toMatchObject({
      itemIdentityVersion: 2,
      matchedBooks: [],
      unresolvedBooks: [],
      duplicateBookMatches: [],
      userPreview: [{ counts: { ...zeroCounts, statuses: 2 } }],
    });
    expect(result.plan.matchingContentHash).toMatch(/^[a-f0-9]{64}$/);
    expect(result.execution.sourceData.books).toEqual([]);
    expect(adapter.exportData).not.toHaveBeenCalled();
    const execute = vi.fn().mockResolvedValue({ rows: [] });
    const db = {
      transaction: vi.fn((callback: (tx: { execute: typeof execute }) => Promise<void>) => callback({ execute })),
      select: vi
        .fn()
        .mockReturnValue({ from: vi.fn().mockReturnValue({ where: vi.fn().mockReturnValue({ limit: vi.fn().mockResolvedValue([{ id: 9 }]) }) }) }),
      delete: vi.fn(),
    };
    await new MigrationPlanningRepository(db as never, 9, 7).finalize({
      plan: result.plan,
      summary: result.durableSummary,
      sourceSnapshotHash: 'source-hash',
      profileHash: 'profile-hash',
      planHash: 'plan-hash',
    });
    const queries = execute.mock.calls.map(([query]) => new PgDialect().sqlToQuery(query));
    expect(queries[0].sql).toContain('INSERT INTO "migration_plan_book_matches"');
    expect(queries[0].sql).toContain('target_count = 1');
    expect(queries[0].sql).not.toMatch(/\bLIMIT\b/);
    expect(queries[1].sql).toContain('LIMIT 40');
    expect(queries[1].params.some((value) => typeof value === 'string' && value.includes('"matchedBooksBatched":true'))).toBe(true);
    expect(db.delete).not.toHaveBeenCalled();
    await module.close();
  });

  it('rejects oversized planner and report lookups before any database work', async () => {
    const db = { select: vi.fn(), execute: vi.fn() };
    const ids = Array.from({ length: 101 }, (_, index) => String(index));
    const planning = new MigrationPlanningRepository(db as never, 9, 7);
    const reports = new MigrationReportRepository(db as never);
    await expect(planning.knownSourceBookIds(ids)).rejects.toBeInstanceOf(BadRequestException);
    await expect(planning.appendCandidates(ids.map(book), { matches: [], unresolved: [] })).rejects.toBeInstanceOf(BadRequestException);
    await expect(reports.sourceBooks(9, ids)).rejects.toBeInstanceOf(BadRequestException);
    expect(db.select).not.toHaveBeenCalled();
    expect(db.execute).not.toHaveBeenCalled();
  });

  it('reads metadata only from the requested owner and source IDs through the source projection', async () => {
    const where = vi.fn().mockReturnValue({ limit: vi.fn().mockResolvedValue([{ sourceBookId: 'b1', title: 'One', author: null, filePath: null }]) });
    const db = {
      select: vi
        .fn()
        .mockReturnValueOnce({
          from: vi.fn().mockReturnValue({ where: vi.fn().mockReturnValue({ limit: vi.fn().mockResolvedValue([{ userId: 7, indexed: true }]) }) }),
        })
        .mockReturnValueOnce({ from: vi.fn().mockReturnValue({ where }) }),
      execute: vi.fn(),
    };
    const module = await Test.createTestingModule({ providers: [MigrationReportRepository, { provide: DB, useValue: db }] }).compile();
    const result = await module.get(MigrationReportRepository).sourceBooks(9, ['b1', 'b2']);
    const query = new PgDialect().sqlToQuery(where.mock.calls[0][0]);
    expect(query.params).toEqual([9, 7, 'b1', 'b2']);
    expect(query.sql).toContain('migration_plan_source_books');
    expect(db.execute).not.toHaveBeenCalled();
    expect(result.get('b1')?.title).toBe('One');
    await module.close();
  });
});
