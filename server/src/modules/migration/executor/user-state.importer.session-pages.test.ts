import { ConflictException } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { PgDialect } from 'drizzle-orm/pg-core';
import type { SQL } from 'drizzle-orm';
import * as schema from '../../../db/schema';
import { ReadingAttemptEventsService } from '../../user-book-status/reading-attempt-events.service';
import { MigrationRepository } from '../migration.repository';
import { MigrationImportRepository } from './migration-import.repository';
import { UserStateImporter } from './user-state.importer';
import type { PlannerResult } from '../planner/planner.types';

type Session = typeof schema.readingSessions.$inferInsert;
type DailyStats = typeof schema.userReadingDailyStats.$inferInsert;

async function fixture() {
  const sessions = new Map<string, Session & { id: number; libraryId: number }>();
  const stats = new Map<string, DailyStats>();
  const dialect = new PgDialect();
  const key = (row: Session) => `${row.userId}:${row.sessionId}`;
  const db = {
    execute: vi.fn().mockResolvedValue(undefined),
    select: vi.fn().mockImplementation(() => ({
      from: () => ({
        where: vi.fn().mockResolvedValue([{ id: 10, settings: { timezone: 'UTC' } }]),
        innerJoin: () => ({
          where: (condition: SQL) => {
            const query = dialect.sqlToQuery(condition);
            if (query.sql.includes('"session_id"')) {
              return [...sessions.values()].filter((row) => query.params.includes(row.userId) && query.params.includes(row.sessionId));
            }
            const [userId, libraryId, end, start] = query.params as [number, number, string, string];
            return [...sessions.values()].filter(
              (row) => row.userId === userId && row.libraryId === libraryId && row.startedAt < new Date(end) && row.endedAt > new Date(start),
            );
          },
        }),
      }),
    })),
    insert: vi.fn().mockImplementation((table: unknown) => ({
      values: (rows: Session[] | DailyStats[]) => ({
        onConflictDoUpdate: (config: { setWhere?: SQL }) => {
          if (table === schema.readingSessions) {
            for (const row of rows as Session[]) {
              const previous = sessions.get(key(row));
              if (previous && config.setWhere && previous.endedAt > row.endedAt) continue;
              sessions.set(key(row), { ...row, id: previous?.id ?? sessions.size + 1, libraryId: 1 });
            }
          } else {
            for (const row of rows as DailyStats[]) stats.set(row.day, row);
          }
        },
      }),
    })),
    delete: vi.fn().mockImplementation((table: unknown) => ({
      where: (condition: SQL) => {
        const { params } = dialect.sqlToQuery(condition);
        if (table === schema.readingSessions) {
          for (const [rowKey, row] of sessions) if (params.includes(row.id)) sessions.delete(rowKey);
        } else {
          for (const day of stats.keys()) if (params.includes(day)) stats.delete(day);
        }
      },
    })),
  };
  const importRepo = new MigrationImportRepository(db as never);
  vi.spyOn(importRepo, 'fetchLibraryIdsByBookIds').mockResolvedValue(new Map([[200, 1]]));
  vi.spyOn(importRepo, 'fetchTargetBookPrimaryFiles').mockResolvedValue({
    primaryFilesByBookId: new Map([[200, 500]]),
    audiobookPrimaryFilesByBookId: new Map(),
  });
  vi.spyOn(importRepo, 'fetchTargetBookFiles').mockResolvedValue(
    new Map([[200, [{ id: 500, hash: null, absolutePath: '/book.epub', format: 'epub', sortOrder: 0, durationSeconds: null }]]]),
  );
  vi.spyOn(importRepo, 'withTransaction').mockImplementation(async (handler) => handler(importRepo));
  const repo = { setRunMetric: vi.fn().mockResolvedValue(undefined) };
  const module = await Test.createTestingModule({
    providers: [
      UserStateImporter,
      { provide: MigrationRepository, useValue: repo },
      { provide: MigrationImportRepository, useValue: importRepo },
      { provide: ReadingAttemptEventsService, useValue: new ReadingAttemptEventsService() },
    ],
  }).compile();
  const importer = module.get(UserStateImporter);
  const ensureRunning = vi.fn().mockResolvedValue(undefined);
  const page = (start: number, count: number, domain?: 'bookmarks' | 'annotations' | 'readingProgress') =>
    ({
      plan: { snapshot: { sourceType: 'booklore' }, userMappings: [{ sourceUserId: 'u1', targetUserId: 10 }], pathMappings: [] },
      execution: {
        matchedBooks: [{ sourceBookId: 'b1', targetBookId: 200 }],
        sourceData: {
          availableDomains: {
            userBookStatuses: false,
            readingProgress: domain === 'readingProgress',
            readingSessions: true,
            bookmarks: domain === 'bookmarks',
            annotations: domain === 'annotations',
            shelves: false,
          },
          books: [{ sourceBookId: 'b1', files: [] }],
          userBookStatuses: [],
          userFileProgress: [],
          shelves: [],
          shelfBooks: [],
          bookmarks: domain === 'bookmarks' ? [{ sourceUserId: 'u1', sourceBookId: 'b1', cfi: '/6/2', title: 'Bookmark', createdAt: null }] : [],
          annotations:
            domain === 'annotations'
              ? [{ sourceUserId: 'u1', sourceBookId: 'b1', cfi: '/6/2', text: 'Highlight', note: null, createdAt: null, updatedAt: null }]
              : [],
          readingSessions: Array.from({ length: count }, (_, index) => ({
            sourceSessionId: String(start + index),
            sourceUserId: 'u1',
            sourceBookId: 'b1',
            bookType: 'EPUB',
            startedAt: '2026-01-01T00:00:00Z',
            endedAt: '2026-01-01T00:01:00Z',
            durationSeconds: 60,
            progressDelta: 1,
            endProgress: 50,
          })),
        },
      },
    }) as unknown as PlannerResult;
  vi.spyOn(importRepo, 'batchInsertBookmarks').mockResolvedValue(undefined);
  vi.spyOn(importRepo, 'batchInsertAnnotations').mockResolvedValue(undefined);
  return { sessions, stats, repo, importRepo, importer, ensureRunning, page };
}

describe('durable user-state session pages', () => {
  it('retains all 501 sessions across 500/1 pages and recomputes complete daily totals', async () => {
    const f = await fixture();
    await f.importer.import(1, f.page(0, 500), f.ensureRunning, false);
    await f.importer.import(1, f.page(500, 1), f.ensureRunning, false);
    expect(f.sessions.size).toBe(501);
    expect(f.stats.get('2026-01-01')).toMatchObject({ readingSeconds: 30060, sessionsCount: 501, progressDelta: 501 });
    expect(f.repo.setRunMetric.mock.calls.filter((call) => call[2] === 'reading_sessions').map((call) => call[3].imported)).toEqual([500, 1]);
  });

  it('retains sessions when later pages contain only bookmarks, annotations or progress', async () => {
    const f = await fixture();
    await f.importer.import(1, f.page(0, 501), f.ensureRunning, false);
    for (const domain of ['bookmarks', 'annotations', 'readingProgress'] as const)
      await f.importer.import(1, f.page(0, 0, domain), f.ensureRunning, false);
    expect(f.sessions.size).toBe(501);
    expect(f.stats.get('2026-01-01')).toMatchObject({ readingSeconds: 30060, sessionsCount: 501 });
    expect(f.importRepo.batchInsertBookmarks).toHaveBeenCalledWith(expect.arrayContaining([expect.objectContaining({ userId: 10, bookId: 200 })]));
    expect(f.importRepo.batchInsertAnnotations).toHaveBeenCalledWith(expect.arrayContaining([expect.objectContaining({ userId: 10, bookId: 200 })]));
  });

  it('resumes after a saved first-page checkpoint and idempotently replays the remaining page while preserving newer state', async () => {
    const f = await fixture();
    await f.importer.import(1, f.page(0, 500), f.ensureRunning, false);
    const savedCheckpoint = 0;
    f.ensureRunning.mockRejectedValueOnce(new ConflictException('Run interrupted'));
    await expect(f.importer.import(1, f.page(500, 1), f.ensureRunning, false)).rejects.toThrow('Run interrupted');
    expect(f.sessions.size).toBe(500);
    const local = {
      ...f.sessions.get('10:booklore:rs:0')!,
      sessionId: 'local-session',
      endedAt: new Date('2026-01-01T00:02:00Z'),
      durationSeconds: 120,
    };
    f.sessions.set('10:local-session', local);
    const remaining = [f.page(500, 1)];
    for (const page of remaining.slice(savedCheckpoint)) await f.importer.import(1, page, f.ensureRunning, false);
    const newer = f.sessions.get('10:booklore:rs:500')!;
    newer.endedAt = new Date('2026-01-01T00:02:00Z');
    newer.durationSeconds = 120;
    await f.importer.import(1, remaining[0]!, f.ensureRunning, false);
    expect(f.sessions.size).toBe(502);
    expect([...f.sessions.values()].filter((row) => row.sessionId.startsWith('booklore:rs:'))).toHaveLength(501);
    expect(f.sessions.get('10:local-session')).toEqual(local);
    expect(f.sessions.get('10:booklore:rs:500')?.durationSeconds).toBe(120);
    expect(f.stats.get('2026-01-01')).toMatchObject({ readingSeconds: 30240, sessionsCount: 502 });
  });
});
