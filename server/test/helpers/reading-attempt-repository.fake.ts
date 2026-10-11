import { vi } from 'vitest';
import type { ReadStatus } from '@bookorbit/types';
import { readingAttempts } from '../../src/db/schema';
import type { ReadingAttemptRepository } from '../../src/modules/user-book-status/reading-attempt.repository';

type Row = typeof readingAttempts.$inferSelect;

export function makeFakeRepo() {
  const rows: Row[] = [];
  let nextId = 1;
  const transactionContext = {};
  let transactionQueue = Promise.resolve();
  const statuses = new Map<string, { status: ReadStatus; source: string; startedAt: Date | null; finishedAt: Date | null; updatedAt: Date }>();
  const projections: Array<{
    status: ReadStatus;
    source: 'manual' | 'auto';
    startedAt: Date | null;
    finishedAt: Date | null;
  }> = [];

  function assertValidAttempt(candidate: Pick<Row, 'userId' | 'bookId' | 'startedOn' | 'endedOn' | 'outcome' | 'deletedAt'>, excludedId?: number) {
    if (candidate.endedOn !== null && candidate.outcome === null) {
      throw new Error('reading_attempts_closed_has_outcome_chk');
    }
    if (candidate.startedOn !== null && candidate.endedOn !== null && candidate.endedOn < candidate.startedOn) {
      throw new Error('reading_attempts_end_after_start_chk');
    }
    if (candidate.outcome === null && candidate.deletedAt === null) {
      const duplicateActive = rows.some(
        (row) =>
          row.id !== excludedId &&
          row.userId === candidate.userId &&
          row.bookId === candidate.bookId &&
          row.outcome === null &&
          row.deletedAt === null,
      );
      if (duplicateActive) throw new Error('reading_attempts_one_active_uidx');
    }
  }

  const repo = {
    transaction: vi.fn((callback: (tx: object) => Promise<unknown>) => {
      const pending = transactionQueue.then(async () => {
        const previousRows = rows.map((row) => ({ ...row }));
        const previousStatuses = new Map([...statuses].map(([key, status]) => [key, { ...status }]));
        const previousProjections = projections.map((projection) => ({ ...projection }));
        try {
          return await callback(transactionContext);
        } catch (error) {
          rows.splice(0, rows.length, ...previousRows);
          statuses.clear();
          for (const [key, status] of previousStatuses) statuses.set(key, status);
          projections.splice(0, projections.length, ...previousProjections);
          throw error;
        }
      });
      transactionQueue = pending.then(
        () => {},
        () => {},
      );
      return pending;
    }),
    lockBook: vi.fn(() => Promise.resolve()),
    findActive: vi.fn((_tx: object, userId: number, bookId: number) =>
      Promise.resolve(rows.find((row) => row.userId === userId && row.bookId === bookId && row.outcome === null && row.deletedAt === null)),
    ),
    findLatest: vi.fn((_tx: object, userId: number, bookId: number) =>
      Promise.resolve([...rows].reverse().find((row) => row.userId === userId && row.bookId === bookId && row.deletedAt === null)),
    ),
    hasCompleted: vi.fn((_tx: object, userId: number, bookId: number) =>
      Promise.resolve(rows.some((row) => row.userId === userId && row.bookId === bookId && row.outcome === 'completed' && row.deletedAt === null)),
    ),
    create: vi.fn(
      (
        _tx: object,
        values: Omit<Row, 'id' | 'deletedAt' | 'createdAt' | 'updatedAt' | 'externalProvider' | 'externalId'> & {
          externalProvider?: string | null;
          externalId?: string | null;
        },
      ) => {
        const now = new Date('2026-07-12T12:00:00.000Z');
        const row: Row = {
          ...values,
          id: nextId++,
          externalProvider: values.externalProvider ?? null,
          externalId: values.externalId ?? null,
          deletedAt: null,
          createdAt: now,
          updatedAt: now,
        };
        assertValidAttempt(row);
        rows.push(row);
        return Promise.resolve(row);
      },
    ),
    createActive: vi.fn(
      (
        _tx: object,
        values: Omit<Row, 'id' | 'deletedAt' | 'createdAt' | 'updatedAt' | 'externalProvider' | 'externalId' | 'endedOn' | 'outcome'> & {
          externalProvider?: string | null;
          externalId?: string | null;
        },
      ) => {
        const existing = rows.find(
          (row) => row.userId === values.userId && row.bookId === values.bookId && row.outcome === null && row.deletedAt === null,
        );
        if (existing) return Promise.resolve(existing);
        return repo.create(_tx, { ...values, endedOn: null, outcome: null });
      },
    ),
    createIdentified: vi.fn((_tx: object, values: Parameters<ReadingAttemptRepository['create']>[1]) => {
      if (
        rows.some((row) => row.userId === values.userId && row.externalProvider === values.externalProvider && row.externalId === values.externalId)
      ) {
        return Promise.resolve(null);
      }
      return repo.create(_tx, values);
    }),
    update: vi.fn((_tx: object, userId: number, bookId: number, id: number, patch: Partial<Row>) => {
      const row = rows.find((item) => item.id === id && item.userId === userId && item.bookId === bookId && item.deletedAt === null);
      if (!row) return Promise.resolve(null);
      assertValidAttempt({ ...row, ...patch }, row.id);
      Object.assign(row, patch, { updatedAt: new Date('2026-07-12T12:00:00.000Z') });
      return Promise.resolve(row);
    }),
    project: vi.fn((_tx: object, userId: number, bookId: number, projection: (typeof projections)[number]) => {
      projections.push(projection);
      const row = { ...projection, updatedAt: new Date('2026-07-12T12:00:00.000Z') };
      statuses.set(`${userId}:${bookId}`, row);
      return Promise.resolve(row);
    }),
    findStatus: vi.fn((_tx: object, userId: number, bookId: number) => Promise.resolve(statuses.get(`${userId}:${bookId}`) ?? null)),
    findByExternal: vi.fn((_tx: object, userId: number, provider: string, externalId: string) =>
      Promise.resolve(rows.find((row) => row.userId === userId && row.externalProvider === provider && row.externalId === externalId)),
    ),
    findOwned: vi.fn((userId: number, bookId: number, id: number) =>
      Promise.resolve(rows.find((row) => row.id === id && row.userId === userId && row.bookId === bookId && row.deletedAt === null)),
    ),
    findDetail: vi.fn((userId: number, bookId: number, id: number) => {
      const row = rows.find((item) => item.id === id && item.userId === userId && item.bookId === bookId && item.deletedAt === null);
      return Promise.resolve(row ? { ...row, totalSessions: 0, totalSeconds: 0 } : null);
    }),
    softDelete: vi.fn((userId: number, bookId: number, id: number) => {
      const row = rows.find((item) => item.id === id && item.userId === userId && item.bookId === bookId && item.deletedAt === null);
      if (!row) return Promise.resolve(false);
      row.deletedAt = new Date();
      return Promise.resolve(true);
    }),
    list: vi.fn(() => Promise.resolve({ items: [], total: 0 })),
  };
  return { repo, rows, projections, transactionContext };
}
