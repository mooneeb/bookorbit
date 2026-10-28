import {
  BadRequestException,
  ForbiddenException,
  Injectable,
  Logger,
  NotFoundException,
  ServiceUnavailableException,
  type OnModuleDestroy,
} from '@nestjs/common';
import { createHash, randomUUID } from 'node:crypto';
import { createReadStream, createWriteStream } from 'node:fs';
import { mkdtemp, open, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Transform } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import * as unzipper from 'unzipper';
import type { NativeEpubSession } from '@bookorbit/types';
import type { RequestUser } from '../../../common/types/request-user';
import { sanitizeLogValue } from '../../../common/utils/log-sanitize.utils';
import { EpubService } from './epub.service';

const MiB = 1024 * 1024;
const TTL = 30 * 60 * 1000;
interface Lease {
  owner: number;
  directory: string;
  manifest: NativeEpubSession;
}

@Injectable()
export class EpubSessionService implements OnModuleDestroy {
  private readonly logger = new Logger(EpubSessionService.name);
  private readonly leases = new Map<string, Lease>();
  private readonly preparing = new Set<number>();
  private readonly expiryTimer = setInterval(() => {
    void this.expire();
  }, 60_000).unref();

  constructor(private readonly epub: EpubService) {}

  async open(bookId: number, fileId: number, user: RequestUser): Promise<NativeEpubSession> {
    await this.expire();
    if (
      this.preparing.has(user.id) ||
      this.preparing.size >= 2 ||
      this.leases.size + this.preparing.size >= 4 ||
      [...this.leases.values()].some((lease) => lease.owner === user.id)
    ) {
      throw new ServiceUnavailableException('Close the current reader or wait for its lease to expire');
    }
    this.preparing.add(user.id);
    const started = Date.now();
    this.logger.log(`[epub.session] [start] bookId=${bookId} fileId=${fileId} userId=${user.id} - prepare online reader`);
    let directory: string | undefined;
    try {
      const source = await this.epub.resolveOriginalPath(bookId, fileId, user);
      const before = await stat(source);
      if (before.size > 512 * MiB) throw new BadRequestException('EPUB exceeds 512 MiB');
      directory = await mkdtemp(join(tmpdir(), 'bookorbit-reader-'));
      const original = join(directory, 'original');
      const sourceHash = await this.copy(createReadStream(source), original, 512 * MiB);
      const after = await stat(source);
      if (before.size !== after.size || before.mtimeMs !== after.mtimeMs || before.ino !== after.ino)
        throw new BadRequestException('Source changed during preparation. Retry');
      await this.checkDirectory(original);
      const archive = await unzipper.Open.file(original);
      const members: NativeEpubSession['members'] = [];
      const paths = new Set<string>();
      let total = 0;
      for (const entry of archive.files) {
        if (entry.type === 'Directory') continue;
        const path = entry.path;
        if (
          path.length > 1024 ||
          path.startsWith('/') ||
          path.includes('\\') ||
          path.split('/').some((part) => !part || part === '.' || part === '..') ||
          paths.has(path)
        ) {
          throw new BadRequestException('Ambiguous or invalid archive member');
        }
        paths.add(path);
        const limit = /\.(?:xhtml|html?|css|xml|opf|ncx|svg)$/i.test(path) ? 4 * MiB : 32 * MiB;
        total += entry.uncompressedSize;
        if (entry.uncompressedSize > limit || total > 2048 * MiB) throw new BadRequestException('EPUB expanded resource limit exceeded');
        const result = await this.copy(entry.stream(), join(directory, String(members.length)), limit, started + 120_000);
        if (result.bytes !== entry.uncompressedSize) throw new BadRequestException('Incorrect archive member size');
        members.push({ path, ...result });
      }
      const manifest: NativeEpubSession = {
        version: 1,
        id: randomUUID(),
        bookId,
        fileId,
        sourceSha256: sourceHash.sha256,
        sourceBytes: sourceHash.bytes,
        expiresAt: new Date(Date.now() + TTL).toISOString(),
        members,
      };
      if (Buffer.byteLength(JSON.stringify(manifest)) > 256 * 1024) throw new BadRequestException('EPUB manifest exceeds 256 KiB');
      this.leases.set(manifest.id, { owner: user.id, directory, manifest });
      this.logger.log(
        `[epub.session] [end] bookId=${bookId} fileId=${fileId} userId=${user.id} durationMs=${Date.now() - started} members=${members.length} - online reader prepared`,
      );
      return manifest;
    } catch (error) {
      if (directory) await rm(directory, { recursive: true, force: true });
      this.logger.warn(
        `[epub.session] [fail] bookId=${bookId} fileId=${fileId} userId=${user.id} durationMs=${Date.now() - started} errorClass=${error instanceof Error ? error.name : 'Unknown'} error="${sanitizeLogValue(error instanceof Error ? error.message : 'Preparation failed')}" - online reader preparation failed`,
      );
      throw error;
    } finally {
      this.preparing.delete(user.id);
    }
  }

  async resource(id: string, index: number, user: RequestUser) {
    const lease = this.owned(id, user);
    await this.epub.resolveOriginalPath(lease.manifest.bookId, lease.manifest.fileId, user);
    const member = lease.manifest.members[index];
    if (!member) throw new NotFoundException('Resource unavailable');
    return { stream: createReadStream(join(lease.directory, String(index))), bytes: member.bytes };
  }

  async original(id: string, user: RequestUser) {
    const lease = this.owned(id, user);
    await this.epub.resolveOriginalPath(lease.manifest.bookId, lease.manifest.fileId, user);
    return { stream: createReadStream(join(lease.directory, 'original')), bytes: lease.manifest.sourceBytes };
  }

  async close(id: string, user: RequestUser) {
    await this.release(this.owned(id, user), 'close');
  }

  private async release(lease: Lease, reason: string) {
    const started = Date.now();
    const { bookId, fileId, id } = lease.manifest;
    const ids = `bookId=${bookId} fileId=${fileId} userId=${lease.owner} sessionId=${id}`;
    this.logger.log(`[epub.session_cleanup] [start] ${ids} reason=${reason} - release online snapshot`);
    try {
      await rm(lease.directory, { recursive: true, force: true });
      this.leases.delete(id);
      this.logger.log(`[epub.session_cleanup] [end] ${ids} durationMs=${Date.now() - started} removed=true - snapshot released`);
    } catch (error) {
      this.logger.warn(
        `[epub.session_cleanup] [fail] ${ids} durationMs=${Date.now() - started} errorClass=${error instanceof Error ? error.name : 'Unknown'} error="${sanitizeLogValue(error instanceof Error ? error.message : 'Cleanup failed')}" - snapshot cleanup failed`,
      );
      throw new ServiceUnavailableException('Snapshot cleanup failed. Retry later');
    }
  }

  private owned(id: string, user: RequestUser) {
    const lease = this.leases.get(id.toLowerCase());
    if (!lease || Date.parse(lease.manifest.expiresAt) <= Date.now()) throw new NotFoundException('Reader lease expired. Reopen the book');
    if (lease.owner !== user.id) throw new ForbiddenException('Reader belongs to another account');
    return lease;
  }

  private async copy(input: NodeJS.ReadableStream, destination: string, limit: number, deadline = Date.now() + 120_000) {
    const hash = createHash('sha256');
    let bytes = 0;
    const meter = new Transform({
      transform(chunk: Buffer, _encoding, callback) {
        bytes += chunk.length;
        if (bytes > limit || Date.now() > deadline) return callback(new BadRequestException('Resource size or preparation deadline exceeded'));
        hash.update(chunk);
        callback(null, chunk);
      },
    });
    await pipeline(input, meter, createWriteStream(destination, { flags: 'wx', mode: 0o600 }), {
      signal: AbortSignal.timeout(Math.max(1, deadline - Date.now())),
    });
    return { bytes, sha256: hash.digest('hex') };
  }

  private async checkDirectory(path: string) {
    const handle = await open(path, 'r');
    try {
      const size = (await handle.stat()).size;
      const tail = Buffer.alloc(Math.min(size, 65_557));
      await handle.read(tail, 0, tail.length, size - tail.length);
      for (let i = tail.length - 22; i >= 0; i--) {
        if (tail.readUInt32LE(i) !== 0x06054b50 || i + 22 + tail.readUInt16LE(i + 20) !== tail.length) continue;
        const count = tail.readUInt16LE(i + 10);
        if (tail.readUInt32LE(i + 12) > 8 * MiB || count > 20_000 || tail.readUInt16LE(i + 4) !== 0 || tail.readUInt16LE(i + 6) !== 0) break;
        return;
      }
      throw new BadRequestException('Unsupported or oversized ZIP directory');
    } finally {
      await handle.close();
    }
  }

  private async expire() {
    for (const lease of this.leases.values()) {
      if (Date.parse(lease.manifest.expiresAt) > Date.now()) continue;
      await this.release(lease, 'expiry').catch(() => undefined);
    }
  }

  async onModuleDestroy() {
    clearInterval(this.expiryTimer);
    const leases = [...this.leases.values()];
    await Promise.all(leases.map((lease) => this.release(lease, 'shutdown')));
  }
}
