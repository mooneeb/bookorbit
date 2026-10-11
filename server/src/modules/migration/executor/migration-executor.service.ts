import { BadRequestException, Inject, Injectable, Logger, Optional } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';

import type { MigrationProgressEvent } from '@bookorbit/types';
import { NotificationType } from '@bookorbit/types';
import { NotificationService } from '../../notification/notification.service';
import { asRecord } from '../core/coerce';
import { parseConnectionConfig } from '../core/connection-config';
import { MigrationEncryptionService } from '../core/migration-encryption.service';
import type { SourceExportData } from '../adapters/source-adapter.types';
import type { PlannedBookMatch, PlannedUnresolvedBook, PlannerResult, PlannedMigration } from '../planner/planner.types';
import { sanitizeLogValue } from '../../../common/utils/log-sanitize.utils';
import { MigrationRepository, type MigrationBatchMetric } from '../migration.repository';
import { MigrationProgressGateway } from '../migration-progress.gateway';
import { SharedOverlaysImporter } from './shared-overlays.importer';
import { CoverImporter } from './cover.importer';
import { UserStateImporter } from './user-state.importer';
import { RunInterruptedError, type RunStateCheck } from './executor-utils';
import { MIGRATION_EXECUTION_CHECKPOINT, type MigrationExecutionCheckpoint } from './migration-checkpoint';

const STAGE_ORDER = ['shared_overlays', 'book_covers', 'user_state'] as const;

@Injectable()
export class MigrationExecutorService {
  private readonly logger = new Logger(MigrationExecutorService.name);
  private readonly running = new Set<number>();
  private readonly executions = new Map<number, Promise<void>>();
  private readonly restartRequested = new Set<number>();
  private readonly appDataPath: string;

  constructor(
    private readonly repo: MigrationRepository,
    private readonly sharedOverlays: SharedOverlaysImporter,
    private readonly covers: CoverImporter,
    private readonly userState: UserStateImporter,
    private readonly config: ConfigService,
    private readonly encryption: MigrationEncryptionService,
    private readonly progressGateway: MigrationProgressGateway,
    private readonly notificationService: NotificationService,
    @Optional() @Inject(MIGRATION_EXECUTION_CHECKPOINT) private readonly checkpoint?: MigrationExecutionCheckpoint,
  ) {
    this.appDataPath = this.config.get<string>('storage.appDataPath')!;
  }

  start(runId: number): void {
    if (this.running.has(runId)) {
      this.restartRequested.add(runId);
      return;
    }
    this.running.add(runId);

    const execution = this.execute(runId).finally(async () => {
      this.running.delete(runId);
      this.executions.delete(runId);
      if (this.restartRequested.delete(runId)) {
        const run = await this.repo.findRunById(runId);
        if (run?.state === 'running') this.start(runId);
      }
    });
    this.executions.set(runId, execution);
  }

  async waitForIdle(runId: number): Promise<void> {
    await this.executions.get(runId);
  }

  private async execute(runId: number): Promise<void> {
    const startMs = Date.now();
    this.logger.log(`[migration.execute] [start] runId=${runId} - migration execution started`);

    const run = await this.repo.findRunById(runId);
    if (!run) return;
    if (run.state !== 'running') return;
    if (!run.planArtifactId) {
      await this.failRun(runId, 'Migration run is missing a dry-run plan artifact');
      return;
    }

    const artifact = await this.repo.findPlanArtifactById(run.planArtifactId);
    const source = await this.repo.findSourceById(run.sourceId);

    if (!artifact || !source) {
      await this.failRun(runId, 'Migration run references missing source or plan artifact');
      return;
    }

    try {
      const artifactPlan = asRecord(artifact.plan) as unknown as PlannedMigration;
      const sourceData = artifact.sourceData as SourceExportData | null;
      if (!sourceData && !asRecord(artifact.summary).sourceBatches) {
        throw new BadRequestException('Plan artifact is missing cached source data. Re-run dry-run.');
      }

      const matchedBooks = Array.isArray(artifactPlan.matchedBooks) ? (artifactPlan.matchedBooks as PlannedBookMatch[]) : [];
      const unresolvedBooks = Array.isArray(artifactPlan.unresolvedBooks) ? (artifactPlan.unresolvedBooks as PlannedUnresolvedBook[]) : [];

      const planned: PlannerResult = {
        plan: artifactPlan,
        execution: {
          sourceData: sourceData ?? {
            users: [],
            books: [],
            userBookStatuses: [],
            userFileProgress: [],
            readingSessions: [],
            bookmarks: [],
            annotations: [],
            shelves: [],
            shelfBooks: [],
          },
          matchedBooks,
          unresolvedBooks,
          duplicateBookMatches: Array.isArray(artifactPlan.duplicateBookMatches) ? artifactPlan.duplicateBookMatches : [],
        },
      };

      const decryptedConfig = this.encryption.decryptConfig(source.connectionConfig);
      const sourceMediaRootPath = this.resolveSourceMediaRootPath(source.type, decryptedConfig);

      if (!sourceData) {
        await this.executeDurableStages(runId, artifact.id, artifactPlan, sourceMediaRootPath);
      } else {
        const completedStages = await this.resolveCompletedStages(runId, run.currentStage);

        await this.executeStage(runId, 'shared_overlays', completedStages, async (ensureRunning) =>
          this.sharedOverlays.import(runId, planned, ensureRunning),
        );
        await this.emitRunProgress(runId, 'running', 'shared_overlays');

        await this.executeStage(runId, 'book_covers', completedStages, async (ensureRunning) =>
          this.covers.import(runId, planned, this.appDataPath, sourceMediaRootPath, ensureRunning),
        );
        await this.emitRunProgress(runId, 'running', 'book_covers');

        await this.executeStage(runId, 'user_state', completedStages, async (ensureRunning) => this.userState.import(runId, planned, ensureRunning));
      }
      await this.checkpoint?.({ runId, stage: 'completed', batchIndex: 0 });
      await this.assertRunIsRunning(runId);

      const completed = await this.repo.updateRunState(
        runId,
        'completed',
        {
          currentStage: 'completed',
          endedAt: new Date(),
          errorMessage: null,
        },
        'running',
      );
      if (!completed) throw new RunInterruptedError(runId, 'changed');
      await this.emitRunProgress(runId, 'completed', 'completed');

      const durationMs = Date.now() - startMs;
      const summary = asRecord(artifact.summary);
      const matchedCount = typeof summary.matchedBooks === 'number' ? summary.matchedBooks : planned.plan.matchedBooks.length;
      const unresolvedCount = typeof summary.unresolvedBooks === 'number' ? summary.unresolvedBooks : planned.plan.unresolvedBooks.length;
      this.logger.log(
        `[migration.execute] [end] runId=${runId} durationMs=${durationMs} matchedBooks=${matchedCount} unresolvedBooks=${unresolvedCount} - migration execution completed`,
      );

      if (run.triggeredByUserId) {
        this.notificationService
          .notify({
            type: NotificationType.MigrationCompleted,
            title: 'Migration completed',
            message: `Matched ${matchedCount} books, ${unresolvedCount} unresolved`,
            scope: { kind: 'user', userId: run.triggeredByUserId },
            meta: { runId, matchedBooks: matchedCount, unresolvedBooks: unresolvedCount },
          })
          .catch(() => {});
      }
    } catch (error) {
      const durationMs = Date.now() - startMs;
      if (error instanceof RunInterruptedError) {
        this.logger.warn(
          `[migration.execute] [fail] runId=${runId} durationMs=${durationMs} errorClass=RunInterruptedError error="${sanitizeLogValue(`run interrupted (state=${error.state})`)}" - migration interrupted`,
        );
        return;
      }
      const message = error instanceof Error ? error.message : String(error);
      const cause = error instanceof Error && error.cause instanceof Error ? ` cause="${sanitizeLogValue(error.cause.message)}"` : '';
      const errorClass = error instanceof Error ? error.constructor.name : 'UnknownError';
      this.logger.warn(
        `[migration.execute] [fail] runId=${runId} durationMs=${durationMs} errorClass=${errorClass} error="${sanitizeLogValue(message)}"${cause} - migration execution failed`,
      );
      const failed = await this.failRun(runId, message);
      if (!failed) return;
      await this.emitRunProgress(runId, 'failed', failed.currentStage);

      if (run.triggeredByUserId) {
        this.notificationService
          .notify({
            type: NotificationType.MigrationFailed,
            title: 'Migration failed',
            message: message.slice(0, 200),
            scope: { kind: 'user', userId: run.triggeredByUserId },
            meta: { runId },
          })
          .catch(() => {});
      }
    }
  }

  private async executeDurableStages(runId: number, artifactId: number, plan: PlannedMigration, sourceMediaRootPath: string | null): Promise<void> {
    const legacyMatches = asRecord(plan).matchedBooksBatched ? null : new Map(plan.matchedBooks.map((match) => [match.sourceBookId, match]));
    const unresolved = new Map(plan.unresolvedBooks.map((row) => [row.sourceBookId, row]));
    for (const stage of STAGE_ORDER) {
      const checkpoint = await this.repo.findBatchCheckpoint(runId, stage);
      let cursor = checkpoint?.batchIndex ?? -1;
      let totals = Array.isArray(checkpoint?.metrics) ? (checkpoint.metrics as MigrationBatchMetric[]) : [];
      if (checkpoint) await this.repo.commitBatchCheckpoint(runId, stage, cursor, totals);
      else await this.repo.clearStageMetrics(runId, stage);
      const advanced = await this.repo.updateRunState(runId, 'running', { currentStage: stage, errorMessage: null }, 'running');
      if (!advanced) throw new RunInterruptedError(runId, 'changed');
      const ensureRunning = this.createRunStateChecker(runId);
      for (;;) {
        await ensureRunning(true);
        const [batch] = await this.repo.listPlanSourceBatches(artifactId, cursor);
        if (!batch) break;
        await this.checkpoint?.({ runId, stage, batchIndex: batch.batchIndex });
        await ensureRunning(true);
        const sourceData = batch.sourceData as SourceExportData;
        const matchedBooks = legacyMatches
          ? sourceData.books.flatMap((book) => {
              const match = legacyMatches.get(book.sourceBookId);
              return match ? [match] : [];
            })
          : await this.repo.findPlanMatchesForBooks(
              artifactId,
              sourceData.books.map((book) => book.sourceBookId),
            );
        const unresolvedBooks = sourceData.books.flatMap((book) => {
          const row = unresolved.get(book.sourceBookId);
          return row ? [row] : [];
        });
        const planned: PlannerResult = { plan, execution: { sourceData, matchedBooks, unresolvedBooks, duplicateBookMatches: [] } };
        if (stage === 'user_state' || batch.bookOverlays === 1) {
          try {
            if (stage === 'shared_overlays') await this.sharedOverlays.import(runId, planned, ensureRunning);
            else if (stage === 'book_covers') await this.covers.import(runId, planned, this.appDataPath, sourceMediaRootPath, ensureRunning);
            else await this.userState.import(runId, planned, ensureRunning, false);
            await ensureRunning(true);
            const metrics = (await this.repo.listRunMetrics(runId)).filter((metric) => metric.stage === stage);
            const cumulative = new Map(totals.map((metric) => [metric.entityType, { ...metric }]));
            for (const metric of metrics) {
              const previous = cumulative.get(metric.entityType) ?? {
                entityType: metric.entityType,
                processed: 0,
                imported: 0,
                skipped: 0,
                unresolved: 0,
                failed: 0,
              };
              for (const key of ['processed', 'imported', 'skipped', 'unresolved', 'failed'] as const) previous[key] += metric[key];
              cumulative.set(metric.entityType, previous);
            }
            totals = [...cumulative.values()];
          } catch (error) {
            if (cursor >= 0) await this.repo.commitBatchCheckpoint(runId, stage, cursor, totals);
            else await this.repo.clearStageMetrics(runId, stage);
            throw error;
          }
        }
        cursor = batch.batchIndex;
        await this.repo.commitBatchCheckpoint(runId, stage, cursor, totals);
        await this.emitRunProgress(runId, 'running', stage);
      }
    }
  }

  private async resolveCompletedStages(runId: number, currentStage: string | null): Promise<Set<string>> {
    const completed = new Set<string>();
    if (!currentStage || currentStage === 'init') return completed;

    const currentIdx = STAGE_ORDER.indexOf(currentStage as (typeof STAGE_ORDER)[number]);
    if (currentIdx <= 0) return completed;

    for (let i = 0; i < currentIdx; i++) {
      const stage = STAGE_ORDER[i];
      const hasMetrics = await this.repo.hasStageMetrics(runId, stage);
      if (hasMetrics) completed.add(stage);
    }
    return completed;
  }

  private async executeStage(
    runId: number,
    stage: string,
    completedStages: Set<string>,
    handler: (ensureRunning: RunStateCheck) => Promise<void>,
  ): Promise<void> {
    if (completedStages.has(stage)) {
      this.logger.log(`[migration.execute] runId=${runId} stage=${stage} - skipping already completed stage`);
      return;
    }

    await this.repo.clearStageMetrics(runId, stage);
    const advanced = await this.repo.updateRunState(
      runId,
      'running',
      {
        currentStage: stage,
        errorMessage: null,
      },
      'running',
    );
    if (!advanced) throw new RunInterruptedError(runId, 'changed');

    const ensureRunning = this.createRunStateChecker(runId);
    await ensureRunning(true);
    await this.checkpoint?.({ runId, stage, batchIndex: 0 });
    await ensureRunning(true);
    await handler(ensureRunning);
    await ensureRunning(true);
  }

  private createRunStateChecker(runId: number, checkEvery = 25): RunStateCheck {
    let sinceLastCheck = 0;
    return async (force = false) => {
      sinceLastCheck += 1;
      if (!force && sinceLastCheck % checkEvery !== 0) return;
      await this.assertRunIsRunning(runId);
    };
  }

  private async assertRunIsRunning(runId: number): Promise<void> {
    const run = await this.repo.findRunById(runId);
    const state = run?.state ?? 'missing';
    if (!run || state !== 'running') {
      throw new RunInterruptedError(runId, state);
    }
  }

  private resolveSourceMediaRootPath(sourceType: string, connectionConfig: unknown): string | null {
    if (sourceType !== 'booklore') return null;
    const config = parseConnectionConfig(sourceType, connectionConfig) as Record<string, unknown>;
    return typeof config.mediaRootPath === 'string' ? config.mediaRootPath : null;
  }

  private async failRun(runId: number, message: string) {
    return this.repo.updateRunState(
      runId,
      'failed',
      {
        endedAt: new Date(),
        errorMessage: message,
      },
      'running',
    );
  }

  private async emitRunProgress(runId: number, state: string, currentStage: string | null): Promise<void> {
    try {
      const metrics = await this.repo.listRunMetrics(runId);
      const totals = metrics.reduce(
        (acc, row) => ({
          processed: acc.processed + row.processed,
          imported: acc.imported + row.imported,
          skipped: acc.skipped + row.skipped,
          unresolved: acc.unresolved + row.unresolved,
          failed: acc.failed + row.failed,
        }),
        { processed: 0, imported: 0, skipped: 0, unresolved: 0, failed: 0 },
      );

      const event: MigrationProgressEvent = {
        runId,
        state: state as MigrationProgressEvent['state'],
        currentStage,
        totals,
        metrics: metrics.map((m) => ({
          stage: m.stage,
          entityType: m.entityType,
          processed: m.processed,
          imported: m.imported,
          skipped: m.skipped,
          unresolved: m.unresolved,
          failed: m.failed,
          updatedAt: m.updatedAt.toISOString(),
        })),
      };
      this.progressGateway.emitProgress(event);
    } catch {
      // Non-critical: don't let progress emission failures break the migration
    }
  }
}
