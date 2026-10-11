import { BadRequestException, ForbiddenException } from '@nestjs/common';
import { SQL } from 'drizzle-orm';
import { PgDialect } from 'drizzle-orm/pg-core';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import { readingAttempts, readingSessions, userReadingDailyStats } from '../../db/schema';
import { readingSessionDeletions } from '../../db/schema/reading-session-deletions';
import { ReadingSessionRepository } from './reading-session.repository';

function queryParams(condition: SQL): unknown[] {
  return new PgDialect().sqlToQuery(condition).params;
}

function makeDbHarness(options?: {
  fileRow?: { bookId: number; libraryId: number } | null;
  insertedIds?: Array<{ id: number }>;
  existingSession?: Partial<typeof readingSessions.$inferSelect> | null;
  deletedSessionId?: string;
  capturedAttempt?: { id: number } | null;
  recomputeRows?: Array<Pick<typeof readingSessions.$inferSelect, 'startedAt' | 'endedAt' | 'durationSeconds' | 'progressDelta'>>;
}) {
  const fileRow = options?.fileRow === undefined ? { bookId: 7, libraryId: 11 } : options.fileRow;
  const insertedIds = options?.insertedIds ?? [{ id: 1 }];
  const existingSession = options?.existingSession
    ? {
        bookFileId: 8,
        source: 'web',
        sessionType: 'read',
        startedAt: new Date('2026-04-15T10:00:00.000Z'),
        endedAt: new Date('2026-04-15T10:01:00.000Z'),
        attemptId: null,
        ...options.existingSession,
      }
    : null;

  const limit = vi.fn().mockResolvedValue(fileRow == null ? [] : [fileRow]);
  const where = vi.fn().mockReturnValue({ limit });
  const innerJoin = vi.fn().mockReturnValue({ where });
  const from = vi.fn().mockReturnValue({ innerJoin });
  const select = vi.fn().mockReturnValue({ from });

  const sessionReturning = vi.fn().mockResolvedValue(insertedIds);
  const sessionConflict = vi.fn().mockReturnValue({ returning: sessionReturning });
  const sessionValues = vi.fn().mockReturnValue({ onConflictDoNothing: sessionConflict });

  const dailyConflictUpdate = vi.fn().mockResolvedValue(undefined);
  const dailyValues = vi.fn().mockReturnValue({ onConflictDoUpdate: dailyConflictUpdate });

  const existingLimit = vi.fn().mockResolvedValue(existingSession == null ? [] : [existingSession]);
  const existingWhere = vi.fn().mockReturnValue({ limit: existingLimit });
  const tombstoneWhere = vi.fn().mockReturnValue({
    limit: vi.fn().mockResolvedValue(options?.deletedSessionId ? [{ sessionId: options.deletedSessionId }] : []),
  });
  const attemptWhere = vi.fn().mockReturnValue({ limit: vi.fn().mockResolvedValue(options?.capturedAttempt ? [options.capturedAttempt] : []) });
  const recomputeWhere = vi.fn().mockResolvedValue(options?.recomputeRows ?? []);
  const txSelect = vi.fn((fields: Record<string, unknown>) => ({
    from: vi.fn((table: unknown) => {
      if (table === readingSessionDeletions) return { where: tombstoneWhere };
      if (table === readingAttempts) return { where: attemptWhere };
      if (table === readingSessions && 'id' in fields) return { where: existingWhere };
      if (table === readingSessions) return { innerJoin: vi.fn().mockReturnValue({ where: recomputeWhere }) };
      throw new Error('Unexpected table in select');
    }),
  }));

  const deleteWhere = vi.fn().mockResolvedValue(undefined);
  const deleteFn = vi.fn().mockReturnValue({ where: deleteWhere });

  const updateWhere = vi.fn().mockResolvedValue(undefined);
  const updateSet = vi.fn().mockReturnValue({ where: updateWhere });
  const txUpdate = vi.fn().mockReturnValue({ set: updateSet });

  const tx = {
    execute: vi.fn().mockResolvedValue(undefined),
    select: txSelect,
    update: txUpdate,
    delete: deleteFn,
    insert: vi.fn((table: unknown) => {
      if (table === readingSessions) return { values: sessionValues };
      if (table === userReadingDailyStats) return { values: dailyValues };
      throw new Error('Unexpected table in insert');
    }),
  };

  const transaction = vi.fn(async (callback: (trx: typeof tx) => Promise<unknown>) => callback(tx));

  const db = { select, transaction };
  const repo = new ReadingSessionRepository(db as never);

  return {
    repo,
    select,
    transaction,
    sessionValues,
    sessionConflict,
    sessionReturning,
    dailyValues,
    dailyConflictUpdate,
    updateSet,
    updateWhere,
    tombstoneWhere,
    existingWhere,
    attemptWhere,
    recomputeWhere,
    deleteWhere,
    tx,
  };
}

describe('ReadingSessionRepository', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('skips when duration is below the minimum threshold', async () => {
    const { repo, select, transaction } = makeDbHarness();

    const result = await repo.saveSession(1, 2, 'short', new Date('2026-04-15T10:00:00.000Z'), new Date('2026-04-15T10:00:09.000Z'), 9, null, null);

    expect(result).toEqual({ kind: 'skipped', reason: 'duration_below_minimum' });
    expect(select).not.toHaveBeenCalled();
    expect(transaction).not.toHaveBeenCalled();
  });

  it('skips when no book file row is found', async () => {
    const { repo, transaction } = makeDbHarness({ fileRow: null });

    const result = await repo.saveSession(
      1,
      9999,
      'missing-file',
      new Date('2026-04-15T10:00:00.000Z'),
      new Date('2026-04-15T10:00:20.000Z'),
      20,
      null,
      null,
    );

    expect(result).toEqual({ kind: 'skipped', reason: 'book_file_not_found' });
    expect(transaction).not.toHaveBeenCalled();
  });

  it('skips when session id already exists (idempotent duplicate)', async () => {
    // A sync-queue retry of a write already stored: same id, same duration. It must stay a no-op.
    const { repo, dailyValues } = makeDbHarness({
      insertedIds: [],
      existingSession: { id: 42, durationSeconds: 60, progressDelta: 3.2 },
    });

    const result = await repo.saveSession(
      5,
      8,
      'duplicate-id',
      new Date('2026-04-15T10:00:00.000Z'),
      new Date('2026-04-15T10:01:00.000Z'),
      60,
      3.2,
      12.5,
    );

    expect(result).toEqual({ kind: 'skipped', reason: 'duplicate_session_id' });
    expect(dailyValues).not.toHaveBeenCalled();
  });

  it('supersedes a checkpointed session when the later write carries more time', async () => {
    // The iOS player checkpoints a session when the app is backgrounded, because `willTerminate`
    // is not delivered if it is then killed, and the later close carries the same sessionId
    // deliberately to replace that partial row. Dropping the second write capped every
    // backgrounded session at the checkpoint: a measured 50s listen recorded 17s.
    const { repo, dailyValues, updateSet } = makeDbHarness({
      fileRow: { bookId: 9, libraryId: 3 },
      insertedIds: [],
      existingSession: { id: 77, durationSeconds: 17, progressDelta: 1.0 },
      recomputeRows: [
        { startedAt: new Date('2026-04-15T10:00:00.000Z'), endedAt: new Date('2026-04-15T10:01:00.000Z'), durationSeconds: 56, progressDelta: 4 },
      ],
    });

    const result = await repo.saveSession(
      5,
      8,
      'checkpointed-id',
      new Date('2026-04-15T10:00:00.000Z'),
      new Date('2026-04-15T10:01:00.000Z'),
      56,
      4.0,
      12.5,
    );

    expect(result).toEqual({ kind: 'superseded', addedSeconds: 39 });
    expect(updateSet).toHaveBeenCalledWith(expect.objectContaining({ durationSeconds: 56 }));
    expect(dailyValues).toHaveBeenCalled();
    const segments = dailyValues.mock.calls[0][0] as Array<{ readingSeconds: number; sessionsCount: number }>;
    expect(segments.reduce((sum, segment) => sum + segment.readingSeconds, 0)).toBe(56);
    expect(segments.reduce((sum, segment) => sum + segment.sessionsCount, 0)).toBe(1);
  });

  it('does not let a stale retry shrink a session', async () => {
    const { repo, dailyValues, updateSet } = makeDbHarness({
      insertedIds: [],
      existingSession: { id: 78, durationSeconds: 90, progressDelta: 2.0 },
    });

    const result = await repo.saveSession(
      5,
      8,
      'already-longer',
      new Date('2026-04-15T10:00:00.000Z'),
      new Date('2026-04-15T10:02:00.000Z'),
      30,
      1.0,
      5.0,
    );

    expect(result).toEqual({ kind: 'skipped', reason: 'duplicate_session_id' });
    expect(updateSet).not.toHaveBeenCalled();
    expect(dailyValues).not.toHaveBeenCalled();
  });

  it('persists session with bookId and explicit source, then upserts daily stats', async () => {
    const { repo, sessionValues, sessionConflict, dailyValues, dailyConflictUpdate, tx } = makeDbHarness({
      fileRow: { bookId: 9, libraryId: 3 },
      insertedIds: [{ id: 99 }],
    });

    const result = await repo.saveSession(
      2,
      4,
      'new-session',
      new Date('2026-04-15T10:00:00.000Z'),
      new Date('2026-04-15T10:01:00.000Z'),
      60,
      null,
      42.5,
      'kobo',
    );

    expect(result).toEqual({ kind: 'saved' });
    expect(sessionValues).toHaveBeenCalledWith(
      expect.objectContaining({
        userId: 2,
        bookFileId: 4,
        bookId: 9,
        sessionId: 'new-session',
        durationSeconds: 60,
        progressDelta: null,
        endProgress: 42.5,
        source: 'kobo',
      }),
    );
    expect(sessionConflict).toHaveBeenCalledWith({ target: [readingSessions.userId, readingSessions.sessionId] });
    expect(tx.execute).toHaveBeenCalledTimes(2);
    expect(dailyValues).toHaveBeenCalledWith([
      expect.objectContaining({
        userId: 2,
        libraryId: 3,
        day: '2026-04-15',
        readingSeconds: 60,
        progressDelta: 0,
        sessionsCount: 1,
        updatedAt: expect.any(Date),
      }),
    ]);
    expect(dailyConflictUpdate).toHaveBeenCalledOnce();
  });

  it('persists the provided source (e.g. kobo) instead of the web default', async () => {
    const { repo, sessionValues } = makeDbHarness({ fileRow: { bookId: 9, libraryId: 3 }, insertedIds: [{ id: 100 }] });

    const result = await repo.saveSession(
      2,
      4,
      'kobo-session',
      new Date('2026-04-15T10:00:00.000Z'),
      new Date('2026-04-15T10:01:00.000Z'),
      60,
      null,
      null,
      'kobo',
    );

    expect(result).toEqual({ kind: 'saved' });
    expect(sessionValues).toHaveBeenCalledWith(expect.objectContaining({ sessionId: 'kobo-session', source: 'kobo' }));
  });

  it('keeps deleted client session identities from being resurrected', async () => {
    const { repo, sessionValues, dailyValues, tombstoneWhere, tx } = makeDbHarness({ deletedSessionId: 'deleted-id' });

    await expect(
      repo.saveSession(5, 8, 'deleted-id', new Date('2026-04-15T10:00:00.000Z'), new Date('2026-04-15T10:01:00.000Z'), 60, null, null),
    ).resolves.toEqual({ kind: 'skipped', reason: 'deleted_session_id' });

    expect(queryParams(tombstoneWhere.mock.calls[0][0])).toEqual([5, 'deleted-id']);
    expect(tx.execute).toHaveBeenCalledOnce();
    expect(sessionValues).not.toHaveBeenCalled();
    expect(dailyValues).not.toHaveBeenCalled();
  });

  it.each([{ bookFileId: 99 }, { source: 'ios' }, { sessionType: 'listen' }, { startedAt: new Date('2026-04-15T10:00:01.000Z') }, { attemptId: 43 }])(
    'rejects a reused checkpoint identity with conflicting fields %o',
    async (conflictingFields) => {
      const { repo, dailyValues, updateSet } = makeDbHarness({
        insertedIds: [],
        capturedAttempt: { id: 42 },
        existingSession: { id: 77, durationSeconds: 17, progressDelta: 1, attemptId: 42, ...conflictingFields },
      });

      await expect(
        repo.saveSession(
          5,
          8,
          'checkpointed-id',
          new Date('2026-04-15T10:00:00.000Z'),
          new Date('2026-04-15T10:01:00.000Z'),
          60,
          null,
          null,
          'web',
          'UTC',
          undefined,
          'read',
          42,
        ),
      ).rejects.toThrow(BadRequestException);
      expect(updateSet).not.toHaveBeenCalled();
      expect(dailyValues).not.toHaveBeenCalled();
    },
  );

  it.each([null, 42])('stores captured attribution %s without looking up a new active attempt', async (attemptId) => {
    const { repo, sessionValues, attemptWhere } = makeDbHarness({ capturedAttempt: { id: 42 } });

    await expect(
      repo.saveSession(
        5,
        8,
        'captured-id',
        new Date('2026-04-15T10:00:00.000Z'),
        new Date('2026-04-15T10:01:00.000Z'),
        60,
        null,
        null,
        'ios',
        'UTC',
        undefined,
        'read',
        attemptId,
      ),
    ).resolves.toEqual({ kind: 'saved' });
    expect(sessionValues).toHaveBeenCalledWith(expect.objectContaining({ attemptId }));
    if (attemptId === null) {
      expect(attemptWhere).not.toHaveBeenCalled();
    } else {
      const query = new PgDialect().sqlToQuery(attemptWhere.mock.calls[0][0]);
      expect(query.params).toEqual([42, 5, 7]);
      expect(query.sql).toContain('"deleted_at" is null');
      expect(query.sql).not.toContain('"outcome" is null');
    }
  });

  it('rejects changing a checkpoint attempt to explicit null', async () => {
    const { repo, dailyValues, updateSet } = makeDbHarness({
      insertedIds: [],
      existingSession: { id: 77, durationSeconds: 17, attemptId: 42 },
    });

    await expect(
      repo.saveSession(
        5,
        8,
        'checkpointed-id',
        new Date('2026-04-15T10:00:00.000Z'),
        new Date('2026-04-15T10:01:00.000Z'),
        60,
        null,
        null,
        'web',
        'UTC',
        undefined,
        'read',
        null,
      ),
    ).rejects.toThrow(BadRequestException);
    expect(updateSet).not.toHaveBeenCalled();
    expect(dailyValues).not.toHaveBeenCalled();
  });

  it('rejects unavailable captured attribution without writing a session or daily stats', async () => {
    const { repo, sessionValues, dailyValues } = makeDbHarness();

    await expect(
      repo.saveSession(
        5,
        8,
        'unavailable-attempt',
        new Date('2026-04-15T10:00:00.000Z'),
        new Date('2026-04-15T10:01:00.000Z'),
        60,
        null,
        null,
        'ios',
        'UTC',
        undefined,
        'read',
        42,
      ),
    ).rejects.toThrow(ForbiddenException);
    expect(sessionValues).not.toHaveBeenCalled();
    expect(dailyValues).not.toHaveBeenCalled();
  });

  it('retains save-time active-attempt lookup for legacy omission', async () => {
    const { repo, sessionValues } = makeDbHarness();

    await repo.saveSession(5, 8, 'legacy-id', new Date('2026-04-15T10:00:00.000Z'), new Date('2026-04-15T10:01:00.000Z'), 60, null, null);

    const attemptId = (sessionValues.mock.calls[0][0] as { attemptId: SQL }).attemptId;
    expect(attemptId).toBeInstanceOf(SQL);
    const query = new PgDialect().sqlToQuery(attemptId);
    expect(query.params).toEqual([5, 7]);
    expect(query.sql).toContain('outcome is null and deleted_at is null');
  });

  it('rejects the enclosing transaction if daily stats fail after inserting a session', async () => {
    const { repo, transaction, dailyConflictUpdate } = makeDbHarness();
    const failure = new Error('daily stats write failed');
    dailyConflictUpdate.mockRejectedValueOnce(failure);

    await expect(
      repo.saveSession(5, 8, 'failed-id', new Date('2026-04-15T10:00:00.000Z'), new Date('2026-04-15T10:01:00.000Z'), 60, null, null),
    ).rejects.toBe(failure);
    await expect(transaction.mock.results[0].value).rejects.toBe(failure);
  });
});

describe('ReadingSessionRepository - insertManualSession', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  function makeManualHarness(options?: { existingSession?: Partial<typeof readingSessions.$inferSelect>; deletedSessionId?: string }) {
    const sessionReturning = vi.fn().mockResolvedValue([{ id: 321 }]);
    const sessionValues = vi.fn().mockReturnValue({ returning: sessionReturning });

    const dailyConflictUpdate = vi.fn().mockResolvedValue(undefined);
    const dailyValues = vi.fn().mockReturnValue({ onConflictDoUpdate: dailyConflictUpdate });

    const tombstoneWhere = vi.fn().mockReturnValue({
      limit: vi.fn().mockResolvedValue(options?.deletedSessionId ? [{ sessionId: options.deletedSessionId }] : []),
    });
    const existingWhere = vi.fn().mockReturnValue({ limit: vi.fn().mockResolvedValue(options?.existingSession ? [options.existingSession] : []) });

    const tx = {
      execute: vi.fn().mockResolvedValue(undefined),
      select: vi.fn().mockReturnValue({
        from: vi.fn((table: unknown) => {
          if (table === readingSessionDeletions) return { where: tombstoneWhere };
          if (table === readingSessions) return { where: existingWhere };
          throw new Error('Unexpected table in select');
        }),
      }),
      insert: vi.fn((table: unknown) => {
        if (table === readingSessions) return { values: sessionValues };
        if (table === userReadingDailyStats) return { values: dailyValues };
        throw new Error('Unexpected table in insert');
      }),
    };

    const transaction = vi.fn(async (callback: (trx: typeof tx) => Promise<unknown>) => callback(tx));
    const db = { transaction };
    const repo = new ReadingSessionRepository(db as never);

    return { repo, sessionValues, dailyValues, dailyConflictUpdate, transaction, tx };
  }

  it('inserts with manual source and upserts daily stats in one transaction', async () => {
    const { repo, sessionValues, dailyValues, dailyConflictUpdate, tx } = makeManualHarness();

    const result = await repo.insertManualSession({
      userId: 5,
      bookId: 10,
      libraryId: 3,
      bookFileId: null,
      sessionId: 'manual:abc',
      startedAt: new Date('2026-04-15T10:00:00.000Z'),
      endedAt: new Date('2026-04-15T10:30:00.000Z'),
      durationSeconds: 1800,
      progressDelta: 12.5,
      endProgress: 60,
      timeZone: 'UTC',
    });

    expect(result).toEqual({ id: 321, attemptId: null });
    expect(sessionValues).toHaveBeenCalledWith(
      expect.objectContaining({
        userId: 5,
        bookId: 10,
        bookFileId: null,
        sessionId: 'manual:abc',
        source: 'manual',
        durationSeconds: 1800,
        progressDelta: 12.5,
        endProgress: 60,
      }),
    );
    expect(dailyValues).toHaveBeenCalledWith([
      expect.objectContaining({ userId: 5, libraryId: 3, day: '2026-04-15', readingSeconds: 1800, progressDelta: 12.5, sessionsCount: 1 }),
    ]);
    expect(tx.execute).toHaveBeenCalledTimes(2);
    expect(dailyConflictUpdate).toHaveBeenCalledOnce();
  });

  const manualParams = {
    userId: 5,
    bookId: 10,
    libraryId: 3,
    bookFileId: null,
    sessionId: 'manual:abc',
    startedAt: new Date('2026-04-15T10:00:00.000Z'),
    endedAt: new Date('2026-04-15T10:30:00.000Z'),
    durationSeconds: 1800,
    progressDelta: 12.5,
    endProgress: 60,
    timeZone: 'UTC',
  };

  it('returns an existing identical manual entry without counting it again', async () => {
    const { repo, sessionValues, dailyValues } = makeManualHarness({
      existingSession: { ...manualParams, id: 321, attemptId: 42, source: 'manual' },
    });

    await expect(repo.insertManualSession(manualParams)).resolves.toEqual({ id: 321, attemptId: 42 });
    expect(sessionValues).not.toHaveBeenCalled();
    expect(dailyValues).not.toHaveBeenCalled();
  });

  it('rejects reuse of a manual identity for a different entry', async () => {
    const { repo, sessionValues, dailyValues } = makeManualHarness({
      existingSession: { ...manualParams, id: 321, source: 'manual', bookId: 99 },
    });

    await expect(repo.insertManualSession(manualParams)).rejects.toThrow(BadRequestException);
    expect(sessionValues).not.toHaveBeenCalled();
    expect(dailyValues).not.toHaveBeenCalled();
  });

  it('rejects replay of a deleted manual entry without recreating it', async () => {
    const { repo, sessionValues, dailyValues } = makeManualHarness({ deletedSessionId: manualParams.sessionId });

    await expect(repo.insertManualSession(manualParams)).rejects.toThrow(BadRequestException);
    expect(sessionValues).not.toHaveBeenCalled();
    expect(dailyValues).not.toHaveBeenCalled();
  });
});

describe('ReadingSessionRepository - findLatestEndProgressBefore', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  function makeLookupHarness(rows: Array<{ endProgress: number | null }>) {
    const limit = vi.fn().mockResolvedValue(rows);
    const orderBy = vi.fn().mockReturnValue({ limit });
    const where = vi.fn().mockReturnValue({ orderBy });
    const from = vi.fn().mockReturnValue({ where });
    const select = vi.fn().mockReturnValue({ from });
    const db = { select };
    return new ReadingSessionRepository(db as never);
  }

  it('returns the latest end progress when present', async () => {
    const repo = makeLookupHarness([{ endProgress: 42.5 }]);
    await expect(repo.findLatestEndProgressBefore(1, 2, new Date())).resolves.toBe(42.5);
  });

  it('returns null when no prior session exists', async () => {
    const repo = makeLookupHarness([]);
    await expect(repo.findLatestEndProgressBefore(1, 2, new Date())).resolves.toBeNull();
  });
});

describe('ReadingSessionRepository - findBookContext', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('returns libraryId and files for an existing book', async () => {
    const bookLimit = vi.fn().mockResolvedValue([{ libraryId: 3 }]);
    const bookWhere = vi.fn().mockReturnValue({ limit: bookLimit });
    const filesWhere = vi.fn().mockResolvedValue([{ id: 42, format: 'epub' }]);
    const from = vi.fn().mockReturnValueOnce({ where: bookWhere }).mockReturnValueOnce({ where: filesWhere });
    const select = vi.fn().mockReturnValue({ from });
    const repo = new ReadingSessionRepository({ select } as never);

    const result = await repo.findBookContext(10);

    expect(result).toEqual({ libraryId: 3, files: [{ id: 42, format: 'epub' }] });
  });

  it('returns null when the book does not exist', async () => {
    const bookLimit = vi.fn().mockResolvedValue([]);
    const bookWhere = vi.fn().mockReturnValue({ limit: bookLimit });
    const from = vi.fn().mockReturnValue({ where: bookWhere });
    const select = vi.fn().mockReturnValue({ from });
    const repo = new ReadingSessionRepository({ select } as never);

    await expect(repo.findBookContext(10)).resolves.toBeNull();
  });
});

describe('ReadingSessionRepository - listByBook', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  function makeQueryChain(result: unknown) {
    const self: Record<string, unknown> = {};
    const terminal = Promise.resolve(result);
    for (const m of ['from', 'innerJoin', 'leftJoin', 'where', 'orderBy', 'limit', 'offset', 'groupBy']) {
      self[m] = vi.fn().mockReturnValue(self);
    }
    self['then'] = (onFulfilled: (v: unknown) => unknown, onRejected: (e: unknown) => unknown) => terminal.then(onFulfilled, onRejected);
    self['catch'] = (onRejected: (e: unknown) => unknown) => terminal.catch(onRejected);
    return self;
  }

  function makeListDb(results: {
    rows?: unknown[];
    count?: unknown[];
    stats?: unknown[];
    summary?: unknown[];
    bySource?: unknown[];
    latest?: unknown[];
  }) {
    const select = vi
      .fn()
      .mockReturnValueOnce({ from: vi.fn().mockReturnValue(makeQueryChain(results.rows ?? [])) })
      .mockReturnValueOnce({ from: vi.fn().mockReturnValue(makeQueryChain(results.count ?? [])) })
      .mockReturnValueOnce({ from: vi.fn().mockReturnValue(makeQueryChain(results.stats ?? [])) })
      .mockReturnValueOnce({ from: vi.fn().mockReturnValue(makeQueryChain(results.summary ?? [])) })
      .mockReturnValueOnce({ from: vi.fn().mockReturnValue(makeQueryChain(results.bySource ?? [])) })
      .mockReturnValueOnce({ from: vi.fn().mockReturnValue(makeQueryChain(results.latest ?? [])) });
    return { db: { select }, select };
  }

  it('returns items, total, and stats with correct structure', async () => {
    const now = new Date('2026-04-15T10:00:00.000Z');
    const later = new Date('2026-04-15T10:30:00.000Z');

    const { db } = makeListDb({
      rows: [
        {
          id: 1,
          bookFileId: 42,
          startedAt: now,
          endedAt: later,
          durationSeconds: 1800,
          progressDelta: 5,
          endProgress: 50,
          format: 'epub',
          source: 'web',
        },
      ],
      count: [{ total: 1 }],
      stats: [
        {
          totalSessions: 1,
          totalSeconds: 1800,
          avgDurationSeconds: 1800,
          firstSessionAt: now,
          lastSessionAt: now,
          paceProgressDelta: 5,
          paceDurationSeconds: 1800,
        },
      ],
      summary: [{ startedAt: now, endedAt: later, durationSeconds: 1800, progressDelta: 5, endProgress: 50 }],
    });
    const repo = new ReadingSessionRepository(db as never);

    const result = await repo.listByBook(1, 2, 1, 25, 'startedAt', 'desc');

    expect(result.total).toBe(1);
    expect(result.stats.totalSessions).toBe(1);
    expect(result.stats.dailySummary).toEqual([{ day: '2026-04-15', totalMinutes: 30 }]);
    expect(result.stats.paceProgressDelta).toBe(5);
    expect(result.stats.paceDurationSeconds).toBe(1800);
    expect(result.stats.progressSummary).toEqual([{ day: '2026-04-15', endProgress: 50 }]);
    expect(result.items).toHaveLength(1);
    expect(result.items[0]?.bookFileId).toBe(42);
    expect(result.items[0]?.startedAt).toBe(now.toISOString());
    expect(result.items[0]?.source).toBe('web');
  });

  it('returns each session type and reads unknown or missing types as reading', async () => {
    const now = new Date('2026-04-15T10:00:00.000Z');
    const later = new Date('2026-04-15T10:30:00.000Z');
    const base = {
      bookFileId: 42,
      startedAt: now,
      endedAt: later,
      durationSeconds: 1800,
      progressDelta: 1,
      endProgress: 50,
      format: 'epub',
      source: 'ios',
    };
    const { db } = makeListDb({
      rows: [
        { ...base, id: 1, sessionType: 'listen' },
        { ...base, id: 2, sessionType: 'tts' },
        { ...base, id: 3, sessionType: 'read' },
        { ...base, id: 4, sessionType: 'hologram' },
        { ...base, id: 5 },
      ],
      count: [{ total: 5 }],
    });
    const repo = new ReadingSessionRepository(db as never);

    const result = await repo.listByBook(1, 2, 1, 25, 'startedAt', 'desc');

    expect(result.items.map((item) => item.sessionType)).toEqual(['listen', 'tts', 'read', 'read', 'read']);
  });

  it('fires six select queries', async () => {
    const { db, select } = makeListDb({});
    const repo = new ReadingSessionRepository(db as never);

    await repo.listByBook(1, 2, 2, 25, 'startedAt', 'desc');

    expect(select).toHaveBeenCalledTimes(6);
  });

  it('splits per-book daily summaries across local midnight', async () => {
    const startedAt = new Date('2026-04-16T03:00:00.000Z');
    const endedAt = new Date('2026-04-16T04:30:00.000Z');
    const { db } = makeListDb({
      count: [{ total: 1 }],
      stats: [{ totalSessions: 1, totalSeconds: 5400, avgDurationSeconds: 5400, firstSessionAt: startedAt, lastSessionAt: startedAt }],
      summary: [{ startedAt, endedAt, durationSeconds: 5400, progressDelta: 9, endProgress: 12 }],
    });
    const repo = new ReadingSessionRepository(db as never);

    const result = await repo.listByBook(1, 2, 1, 25, 'startedAt', 'desc', undefined, undefined, undefined, 'America/New_York');

    expect(result.stats.dailySummary).toEqual([
      { day: '2026-04-15', totalMinutes: 60 },
      { day: '2026-04-16', totalMinutes: 30 },
    ]);
    expect(result.stats.progressSummary).toEqual([{ day: '2026-04-16', endProgress: 12 }]);
  });

  it('returns empty items and zero stats when no data', async () => {
    const { db } = makeListDb({});
    const repo = new ReadingSessionRepository(db as never);

    const result = await repo.listByBook(1, 2, 1, 25, 'startedAt', 'desc');

    expect(result.items).toEqual([]);
    expect(result.total).toBe(0);
    expect(result.stats.totalSessions).toBe(0);
    expect(result.stats.dailySummary).toEqual([]);
    expect(result.stats.paceProgressDelta).toBe(0);
    expect(result.stats.paceDurationSeconds).toBe(0);
    expect(result.stats.progressSummary).toEqual([]);
  });

  it('handles null statsRow gracefully', async () => {
    const { db } = makeListDb({});
    const repo = new ReadingSessionRepository(db as never);

    const result = await repo.listByBook(1, 2, 1, 25, 'startedAt', 'desc');

    expect(result.stats.totalSessions).toBe(0);
    expect(result.stats.firstSessionAt).toBeNull();
    expect(result.stats.lastSessionAt).toBeNull();
  });

  it('converts Date stats fields to ISO strings', async () => {
    const now = new Date('2026-04-15T10:00:00.000Z');
    const { db } = makeListDb({
      count: [{ total: 1 }],
      stats: [{ totalSessions: 1, totalSeconds: 60, avgDurationSeconds: 60, firstSessionAt: now, lastSessionAt: now }],
    });
    const repo = new ReadingSessionRepository(db as never);

    const result = await repo.listByBook(1, 2, 1, 25, 'startedAt', 'desc');

    expect(result.stats.firstSessionAt).toBe(now.toISOString());
    expect(result.stats.lastSessionAt).toBe(now.toISOString());
  });

  it('maps null format and null source to null in items', async () => {
    const now = new Date('2026-04-15T10:00:00.000Z');
    const { db } = makeListDb({
      rows: [
        {
          id: 1,
          bookFileId: null,
          startedAt: now,
          endedAt: now,
          durationSeconds: 60,
          progressDelta: null,
          endProgress: null,
          format: null,
          source: null,
        },
      ],
      count: [{ total: 1 }],
      stats: [{ totalSessions: 1, totalSeconds: 60, avgDurationSeconds: 60, firstSessionAt: null, lastSessionAt: null }],
    });
    const repo = new ReadingSessionRepository(db as never);

    const result = await repo.listByBook(1, 2, 1, 25, 'startedAt', 'desc');

    expect(result.items[0]?.bookFileId).toBeNull();
    expect(result.items[0]?.format).toBeNull();
    expect(result.items[0]?.source).toBeNull();
  });

  it('applies dateFrom and dateTo when provided', async () => {
    const { db } = makeListDb({});
    const repo = new ReadingSessionRepository(db as never);

    await expect(repo.listByBook(1, 2, 1, 25, 'startedAt', 'desc', '2026-01-01', '2026-12-31')).resolves.toBeDefined();
  });

  it('supports asc sort direction', async () => {
    const { db } = makeListDb({});
    const repo = new ReadingSessionRepository(db as never);

    await expect(repo.listByBook(1, 2, 1, 25, 'startedAt', 'asc')).resolves.toBeDefined();
  });

  it('keeps native Apple sources distinct while folding legacy BookOrbit sessions', async () => {
    const { db } = makeListDb({
      count: [{ total: 5 }],
      stats: [{ totalSessions: 5, totalSeconds: 380, avgDurationSeconds: 76, firstSessionAt: null, lastSessionAt: null }],
      bySource: [
        { source: 'web', totalSeconds: 100, totalSessions: 1 },
        { source: 'manual', totalSeconds: 50, totalSessions: 1 },
        { source: null, totalSeconds: 30, totalSessions: 1 },
        { source: 'ios', totalSeconds: 70, totalSessions: 1 },
        { source: 'watchos', totalSeconds: 40, totalSessions: 1 },
        { source: 'kobo', totalSeconds: 200, totalSessions: 2 },
      ],
    });
    const repo = new ReadingSessionRepository(db as never);

    const result = await repo.listByBook(1, 2, 1, 25, 'startedAt', 'desc');

    // web + manual + null collapse into bookorbit; native clients retain identity.
    expect(result.stats.bySource).toEqual([
      { bucket: 'bookorbit', totalSeconds: 180, totalSessions: 3 },
      { bucket: 'ios', totalSeconds: 70, totalSessions: 1 },
      { bucket: 'watchos', totalSeconds: 40, totalSessions: 1 },
      { bucket: 'kobo', totalSeconds: 200, totalSessions: 2 },
    ]);
  });

  it('returns an empty bySource when there are no sessions', async () => {
    const { db } = makeListDb({});
    const repo = new ReadingSessionRepository(db as never);

    const result = await repo.listByBook(1, 2, 1, 25, 'startedAt', 'desc');

    expect(result.stats.bySource).toEqual([]);
  });

  it('exposes the latest recorded end progress on stats', async () => {
    const { db } = makeListDb({ latest: [{ endProgress: 76.5 }] });
    const repo = new ReadingSessionRepository(db as never);

    const result = await repo.listByBook(1, 2, 1, 25, 'startedAt', 'desc');

    expect(result.stats.latestEndProgress).toBe(76.5);
  });

  it('reports a null latest end progress when no session recorded one', async () => {
    const { db } = makeListDb({ latest: [] });
    const repo = new ReadingSessionRepository(db as never);

    const result = await repo.listByBook(1, 2, 1, 25, 'startedAt', 'desc');

    expect(result.stats.latestEndProgress).toBeNull();
  });

  it('keeps the latest end progress outside the date and format filters', async () => {
    const { db } = makeListDb({ rows: [], count: [{ total: 0 }], summary: [], latest: [{ endProgress: 100 }] });
    const repo = new ReadingSessionRepository(db as never);

    const result = await repo.listByBook(1, 2, 1, 25, 'startedAt', 'desc', '2026-01-01', '2026-01-31', 'EPUB');

    expect(result.stats.progressSummary).toEqual([]);
    expect(result.stats.latestEndProgress).toBe(100);
  });
});

describe('ReadingSessionRepository - findLatestEndProgress', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  function makeLatestHarness(rows: Array<{ endProgress: number | null }>) {
    const limit = vi.fn().mockResolvedValue(rows);
    const orderBy = vi.fn().mockReturnValue({ limit });
    const where = vi.fn().mockReturnValue({ orderBy });
    const from = vi.fn().mockReturnValue({ where });
    const select = vi.fn().mockReturnValue({ from });
    const repo = new ReadingSessionRepository({ select } as never);
    return { repo, orderBy, limit, where };
  }

  it('returns the end progress of the most recent session that recorded one', async () => {
    const { repo, orderBy, limit } = makeLatestHarness([{ endProgress: 42.5 }]);

    await expect(repo.findLatestEndProgress(1, 2)).resolves.toBe(42.5);
    expect(orderBy).toHaveBeenCalledTimes(1);
    expect(orderBy.mock.calls[0]).toHaveLength(2);
    expect(limit).toHaveBeenCalledWith(1);
  });

  it('returns null when the book has no session with an end progress', async () => {
    const { repo } = makeLatestHarness([]);

    await expect(repo.findLatestEndProgress(1, 2)).resolves.toBeNull();
  });

  it('returns null when the most recent row carries a null end progress', async () => {
    const { repo } = makeLatestHarness([{ endProgress: null }]);

    await expect(repo.findLatestEndProgress(1, 2)).resolves.toBeNull();
  });
});

describe('ReadingSessionRepository - deleteSessionByBook', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  function makeDeleteHarness(
    sessionRow: { id: number; startedAt: Date; endedAt: Date; durationSeconds: number; progressDelta: number | null; libraryId: number } | null,
    recomputeRows: Array<{ startedAt: Date; endedAt: Date; durationSeconds: number; progressDelta: number | null }> = [],
    identityExists = sessionRow !== null,
  ) {
    const identityWhere = vi.fn().mockReturnValue({ limit: vi.fn().mockResolvedValue(identityExists ? [{ sessionId: 'client-session-5' }] : []) });
    const identityFrom = vi.fn().mockReturnValue({ where: identityWhere });
    const limit = vi.fn().mockResolvedValue(sessionRow ? [{ ...sessionRow, clientSessionId: 'client-session-5' }] : []);
    const lookupWhere = vi.fn().mockReturnValue({ limit });
    const lookupInnerJoin = vi.fn().mockReturnValue({ where: lookupWhere });
    const lookupFrom = vi.fn().mockReturnValue({ innerJoin: lookupInnerJoin });

    const recomputeWhere = vi.fn().mockResolvedValue(recomputeRows);
    const recomputeInnerJoin = vi.fn().mockReturnValue({ where: recomputeWhere });
    const recomputeFrom = vi.fn().mockReturnValue({ innerJoin: recomputeInnerJoin });
    const select = vi
      .fn()
      .mockReturnValueOnce({ from: identityFrom })
      .mockReturnValueOnce({ from: lookupFrom })
      .mockReturnValue({ from: recomputeFrom });

    const deleteWhere = vi.fn().mockResolvedValue(undefined);
    const deleteFn = vi.fn().mockReturnValue({ where: deleteWhere });
    const dailyConflictUpdate = vi.fn().mockResolvedValue(undefined);
    const dailyValues = vi.fn().mockReturnValue({ onConflictDoUpdate: dailyConflictUpdate });
    const tombstoneValues = vi.fn().mockReturnValue({ onConflictDoNothing: vi.fn().mockResolvedValue(undefined) });
    const insert = vi.fn((table: unknown) => {
      if (table === userReadingDailyStats) return { values: dailyValues };
      if (table === readingSessionDeletions) return { values: tombstoneValues };
      throw new Error('Unexpected table in insert');
    });

    const tx = { execute: vi.fn().mockResolvedValue(undefined), select, delete: deleteFn, insert };
    const transaction = vi.fn(async (cb: (trx: typeof tx) => Promise<unknown>) => cb(tx));
    const db = { transaction };
    const repo = new ReadingSessionRepository(db as never);

    return {
      repo,
      innerJoin: lookupInnerJoin,
      identityWhere,
      lookupWhere,
      recomputeWhere,
      deleteWhere,
      deleteFn,
      dailyValues,
      tombstoneValues,
      transaction,
      tx,
    };
  }

  it('returns { found: false } when session not found', async () => {
    const { repo, tx, tombstoneValues } = makeDeleteHarness(null);

    const result = await repo.deleteSessionByBook(1, 2, 99);

    expect(result).toEqual({ found: false });
    expect(tx.execute).not.toHaveBeenCalled();
    expect(tombstoneValues).not.toHaveBeenCalled();
  });

  it('looks up the session with a single books join', async () => {
    const { repo, innerJoin } = makeDeleteHarness(null, [], true);

    await repo.deleteSessionByBook(1, 2, 99);

    expect(innerJoin).toHaveBeenCalledOnce();
  });

  it('does not delete or create a tombstone if the locked session has disappeared', async () => {
    const { repo, deleteFn, tombstoneValues, tx } = makeDeleteHarness(null, [], true);

    await expect(repo.deleteSessionByBook(1, 2, 5)).resolves.toEqual({ found: false });
    expect(tx.execute).toHaveBeenCalledOnce();
    expect(deleteFn).not.toHaveBeenCalled();
    expect(tombstoneValues).not.toHaveBeenCalled();
  });

  it('returns { found: true } and deletes when session found', async () => {
    const { repo, deleteFn, tombstoneValues, tx } = makeDeleteHarness({
      id: 5,
      startedAt: new Date('2026-04-15T10:00:00.000Z'),
      endedAt: new Date('2026-04-15T10:30:00.000Z'),
      durationSeconds: 1800,
      progressDelta: null,
      libraryId: 3,
    });

    const result = await repo.deleteSessionByBook(1, 2, 5);

    expect(result).toEqual({ found: true });
    expect(deleteFn).toHaveBeenCalledWith(readingSessions);
    expect(tombstoneValues).toHaveBeenCalledWith({ userId: 1, bookId: 2, sessionId: 'client-session-5' });
    expect(tx.execute).toHaveBeenCalledTimes(2);
  });

  it('re-inserts re-aggregated daily stats after deletion when other sessions remain', async () => {
    const { repo, dailyValues, identityWhere, lookupWhere, recomputeWhere, deleteWhere } = makeDeleteHarness(
      {
        id: 5,
        startedAt: new Date('2026-04-15T10:00:00.000Z'),
        endedAt: new Date('2026-04-15T10:30:00.000Z'),
        durationSeconds: 1800,
        progressDelta: null,
        libraryId: 3,
      },
      [
        {
          startedAt: new Date('2026-04-15T11:00:00.000Z'),
          endedAt: new Date('2026-04-15T11:20:00.000Z'),
          durationSeconds: 1200,
          progressDelta: 2,
        },
      ],
    );

    await repo.deleteSessionByBook(1, 2, 5);

    expect(dailyValues).toHaveBeenCalledWith([
      expect.objectContaining({ day: '2026-04-15', readingSeconds: 1200, progressDelta: 2, sessionsCount: 1 }),
    ]);
    expect(queryParams(identityWhere.mock.calls[0][0])).toEqual([5, 1, 2]);
    expect(queryParams(lookupWhere.mock.calls[0][0])).toEqual([5, 1, 2]);
    expect(queryParams(recomputeWhere.mock.calls[0][0]).slice(0, 2)).toEqual([1, 3]);
    expect(queryParams(deleteWhere.mock.calls[0][0])).toEqual([5, 1]);
    expect(queryParams(deleteWhere.mock.calls[1][0])).toEqual([1, 3, '2026-04-15']);
  });

  it('deletes the userReadingDailyStats row for the session day', async () => {
    const { repo, deleteFn } = makeDeleteHarness({
      id: 5,
      startedAt: new Date('2026-04-15T10:00:00.000Z'),
      endedAt: new Date('2026-04-15T10:30:00.000Z'),
      durationSeconds: 1800,
      progressDelta: null,
      libraryId: 3,
    });

    await repo.deleteSessionByBook(1, 2, 5);

    expect(deleteFn).toHaveBeenCalledWith(userReadingDailyStats);
    expect(deleteFn).toHaveBeenCalledTimes(2);
  });

  it('uses a transaction for the entire delete', async () => {
    const { repo, transaction } = makeDeleteHarness(null);

    await repo.deleteSessionByBook(1, 2, 99);

    expect(transaction).toHaveBeenCalledOnce();
  });
});

describe('ReadingSessionRepository - deleteLegacyKoreaderSyncEstimatesBatch', () => {
  function makeCleanupHarness(
    rows: Array<{
      id: number;
      userId: number;
      libraryId: number;
      startedAt: Date;
      endedAt: Date;
      durationSeconds: number;
      progressDelta: number | null;
      userSettings: Record<string, unknown>;
    }>,
  ) {
    const initialLimit = vi.fn().mockResolvedValue(rows);
    const initialSelect = {
      from: vi.fn().mockReturnValue({
        innerJoin: vi.fn().mockReturnValue({
          innerJoin: vi.fn().mockReturnValue({
            where: vi.fn().mockReturnValue({ orderBy: vi.fn().mockReturnValue({ limit: initialLimit }) }),
          }),
        }),
      }),
    };
    const survivingSessions = [
      {
        startedAt: new Date('2026-07-01T10:00:00.000Z'),
        endedAt: new Date('2026-07-01T10:05:00.000Z'),
        durationSeconds: 300,
        progressDelta: 1,
      },
    ];
    const recomputeWhere = vi.fn().mockResolvedValue(survivingSessions);
    const recomputeSelect = {
      from: vi.fn().mockReturnValue({ innerJoin: vi.fn().mockReturnValue({ where: recomputeWhere }) }),
    };
    const select = vi.fn().mockReturnValue(recomputeSelect).mockReturnValueOnce(initialSelect);
    const deleteWhere = vi.fn().mockResolvedValue(undefined);
    const deleteFn = vi.fn().mockReturnValue({ where: deleteWhere });
    const dailyValues = vi.fn().mockReturnValue({ onConflictDoUpdate: vi.fn().mockResolvedValue(undefined) });
    const insert = vi.fn((table: unknown) => {
      if (table === userReadingDailyStats) return { values: dailyValues };
      throw new Error('Unexpected table in insert');
    });
    const tx = { select, delete: deleteFn, insert, execute: vi.fn().mockResolvedValue(undefined) };
    const transaction = vi.fn(async (callback: (trx: typeof tx) => Promise<unknown>) => callback(tx));

    return {
      repo: new ReadingSessionRepository({ transaction } as never),
      deleteFn,
      dailyValues,
      initialLimit,
      recomputeWhere,
      transaction,
    };
  }

  it('deletes one bounded batch and rebuilds the affected daily totals', async () => {
    const { repo, deleteFn, dailyValues, initialLimit } = makeCleanupHarness([
      {
        id: 9,
        userId: 7,
        libraryId: 3,
        startedAt: new Date('2026-07-01T09:45:00.000Z'),
        endedAt: new Date('2026-07-01T10:00:00.000Z'),
        durationSeconds: 900,
        progressDelta: 4,
        userSettings: { timezone: 'UTC' },
      },
    ]);

    await expect(repo.deleteLegacyKoreaderSyncEstimatesBatch(500)).resolves.toEqual({ deleted: 1 });

    expect(initialLimit).toHaveBeenCalledWith(500);
    expect(deleteFn).toHaveBeenCalledWith(readingSessions);
    expect(deleteFn).toHaveBeenCalledWith(userReadingDailyStats);
    expect(dailyValues).toHaveBeenCalledWith([
      expect.objectContaining({ userId: 7, libraryId: 3, day: '2026-07-01', readingSeconds: 300, sessionsCount: 1 }),
    ]);
  });

  it('does not rewrite daily totals when no legacy estimates remain', async () => {
    const { repo, deleteFn, dailyValues, transaction } = makeCleanupHarness([]);

    await expect(repo.deleteLegacyKoreaderSyncEstimatesBatch(500)).resolves.toEqual({ deleted: 0 });

    expect(deleteFn).not.toHaveBeenCalled();
    expect(dailyValues).not.toHaveBeenCalled();
    expect(transaction).toHaveBeenCalledOnce();
  });

  it('recomputes sparse history in bounded date ranges', async () => {
    const row = (id: number, day: string) => ({
      id,
      userId: 7,
      libraryId: 3,
      startedAt: new Date(`${day}T09:45:00.000Z`),
      endedAt: new Date(`${day}T10:00:00.000Z`),
      durationSeconds: 900,
      progressDelta: 4,
      userSettings: { timezone: 'UTC' },
    });
    const { repo, recomputeWhere } = makeCleanupHarness([row(9, '2024-01-01'), row(10, '2026-07-01')]);

    await repo.deleteLegacyKoreaderSyncEstimatesBatch(500);

    expect(recomputeWhere).toHaveBeenCalledTimes(2);
  });
});
