import { ForbiddenException, Injectable, Logger, OnModuleInit } from '@nestjs/common';
import { createHash, randomUUID } from 'crypto';
import type { AchievementBackfillResult, MaintenanceOperationStatus } from '@bookorbit/types';
import { sanitizeLogValue } from '../../common/utils/log-sanitize.utils';
import type { RequestUser } from '../../common/types/request-user';
import { AppSettingsService } from '../app-settings/app-settings.service';
import { AchievementRepository } from './achievement.repository';
import { AchievementService } from './achievement.service';
import { ACHIEVEMENT_EVENT_BACKFILL } from './achievement-events.service';
import { ACHIEVEMENT_SEED } from './seed/achievement-seed';

const BATCH_SIZE = 50;
const BACKFILL_SIGNATURE_KEY = 'achievements_backfill_signature';

export type BackfillResult = AchievementBackfillResult;

// Changes to the set of seeded achievement keys mean some users may now qualify for badges that did
// not exist before, so the signature gates a one-off retroactive catch-up after each such change.
function computeSeedSignature(): string {
  const keys = ACHIEVEMENT_SEED.map((a) => a.key).sort();
  return createHash('sha1').update(keys.join(',')).digest('hex');
}

@Injectable()
export class AchievementBackfillService implements OnModuleInit {
  private readonly logger = new Logger(AchievementBackfillService.name);
  private manualRun: Promise<BackfillResult> | null = null;
  private currentStatus: MaintenanceOperationStatus = {
    runId: null,
    status: 'idle',
    processed: 0,
    failed: 0,
    awardsGranted: 0,
    startedAt: null,
    completedAt: null,
  };

  constructor(
    private readonly repo: AchievementRepository,
    private readonly achievementService: AchievementService,
    private readonly appSettings: AppSettingsService,
  ) {}

  onModuleInit(): void {
    void this.runAutoBackfill();
  }

  private requireSuperuser(requestingUser: RequestUser): void {
    if (!requestingUser.isSuperuser) {
      throw new ForbiddenException('Only superusers can trigger achievement backfill');
    }
  }

  status(requestingUser: RequestUser): MaintenanceOperationStatus {
    this.requireSuperuser(requestingUser);
    return { ...this.currentStatus };
  }

  startBackfill(requestingUser: RequestUser): MaintenanceOperationStatus {
    this.requireSuperuser(requestingUser);
    if (this.manualRun) return this.status(requestingUser);
    this.currentStatus = {
      runId: randomUUID(),
      status: 'running',
      processed: 0,
      failed: 0,
      awardsGranted: 0,
      startedAt: new Date().toISOString(),
      completedAt: null,
    };
    const run = this.executeBackfill(requestingUser.id);
    this.manualRun = run;
    void run.then(
      () => {
        this.manualRun = null;
      },
      () => {
        this.manualRun = null;
      },
    );
    return this.status(requestingUser);
  }

  async runBackfill(requestingUser: RequestUser): Promise<BackfillResult> {
    this.startBackfill(requestingUser);
    return this.manualRun!;
  }

  private async executeBackfill(userId: number): Promise<BackfillResult> {
    const event = 'achievement.backfill';
    const startedAt = Date.now();
    this.logger.log(`[${event}] [start] userId=${userId} batchSize=${BATCH_SIZE} - backfill started`);
    try {
      let awardsGranted = 0;
      const usersProcessed = await this.forEachUserInBatches(
        event,
        async (userId) => {
          const count = await this.processUser(userId);
          awardsGranted += count;
          this.currentStatus.awardsGranted = awardsGranted;
        },
        (processed, failed) => {
          this.currentStatus.processed = processed;
          this.currentStatus.failed = failed;
        },
      );
      this.currentStatus.status = 'completed';
      this.currentStatus.completedAt = new Date().toISOString();
      this.logger.log(
        `[${event}] [end] userId=${userId} durationMs=${Date.now() - startedAt} usersProcessed=${usersProcessed} awardsGranted=${awardsGranted} failed=${this.currentStatus.failed} - backfill completed`,
      );
      return { usersProcessed, awardsGranted };
    } catch (error) {
      this.currentStatus.status = 'failed';
      this.currentStatus.completedAt = new Date().toISOString();
      const errorClass = error instanceof Error ? error.name : 'Error';
      this.logger.error(
        `[${event}] [fail] userId=${userId} durationMs=${Date.now() - startedAt} errorClass=${errorClass} error="${sanitizeLogValue(error instanceof Error ? error.message : String(error))}" - backfill failed`,
      );
      throw error;
    }
  }

  // Retroactively awards badges for everything users already did before a newly added achievement existed.
  // Gated by a seed signature so it runs at most once per change to the achievement set, and awards silently
  // (the BACKFILL event suppresses notifications) to avoid flooding users with historical badges.
  private async runAutoBackfill(): Promise<void> {
    const event = 'achievement.auto_backfill';
    const startedAt = Date.now();
    try {
      const signature = computeSeedSignature();
      const stored = await this.appSettings.getValue(BACKFILL_SIGNATURE_KEY);
      if (stored === signature) return;

      // onModuleInit hooks run concurrently (Nest awaits them with Promise.all), so wait for the
      // catalogue seed explicitly: awarding before the new achievement rows exist would fail the FK.
      await this.achievementService.ensureCatalogueSeeded();

      this.logger.log(`[${event}] [start] batchSize=${BATCH_SIZE} - achievement auto-backfill started`);

      const usersProcessed = await this.forEachUserInBatches(event, (userId) =>
        this.achievementService.handleEvent(ACHIEVEMENT_EVENT_BACKFILL, { userId }),
      );

      await this.appSettings.setValue(BACKFILL_SIGNATURE_KEY, signature);
      this.logger.log(`[${event}] [end] usersProcessed=${usersProcessed} durationMs=${Date.now() - startedAt} - achievement auto-backfill completed`);
    } catch (error) {
      const errorMessage = sanitizeLogValue(error instanceof Error ? error.message : String(error));
      const errorClass = error instanceof Error ? error.name : 'Error';
      this.logger.error(
        `[${event}] [fail] durationMs=${Date.now() - startedAt} errorClass=${errorClass} error="${errorMessage}" - achievement auto-backfill failed`,
      );
    }
  }

  private async forEachUserInBatches(
    event: string,
    onUser: (userId: number) => Promise<unknown>,
    onProgress?: (processed: number, failed: number) => void,
  ): Promise<number> {
    let usersProcessed = 0;
    let failed = 0;
    let cursor = 0;
    while (true) {
      const batch = await this.repo.backfillUserIdsAfter(cursor);
      if (batch.length === 0) break;
      const batchStartedAt = Date.now();
      const results = await Promise.allSettled(batch.map((userId) => onUser(userId)));
      for (const [index, result] of results.entries()) {
        if (result.status === 'fulfilled') {
          usersProcessed++;
        } else {
          failed++;
          const errorMessage = sanitizeLogValue(result.reason instanceof Error ? result.reason.message : String(result.reason));
          const errorClass = result.reason instanceof Error ? result.reason.name : 'Error';
          this.logger.warn(
            `[${event}] [fail] userId=${batch[index]} durationMs=${Date.now() - batchStartedAt} errorClass=${errorClass} error="${errorMessage}" - user batch processing failed`,
          );
        }
      }
      cursor = batch[batch.length - 1];
      onProgress?.(usersProcessed, failed);
    }
    return usersProcessed;
  }

  private async processUser(userId: number): Promise<number> {
    const earnedKeysBefore = await this.repo.findUserEarnedKeys(userId);
    const countBefore = earnedKeysBefore.size;

    await this.achievementService.handleEvent(ACHIEVEMENT_EVENT_BACKFILL, { userId });

    const earnedKeysAfter = await this.repo.findUserEarnedKeys(userId);
    return earnedKeysAfter.size - countBefore;
  }
}
