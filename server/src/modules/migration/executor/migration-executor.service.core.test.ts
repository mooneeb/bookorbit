import { RunInterruptedError } from './executor-utils';
import { MigrationExecutorService } from './migration-executor.service';

function makeExecutorService() {
  const repo = {
    findRunById: vi.fn(),
    findBatchCheckpoint: vi.fn(),
    commitBatchCheckpoint: vi.fn(),
    listPlanSourceBatches: vi.fn(),
    findPlanMatchesForBooks: vi.fn(),
    findPlanArtifactById: vi.fn(),
    findSourceById: vi.fn(),
    hasStageMetrics: vi.fn().mockResolvedValue(false),
    clearStageMetrics: vi.fn().mockResolvedValue(undefined),
    updateRunState: vi.fn().mockResolvedValue({ id: 5, state: 'running', currentStage: 'book_covers' }),
    listRunMetrics: vi.fn().mockResolvedValue([]),
  };
  const sharedOverlays = { import: vi.fn().mockResolvedValue(undefined) };
  const covers = { import: vi.fn().mockResolvedValue(undefined) };
  const userState = { import: vi.fn().mockResolvedValue(undefined) };
  const config = { get: vi.fn().mockReturnValue('/app-data') };
  const encryption = { decryptConfig: vi.fn((value: unknown) => value) };
  const progressGateway = { emitProgress: vi.fn() };

  const service = new MigrationExecutorService(
    repo as never,
    sharedOverlays as never,
    covers as never,
    userState as never,
    config as never,
    encryption as never,
    progressGateway as never,
    { notify: vi.fn().mockResolvedValue(undefined) } as never,
  );

  return { service, repo, sharedOverlays, covers, userState, progressGateway };
}

describe('MigrationExecutorService core orchestration', () => {
  it('start ignores duplicate run ids already in progress', async () => {
    const { service } = makeExecutorService();
    const executeSpy = vi.spyOn(service as never, 'execute').mockResolvedValue(undefined);

    service.start(91);
    service.start(91);
    await Promise.resolve();

    expect(executeSpy).toHaveBeenCalledTimes(1);
  });

  it('resolveCompletedStages includes only stages that already have persisted metrics', async () => {
    const { service, repo } = makeExecutorService();
    repo.hasStageMetrics.mockResolvedValueOnce(true).mockResolvedValueOnce(false);

    const completed = await (service as never).resolveCompletedStages(7, 'user_state');

    expect(completed).toEqual(new Set(['shared_overlays']));
    expect(repo.hasStageMetrics).toHaveBeenCalledWith(7, 'shared_overlays');
    expect(repo.hasStageMetrics).toHaveBeenCalledWith(7, 'book_covers');
  });

  it('executeStage skips handler when stage is already marked completed', async () => {
    const { service, repo } = makeExecutorService();
    const handler = vi.fn();

    await (service as never).executeStage(22, 'shared_overlays', new Set(['shared_overlays']), handler);

    expect(handler).not.toHaveBeenCalled();
    expect(repo.clearStageMetrics).not.toHaveBeenCalled();
    expect(repo.updateRunState).not.toHaveBeenCalled();
  });

  it('executeStage clears prior metrics, updates run stage, and executes handler while run is active', async () => {
    const { service, repo } = makeExecutorService();
    repo.findRunById.mockResolvedValue({ id: 22, state: 'running' });
    const handler = vi.fn().mockResolvedValue(undefined);

    await (service as never).executeStage(22, 'shared_overlays', new Set(), handler);

    expect(repo.clearStageMetrics).toHaveBeenCalledWith(22, 'shared_overlays');
    expect(repo.updateRunState).toHaveBeenCalledWith(
      22,
      'running',
      {
        currentStage: 'shared_overlays',
        errorMessage: null,
      },
      'running',
    );
    expect(handler).toHaveBeenCalledTimes(1);
  });

  it('failRun marks the run as failed and returns the previous stage', async () => {
    const { service, repo } = makeExecutorService();
    repo.findRunById.mockResolvedValue({ id: 5, currentStage: 'book_covers' });

    const failedStage = await (service as never).failRun(5, 'boom');

    expect(failedStage).toEqual(expect.objectContaining({ currentStage: 'book_covers' }));
    expect(repo.updateRunState).toHaveBeenCalledWith(
      5,
      'failed',
      expect.objectContaining({
        errorMessage: 'boom',
        endedAt: expect.any(Date),
      }),
      'running',
    );
  });

  it('stops a stage if cancellation wins its conditional update', async () => {
    const { service, repo } = makeExecutorService();
    repo.updateRunState.mockResolvedValue(null);
    const handler = vi.fn();

    await expect((service as never).executeStage(22, 'user_state', new Set(), handler)).rejects.toBeInstanceOf(RunInterruptedError);
    expect(handler).not.toHaveBeenCalled();
    expect(repo.updateRunState).toHaveBeenCalledWith(22, 'running', expect.any(Object), 'running');
  });

  it('does not fail a run when cancellation already won', async () => {
    const { service, repo } = makeExecutorService();
    repo.updateRunState.mockResolvedValue(null);

    await expect((service as never).failRun(5, 'late provider failure')).resolves.toBeNull();
    expect(repo.updateRunState).toHaveBeenCalledWith(5, 'failed', expect.any(Object), 'running');
  });

  it('waitForIdle holds retries until the previous execution has settled', async () => {
    const { service } = makeExecutorService();
    let release!: () => void;
    vi.spyOn(service as never, 'execute').mockImplementation(
      () =>
        new Promise<void>((resolve) => {
          release = resolve;
        }),
    );
    service.start(91);
    const settled = vi.fn();
    const idle = service.waitForIdle(91).then(settled);
    await Promise.resolve();
    expect(settled).not.toHaveBeenCalled();
    release();
    await idle;
    expect(settled).toHaveBeenCalledTimes(1);
  });

  it('emitRunProgress aggregates stage metrics and emits gateway event', async () => {
    const { service, repo, progressGateway } = makeExecutorService();
    repo.listRunMetrics.mockResolvedValue([
      {
        stage: 'shared_overlays',
        entityType: 'book_metadata',
        processed: 4,
        imported: 2,
        skipped: 1,
        unresolved: 1,
        failed: 0,
        updatedAt: new Date('2026-01-01T00:00:00.000Z'),
      },
      {
        stage: 'book_covers',
        entityType: 'book_covers',
        processed: 2,
        imported: 2,
        skipped: 0,
        unresolved: 0,
        failed: 0,
        updatedAt: new Date('2026-01-01T00:00:01.000Z'),
      },
    ]);

    await (service as never).emitRunProgress(77, 'running', 'book_covers');

    expect(progressGateway.emitProgress).toHaveBeenCalledWith(
      expect.objectContaining({
        runId: 77,
        state: 'running',
        currentStage: 'book_covers',
        totals: {
          processed: 6,
          imported: 4,
          skipped: 1,
          unresolved: 1,
          failed: 0,
        },
      }),
    );
  });

  it('emitRunProgress swallows progress emission failures', async () => {
    const { service, repo, progressGateway } = makeExecutorService();
    repo.listRunMetrics.mockResolvedValue([
      {
        stage: 'shared_overlays',
        entityType: 'book_metadata',
        processed: 1,
        imported: 1,
        skipped: 0,
        unresolved: 0,
        failed: 0,
        updatedAt: new Date(),
      },
    ]);
    progressGateway.emitProgress.mockImplementation(() => {
      throw new Error('socket down');
    });

    await expect((service as never).emitRunProgress(1, 'running', 'shared_overlays')).resolves.toBeUndefined();
  });

  it('execute marks run as failed when source or plan artifact is missing', async () => {
    const { service, repo } = makeExecutorService();
    repo.findRunById.mockResolvedValue({ id: 5, state: 'running', sourceId: 1, planArtifactId: 9 });
    repo.findPlanArtifactById.mockResolvedValue(null);
    repo.findSourceById.mockResolvedValue({ id: 1, type: 'booklore' });

    await (service as never).execute(5);

    expect(repo.updateRunState).toHaveBeenCalledWith(
      5,
      'failed',
      expect.objectContaining({
        errorMessage: 'Migration run references missing source or plan artifact',
      }),
      'running',
    );
  });

  it('execute marks run as failed when run has no dry-run plan artifact id', async () => {
    const { service, repo, sharedOverlays, covers, userState } = makeExecutorService();
    repo.findRunById.mockResolvedValue({ id: 8, state: 'running', sourceId: 1, planArtifactId: null, currentStage: 'init' });

    await (service as never).execute(8);

    expect(repo.updateRunState).toHaveBeenCalledWith(
      8,
      'failed',
      expect.objectContaining({
        errorMessage: 'Migration run is missing a dry-run plan artifact',
      }),
      'running',
    );
    expect(sharedOverlays.import).not.toHaveBeenCalled();
    expect(covers.import).not.toHaveBeenCalled();
    expect(userState.import).not.toHaveBeenCalled();
  });

  it('execute marks run as failed when plan artifact source data is missing', async () => {
    const { service, repo } = makeExecutorService();
    repo.findRunById.mockResolvedValue({ id: 9, state: 'running', sourceId: 1, planArtifactId: 10, currentStage: 'init' });
    repo.findPlanArtifactById.mockResolvedValue({
      id: 10,
      plan: { matchedBooks: [], unresolvedBooks: [] },
      sourceData: null,
    });
    repo.findSourceById.mockResolvedValue({
      id: 1,
      type: 'booklore',
      connectionConfig: {
        host: 'localhost',
        user: 'reader',
        password: 'secret',
        database: 'booklore',
        mediaRootPath: '/tmp/booklore-media',
      },
    });

    await (service as never).execute(9);

    expect(repo.updateRunState).toHaveBeenCalledWith(
      9,
      'failed',
      expect.objectContaining({
        errorMessage: 'Plan artifact is missing cached source data. Re-run dry-run.',
      }),
      'running',
    );
  });

  it('execute runs stages in order and marks run completed', async () => {
    const { service, repo, sharedOverlays, covers, userState, progressGateway } = makeExecutorService();
    repo.findRunById.mockResolvedValue({ id: 11, state: 'running', sourceId: 1, planArtifactId: 44, currentStage: 'init' });
    repo.findPlanArtifactById.mockResolvedValue({
      id: 44,
      plan: { matchedBooks: [{ sourceBookId: 'source-1', targetBookId: 901 }], unresolvedBooks: [] },
      sourceData: { books: [] },
    });
    repo.findSourceById.mockResolvedValue({
      id: 1,
      type: 'booklore',
      connectionConfig: {
        host: 'localhost',
        user: 'reader',
        password: 'secret',
        database: 'booklore',
        mediaRootPath: '/tmp/booklore-media',
      },
    });

    await (service as never).execute(11);

    expect(sharedOverlays.import).toHaveBeenCalledWith(11, expect.any(Object), expect.any(Function));
    expect(covers.import).toHaveBeenCalledWith(11, expect.any(Object), '/app-data', '/tmp/booklore-media', expect.any(Function));
    expect(userState.import).toHaveBeenCalledWith(11, expect.any(Object), expect.any(Function));
    expect(repo.updateRunState).toHaveBeenCalledWith(
      11,
      'completed',
      expect.objectContaining({
        currentStage: 'completed',
        errorMessage: null,
      }),
      'running',
    );

    const emittedStates = progressGateway.emitProgress.mock.calls.map((call) => call[0].state);
    expect(emittedStates).toEqual(['running', 'running', 'completed']);
  });

  it('execute exits cleanly without failing the run when interrupted', async () => {
    const { service, repo, sharedOverlays, progressGateway } = makeExecutorService();
    const running = { id: 12, state: 'running', sourceId: 1, planArtifactId: 77, currentStage: 'init' };
    repo.findRunById.mockResolvedValueOnce(running).mockResolvedValueOnce({ ...running, state: 'cancelled' });
    repo.findPlanArtifactById.mockResolvedValue({
      id: 77,
      plan: { matchedBooks: [], unresolvedBooks: [] },
      sourceData: { books: [] },
    });
    repo.findSourceById.mockResolvedValue({
      id: 1,
      type: 'booklore',
      connectionConfig: {
        host: 'localhost',
        user: 'reader',
        password: 'secret',
        database: 'booklore',
        mediaRootPath: '/tmp/booklore-media',
      },
    });

    await (service as never).execute(12);

    const terminalStates = repo.updateRunState.mock.calls.map((call) => call[1]);
    expect(terminalStates).not.toContain('failed');
    expect(terminalStates).not.toContain('completed');
    expect(sharedOverlays.import).not.toHaveBeenCalled();
    expect(progressGateway.emitProgress).not.toHaveBeenCalled();
  });

  it('does not announce completion when cancellation wins the final conditional update', async () => {
    const { service, repo, progressGateway } = makeExecutorService();
    repo.findRunById.mockResolvedValue({ id: 11, state: 'running', sourceId: 1, planArtifactId: 44, currentStage: 'init' });
    repo.findPlanArtifactById.mockResolvedValue({ id: 44, plan: { matchedBooks: [], unresolvedBooks: [] }, sourceData: { books: [] } });
    repo.findSourceById.mockResolvedValue({ id: 1, type: 'custom', connectionConfig: {} });
    repo.updateRunState.mockImplementation((_runId, state) => Promise.resolve(state === 'completed' ? null : { id: 11, state }));

    await (service as never).execute(11);

    expect(repo.updateRunState).toHaveBeenCalledWith(11, 'completed', expect.any(Object), 'running');
    expect(repo.updateRunState.mock.calls.some((call) => call[1] === 'failed')).toBe(false);
    expect(progressGateway.emitProgress.mock.calls.some((call) => call[0].state === 'completed')).toBe(false);
  });

  it('resolveSourceMediaRootPath handles non-booklore and missing media root paths', () => {
    const { service } = makeExecutorService();

    expect((service as never).resolveSourceMediaRootPath('custom', { foo: 'bar' })).toBeNull();
    expect(
      (service as never).resolveSourceMediaRootPath('booklore', {
        host: 'localhost',
        user: 'reader',
        password: 'secret',
        database: 'booklore',
      }),
    ).toBeNull();
  });
});

describe('durable matched batches with bounded plan previews', () => {
  it('resumes the same run after a committed batch and imports all 105 matches and 501 bookmarks', async () => {
    const { service, repo, userState } = makeExecutorService();
    const matches = Array.from({ length: 105 }, (_, i) => ({ sourceBookId: String(i), targetBookId: i + 1, strategy: 'isbn' }));
    const data = (start: number, count: number, bookmarkCount: number) => ({
      users: [],
      books: matches.slice(start, start + count).map((match) => ({ sourceBookId: match.sourceBookId })),
      userBookStatuses: [],
      userFileProgress: [],
      readingSessions: [],
      annotations: [],
      shelves: [],
      shelfBooks: [],
      bookmarks: Array.from({ length: bookmarkCount }, (_, index) => ({ sourceBookId: String(start + (index % count)) })),
    });
    const batches = [
      { batchIndex: 0, bookOverlays: 1, sourceData: data(0, 100, 500) },
      { batchIndex: 1, bookOverlays: 1, sourceData: data(100, 5, 1) },
    ];
    const checkpoints = new Map<string, { batchIndex: number; metrics: unknown[] }>();
    repo.findBatchCheckpoint.mockImplementation((_runId, stage) => Promise.resolve(checkpoints.get(stage)));
    repo.commitBatchCheckpoint.mockImplementation((_runId, stage, batchIndex, metrics) => {
      checkpoints.set(stage, { batchIndex, metrics });
      return Promise.resolve();
    });
    repo.listPlanSourceBatches.mockImplementation((_artifactId, cursor) =>
      Promise.resolve(batches.filter((batch) => batch.batchIndex > cursor).slice(0, 1)),
    );
    repo.findPlanMatchesForBooks.mockImplementation((_artifactId, ids: string[]) =>
      Promise.resolve(matches.filter((match) => ids.includes(match.sourceBookId))),
    );
    repo.findRunById.mockResolvedValue({ id: 5, state: 'running' });
    const imported = new Set<string>();
    let bookmarks = 0;
    let interrupted = false;
    userState.import.mockImplementation((_runId, planned) => {
      if (planned.execution.matchedBooks[0].sourceBookId === '100' && !interrupted) {
        interrupted = true;
        return Promise.reject(new RunInterruptedError(5, 'failed'));
      }
      for (const match of planned.execution.matchedBooks) imported.add(match.sourceBookId);
      bookmarks += planned.execution.sourceData.bookmarks.length;
      return Promise.resolve();
    });
    const plan = { matchedBooksBatched: true, matchedBooks: matches.slice(0, 40), unresolvedBooks: [] };
    await expect((service as never).executeDurableStages(5, 1, plan, null)).rejects.toBeInstanceOf(RunInterruptedError);
    expect(checkpoints.get('user_state')?.batchIndex).toBe(0);
    expect(imported.size).toBe(100);
    await (service as never).executeDurableStages(5, 1, plan, null);
    expect(imported.size).toBe(105);
    expect(bookmarks).toBe(501);
    expect(userState.import).toHaveBeenCalledTimes(3);
    expect(repo.findPlanMatchesForBooks).toHaveBeenCalledWith(1, expect.arrayContaining(['104']));
  });
});
