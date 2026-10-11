import { BadRequestException, ConflictException, Injectable, InternalServerErrorException, Logger, NotFoundException } from '@nestjs/common';
import type {
  CreateReadingAttemptPayload,
  ReadingAttempt,
  ReadingAttemptListResponse,
  ReadingAttemptOrigin,
  ReadingAttemptOutcome,
  ReadingAttemptPatch,
  ReadStatus,
  UserBookStatus,
} from '@bookorbit/types';

import { ReadingAttemptRepository, type AttemptProjection } from './reading-attempt.repository';
import { ReadingAttemptEventsService } from './reading-attempt-events.service';
import { READING_DATE_ERROR_CODES } from './user-book-status.constants';
import { hasReachedProgressThreshold } from '../../common/utils/progress-threshold.utils';
import { sanitizeLogValue } from '../../common/utils/log-sanitize.utils';

function dateToUtcDate(value: string | null): Date | null {
  return value ? new Date(`${value}T00:00:00.000Z`) : null;
}

function outcomeForStatus(status: ReadStatus): ReadingAttemptOutcome | null {
  if (status === 'read') return 'completed';
  if (status === 'skimmed') return 'skimmed';
  if (status === 'abandoned') return 'abandoned';
  return null;
}

/**
 * Closing an attempt on a date earlier than it started violates the reading_attempts range
 * check. A device reporting a skewed clock can leave startedOn in the future, so the implied
 * close date has to yield to it. Explicit caller dates are validated upstream and left alone.
 */
function notBeforeStart(endedOn: string, startedOn: string | null): string {
  return startedOn && endedOn < startedOn ? startedOn : endedOn;
}

/**
 * unread and want_to_read never carry lifecycle dates. The attempt keeps its own dates so the
 * reading log still shows the history; the projection just stops claiming them for the book.
 */
function projectionDatesFor(
  status: ReadStatus,
  attempt: { startedOn: string | null; endedOn: string | null; outcome: ReadingAttemptOutcome | null } | null | undefined,
): { startedOn: string | null; endedOn: string | null } {
  if (!attempt || status === 'unread' || status === 'want_to_read') return { startedOn: null, endedOn: null };
  return { startedOn: attempt.startedOn, endedOn: attempt.outcome === 'completed' ? attempt.endedOn : null };
}

type ManualStatusOptions = {
  statusWasExplicit?: boolean;
  baseStatusUpdatedAt?: string | null;
};

@Injectable()
export class ReadingAttemptService {
  private readonly logger = new Logger(ReadingAttemptService.name);

  constructor(
    private readonly repo: ReadingAttemptRepository,
    private readonly events: ReadingAttemptEventsService,
  ) {}

  coalesceChanges<T>(operation: () => T | Promise<T>): Promise<T> {
    return this.events.coalesceChanges(operation);
  }

  async applyManualStatus(
    userId: number,
    bookId: number,
    status: ReadStatus,
    startedOn: string | null | undefined,
    endedOn: string | null | undefined,
    today: string,
    options: ManualStatusOptions = {},
  ): Promise<UserBookStatus> {
    let changed = false;
    const result = await this.repo.transaction<UserBookStatus>(async (tx) => {
      await this.repo.lockBook(tx, userId, bookId);
      const current = await this.repo.findStatus(tx, userId, bookId);
      if (options.statusWasExplicit === false) status = (current?.status as ReadStatus | undefined) ?? 'unread';
      if (options.baseStatusUpdatedAt !== undefined && (current?.updatedAt.toISOString() ?? null) !== options.baseStatusUpdatedAt) {
        throw new ConflictException({
          message: 'The reading status changed while this edit was offline',
          errorCode: 'PERSONAL_RECORD_CONFLICT',
          field: 'status',
          current: current
            ? {
                status: current.status,
                source: current.source,
                startedAt: current.startedAt?.toISOString().slice(0, 10) ?? null,
                finishedAt: current.finishedAt?.toISOString().slice(0, 10) ?? null,
                updatedAt: current.updatedAt.toISOString(),
              }
            : null,
        });
      }
      let active: Awaited<ReturnType<ReadingAttemptRepository['findActive']>> | null = await this.repo.findActive(tx, userId, bookId);
      let latest = active ?? (await this.repo.findLatest(tx, userId, bookId));
      const hasStartedOn = startedOn !== undefined;
      const hasEndedOn = endedOn !== undefined;
      const hasDatePatch = hasStartedOn || hasEndedOn;
      const statusWasExplicit = options.statusWasExplicit !== false;
      let projectedStatus = status;

      const requireUpdatedAttempt = async (
        attemptId: number,
        patch: Parameters<ReadingAttemptRepository['update']>[4],
      ): Promise<NonNullable<Awaited<ReturnType<ReadingAttemptRepository['update']>>>> => {
        const original = active?.id === attemptId ? active : latest;
        changed ||= Object.entries(patch).some(([key, value]) => original?.[key as keyof typeof original] !== value);
        const updated = await this.repo.update(tx, userId, bookId, attemptId, patch);
        if (!updated) throw new InternalServerErrorException('Reading attempt disappeared during update');
        return updated;
      };

      if (!statusWasExplicit && hasDatePatch) {
        const target = active ?? latest;
        if (!target) {
          if (endedOn !== undefined && endedOn !== null) {
            const resolvedStartedOn = startedOn ?? null;
            this.validateDates(resolvedStartedOn, endedOn);
            changed = true;
            latest = await this.repo.create(tx, {
              userId,
              bookId,
              startedOn: resolvedStartedOn,
              endedOn,
              outcome: 'completed',
              origin: 'manual',
            });
            projectedStatus = 'read';
          } else if (startedOn !== undefined && startedOn !== null) {
            changed = true;
            active = await this.repo.createActive(tx, {
              userId,
              bookId,
              startedOn,
              origin: 'manual',
            });
            latest = active;
          }
        } else {
          const resolvedStartedOn = hasStartedOn ? (startedOn ?? null) : target.startedOn;
          const resolvedEndedOn = hasEndedOn ? (endedOn ?? null) : target.endedOn;
          const completesAttempt = endedOn !== undefined && endedOn !== null;
          this.validateDates(resolvedStartedOn, resolvedEndedOn);
          const updated = await requireUpdatedAttempt(target.id, {
            ...(hasStartedOn ? { startedOn: startedOn ?? null } : {}),
            ...(hasEndedOn ? { endedOn: endedOn ?? null } : {}),
            ...(completesAttempt ? { outcome: 'completed' as const } : {}),
          });
          if (active) {
            if (completesAttempt) {
              active = null;
              latest = updated;
              projectedStatus = 'read';
            } else {
              active = updated;
              latest = updated;
            }
          } else {
            latest = updated;
            if (completesAttempt) projectedStatus = 'read';
          }
        }

        if (active) {
          const hasCompleted = await this.repo.hasCompleted(tx, userId, bookId);
          projectedStatus = status === 'on_hold' ? 'on_hold' : hasCompleted ? 'rereading' : 'reading';
        }
      } else {
        const isActiveStatus = status === 'reading' || status === 'rereading' || status === 'on_hold';
        const clearsLifecycle = status === 'unread' || status === 'want_to_read';
        if ((isActiveStatus && endedOn !== undefined && endedOn !== null) || (clearsLifecycle && (startedOn != null || endedOn != null))) {
          throw new BadRequestException({
            message: 'Reading dates conflict with the requested status',
            errorCode: READING_DATE_ERROR_CODES.statusConflict,
          });
        }

        if (status === 'rereading' && !(await this.repo.hasCompleted(tx, userId, bookId))) {
          changed = true;
          await this.repo.create(tx, {
            userId,
            bookId,
            startedOn: null,
            endedOn: null,
            outcome: 'completed',
            origin: 'migration',
          });
        }

        if (isActiveStatus) {
          if (!active) {
            changed = true;
            active = await this.repo.createActive(tx, {
              userId,
              bookId,
              startedOn: startedOn === undefined ? today : startedOn,
              origin: 'manual',
            });
          } else if (hasStartedOn) {
            this.validateDates(startedOn ?? null, null);
            active = await requireUpdatedAttempt(active.id, { startedOn: startedOn ?? null });
          }
          latest = active;
        } else {
          const outcome = outcomeForStatus(status);
          if (outcome) {
            if (active) {
              const resolvedStartedOn = hasStartedOn ? (startedOn ?? null) : active.startedOn;
              const resolvedEndedOn = hasEndedOn ? (endedOn ?? null) : notBeforeStart(today, resolvedStartedOn);
              this.validateDates(resolvedStartedOn, resolvedEndedOn);
              latest = await requireUpdatedAttempt(active.id, {
                ...(hasStartedOn ? { startedOn: startedOn ?? null } : {}),
                endedOn: resolvedEndedOn,
                outcome,
              });
              active = null;
            } else if (latest?.outcome !== outcome) {
              const resolvedStartedOn = startedOn ?? null;
              const resolvedEndedOn = hasEndedOn ? (endedOn ?? null) : notBeforeStart(today, resolvedStartedOn);
              this.validateDates(resolvedStartedOn, resolvedEndedOn);
              changed = true;
              latest = await this.repo.create(tx, {
                userId,
                bookId,
                startedOn: resolvedStartedOn,
                endedOn: resolvedEndedOn,
                outcome,
                origin: 'manual',
              });
            } else if (latest && hasDatePatch) {
              const resolvedStartedOn = hasStartedOn ? (startedOn ?? null) : latest.startedOn;
              const resolvedEndedOn = hasEndedOn ? (endedOn ?? null) : latest.endedOn;
              this.validateDates(resolvedStartedOn, resolvedEndedOn);
              latest = await requireUpdatedAttempt(latest.id, {
                ...(hasStartedOn ? { startedOn: startedOn ?? null } : {}),
                ...(hasEndedOn ? { endedOn: endedOn ?? null } : {}),
              });
            }
          } else if (active) {
            const resolvedStartedOn = hasStartedOn ? (startedOn ?? null) : active.startedOn;
            const resolvedEndedOn = hasEndedOn ? (endedOn ?? null) : notBeforeStart(today, resolvedStartedOn);
            this.validateDates(resolvedStartedOn, resolvedEndedOn);
            latest = await requireUpdatedAttempt(active.id, {
              ...(hasStartedOn ? { startedOn: startedOn ?? null } : {}),
              endedOn: resolvedEndedOn,
              outcome: 'abandoned',
            });
            active = null;
          } else if (latest && hasDatePatch) {
            const resolvedStartedOn = hasStartedOn ? (startedOn ?? null) : latest.startedOn;
            const resolvedEndedOn = hasEndedOn ? (endedOn ?? null) : latest.endedOn;
            this.validateDates(resolvedStartedOn, resolvedEndedOn);
            latest = await requireUpdatedAttempt(latest.id, {
              ...(hasStartedOn ? { startedOn: startedOn ?? null } : {}),
              ...(hasEndedOn ? { endedOn: endedOn ?? null } : {}),
            });
          }
        }

        if (active) {
          const hasCompleted = await this.repo.hasCompleted(tx, userId, bookId);
          projectedStatus = status === 'on_hold' ? 'on_hold' : hasCompleted ? 'rereading' : 'reading';
        }
      }

      const projectionTarget = active ?? latest;
      const projected = projectionDatesFor(projectedStatus, projectionTarget);
      const projection: AttemptProjection = {
        status: projectedStatus,
        source: 'manual',
        startedAt: dateToUtcDate(projected.startedOn),
        finishedAt: dateToUtcDate(projected.endedOn),
      };
      changed ||= this.hasProjectionChanged(current, projection);
      const persisted = await this.repo.project(tx, userId, bookId, projection);
      return {
        status: projectedStatus,
        source: 'manual',
        startedAt: projected.startedOn,
        finishedAt: projected.endedOn,
        updatedAt: persisted.updatedAt.toISOString(),
      };
    });
    if (changed) this.events.notifyChanged(userId);
    return result;
  }

  async recordActivity(input: {
    userId: number;
    bookId: number;
    occurredOn: string;
    origin: Exclude<ReadingAttemptOrigin, 'manual' | 'hardcover' | 'migration'>;
    progress: number;
    finishThreshold: number;
    strongRereadEvidence: boolean;
    meaningfulActivity: boolean;
    attemptId?: number | null;
  }): Promise<UserBookStatus | null> {
    let changed = false;
    const result = await this.repo.transaction<UserBookStatus | null>(async (tx) => {
      await this.repo.lockBook(tx, input.userId, input.bookId);
      let active: Awaited<ReturnType<ReadingAttemptRepository['findActive']>> | null = await this.repo.findActive(tx, input.userId, input.bookId);
      if (input.attemptId !== undefined && (input.attemptId === null || active?.id !== input.attemptId)) return null;
      let latest = active ?? (await this.repo.findLatest(tx, input.userId, input.bookId));
      const hasCompleted = await this.repo.hasCompleted(tx, input.userId, input.bookId);
      const isFinished = hasReachedProgressThreshold(input.progress, input.finishThreshold);

      if (!active && hasCompleted && !input.strongRereadEvidence && !input.meaningfulActivity) return null;
      if (!active && isFinished && !hasCompleted) {
        latest = await this.repo.create(tx, {
          userId: input.userId,
          bookId: input.bookId,
          startedOn: null,
          endedOn: input.occurredOn,
          outcome: 'completed',
          origin: input.origin,
        });
        changed = true;
      }
      if (!active && isFinished && hasCompleted && input.strongRereadEvidence) {
        latest = await this.repo.create(tx, {
          userId: input.userId,
          bookId: input.bookId,
          startedOn: input.occurredOn,
          endedOn: input.occurredOn,
          outcome: 'completed',
          origin: input.origin,
        });
        changed = true;
      }
      if (!active && !isFinished && (input.progress > 0 || input.strongRereadEvidence || input.meaningfulActivity)) {
        active = await this.repo.createActive(tx, {
          userId: input.userId,
          bookId: input.bookId,
          startedOn: input.occurredOn,
          origin: input.origin,
        });
        changed = true;
      }

      let projectionTarget = active ?? latest;
      let status: ReadStatus;
      if (active && isFinished) {
        projectionTarget = await this.repo.update(tx, input.userId, input.bookId, active.id, {
          endedOn: notBeforeStart(input.occurredOn, active.startedOn),
          outcome: 'completed',
        });
        changed = true;
        status = 'read';
      } else if (active) {
        status = hasCompleted ? 'rereading' : 'reading';
      } else if (latest?.outcome === 'completed') {
        status = 'read';
      } else {
        return null;
      }

      const current = await this.repo.findStatus(tx, input.userId, input.bookId);
      const projection: AttemptProjection = {
        status,
        source: 'auto',
        startedAt: dateToUtcDate(projectionTarget?.startedOn ?? null),
        finishedAt: projectionTarget?.outcome === 'completed' ? dateToUtcDate(projectionTarget.endedOn) : null,
      };
      changed ||= this.hasProjectionChanged(current, projection);
      const persisted = await this.repo.project(tx, input.userId, input.bookId, projection);
      return {
        status,
        source: 'auto',
        startedAt: projectionTarget?.startedOn ?? null,
        finishedAt: projectionTarget?.outcome === 'completed' ? (projectionTarget.endedOn ?? null) : null,
        updatedAt: persisted.updatedAt.toISOString(),
      };
    });
    if (changed) this.events.notifyChanged(input.userId);
    return result;
  }

  async list(userId: number, bookId: number, page = 1, pageSize = 20): Promise<ReadingAttemptListResponse> {
    const result = await this.repo.list(userId, bookId, page, pageSize);
    return {
      items: result.items.map((row) => this.toDto(row)),
      page,
      pageSize,
      total: result.total,
    };
  }

  async findOne(userId: number, bookId: number, attemptId: number): Promise<ReadingAttempt> {
    const row = await this.repo.findDetail(userId, bookId, attemptId);
    if (!row) throw new NotFoundException('Reading attempt not found');
    return this.toDto(row);
  }

  async createHistorical(userId: number, bookId: number, input: CreateReadingAttemptPayload): Promise<ReadingAttempt> {
    const event = 'reading_attempt.create_historical';
    const startedAt = Date.now();
    this.logger.log(
      `[${event}] [start] userId=${userId} bookId=${bookId} idempotent=${input.clientId !== undefined} - historical reading attempt creation started`,
    );
    try {
      this.validateDates(input.startedOn ?? null, input.endedOn ?? null);
      const { row, changed } = await this.repo.transaction(async (tx) => {
        await this.repo.lockBook(tx, userId, bookId);
        const values = {
          userId,
          bookId,
          startedOn: input.startedOn ?? null,
          endedOn: input.endedOn ?? null,
          outcome: input.outcome,
          origin: 'manual' as const,
        };
        let row;
        if (input.clientId) {
          const identity = input.clientId.toLowerCase();
          row = await this.repo.createIdentified(tx, { ...values, externalProvider: 'native', externalId: identity });
          if (!row) {
            const existing = await this.repo.findByExternal(tx, userId, 'native', identity);
            if (!existing) throw new InternalServerErrorException('Reading attempt identity conflict did not resolve');
            if (existing.bookId !== bookId || existing.deletedAt) {
              throw new ConflictException({
                message: 'The historical reading operation was deleted or belongs to another book',
                errorCode: 'READING_ATTEMPT_CONFLICT',
                current: null,
              });
            }
            const current = await this.repo.findDetail(userId, bookId, existing.id, tx);
            if (!current) throw new NotFoundException('Reading attempt not found');
            return { row: current, changed: false };
          }
        } else row = await this.repo.create(tx, values);
        await this.rebuildProjectionInTransaction(tx, userId, bookId);
        return { row: { ...row, totalSessions: 0, totalSeconds: 0 }, changed: true };
      });
      if (changed) this.events.notifyChanged(userId);
      this.logger.log(
        `[${event}] [end] userId=${userId} bookId=${bookId} attemptId=${row.id} durationMs=${Date.now() - startedAt} created=${changed} - historical reading attempt acknowledged`,
      );
      return this.toDto(row);
    } catch (error) {
      const errorClass = error instanceof Error ? error.constructor.name : 'unknown';
      const message = sanitizeLogValue(error instanceof Error ? error.message : String(error));
      this.logger.warn(
        `[${event}] [fail] userId=${userId} bookId=${bookId} durationMs=${Date.now() - startedAt} errorClass=${errorClass} error="${message}" - historical reading attempt creation failed`,
      );
      throw error;
    }
  }

  async importExternalRead(
    userId: number,
    bookId: number,
    input: { provider: 'hardcover'; externalId: string; startedOn: string | null; endedOn: string | null },
  ): Promise<void> {
    this.validateDates(input.startedOn, input.endedOn);
    const changed = await this.repo.transaction(async (tx) => {
      await this.repo.lockBook(tx, userId, bookId);
      const existing = await this.repo.findByExternal(tx, userId, input.provider, input.externalId);
      if (existing?.deletedAt) return false;
      if (existing) {
        const patch = {
          ...(existing.startedOn === null && input.startedOn !== null ? { startedOn: input.startedOn } : {}),
          ...(existing.endedOn === null && input.endedOn !== null ? { endedOn: input.endedOn, outcome: 'completed' as const } : {}),
        };
        if (Object.keys(patch).length === 0) return false;
        const updated = await this.repo.update(tx, userId, bookId, existing.id, patch);
        if (updated) await this.rebuildProjectionInTransaction(tx, userId, bookId);
        return updated !== null;
      }
      const active = input.endedOn === null ? await this.repo.findActive(tx, userId, bookId) : null;
      if (input.endedOn === null && !active) {
        await this.repo.createActive(tx, {
          userId,
          bookId,
          startedOn: input.startedOn,
          origin: 'hardcover',
          externalProvider: input.provider,
          externalId: input.externalId,
        });
      } else {
        await this.repo.create(tx, {
          userId,
          bookId,
          startedOn: input.startedOn,
          endedOn: input.endedOn,
          outcome: input.endedOn ? 'completed' : 'abandoned',
          origin: 'hardcover',
          externalProvider: input.provider,
          externalId: input.externalId,
        });
      }
      await this.rebuildProjectionInTransaction(tx, userId, bookId);
      return true;
    });
    if (changed) this.events.notifyChanged(userId);
  }

  async update(userId: number, bookId: number, attemptId: number, patch: ReadingAttemptPatch): Promise<ReadingAttempt> {
    const event = 'reading_attempt.update';
    const startedAt = Date.now();
    this.logger.log(
      `[${event}] [start] userId=${userId} bookId=${bookId} attemptId=${attemptId} conditional=${patch.baseUpdatedAt !== undefined} - reading attempt update started`,
    );
    try {
      const { baseUpdatedAt, ...mutation } = patch;
      const { row, changed } = await this.repo.transaction(async (tx) => {
        await this.repo.lockBook(tx, userId, bookId);
        const existing = await this.repo.findOwned(userId, bookId, attemptId, tx);
        if (!existing) throw new NotFoundException('Reading attempt not found');
        if (baseUpdatedAt !== undefined && existing.updatedAt.toISOString() !== baseUpdatedAt) {
          const current = await this.repo.findDetail(userId, bookId, attemptId, tx);
          throw new ConflictException({
            message: 'The historical reading attempt changed while this edit was offline',
            errorCode: 'READING_ATTEMPT_CONFLICT',
            current: current ? this.toDto(current) : null,
          });
        }
        const startedOn = mutation.startedOn === undefined ? existing.startedOn : mutation.startedOn;
        const endedOn = mutation.endedOn === undefined ? existing.endedOn : mutation.endedOn;
        const outcome = mutation.outcome === undefined ? existing.outcome : mutation.outcome;
        this.validateDates(startedOn, endedOn);
        if (endedOn && outcome === null) throw new BadRequestException('A closed attempt requires an outcome');
        const changed = Object.entries(mutation).some(([key, value]) => existing[key as keyof typeof existing] !== value);
        const row = await this.repo.update(tx, userId, bookId, attemptId, mutation);
        if (!row) throw new NotFoundException('Reading attempt not found');
        const projectionChanged = await this.rebuildProjectionInTransaction(tx, userId, bookId);
        const detail = await this.repo.findDetail(userId, bookId, attemptId, tx);
        if (!detail) throw new NotFoundException('Reading attempt not found');
        return { row: detail, changed: changed || projectionChanged };
      });
      if (changed) this.events.notifyChanged(userId);
      this.logger.log(
        `[${event}] [end] userId=${userId} bookId=${bookId} attemptId=${attemptId} durationMs=${Date.now() - startedAt} changed=${changed} - reading attempt updated`,
      );
      return this.toDto(row);
    } catch (error) {
      const errorClass = error instanceof Error ? error.constructor.name : 'unknown';
      const message = sanitizeLogValue(error instanceof Error ? error.message : String(error));
      this.logger.warn(
        `[${event}] [fail] userId=${userId} bookId=${bookId} attemptId=${attemptId} durationMs=${Date.now() - startedAt} errorClass=${errorClass} error="${message}" - reading attempt update failed`,
      );
      throw error;
    }
  }

  async delete(userId: number, bookId: number, attemptId: number): Promise<void> {
    await this.repo.transaction(async (tx) => {
      await this.repo.lockBook(tx, userId, bookId);
      if (!(await this.repo.softDelete(userId, bookId, attemptId, tx))) throw new NotFoundException('Reading attempt not found');
      await this.rebuildProjectionInTransaction(tx, userId, bookId);
    });
    this.events.notifyChanged(userId);
  }

  private async rebuildProjectionInTransaction(
    tx: Parameters<Parameters<ReadingAttemptRepository['transaction']>[0]>[0],
    userId: number,
    bookId: number,
  ): Promise<boolean> {
    const active = await this.repo.findActive(tx, userId, bookId);
    const latest = active ?? (await this.repo.findLatest(tx, userId, bookId));
    const current = await this.repo.findStatus(tx, userId, bookId);
    const hasCompleted = await this.repo.hasCompleted(tx, userId, bookId);
    const target = active ?? latest;
    let status: ReadStatus = 'unread';
    if (active) status = current?.status === 'on_hold' ? 'on_hold' : hasCompleted ? 'rereading' : 'reading';
    else if (current?.status === 'want_to_read' || current?.status === 'unread') status = current.status;
    else if (latest?.outcome === 'completed') status = 'read';
    else if (latest?.outcome === 'skimmed') status = 'skimmed';
    else if (latest?.outcome === 'abandoned') status = 'abandoned';
    const projected = projectionDatesFor(status, target);
    const projection: AttemptProjection = {
      status,
      source: 'manual',
      startedAt: dateToUtcDate(projected.startedOn),
      finishedAt: dateToUtcDate(projected.endedOn),
    };
    const changed = this.hasProjectionChanged(current, projection);
    await this.repo.project(tx, userId, bookId, projection);
    return changed;
  }

  private hasProjectionChanged(current: Awaited<ReturnType<ReadingAttemptRepository['findStatus']>>, projection: AttemptProjection): boolean {
    return (
      current?.status !== projection.status ||
      current?.source !== projection.source ||
      (current?.startedAt?.toISOString() ?? null) !== (projection.startedAt?.toISOString() ?? null) ||
      (current?.finishedAt?.toISOString() ?? null) !== (projection.finishedAt?.toISOString() ?? null)
    );
  }

  private validateDates(startedOn: string | null, endedOn: string | null): void {
    if (startedOn && endedOn && endedOn < startedOn) {
      throw new BadRequestException({
        message: 'endedOn must be on or after startedOn',
        errorCode: READING_DATE_ERROR_CODES.invalidOrder,
      });
    }
  }

  private toDto(row: {
    id: number;
    bookId: number;
    startedOn: string | null;
    endedOn: string | null;
    outcome: ReadingAttemptOutcome | null;
    origin: ReadingAttemptOrigin;
    externalProvider: string | null;
    externalId: string | null;
    totalSessions: number;
    totalSeconds: number;
    createdAt: Date;
    updatedAt: Date;
  }): ReadingAttempt {
    return {
      id: row.id,
      bookId: row.bookId,
      startedOn: row.startedOn,
      endedOn: row.endedOn,
      outcome: row.outcome,
      origin: row.origin,
      externalProvider: row.externalProvider,
      externalId: row.externalId,
      totalSessions: row.totalSessions,
      totalSeconds: row.totalSeconds,
      createdAt: row.createdAt.toISOString(),
      updatedAt: row.updatedAt.toISOString(),
    };
  }
}
