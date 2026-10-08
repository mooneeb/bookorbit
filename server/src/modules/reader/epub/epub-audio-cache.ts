import { BadRequestException, Logger, ServiceUnavailableException } from '@nestjs/common';
import { createReadStream, type Stats } from 'fs';
import { mkdtemp, open, rm, stat, type FileHandle } from 'fs/promises';
import { tmpdir } from 'os';
import { join } from 'path';
import { Readable, Transform, Writable } from 'stream';
import { pipeline } from 'stream/promises';
import { createInflateRaw } from 'zlib';
import type { File } from 'unzipper';
import { sanitizeLogValue } from '../../../common/utils/log-sanitize.utils';

interface StagedAudio {
  file: FileHandle;
  size: number;
  readers: number;
  expired?: boolean;
}

interface StagingJob {
  controller: AbortController;
  waiters: number;
  settled: boolean;
  promise: Promise<StagedAudio>;
}

export function audioSourceRevision(source: Stats): string {
  return `${source.dev}:${source.ino}:${source.size}:${source.mtimeMs}:${source.ctimeMs}`;
}

export class EpubAudioCache {
  private readonly logger = new Logger(EpubAudioCache.name);
  private readonly ready = new Map<string, StagedAudio>();
  private readonly jobs = new Map<string, StagingJob>();
  private reservedBytes = 0;
  private closed = false;
  private reservations = 0;

  constructor(private readonly maximumBytes: number) {}

  async stream(
    userId: number,
    bookId: number,
    sourcePath: string,
    revision: string,
    entry: File,
    range: { start: number; end: number } | null,
    signal?: AbortSignal,
  ): Promise<Readable> {
    if (this.closed || signal?.aborted) throw new ServiceUnavailableException('Narration request cancelled');
    const source = await open(sourcePath, 'r');
    let sourceTransferred = false;
    try {
      if (audioSourceRevision(await source.stat()) !== revision) throw new BadRequestException('Narration audio changed while reading');
      const header = Buffer.alloc(30);
      const { bytesRead } = await source.read(header, 0, 30, entry.offsetToLocalFileHeader);
      if (bytesRead !== 30 || header.readUInt32LE(0) !== 0x04034b50 || entry.flags & 1) {
        throw new BadRequestException('Invalid narration audio entry');
      }
      const offset = entry.offsetToLocalFileHeader + 30 + header.readUInt16LE(26) + header.readUInt16LE(28);
      if (entry.compressionMethod === 0) {
        if (entry.compressedSize !== entry.uncompressedSize) throw new BadRequestException('Invalid narration audio size');
        await this.verifySource(sourcePath, revision);
        if (!entry.uncompressedSize) return Readable.from([]);
        const stream = createReadStream('', {
          fd: source.fd,
          start: offset + (range?.start ?? 0),
          end: offset + (range?.end ?? entry.uncompressedSize - 1),
          signal,
          autoClose: false,
        });
        // The stream owns this descriptor so replacing the source path cannot mix revisions.
        let released = false;
        const release = () => {
          if (!released) {
            released = true;
            void source.close();
          }
        };
        stream.once('end', release);
        stream.once('error', release);
        stream.once('close', release);
        sourceTransferred = true;
        return stream;
      }
      if (entry.compressionMethod !== 8) throw new BadRequestException('Unsupported narration audio compression');
      const key = JSON.stringify([userId, sourcePath, revision, entry.path, entry.crc32, entry.uncompressedSize]);
      let staged = this.ready.get(key);
      if (!staged) {
        let job = this.jobs.get(key);
        if (!job) {
          if (this.jobs.size >= 2) throw new ServiceUnavailableException('Narration staging is busy; retry shortly');
          const controller = new AbortController();
          job = {
            controller,
            waiters: 0,
            settled: false,
            promise: this.prepare(userId, bookId, sourcePath, revision, offset, entry, controller.signal),
          };
          this.jobs.set(key, job);
          const activeJob = job;
          void job.promise.then(
            (result) => {
              this.ready.set(key, result);
              activeJob.settled = true;
              this.finishJob(key, activeJob);
            },
            () => {
              activeJob.settled = true;
              this.finishJob(key, activeJob);
            },
          );
        }
        if (!staged && job) {
          job.waiters++;
          try {
            staged = await this.wait(job.promise, signal);
            staged.readers++;
          } finally {
            job.waiters--;
            if (!job.waiters && !job.settled) job.controller.abort();
            this.finishJob(key, job);
          }
        }
      } else staged.readers++;
      if (!staged) throw new ServiceUnavailableException('Narration staging unavailable; retry shortly');
      try {
        await this.verifySource(sourcePath, revision);
        this.ready.delete(key);
        this.ready.set(key, staged);
        const stream = entry.uncompressedSize
          ? createReadStream('', {
              fd: staged.file.fd,
              start: range?.start ?? 0,
              end: range?.end ?? entry.uncompressedSize - 1,
              autoClose: false,
              signal,
            })
          : Readable.from([]);
        let released = false;
        const release = () => {
          if (!released) {
            released = true;
            void this.release(staged);
          }
        };
        stream.once('end', release);
        stream.once('error', release);
        stream.once('close', release);
        return stream;
      } catch (error) {
        staged.expired = true;
        this.ready.delete(key);
        await this.release(staged);
        throw error;
      }
    } finally {
      // Deflated extraction owns a separate source descriptor.
      if (!sourceTransferred) await source.close();
    }
  }

  private finishJob(key: string, job: StagingJob): void {
    if (job.settled && !job.waiters && this.jobs.get(key) === job) this.jobs.delete(key);
  }

  private async release(staged: StagedAudio): Promise<void> {
    staged.readers--;
    if (staged.expired && !staged.readers) {
      await staged.file.close();
      this.reservedBytes -= staged.size;
      this.reservations--;
    }
  }

  private async reserve(size: number): Promise<void> {
    if (!Number.isSafeInteger(size) || size < 0) throw new BadRequestException('Invalid narration audio size');
    if (size > this.maximumBytes) {
      throw new ServiceUnavailableException('Narration staging capacity is insufficient; increase EPUB_AUDIO_CACHE_BYTES and retry');
    }
    for (const [key, staged] of this.ready) {
      if (this.reservedBytes + size <= this.maximumBytes && this.reservations < 64) break;
      if (staged.readers || this.jobs.get(key)?.waiters) continue;
      this.ready.delete(key);
      await staged.file.close();
      this.reservedBytes -= staged.size;
      this.reservations--;
    }
    if (this.reservedBytes + size > this.maximumBytes || this.reservations >= 64) {
      throw new ServiceUnavailableException('Narration staging is busy; retry shortly');
    }
    this.reservedBytes += size;
    this.reservations++;
  }

  private async prepare(
    userId: number,
    bookId: number,
    sourcePath: string,
    revision: string,
    offset: number,
    entry: File,
    signal: AbortSignal,
  ): Promise<StagedAudio> {
    await this.reserve(entry.uncompressedSize);
    try {
      return await this.stage(userId, bookId, sourcePath, revision, offset, entry, signal);
    } catch (error) {
      this.reservedBytes -= entry.uncompressedSize;
      this.reservations--;
      throw error;
    }
  }

  private async stage(
    userId: number,
    bookId: number,
    sourcePath: string,
    revision: string,
    offset: number,
    entry: File,
    signal: AbortSignal,
  ): Promise<StagedAudio> {
    const started = Date.now();
    this.logger.log(`[epub.audio_stage] [start] bookId=${bookId} userId=${userId} size=${entry.uncompressedSize} - narration staging started`);
    let output: FileHandle | undefined;
    let input: FileHandle | undefined;
    let directory: string | undefined;
    try {
      directory = await mkdtemp(join(tmpdir(), 'bookorbit-audio-'));
      const path = join(directory, 'audio');
      output = await open(path, 'wx+', 0o600);
      // An unlinked file is reclaimed even if the process crashes, keeping temporary storage bounded.
      await rm(path);
      await rm(directory, { recursive: true });
      directory = undefined;
      input = await open(sourcePath, 'r');
      if (audioSourceRevision(await input.stat()) !== revision) {
        throw new BadRequestException('Narration audio changed while reading');
      }
      let decodedBytes = 0;
      const limit = new Transform({
        transform(chunk: Buffer, _encoding, callback) {
          decodedBytes += chunk.length;
          callback(decodedBytes > entry.uncompressedSize ? new BadRequestException('Invalid narration audio size') : null, chunk);
        },
      });
      let pendingWrite: Promise<void> | undefined;
      await pipeline(
        input.createReadStream({ start: offset, end: offset + entry.compressedSize - 1 }),
        createInflateRaw(),
        limit,
        new Writable({
          write(chunk: Buffer, _encoding, callback) {
            pendingWrite = output!.writeFile(chunk);
            pendingWrite.then(() => callback(), callback);
          },
          destroy(error, callback) {
            if (pendingWrite)
              void pendingWrite.then(
                () => callback(error),
                () => callback(error),
              );
            else callback(error);
          },
        }),
        { signal },
      );
      if (decodedBytes !== entry.uncompressedSize) throw new BadRequestException('Invalid narration audio size');
      await this.verifySource(sourcePath, revision);
      this.logger.log(
        `[epub.audio_stage] [end] bookId=${bookId} userId=${userId} durationMs=${Date.now() - started} decodedBytes=${decodedBytes} - narration staging completed`,
      );
      return { file: output, size: decodedBytes, readers: 0 };
    } catch (error) {
      await output?.close();
      this.logger.warn(
        `[epub.audio_stage] [fail] bookId=${bookId} userId=${userId} durationMs=${Date.now() - started} errorClass=${error instanceof Error ? error.name : 'Unknown'} error="${sanitizeLogValue(error instanceof Error ? error.message : 'Unknown error')}" - narration staging failed`,
      );
      if (error instanceof BadRequestException) throw error;
      throw new ServiceUnavailableException('Narration staging interrupted; retry shortly');
    } finally {
      await input?.close();
      if (directory) await rm(directory, { recursive: true, force: true });
    }
  }

  private async verifySource(path: string, revision: string): Promise<void> {
    if (audioSourceRevision(await stat(path)) !== revision) throw new BadRequestException('Narration audio changed while reading');
  }

  private async wait<T>(promise: Promise<T>, signal?: AbortSignal): Promise<T> {
    if (!signal) return promise;
    if (signal.aborted) throw new ServiceUnavailableException('Narration request cancelled');
    let onAbort: () => void;
    try {
      return await Promise.race([
        promise,
        new Promise<never>((_resolve, reject) => {
          onAbort = () => reject(new ServiceUnavailableException('Narration request cancelled'));
          signal.addEventListener('abort', onAbort, { once: true });
        }),
      ]);
    } finally {
      signal.removeEventListener('abort', onAbort!);
    }
  }

  async close(): Promise<void> {
    this.closed = true;
    for (const job of this.jobs.values()) job.controller.abort();
    await Promise.allSettled([...this.jobs.values()].map((job) => job.promise));
    await Promise.allSettled([...this.ready.values()].map((audio) => audio.file.close()));
    this.ready.clear();
  }
}
