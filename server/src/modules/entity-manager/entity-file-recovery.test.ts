import { Test } from '@nestjs/testing';
import { sql } from 'drizzle-orm';
import { PgDialect } from 'drizzle-orm/pg-core';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { EntityManagerService } from './entity-manager.service';
import { mutateEntityBooks } from './strategies/entity-mutation-books';
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
import type { RequestUser } from '../../common/types/request-user';
const user = { id: 42, isSuperuser: true } as RequestUser;
const dialect = new PgDialect();
async function fixture() {
  const directory = await mkdtemp(join(tmpdir(), 'entity-recovery-test-'));
  const path = join(directory, 'book.epub');
  await writeFile(path, 'old metadata');
  const pending = new Map<string, number[]>();
  let committed = false;
  let restored = false;
  const mutate = vi.fn().mockResolvedValue(undefined);
  const tx = {
    insert: vi.fn(() => ({ values: vi.fn().mockResolvedValue(undefined) })),
    execute: vi.fn((statement) => {
      const query = dialect.sqlToQuery(statement);
      if (query.sql.includes('AS outside')) return { rows: [{ outside: false }] };
      if (query.sql.includes('count(*)::int')) return { rows: [{ count: 1 }] };
      if (query.sql.includes('AS "bookId"')) return { rows: query.params[0] === 0 ? [{ bookId: 1 }] : [] };
      if (query.sql.includes('entity_file_write_books')) pending.set(String(query.params[0]), [1]);
      return { rows: [] };
    }),
  };
  const db = {
    transaction: vi.fn(async (callback) => {
      const result = await callback(tx);
      committed = true;
      return result;
    }),
  };
  const strategy = {
    entityType: 'author',
    isInline: false,
    merge: vi.fn((input) => mutateEntityBooks(db as never, input, { libraryIds: [1] }, sql`SELECT id FROM books`, mutate)),
  };
  const writer = {
    writeToFile: vi.fn(async () => {
      expect(committed).toBe(true);
      if (!restored) return { status: 'failed', fieldsWritten: [], durationMs: 0 };
      await writeFile(path, 'merged metadata');
      return { status: 'success', fieldsWritten: ['authors'], durationMs: 1 };
    }),
  };
  const repo = {
    filterBookIdsByScope: vi.fn((ids) => Promise.resolve(ids)),
    deleteDismissedPairsForEntity: vi.fn(),
    resumeFileWrites: vi.fn(async (operationId, _userId, _type, write) => {
      const ids = pending.get(operationId)!;
      const completed = await write(ids);
      const remaining = ids.filter((id) => !completed.includes(id));
      pending.set(operationId, remaining);
      return { operationId, pendingBookCount: remaining.length, processed: ids.length, completed: completed.length };
    }),
  };
  async function service() {
    const module = await Test.createTestingModule({
      providers: [
        EntityManagerService,
        { provide: EntityManagerRepository, useValue: repo },
        { provide: FileWriteService, useValue: writer },
        { provide: LibraryService, useValue: { findAccessibleLibraryIds: vi.fn().mockResolvedValue([1]) } },
        { provide: MetadataScoreService, useValue: { calculateAndSaveMany: vi.fn() } },
        { provide: DuplicateComputeService, useValue: { invalidateCandidatesForEntities: vi.fn() } },
        ...[AuthorStrategy, GenreStrategy, TagStrategy, NarratorStrategy, PublisherStrategy, LanguageStrategy, SeriesStrategy].map((provide) => ({
          provide,
          useValue: strategy,
        })),
      ],
    }).compile();
    return module.get(EntityManagerService);
  }
  return {
    service,
    strategy,
    mutate,
    writer,
    repo,
    pending,
    path,
    restore: () => {
      restored = true;
    },
    cleanup: () => rm(directory, { recursive: true, force: true }),
  };
}
it('retains a failed merged book receipt and leaves source file bytes unchanged', async () => {
  const f = await fixture();
  try {
    const result = await (await f.service()).merge('author', user, 1, [2], true);
    expect(result.fileWriteRecovery?.pendingBookCount).toBe(1);
    expect([...f.pending.values()]).toEqual([[1]]);
    expect(await readFile(f.path, 'utf8')).toBe('old metadata');
  } finally {
    await f.cleanup();
  }
});
it('retries retained IDs after the writer recovers without repeating the merge', async () => {
  const f = await fixture();
  try {
    const service = await f.service();
    const merged = await service.merge('author', user, 1, [2], true);
    f.restore();
    const retry = await service.resumeFileWrites('author', user, merged.fileWriteRecovery!.operationId);
    expect(retry).toMatchObject({ pendingBookCount: 0, completed: 1 });
    expect(await readFile(f.path, 'utf8')).toBe('merged metadata');
    expect(f.strategy.merge).toHaveBeenCalledTimes(1);
    expect(f.mutate).toHaveBeenCalledTimes(1);
    expect(f.writer.writeToFile).toHaveBeenCalledTimes(2);
  } finally {
    await f.cleanup();
  }
});
it('resumes committed IDs in a new service after interruption before batch writes', async () => {
  const f = await fixture();
  try {
    f.repo.resumeFileWrites.mockRejectedValueOnce(new Error('process interrupted'));
    await expect((await f.service()).merge('author', user, 1, [2], true)).rejects.toThrow('process interrupted');
    expect(f.writer.writeToFile).not.toHaveBeenCalled();
    const operationId = [...f.pending.keys()][0]!;
    f.restore();
    const resumed = await (await f.service()).resumeFileWrites('author', user, operationId);
    expect(resumed.pendingBookCount).toBe(0);
    expect(await readFile(f.path, 'utf8')).toBe('merged metadata');
    expect(f.mutate).toHaveBeenCalledTimes(1);
  } finally {
    await f.cleanup();
  }
});
