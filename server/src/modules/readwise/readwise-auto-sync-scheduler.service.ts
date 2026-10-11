import { Injectable, Logger, Optional } from '@nestjs/common';
import { Interval } from '@nestjs/schedule';

import { sanitizeLogValue } from '../../common/utils/log-sanitize.utils';
import {
  READWISE_AUTO_SYNC_DEBOUNCE_MS,
  READWISE_AUTO_SYNC_MAX_RETRIES,
  READWISE_AUTO_SYNC_MAX_WAIT_MS,
  READWISE_AUTO_SYNC_RETRY_BASE_MS,
} from './readwise.constants';
import { ReadwiseSyncService } from './readwise-sync.service';
import { ReadwiseRepository } from './readwise.repository';

interface AutoSyncState {
  userId: number;
  timer: NodeJS.Timeout | null;
  inFlight: boolean;
  pending: boolean;
  retryAttempt: number;
  firstPendingAtMs: number | null;
}

const SCHEDULER_EVENT = 'readwise.scheduler';

@Injectable()
export class ReadwiseAutoSyncSchedulerService {
  private readonly logger = new Logger(ReadwiseAutoSyncSchedulerService.name);
  private readonly states = new Map<number, AutoSyncState>();
  private readonly userSyncQueues = new Map<number, Promise<boolean>>();
  private reconciliationCursor = 0;

  constructor(
    private readonly syncService: ReadwiseSyncService,
    @Optional() private readonly repo?: ReadwiseRepository,
  ) {}

  @Interval(60_000)
  async reconcileMissedEvents(): Promise<void> {
    if (!this.repo) return;
    const users = await this.repo.findSyncCandidates(this.reconciliationCursor, 50);
    this.reconciliationCursor = users.length === 50 ? users[users.length - 1]! : 0;
    for (const userId of users) this.requestSync(userId);
  }

  requestSync(userId: number): void {
    const state = this.states.get(userId) ?? {
      userId,
      timer: null,
      inFlight: false,
      pending: false,
      retryAttempt: 0,
      firstPendingAtMs: null,
    };
    this.states.set(userId, state);
    if (!state.pending) state.firstPendingAtMs = Date.now();
    state.pending = true;
    state.retryAttempt = 0;
    if (state.inFlight) return;
    this.schedule(state);
  }

  private schedule(state: AutoSyncState, delayMs = READWISE_AUTO_SYNC_DEBOUNCE_MS, capByMaxWait = true): void {
    if (state.timer) clearTimeout(state.timer);
    const cappedDelayMs = capByMaxWait ? Math.min(delayMs, this.remainingMaxWaitMs(state)) : delayMs;
    state.timer = setTimeout(() => {
      state.timer = null;
      void this.runDue(state.userId);
    }, cappedDelayMs);
  }

  private async runDue(userId: number): Promise<void> {
    const state = this.states.get(userId);
    if (!state || state.inFlight || !state.pending) return;
    state.pending = false;
    state.firstPendingAtMs = null;
    state.inFlight = true;
    let nextDelayMs = READWISE_AUTO_SYNC_DEBOUNCE_MS;
    const startedAtMs = Date.now();
    try {
      if (await this.enqueue(userId, () => this.syncService.flush(userId))) {
        state.pending = true;
        state.firstPendingAtMs = Date.now();
      }
      state.retryAttempt = 0;
    } catch (err) {
      const durationMs = Date.now() - startedAtMs;
      const errorClass = err instanceof Error ? err.constructor.name : 'UnknownError';
      if (state.retryAttempt < READWISE_AUTO_SYNC_MAX_RETRIES) {
        state.retryAttempt += 1;
        state.pending = true;
        state.firstPendingAtMs ??= Date.now();
        nextDelayMs = READWISE_AUTO_SYNC_RETRY_BASE_MS * Math.pow(2, state.retryAttempt - 1);
        this.logger.warn(
          `[${SCHEDULER_EVENT}] [fail] userId=${userId} durationMs=${durationMs} errorClass=${errorClass} error="${sanitizeLogValue(err instanceof Error ? err.message : String(err))}" retryAttempt=${state.retryAttempt} nextDelayMs=${nextDelayMs} - Readwise flush failed; retry scheduled`,
        );
      } else {
        state.retryAttempt = 0;
        this.logger.error(
          `[${SCHEDULER_EVENT}] [fail] userId=${userId} durationMs=${durationMs} errorClass=${errorClass} error="${sanitizeLogValue(err instanceof Error ? err.message : String(err))}" retryExhausted=true - Readwise flush failed; retries exhausted`,
        );
      }
    } finally {
      state.inFlight = false;
      if (state.pending) this.schedule(state, nextDelayMs, nextDelayMs === READWISE_AUTO_SYNC_DEBOUNCE_MS);
      else this.states.delete(userId);
    }
  }

  private remainingMaxWaitMs(state: AutoSyncState): number {
    if (state.firstPendingAtMs === null) return READWISE_AUTO_SYNC_DEBOUNCE_MS;
    const elapsedMs = Date.now() - state.firstPendingAtMs;
    return Math.max(0, READWISE_AUTO_SYNC_MAX_WAIT_MS - elapsedMs);
  }

  private enqueue(userId: number, task: () => Promise<boolean>): Promise<boolean> {
    const previous = this.userSyncQueues.get(userId) ?? Promise.resolve(false);
    const current = previous.catch(() => undefined).then(task);
    this.userSyncQueues.set(userId, current);
    current
      .finally(() => {
        if (this.userSyncQueues.get(userId) === current) this.userSyncQueues.delete(userId);
      })
      .catch(() => undefined);
    return current;
  }
}
