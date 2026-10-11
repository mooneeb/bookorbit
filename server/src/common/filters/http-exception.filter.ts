import { ExceptionFilter, Catch, ArgumentsHost, HttpException, HttpStatus, Logger } from '@nestjs/common';
import { FastifyReply, FastifyRequest } from 'fastify';
import {
  PERSONAL_NOTE_MAX_LENGTH,
  READ_STATUSES,
  READING_ATTEMPT_ORIGINS,
  READING_ATTEMPT_OUTCOMES,
  type PersonalRecordConflict,
  type ReadingAttemptConflict,
} from '@bookorbit/types';

import { redactUrlCredentials } from '../utils/log-url.utils';

@Catch()
export class GlobalExceptionFilter implements ExceptionFilter {
  private readonly logger = new Logger(GlobalExceptionFilter.name);

  catch(exception: unknown, host: ArgumentsHost) {
    const ctx = host.switchToHttp();
    const reply = ctx.getResponse<FastifyReply>();
    const request = ctx.getRequest<FastifyRequest>();

    const exc = exception as Record<string, unknown> | undefined;

    if (exc?.code === 'ERR_STREAM_PREMATURE_CLOSE') {
      return;
    }

    const status =
      exception instanceof HttpException
        ? exception.getStatus()
        : typeof exc?.statusCode === 'number'
          ? Number(exc.statusCode)
          : HttpStatus.INTERNAL_SERVER_ERROR;

    const raw = exception instanceof HttpException ? exception.getResponse() : 'Internal server error';
    const rawObject = typeof raw === 'object' && raw !== null ? (raw as Record<string, unknown>) : undefined;
    const message = typeof raw === 'string' ? raw : ((rawObject?.message as string) ?? (exc?.message as string) ?? 'An error occurred');
    const errorCode = typeof rawObject?.errorCode === 'string' ? rawObject.errorCode : undefined;
    // The code's parameters, and useless without them: a client translating "you can have {limit}
    // in flight at once" has the sentence but not the number, and renders the placeholder empty.
    // Scalars only, so a thrower cannot smuggle a nested object of internals into an error body.
    const errorMeta = errorCode ? scalarMeta(rawObject?.errorMeta) : undefined;
    const retryAfterSeconds = typeof rawObject?.retryAfterSeconds === 'number' ? rawObject.retryAfterSeconds : undefined;
    const conflict =
      errorCode === 'PERSONAL_RECORD_CONFLICT'
        ? personalRecordConflict(rawObject)
        : errorCode === 'READING_ATTEMPT_CONFLICT'
          ? readingAttemptConflict(rawObject)
          : undefined;

    if (status >= (HttpStatus.INTERNAL_SERVER_ERROR as number)) {
      this.logger.error(exception);
    }

    if (reply.sent) {
      return;
    }

    reply.status(status).send({
      statusCode: status,
      message,
      path: redactUrlCredentials(request.url),
      timestamp: new Date().toISOString(),
      requestId: request.id,
      ...(errorCode ? { errorCode } : {}),
      ...(errorMeta ? { errorMeta } : {}),
      ...(retryAfterSeconds !== undefined ? { retryAfterSeconds } : {}),
      ...conflict,
    });
  }
}

function readingAttemptConflict(value: Record<string, unknown> | undefined): ReadingAttemptConflict | undefined {
  const current = value?.current;
  if (current === null) return { current: null };
  if (typeof current !== 'object' || current === null || Array.isArray(current)) return undefined;
  const row = current as Record<string, unknown>;
  if (
    typeof row.id !== 'number' ||
    !Number.isInteger(row.id) ||
    typeof row.bookId !== 'number' ||
    !Number.isInteger(row.bookId) ||
    (row.startedOn !== null && typeof row.startedOn !== 'string') ||
    (row.endedOn !== null && typeof row.endedOn !== 'string') ||
    (row.outcome !== null && !READING_ATTEMPT_OUTCOMES.includes(row.outcome as (typeof READING_ATTEMPT_OUTCOMES)[number])) ||
    !READING_ATTEMPT_ORIGINS.includes(row.origin as (typeof READING_ATTEMPT_ORIGINS)[number]) ||
    (row.externalProvider !== null && typeof row.externalProvider !== 'string') ||
    (row.externalId !== null && typeof row.externalId !== 'string') ||
    typeof row.totalSessions !== 'number' ||
    !Number.isInteger(row.totalSessions) ||
    typeof row.totalSeconds !== 'number' ||
    !Number.isInteger(row.totalSeconds) ||
    typeof row.createdAt !== 'string' ||
    typeof row.updatedAt !== 'string'
  )
    return undefined;
  return {
    current: {
      id: row.id,
      bookId: row.bookId,
      startedOn: row.startedOn,
      endedOn: row.endedOn,
      outcome: row.outcome as (typeof READING_ATTEMPT_OUTCOMES)[number] | null,
      origin: row.origin as (typeof READING_ATTEMPT_ORIGINS)[number],
      externalProvider: row.externalProvider,
      externalId: row.externalId,
      totalSessions: row.totalSessions,
      totalSeconds: row.totalSeconds,
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
    },
  };
}

function personalRecordConflict(value: Record<string, unknown> | undefined): PersonalRecordConflict | undefined {
  const current = value?.current;
  if (value?.field === 'note' && (current === null || (typeof current === 'string' && current.length <= PERSONAL_NOTE_MAX_LENGTH))) {
    return { field: 'note', current };
  }
  if (value?.field === 'rating' && (current === null || (typeof current === 'number' && Number.isInteger(current) && current >= 1 && current <= 5))) {
    return { field: 'rating', current };
  }
  if (value?.field !== 'status') return undefined;
  if (current === null) return { field: 'status', current: null };
  if (typeof current !== 'object' || Array.isArray(current)) return undefined;
  const state = current as Record<string, unknown>;
  if (
    !READ_STATUSES.includes(state.status as (typeof READ_STATUSES)[number]) ||
    (state.source !== 'auto' && state.source !== 'manual') ||
    (state.startedAt !== null && typeof state.startedAt !== 'string') ||
    (state.finishedAt !== null && typeof state.finishedAt !== 'string') ||
    typeof state.updatedAt !== 'string'
  )
    return undefined;
  return {
    field: 'status',
    current: {
      status: state.status as (typeof READ_STATUSES)[number],
      source: state.source,
      startedAt: state.startedAt,
      finishedAt: state.finishedAt,
      updatedAt: state.updatedAt,
    },
  };
}

/**
 * Translation parameters are strings and numbers. Anything else in there is either a mistake or
 * somebody putting an object into an error body, and neither belongs on the wire.
 */
function scalarMeta(value: unknown): Record<string, string | number> | undefined {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return undefined;
  const entries = Object.entries(value).filter(([, item]) => typeof item === 'string' || typeof item === 'number') as Array<
    [string, string | number]
  >;
  return entries.length ? Object.fromEntries(entries) : undefined;
}
