import { Test } from '@nestjs/testing';
import type { RequestUser } from '../../common/types/request-user';
import { EntityManagerService } from './entity-manager.service';
import { EntityManagerRepository } from './entity-manager.repository';
import { FileWriteService } from '../file-write/file-write.service';
import { LibraryService } from '../library/library.service';
import { MetadataScoreService } from '../metadata-score/metadata-score.service';
import { DuplicateComputeService } from './duplicate-compute.service';
import { AuthorStrategy } from './strategies/author.strategy';
import { GenreStrategy } from './strategies/genre.strategy';
import { TagStrategy } from './strategies/tag.strategy';
import { NarratorStrategy } from './strategies/narrator.strategy';
import { PublisherStrategy } from './strategies/publisher.strategy';
import { LanguageStrategy } from './strategies/language.strategy';
import { SeriesStrategy } from './strategies/series.strategy';
const user = { id: 42, isSuperuser: true } as RequestUser;
const operationId = 'persisted-operation';
function fixture(count: number, failures = new Set<number>()) {
  const pending = new Map(Array.from({ length: count }, (_, index) => [index + 1, null as Date | null]));
  const merge = vi.fn();
  let active = 0;
  let maxActive = 0;
  let interrupted = false;
  const writer = {
    writeToFile: vi.fn(async (id: number) => {
      active++;
      maxActive = Math.max(maxActive, active);
      await new Promise<void>((resolve) => setImmediate(resolve));
      active--;
      return { status: failures.has(id) ? 'failed' : 'success' };
    }),
  };
  const batchSizes: number[] = [];
  const repo = {
    filterBookIdsByScope: vi.fn((ids: number[]) => Promise.resolve(ids)),
    resumeFileWrites: vi.fn(async (_id, _user, _type, write, attemptedBefore: Date) => {
      if (interrupted) throw new Error('process interrupted');
      const ids = [...pending]
        .filter(([, attemptedAt]) => attemptedAt === null || attemptedAt < attemptedBefore)
        .slice(0, 50)
        .map(([id]) => id);
      batchSizes.push(ids.length);
      const completed = await write(ids);
      for (const id of ids) pending.set(id, new Date(Math.max(Date.now(), attemptedBefore.getTime())));
      for (const id of completed) pending.delete(id);
      return { operationId, pendingBookCount: pending.size, processed: ids.length, completed: completed.length };
    }),
  };
  async function service() {
    const module = await Test.createTestingModule({
      providers: [
        EntityManagerService,
        { provide: EntityManagerRepository, useValue: repo },
        { provide: FileWriteService, useValue: writer },
        { provide: LibraryService, useValue: { findAccessibleLibraryIds: vi.fn().mockResolvedValue([1]) } },
        { provide: MetadataScoreService, useValue: {} },
        { provide: DuplicateComputeService, useValue: {} },
        ...[AuthorStrategy, GenreStrategy, TagStrategy, NarratorStrategy, PublisherStrategy, LanguageStrategy, SeriesStrategy].map((provide) => ({
          provide,
          useValue: { merge },
        })),
      ],
    }).compile();
    return module.get(EntityManagerService);
  }
  return {
    service,
    pending,
    writer,
    merge,
    repo,
    batchSizes,
    maxActive: () => maxActive,
    interrupt: () => {
      interrupted = true;
    },
    restore: () => {
      interrupted = false;
    },
  };
}
it('automatically drains 1201 successful updates in batches of 50 with at most five writes at once', async () => {
  const f = fixture(1201);
  const service = await f.service();
  const response = await service.resumeFileWrites('author', user, operationId);
  expect(response.pendingBookCount).toBe(1151);
  await vi.waitFor(() => expect(f.pending.size).toBe(0));
  expect(f.writer.writeToFile).toHaveBeenCalledTimes(1201);
  expect(Math.max(...f.batchSizes)).toBe(50);
  expect(f.maxActive()).toBe(5);
  await service.onModuleDestroy();
});
it('retains failed first IDs while automatically attempting all later untouched IDs once', async () => {
  const f = fixture(1201, new Set(Array.from({ length: 50 }, (_, index) => index + 1)));
  const service = await f.service();
  await service.resumeFileWrites('author', user, operationId);
  await vi.waitFor(() => expect(f.writer.writeToFile).toHaveBeenCalledTimes(1201));
  await vi.waitFor(() => expect(f.pending.size).toBe(50));
  expect([...f.pending.keys()]).toEqual(Array.from({ length: 50 }, (_, index) => index + 1));
  await service.onModuleDestroy();
  expect(f.writer.writeToFile).toHaveBeenCalledTimes(1201);
});
it('resumes the persisted remaining IDs after interruption without merging again', async () => {
  const f = fixture(1201);
  const first = await f.service();
  await first.resumeFileWrites('author', user, operationId);
  f.interrupt();
  await vi.waitFor(() => expect(f.repo.resumeFileWrites).toHaveBeenCalledTimes(2));
  await first.onModuleDestroy();
  expect(f.pending.size).toBe(1151);
  f.restore();
  const restarted = await f.service();
  await restarted.resumeFileWrites('author', user, operationId);
  await vi.waitFor(() => expect(f.pending.size).toBe(0));
  expect(f.writer.writeToFile).toHaveBeenCalledTimes(1201);
  expect(f.merge).not.toHaveBeenCalled();
  await restarted.onModuleDestroy();
});
