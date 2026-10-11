import { ConflictException } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { PgDialect } from 'drizzle-orm/pg-core';
import { open } from 'fs/promises';
import { describe, expect, it, vi } from 'vitest';
import type { MissingFileRepairPreview } from '@bookorbit/types';
import { DB } from '../../db';
import * as schema from '../../db/schema';
import { LibraryService } from '../library/library.service';
import { PathPolicyService } from '../path/path-policy.service';
import { MissingFileRepairService } from './missing-file-repair.service';

vi.mock('fs/promises', () => ({ open: vi.fn() }));

const user = { id: 7, isSuperuser: false } as never;
const dialect = new PgDialect();

async function setup({
  replacementPath = '/books/Author/Title/replacement.epub',
  organizationMode = 'book_per_folder',
  multipleFiles = false,
  occupied = false,
} = {}) {
  const book = { id: 10, libraryId: 2, libraryFolderId: 3, folderPath: '/books/Author/Title', status: 'missing' };
  const file = { id: 11, bookId: book.id, absolutePath: '/books/Author/Title/missing.epub' };
  const sibling = { id: 12, bookId: book.id, absolutePath: '/books/Author/Title/companion.pdf' };
  const contextQuery = {
    from: vi.fn().mockReturnThis(),
    innerJoin: vi.fn().mockReturnThis(),
    where: vi.fn().mockReturnThis(),
    limit: vi.fn().mockResolvedValue([{ book, file, root: '/books', organizationMode }]),
  };
  const lockedBook = { from: vi.fn().mockReturnThis(), where: vi.fn().mockReturnThis(), for: vi.fn().mockResolvedValue([book]) };
  const fileQuery = {
    from: vi.fn().mockReturnThis(),
    where: vi.fn().mockReturnThis(),
    limit: vi.fn().mockResolvedValue(multipleFiles ? [file, sibling] : [file]),
  };
  const collisionQuery = {
    from: vi.fn().mockReturnThis(),
    where: vi.fn().mockReturnThis(),
    limit: vi.fn().mockResolvedValue(occupied ? [{ id: 99 }] : []),
  };
  const fileWrite = { set: vi.fn().mockReturnThis(), where: vi.fn().mockReturnThis(), returning: vi.fn().mockResolvedValue([{ id: file.id }]) };
  const bookWrite = { set: vi.fn().mockReturnThis(), where: vi.fn().mockResolvedValue(undefined) };
  const tx = {
    select: vi.fn().mockReturnValueOnce(lockedBook).mockReturnValueOnce(fileQuery).mockReturnValueOnce(collisionQuery),
    update: vi.fn().mockReturnValueOnce(fileWrite).mockReturnValueOnce(bookWrite),
  };
  const db = {
    select: vi.fn().mockReturnValue(contextQuery),
    transaction: vi.fn().mockImplementation((callback: (transaction: typeof tx) => Promise<void>) => callback(tx)),
  };
  const libraries = { verifyUserAccessLevel: vi.fn().mockResolvedValue(undefined) };
  const module = await Test.createTestingModule({
    providers: [
      MissingFileRepairService,
      { provide: DB, useValue: db },
      { provide: LibraryService, useValue: libraries },
      { provide: PathPolicyService, useValue: {} },
    ],
  }).compile();
  const service = module.get(MissingFileRepairService);
  const preview: MissingFileRepairPreview = {
    bookId: book.id,
    fileId: file.id,
    currentPath: file.absolutePath,
    replacementPath,
    previewToken: 'verified-content',
    sizeBytes: 100,
    alreadyApplied: false,
  };
  vi.spyOn(service, 'preview').mockResolvedValue(preview);
  vi.mocked(open).mockResolvedValue({
    stat: vi.fn().mockResolvedValue({ ino: 123n, mtimeMs: 1234n }),
    close: vi.fn().mockResolvedValue(undefined),
  } as never);
  const input = { bookId: book.id, fileId: file.id, replacementPath, previewToken: preview.previewToken };
  return { service, input, book, file, sibling, tx, fileWrite, bookWrite, collisionQuery, contextQuery, libraries };
}

describe('MissingFileRepairService book path identity', () => {
  it('repairs a multi-file book in its absolute folder without changing sibling identities', async () => {
    const { service, input, book, file, sibling, tx, fileWrite, bookWrite } = await setup({ multipleFiles: true });
    await expect(service.repair(input, user)).resolves.toMatchObject({ bookId: book.id, fileId: file.id, repaired: true });
    expect(tx.update.mock.calls.map(([table]) => table)).toEqual([schema.bookFiles, schema.books]);
    expect(fileWrite.set).toHaveBeenCalledExactlyOnceWith({
      absolutePath: input.replacementPath,
      relPath: 'Author/Title/replacement.epub',
      ino: 123n,
      mtime: new Date(1234),
      updatedAt: expect.any(Date),
    });
    const filePredicate = dialect.sqlToQuery(fileWrite.where.mock.calls[0][0]);
    expect(filePredicate.params).toEqual([file.id, book.id, file.absolutePath]);
    expect(filePredicate.params).not.toContain(sibling.id);
    expect(bookWrite.set).toHaveBeenCalledExactlyOnceWith({ status: 'present', updatedAt: expect.any(Date) });
    expect(bookWrite.set.mock.calls[0][0]).not.toHaveProperty('folderPath');
    expect(book.folderPath).toBe('/books/Author/Title');
    expect(sibling).toEqual({ id: 12, bookId: 10, absolutePath: '/books/Author/Title/companion.pdf' });
  });

  it('uses scanner and rename compatible absolute identities for file, folder and root-level books', async () => {
    const cases = [
      { organizationMode: 'book_per_file', replacementPath: '/books/Author/New/book.epub', expected: '/books/Author/New/book.epub' },
      { organizationMode: 'book_per_folder', replacementPath: '/books/Author/New/book.epub', expected: '/books/Author/New' },
      { organizationMode: 'book_per_folder', replacementPath: '/books/loose.epub', expected: '/books/loose.epub' },
    ];
    for (const { expected, ...options } of cases) {
      const { service, input, book, collisionQuery, bookWrite, contextQuery, libraries } = await setup(options);
      await service.repair(input, user);
      expect(bookWrite.set).toHaveBeenCalledExactlyOnceWith({ status: 'present', folderPath: expected, updatedAt: expect.any(Date) });
      expect(dialect.sqlToQuery(collisionQuery.where.mock.calls[0][0]).params).toEqual([book.libraryId, expected]);
      expect(contextQuery.innerJoin.mock.calls.map(([table]) => table)).toContain(schema.libraries);
      expect(libraries.verifyUserAccessLevel).toHaveBeenCalledWith(7, book.libraryId, false, 'editor');
    }
  });

  it('rejects an occupied absolute folder with HTTP 409 before any identity writes', async () => {
    const { service, input, tx, collisionQuery } = await setup({ replacementPath: '/books/Other/book.epub', occupied: true });
    const error = await service.repair(input, user).catch((failure: unknown) => failure);
    expect(error).toBeInstanceOf(ConflictException);
    expect((error as ConflictException).getStatus()).toBe(409);
    expect(dialect.sqlToQuery(collisionQuery.where.mock.calls[0][0]).params).toEqual([2, '/books/Other']);
    expect(tx.update).not.toHaveBeenCalled();
  });
});
