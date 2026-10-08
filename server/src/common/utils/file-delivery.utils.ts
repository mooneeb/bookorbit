import { ConflictException, Logger, NotFoundException, ServiceUnavailableException } from '@nestjs/common';
import { createHash } from 'node:crypto';
import type { BigIntStats } from 'node:fs';
import { open, type FileHandle } from 'node:fs/promises';
import type { FastifyReply } from 'fastify';
import { sanitizeLogValue } from './log-sanitize.utils';

const logger = new Logger('FileDelivery');
const checksums = new Map<string, string>();
const pendingChecksums = new Map<string, Promise<string>>();
const hashingWaiters: Array<() => void> = [];
let hashingCount = 0;

function revision(stat: BigIntStats): string {
  return `${stat.dev}:${stat.ino}:${stat.size}:${stat.mtimeNs}:${stat.ctimeNs}`;
}

export function ifRangeMatches(value: string | undefined, etag: string): boolean {
  return value === undefined || value === etag;
}

function parseRange(header: string, size: number): { start: number; end: number } | null {
  const match = /^bytes=(\d*)-(\d*)$/.exec(header);
  if (!match || size <= 0 || (!match[1] && !match[2])) return null;
  if (!match[1]) {
    const length = Number(match[2]);
    return Number.isSafeInteger(length) && length > 0 ? { start: Math.max(0, size - length), end: size - 1 } : null;
  }
  const start = Number(match[1]);
  const end = match[2] ? Number(match[2]) : size - 1;
  if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start >= size || end < start) return null;
  return { start, end: Math.min(end, size - 1) };
}

async function checksum(file: FileHandle, sourceRevision: string): Promise<string> {
  const cached = checksums.get(sourceRevision);
  if (cached) {
    checksums.delete(sourceRevision);
    checksums.set(sourceRevision, cached);
    return cached;
  }
  const pending = pendingChecksums.get(sourceRevision);
  if (pending) return pending;
  if (pendingChecksums.size >= 32) throw new ServiceUnavailableException('File verification is busy. Retry shortly.');
  const work = (async () => {
    if (hashingCount >= 2) await new Promise<void>((resolve) => hashingWaiters.push(resolve));
    else hashingCount++;
    try {
      const hash = createHash('sha256');
      const stream = file.createReadStream({ start: 0, autoClose: false, highWaterMark: 64 * 1024 });
      for await (const chunk of stream) hash.update(chunk as Buffer);
      if (revision(await file.stat({ bigint: true })) !== sourceRevision) throw new ConflictException('File changed during verification. Retry.');
      const digest = hash.digest('hex');
      checksums.set(sourceRevision, digest);
      if (checksums.size > 128) checksums.delete(checksums.keys().next().value!);
      return digest;
    } finally {
      const next = hashingWaiters.shift();
      if (next) next();
      else hashingCount--;
    }
  })();
  pendingChecksums.set(sourceRevision, work);
  try {
    return await work;
  } finally {
    pendingChecksums.delete(sourceRevision);
  }
}

export async function serveVerifiedFile(
  reply: FastifyReply,
  path: string,
  rangeHeader: string | undefined,
  ifRangeHeader: string | undefined,
  context: { userId: number; resourceId: string | number },
): Promise<void> {
  const startedAt = Date.now();
  const ids = `userId=${context.userId} resourceId=${sanitizeLogValue(String(context.resourceId))}`;
  let file: FileHandle | undefined;
  logger.log(`[file.delivery] [start] ${ids} ranged=${rangeHeader !== undefined} - file delivery started`);
  try {
    try {
      file = await open(path, 'r');
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === 'ENOENT') throw new NotFoundException('File not found on disk');
      throw error;
    }
    const sourceStat = await file.stat({ bigint: true });
    if (!sourceStat.isFile()) throw new NotFoundException('File not found on disk');
    const size = Number(sourceStat.size);
    if (!Number.isSafeInteger(size)) throw new ServiceUnavailableException('File exceeds supported delivery size');
    const sourceRevision = revision(sourceStat);
    const digest = await checksum(file, sourceRevision);
    if (revision(await file.stat({ bigint: true })) !== sourceRevision) throw new ConflictException('File changed during verification. Retry.');
    const etag = `"${digest}"`;
    reply.header('Accept-Ranges', 'bytes');
    reply.header('ETag', etag);
    reply.header('X-Content-SHA256', digest);
    reply.header('Cache-Control', 'private, no-store');
    const range = rangeHeader && ifRangeMatches(ifRangeHeader, etag) ? parseRange(rangeHeader, size) : undefined;
    if (range === null) {
      reply.status(416).header('Content-Range', `bytes */${size}`).header('Content-Length', 0).send();
      await file.close();
      file = undefined;
      logger.log(`[file.delivery] [end] ${ids} durationMs=${Date.now() - startedAt} sizeBytes=${size} status=416 - range rejected`);
      return;
    }
    const bytes = range ? range.end - range.start + 1 : size;
    reply.header('Content-Length', bytes);
    if (range) reply.status(206).header('Content-Range', `bytes ${range.start}-${range.end}/${size}`);
    const stream = file.createReadStream({ start: range?.start ?? 0, ...(range ? { end: range.end } : {}), highWaterMark: 64 * 1024 });
    file = undefined;
    stream.once('error', (error) => {
      logger.warn(
        `[file.delivery] [fail] ${ids} durationMs=${Date.now() - startedAt} errorClass=${error.name} error="${sanitizeLogValue(error.message)}" - file delivery failed`,
      );
    });
    stream.once('end', () => {
      logger.log(
        `[file.delivery] [end] ${ids} durationMs=${Date.now() - startedAt} sizeBytes=${size} deliveredBytes=${bytes} status=${range ? 206 : 200} - file delivery completed`,
      );
    });
    reply.send(stream);
  } catch (error) {
    if (file) await file.close();
    if (error instanceof ServiceUnavailableException) reply.header('Retry-After', '1');
    logger.warn(
      `[file.delivery] [fail] ${ids} durationMs=${Date.now() - startedAt} errorClass=${error instanceof Error ? error.name : 'Unknown'} error="${sanitizeLogValue(error instanceof Error ? error.message : String(error))}" - file delivery failed`,
    );
    throw error;
  }
}
