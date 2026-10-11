import { drizzle } from 'drizzle-orm/node-postgres';

import * as schema from '../../db/schema';
import { BulkRenameRepository } from './bulk-rename.repository';

describe('BulkRenameRepository', () => {
  function queryChain(rows: unknown) {
    return {
      from: vi.fn().mockReturnThis(),
      innerJoin: vi.fn().mockReturnThis(),
      where: vi.fn().mockReturnThis(),
      orderBy: vi.fn().mockImplementation(function (this: unknown) {
        return Object.assign(Promise.resolve(rows), { limit: vi.fn().mockResolvedValue(rows) });
      }),
      limit: vi.fn().mockResolvedValue(rows),
    };
  }

  describe('findBooksPageForLibrary', () => {
    it('maps book rows and groups authors by book', async () => {
      const bookRows = [
        {
          bookId: 1,
          primaryFileId: 11,
          absolutePath: '/lib/old/a.epub',
          relPath: 'old/a.epub',
          format: 'epub',
          libraryFolderPath: '/lib',
          organizationMode: 'book_per_file',
          fileNamingPattern: '{title}',
          bookFolderPath: '/lib/old/a.epub',
          title: 'A',
          subtitle: null,
          publisher: null,
          language: 'en',
          isbn10: '0306406152',
          isbn13: null,
          publishedYear: 2001,
          seriesName: null,
          seriesIndex: null,
        },
        {
          bookId: 2,
          primaryFileId: 21,
          absolutePath: '/lib/old/b.epub',
          relPath: 'old/b.epub',
          format: 'epub',
          libraryFolderPath: '/lib',
          organizationMode: 'book_per_file',
          fileNamingPattern: '{title}',
          bookFolderPath: '/lib/old/b.epub',
          title: 'B',
          subtitle: null,
          publisher: null,
          language: null,
          isbn13: null,
          publishedYear: null,
          seriesName: null,
          seriesIndex: null,
        },
      ];
      const authorRows = [
        { bookId: 1, name: 'Author One' },
        { bookId: 1, name: 'Author Two' },
        { bookId: 2, name: 'Author Three' },
      ];
      const narratorRows = [
        { bookId: 1, name: 'Narrator One' },
        { bookId: 2, name: 'Narrator Two' },
        { bookId: 2, name: 'Narrator Three' },
      ];

      const fileRows = [
        { bookId: 1, id: 11, absolutePath: '/lib/old/a.epub', format: 'epub', role: 'content', sortOrder: null },
        { bookId: 1, id: 12, absolutePath: '/lib/old/a.jpg', format: 'jpg', role: 'cover', sortOrder: null },
        { bookId: 2, id: 21, absolutePath: '/lib/old/b.epub', format: 'epub', role: 'content', sortOrder: null },
      ];

      const db = {
        select: vi
          .fn()
          .mockReturnValueOnce(queryChain(bookRows))
          .mockReturnValueOnce(queryChain(authorRows))
          .mockReturnValueOnce(queryChain(narratorRows))
          .mockReturnValueOnce(queryChain(fileRows))
          .mockReturnValue(queryChain([])),
      };

      const repo = new BulkRenameRepository(db as never);
      const result = await repo.findBooksPageForLibrary(7, 0, 1000);

      expect(result).toHaveLength(2);
      expect(result[0]).toMatchObject({
        bookId: 1,
        title: 'A',
        absolutePath: '/lib/old/a.epub',
        authors: ['Author One', 'Author Two'],
        narrators: ['Narrator One'],
        metadata: { language: 'en', publishedYear: 2001, isbn10: '0306406152', isbn13: null },
      });
      expect(result[1]).toMatchObject({ bookId: 2, authors: ['Author Three'], narrators: ['Narrator Two', 'Narrator Three'] });

      // Sibling files travel with the book so the preview can see a multi-file layout.
      expect(result[0]?.primaryFileId).toBe(11);
      expect(result[0]?.files.map((file) => file.id)).toEqual([11, 12]);
      expect(result[1]?.files.map((file) => file.id)).toEqual([21]);
    });

    it('returns books with empty author and narrator lists when none are linked', async () => {
      const bookRows = [
        {
          bookId: 1,
          primaryFileId: 11,
          absolutePath: '/lib/old/a.epub',
          relPath: 'old/a.epub',
          format: 'epub',
          libraryFolderPath: '/lib',
          organizationMode: 'book_per_file',
          fileNamingPattern: '{title}',
          bookFolderPath: '/lib/old/a.epub',
          title: 'A',
          subtitle: null,
          publisher: null,
          language: null,
          isbn13: null,
          publishedYear: null,
          seriesName: null,
          seriesIndex: null,
        },
      ];

      const db = {
        select: vi
          .fn()
          .mockReturnValueOnce(queryChain(bookRows))
          .mockReturnValueOnce(queryChain([]))
          .mockReturnValueOnce(queryChain([]))
          .mockReturnValueOnce(queryChain([]))
          .mockReturnValue(queryChain([])),
      };

      const repo = new BulkRenameRepository(db as never);
      const result = await repo.findBooksPageForLibrary(7, 0, 1000);

      expect(result).toHaveLength(1);
      expect(result[0].authors).toEqual([]);
      expect(result[0].narrators).toEqual([]);
      expect(result[0].files).toEqual([]);
    });

    it('returns an empty array and skips the contributor queries when the library has no books', async () => {
      const db = { select: vi.fn().mockReturnValueOnce(queryChain([])) };

      const repo = new BulkRenameRepository(db as never);
      const result = await repo.findBooksPageForLibrary(7, 0, 1000);

      expect(result).toEqual([]);
      expect(db.select).toHaveBeenCalledTimes(1);
    });

    it('bounds candidate queries and scopes related records to the selected page', async () => {
      const calls: Array<{ text: string; params: unknown[] }> = [];
      const fakeClient = {
        query: vi.fn().mockImplementation((cfg: { text: string }, params: unknown[]) => {
          calls.push({ text: cfg.text, params });
          return Promise.resolve({ rows: calls.length === 1 ? [[91, ...new Array(20).fill(null)]] : [] });
        }),
      };
      const db = drizzle({ client: fakeClient as never, schema });
      await new BulkRenameRepository(db).findBooksPageForLibrary(42, 90, 1000);
      expect(calls[0].params).toEqual([42, 90, 1000, 250]);
      for (const query of calls.slice(1)) expect(query.params).toEqual([91]);
    });
  });

  describe('findLibrarySettings', () => {
    function settingsChain(rows: unknown) {
      return {
        from: vi.fn().mockReturnThis(),
        where: vi.fn().mockReturnThis(),
        limit: vi.fn().mockResolvedValue(rows),
      };
    }

    it('returns the settings row when the library exists', async () => {
      const row = { fileRenameEnabled: true, fileNamingPattern: '{title}', organizationMode: 'book_per_file', watch: false };
      const db = { select: vi.fn().mockReturnValue(settingsChain([row])) };

      const repo = new BulkRenameRepository(db as never);

      await expect(repo.findLibrarySettings(1)).resolves.toEqual(row);
    });

    it('returns null when the library is missing', async () => {
      const db = { select: vi.fn().mockReturnValue(settingsChain([])) };

      const repo = new BulkRenameRepository(db as never);

      await expect(repo.findLibrarySettings(999)).resolves.toBeNull();
    });
  });
});
