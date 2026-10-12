import { Test, type TestingModule } from '@nestjs/testing';
import { getTableColumns } from 'drizzle-orm';
import { drizzle } from 'drizzle-orm/node-postgres';
import { DB } from '../../db';
import * as schema from '../../db/schema';
import { MIN_VALID_FILE_TIME_MS } from '../../common/utils/file-time.utils';
import { LibraryRepository } from './library.repository';

type Query = { text: string; params: unknown[] };
function tableRow(table: typeof schema.libraries | typeof schema.libraryFolders, values: Record<string, unknown>) {
  return Object.keys(getTableColumns(table)).map((key) => values[key] ?? null);
}

describe('LibraryRepository SQL and result contracts', () => {
  let module: TestingModule;
  let repo: LibraryRepository;
  let calls: Query[];
  let responses: Array<unknown[][] | Error>;
  beforeEach(async () => {
    calls = [];
    responses = [];
    const client = {
      query: vi.fn((config: string | { text: string }, params: unknown[] = []) => {
        const text = typeof config === 'string' ? config : config.text;
        calls.push({ text, params });
        if (['begin', 'commit', 'rollback'].includes(text)) return Promise.resolve({ rows: [], rowCount: 0 });
        const rows = responses.shift() ?? [];
        if (rows instanceof Error) return Promise.reject(rows);
        return Promise.resolve({ rows, rowCount: rows.length });
      }),
    };
    module = await Test.createTestingModule({
      providers: [LibraryRepository, { provide: DB, useValue: drizzle({ client: client as never, schema }) }],
    }).compile();
    repo = module.get(LibraryRepository);
  });
  afterEach(async () => {
    await module.close();
  });

  it('pages move destinations using editor or owner grants, source exclusion, and literal search', async () => {
    responses.push([[8, 'Archive', 'book_per_file']], [[17]]);
    await expect(repo.findMoveDestinations(42, false, 7, 2, 5, 'A%_')).resolves.toEqual({
      items: [{ id: 8, name: 'Archive', organizationMode: 'book_per_file' }],
      total: 17,
      page: 2,
      size: 5,
    });
    expect(calls).toHaveLength(2);
    for (const query of calls) {
      expect(query.text).toContain('exists (select');
      expect(query.text).toContain('"user_library_access"."user_id" =');
      expect(query.text).toContain('"user_library_access"."library_id" = "libraries"."id"');
      expect(query.text).toContain('"libraries"."id" <>');
      expect(query.params).toEqual(expect.arrayContaining(['books', 7, 42, 'editor', 'owner', '%A\\%\\_%']));
      expect(query.params).not.toContain('viewer');
    }
    expect(calls[0].text).toContain('order by lower("libraries"."name"), "libraries"."id" limit');
    expect(calls[0].params.slice(-2)).toEqual([5, 10]);
  });
  it('allows superuser destinations without grants and defaults a missing count', async () => {
    await expect(repo.findMoveDestinations(42, true, 7, 0, 25)).resolves.toEqual({ items: [], total: 0, page: 0, size: 25 });
    expect(calls[0].text).not.toContain('exists');
    expect(calls[0].params).toEqual(['books', 7, 25]);
  });
  it('pages downloads folders within a library and defaults an empty page', async () => {
    responses.push([[13, '/archive/books']], [[9]], [], []);
    await expect(repo.findMoveFolders(8, 1, 3, 'books_')).resolves.toEqual({
      libraryId: 8,
      items: [{ id: 13, path: '/archive/books' }],
      total: 9,
      page: 1,
      size: 3,
    });
    await expect(repo.findMoveFolders(8, 0, 10)).resolves.toEqual({ libraryId: 8, items: [], total: 0, page: 0, size: 10 });
    expect(calls[0].params).toEqual([8, 'downloads', '%books\\_%', 3, 3]);
    expect(calls[1].params).toEqual([8, 'downloads', '%books\\_%']);
    expect(calls[0].text).toContain('order by "library_folders"."id" limit');
    expect(calls[2].params).toEqual([8, 'downloads', 10]);
  });
  it('retains empty libraries and counts present books using the left join', async () => {
    responses.push([[...tableRow(schema.libraries, { id: 7, name: 'Empty' }), null, 0, null]]);
    await expect(repo.findAll()).resolves.toEqual([expect.objectContaining({ id: 7, name: 'Empty', accessLevel: null, bookCount: 0 })]);
    expect(calls[0].text).toContain('left join "books" on ("books"."library_id" = "libraries"."id" and "books"."status" =');
    expect(calls[0].params).toEqual(['present', 'books']);
    expect(calls[0].text).toContain('group by "libraries"."id" order by "libraries"."display_order", "libraries"."name"');
  });
  it('scopes the user overview and applies content filters to book counts without hiding empty libraries', async () => {
    await repo.findAllForUser(42, { includeTagIds: [11], includeGenreIds: [], excludeTagIds: [], excludeGenreIds: [19] });
    await repo.findAllForUser(43);
    expect(calls[0].text).toContain('inner join "user_library_access" on');
    expect(calls[0].text).toContain('"user_library_access"."user_id" =');
    expect(calls[0].text).toContain('left join "books" on');
    expect(calls[0].text).toContain('exists (select 1 from "book_tags"');
    expect(calls[0].text).toContain('not exists (select 1 from "book_genres"');
    expect(calls[0].params).toEqual([42, 'present', 11, 19, 'books']);
    expect(calls[1].params).toEqual([43, 'present', 'books']);
    for (const field of ['organization_mode', 'auto_scan_cron_expression', 'watch', 'file_write_enabled', 'file_rename_enabled'])
      expect(calls[0].text).toContain(`"libraries"."${field}"`);
    expect(calls[0].text).toContain('order by "libraries"."display_order", "libraries"."name"');
  });
  it('selects visible ids with user grant scope and configured scan schedules', async () => {
    responses.push([[7]], [[7], [9]], [[7, '0 4 * * *']]);
    await expect(repo.findAccessibleIdsForUser(42)).resolves.toEqual([{ id: 7 }]);
    await expect(repo.findAllIds()).resolves.toEqual([{ id: 7 }, { id: 9 }]);
    await expect(repo.findAutoScanSchedules()).resolves.toEqual([{ id: 7, autoScanCronExpression: '0 4 * * *' }]);
    expect(calls[0].params).toEqual([42, 'books']);
    expect(calls[0].text).toContain('"user_library_access"."user_id" =');
    expect(calls[1].params).toEqual(['books']);
    expect(calls[2].text).toContain('"libraries"."auto_scan_cron_expression" is not null');
    expect(calls[2].text).toContain('order by "libraries"."id"');
  });
  it('looks up one visible library, returns missing rows, and skips empty id sets', async () => {
    await expect(repo.findByIds([])).resolves.toEqual([]);
    await expect(repo.findFoldersByLibraryIds([])).resolves.toEqual([]);
    expect(calls).toHaveLength(0);
    responses.push([tableRow(schema.libraries, { id: 7, name: 'Archive' })], [], [[7]]);
    await expect(repo.findById(7)).resolves.toEqual([expect.objectContaining({ id: 7, name: 'Archive' })]);
    await expect(repo.findById(999)).resolves.toEqual([]);
    await expect(repo.findByIds([7, 8])).resolves.toEqual([{ id: 7 }]);
    expect(calls.map(({ params }) => params)).toEqual([
      [7, 'books', 1],
      [999, 'books', 1],
      [7, 8, 'books'],
    ]);
  });
  it('checks case-insensitive names while excluding the library being renamed', async () => {
    responses.push([[7]], []);
    await expect(repo.findByName('ArChIvE')).resolves.toEqual([{ id: 7 }]);
    await expect(repo.findByName('ArChIvE', 7)).resolves.toEqual([]);
    expect(calls[0].text).toContain('lower("libraries"."name") =');
    expect(calls[0].params).toEqual(['archive', 1]);
    expect(calls[1].text).toContain('"libraries"."id" !=');
    expect(calls[1].params).toEqual(['archive', 7, 1]);
  });
  it('orders scoped and all folders deterministically and joins names for path listings', async () => {
    const folder = tableRow(schema.libraryFolders, { id: 13, libraryId: 7, path: '/archive' });
    responses.push([folder], [folder], [folder], [[7, '/archive', 'Archive']]);
    await expect(repo.findFoldersByLibrary(7)).resolves.toEqual([expect.objectContaining({ id: 13, libraryId: 7 })]);
    await repo.findAllFolders();
    await repo.findFoldersByLibraryIds([7, 8]);
    await expect(repo.findAllFolderPaths()).resolves.toEqual([{ libraryId: 7, path: '/archive', libraryName: 'Archive' }]);
    expect(calls[0].params).toEqual([7]);
    expect(calls[0].text).toContain('order by "library_folders"."created_at", "library_folders"."id"');
    for (const query of calls.slice(1, 3))
      expect(query.text).toContain('order by "library_folders"."library_id", "library_folders"."created_at", "library_folders"."id"');
    expect(calls[2].params).toEqual([7, 8]);
    expect(calls[3].text).toContain('inner join "libraries" on "libraries"."id" = "library_folders"."library_id"');
    expect(calls[3].text).toContain(
      'order by "libraries"."display_order", "libraries"."name", "library_folders"."created_at", "library_folders"."id"',
    );
  });
  it('returns inserts and scopes timestamped updates to the requested library', async () => {
    responses.push(
      [tableRow(schema.libraries, { id: 7, name: 'Archive' })],
      [tableRow(schema.libraryFolders, { id: 13, libraryId: 7, path: '/archive' })],
      [],
    );
    await expect(repo.insert({ name: 'Archive' })).resolves.toEqual([expect.objectContaining({ id: 7, name: 'Archive' })]);
    await expect(repo.insertFolders([{ libraryId: 7, path: '/archive' }])).resolves.toEqual([expect.objectContaining({ id: 13, libraryId: 7 })]);
    await expect(repo.update(999, { name: 'Renamed' })).resolves.toEqual([]);
    expect(calls[0].params).toContain('Archive');
    expect(calls[1].params).toEqual(expect.arrayContaining([7, '/archive']));
    expect(calls[2].text).toContain('set "name" =');
    expect(calls[2].text).toContain('"updated_at" =');
    expect(calls[2].text).toContain('where "libraries"."id" =');
    expect(calls[2].params.at(-1)).toBe(999);
  });
  it('inserts podcast settings idempotently and bounds podcast and cleanup job discovery', async () => {
    responses.push([], [[11]], [[31, { localPath: '/downloads/obsolete.mp3' }]]);
    await repo.insertPodcastSettings(7);
    await expect(repo.findPodcastIds(7, 10, 25)).resolves.toEqual([{ id: 11 }]);
    await expect(repo.findPodcastCleanupJobs(7, 30, 25)).resolves.toEqual([{ id: 31, payload: { localPath: '/downloads/obsolete.mp3' } }]);
    expect(calls[0].text).toContain('on conflict do nothing');
    expect(calls[0].params).toContain(7);
    expect(calls[1].params).toEqual([7, 10, 25]);
    expect(calls[2].params).toEqual([7, 'file_cleanup', 30, 25]);
    expect(calls[2].text).toContain("in ('queued', 'failed', 'cancelled')");
  });
  it('bounds owned podcast cleanup by episode cursor and excludes local-origin media', async () => {
    responses.push([[101, '/downloads/episode.mp3']]);
    await expect(repo.findPodcastMediaFiles(7, 100, 50)).resolves.toEqual([{ episodeId: 101, localPath: '/downloads/episode.mp3' }]);
    expect(calls[0].params).toEqual([7, 'feed', 100, 50]);
    expect(calls[0].text).toContain('"podcast_episode_media"."local_path" is not null');
    expect(calls[0].text).toContain('order by "podcast_episodes"."id" asc limit');
  });
  it('uses existence-sized media and blocking-job reads with correct storage ownership', async () => {
    responses.push([[11]], [], [[31]], []);
    await expect(repo.hasPodcastMediaFiles(7)).resolves.toBe(true);
    await expect(repo.hasPodcastMediaFiles(8)).resolves.toBe(false);
    await expect(repo.hasBlockingPodcastStorageJobs(7)).resolves.toBe(true);
    await expect(repo.hasBlockingPodcastStorageJobs(8)).resolves.toBe(false);
    for (const query of calls) expect(query.params.at(-1)).toBe(1);
    expect(calls[0].params).toEqual([7, 'feed', 1]);
    expect(calls[2].params).toEqual([7, 'download', 'retention', 'purge', 'merge', 'file_cleanup', 1]);
    expect(calls[2].text).toContain("= 'processing' or");
    expect(calls[2].text).toContain("in ('queued', 'failed', 'cancelled')");
  });
  it('cancels queued jobs and resets only cancelled download media still queued', async () => {
    responses.push(
      [
        ['cancelled', 'download', 101],
        ['processing', 'download', 102],
        ['cancelled', 'file_cleanup', 103],
        ['cancelled', 'download', null],
      ],
      [],
      [['processing', 'download', 104]],
    );
    await expect(repo.cancelPodcastJobs(7)).resolves.toBe(1);
    expect(calls[0].text).toContain('case when "podcast_jobs"."status" = \'queued\' then \'cancelled\'');
    expect(calls[0].text).toContain("in ('queued', 'processing')");
    expect(calls[0].params).toEqual(expect.arrayContaining([true, 7]));
    expect(calls[1].params).toEqual(expect.arrayContaining(['remote', 101, 'queued']));
    expect(calls[1].params).not.toContain(102);
    expect(calls[1].params).not.toContain(103);
    await expect(repo.cancelPodcastJobs(8)).resolves.toBe(1);
    expect(calls).toHaveLength(3);
  });
  it('scopes book-id lists and destructive library deletes', async () => {
    responses.push([[101], [102]]);
    await expect(repo.findBookIdsByLibrary(7)).resolves.toEqual([{ id: 101 }, { id: 102 }]);
    await repo.delete(7);
    expect(calls[0].params).toEqual([7]);
    expect(calls[1]).toEqual({ text: 'delete from "libraries" where "libraries"."id" = $1', params: [7] });
  });
  it('atomically invalidates library hashes when deleting one folder or all library roots', async () => {
    await repo.deleteFolder(13);
    await repo.deleteFoldersByLibrary(7);
    for (const query of calls) {
      expect(query.text).toContain('with deleted as');
      expect(query.text).toContain('delete from "library_folders"');
      expect(query.text).toContain('koreader_hash_revision = koreader_hash_revision + 1');
      expect(query.text).toContain('where id in (select library_id from deleted)');
    }
    expect(calls[0].text).toContain('"library_folders"."id" =');
    expect(calls[0].params).toEqual([13]);
    expect(calls[1].text).toContain('"library_folders"."library_id" =');
    expect(calls[1].params).toEqual([7]);
  });
  it('commits display orders together and rolls back when any write fails', async () => {
    await repo.updateDisplayOrders([
      { id: 7, displayOrder: 3 },
      { id: 8, displayOrder: 4 },
    ]);
    expect(calls.map(({ text }) => text)).toEqual([
      'begin',
      expect.stringContaining('update "libraries"'),
      expect.stringContaining('update "libraries"'),
      'commit',
    ]);
    expect(calls[1].params[0]).toBe(3);
    expect(calls[1].params.at(-1)).toBe(7);
    expect(calls[2].params[0]).toBe(4);
    expect(calls[2].params.at(-1)).toBe(8);
    calls.length = 0;
    responses.push([], new Error('constraint rejected order'));
    await expect(
      repo.updateDisplayOrders([
        { id: 7, displayOrder: 3 },
        { id: 8, displayOrder: 4 },
      ]),
    ).rejects.toThrow();
    expect(calls.at(-1)?.text).toBe('rollback');
    expect(calls.map(({ text }) => text)).not.toContain('commit');
  });
  it('aggregates present books and primary file formats and sizes in separate queries', async () => {
    responses.push(
      [[3]],
      [
        ['epub', 2, '3000'],
        ['pdf', 1, 700n],
      ],
      [],
      [[null, 1, 200]],
    );
    await expect(repo.getStats(7)).resolves.toEqual({ totalBooks: 3, totalSizeBytes: 3700, formatCounts: { epub: 2, pdf: 1 } });
    await expect(repo.getStats(8)).resolves.toEqual({ totalBooks: 0, totalSizeBytes: 200, formatCounts: {} });
    expect(calls[0].params).toEqual([7, 'present']);
    expect(calls[1].params).toEqual([7, 'present']);
    expect(calls[0].text).not.toContain('join');
    expect(calls[1].text).toContain('inner join "book_files" on "book_files"."id" = "books"."primary_file_id"');
    expect(calls[1].text).toContain('group by "book_files"."format"');
  });
  it('rejects unsafe and unsupported sizes instead of rounding aggregate data', async () => {
    responses.push([[1]], [['epub', 1, '9007199254740992']], [[1]], [['epub', 1, null]]);
    await expect(repo.getStats(7)).rejects.toThrow('totalSizeBytes exceeds Number.MAX_SAFE_INTEGER');
    await expect(repo.getStats(7)).rejects.toThrow('Unsupported bigint value: null');
  });
  it('aggregates a library set in two queries with defaults for empty libraries', async () => {
    responses.push(
      [
        [7, 3],
        [8, 1],
      ],
      [
        [7, 'epub', 2, '3000'],
        [7, 'pdf', 1, '700'],
        [8, 'cbz', 1, '500'],
        [8, null, 1, '200'],
      ],
    );
    await expect(repo.getStatsForLibraries([7, 8, 9])).resolves.toEqual(
      new Map([
        [7, { totalBooks: 3, totalSizeBytes: 3700, formatCounts: { epub: 2, pdf: 1 } }],
        [8, { totalBooks: 1, totalSizeBytes: 700, formatCounts: { cbz: 1 } }],
        [9, { totalBooks: 0, totalSizeBytes: 0, formatCounts: {} }],
      ]),
    );
    expect(calls).toHaveLength(2);
    for (const query of calls) expect(query.params).toEqual([7, 8, 9, 'present']);
    calls.length = 0;
    await expect(repo.getStatsForLibraries([])).resolves.toEqual(new Map());
    expect(calls).toHaveLength(0);
  });
  it('answers user access in one library-scoped join including superusers without grants', async () => {
    responses.push([[42], [43]]);
    await expect(repo.findUserIdsWithAccess(7, [42, 43, 44])).resolves.toEqual([{ id: 42 }, { id: 43 }]);
    expect(calls[0].text).toContain('left join "user_library_access" on');
    expect(calls[0].text).toContain('"user_library_access"."library_id" =');
    expect(calls[0].text).toContain('"users"."is_superuser" =');
    expect(calls[0].text).toContain('"user_library_access"."user_id" is not null');
    expect(calls[0].params).toEqual([7, 42, 43, 44, true]);
  });
  it('returns added-at snapshot bounds and defaults a missing aggregate row', async () => {
    responses.push([[6, 106]], []);
    await expect(repo.getAddedAtRecomputeBounds(7)).resolves.toEqual({ total: 6, maxId: 106 });
    await expect(repo.getAddedAtRecomputeBounds(8)).resolves.toEqual({ total: 0, maxId: 0 });
    expect(calls[0].params).toEqual([7]);
    expect(calls[0].text).toContain('coalesce(max("id"), 0)::int');
  });
  it('bounds added-at book and file pages and maps timestamp and root fields', async () => {
    responses.push([[101, '2026-01-01T00:00:00Z', '2026-01-01 00:00:00+00']], [[301, 101, '/archive/book.epub', '2026-01-01T00:00:00Z', '/archive']]);
    await expect(repo.findAddedAtBookBatch(7, 100, 500, 50)).resolves.toEqual([
      { id: 101, addedAt: new Date('2026-01-01T00:00:00Z'), previousAddedAt: '2026-01-01 00:00:00+00' },
    ]);
    await expect(repo.findAddedAtFileBatch(7, [101], 300, 25)).resolves.toEqual([
      { id: 301, bookId: 101, absolutePath: '/archive/book.epub', mtime: new Date('2026-01-01T00:00:00Z'), rootPath: '/archive' },
    ]);
    expect(calls[0].params).toEqual([7, 100, 500, 50]);
    expect(calls[0].text).toContain('"books"."id" >');
    expect(calls[0].text).toContain('"books"."id" <=');
    expect(calls[0].text).toContain('order by "books"."id" limit');
    expect(calls[1].params).toEqual([7, 101, 'content', 300, 25]);
    expect(calls[1].text).toContain('inner join "library_folders" on "library_folders"."id" = "books"."library_folder_id"');
    expect(calls[1].text).toContain('order by "book_files"."id" limit');
  });
  it('selects valid minimum content mtimes within the library and book set', async () => {
    responses.push([[101, '2026-01-01T00:00:00Z']]);
    await expect(repo.findAddedAtMtimes(7, [101, 102])).resolves.toEqual([{ bookId: 101, mtime: new Date('2026-01-01T00:00:00Z') }]);
    expect(calls[0].params).toEqual([7, 101, 102, 'content', new Date(MIN_VALID_FILE_TIME_MS).toISOString()]);
    expect(calls[0].text).toContain('min("book_files"."mtime")');
    expect(calls[0].text).toContain('group by "book_files"."book_id"');
  });
  it('updates added-at batches with scope and optimistic previous-value checks and skips empty batches', async () => {
    await expect(repo.updateAddedAtBatch(7, [])).resolves.toEqual([]);
    expect(calls).toHaveLength(0);
    responses.push([[101]]);
    const addedAt = new Date('2026-01-01T00:00:00Z');
    await expect(
      repo.updateAddedAtBatch(7, [
        { id: 101, addedAt, previousAddedAt: '2025-01-01 00:00:00+00' },
        { id: 102, addedAt, previousAddedAt: '2024-01-01 00:00:00+00' },
      ]),
    ).resolves.toEqual([101]);
    expect(calls[0].text).toContain('from (values');
    expect(calls[0].text).toContain('"books"."library_id" =');
    expect(calls[0].text).toContain('"books"."id" = dates.id');
    expect(calls[0].text).toContain('"books"."added_at" = dates.previous_added_at');
    expect(calls[0].params.slice(1)).toEqual([
      101,
      addedAt.toISOString(),
      '2025-01-01 00:00:00+00',
      102,
      addedAt.toISOString(),
      '2024-01-01 00:00:00+00',
      7,
    ]);
  });
  it('checks exact user and library keys and returns existing access levels or null', async () => {
    responses.push([[42, 7, 'owner']], [], [['editor']], []);
    await expect(repo.hasUserAccess(42, 7)).resolves.toBe(true);
    await expect(repo.hasUserAccess(43, 7)).resolves.toBe(false);
    await expect(repo.findUserAccessLevel(42, 7)).resolves.toBe('editor');
    await expect(repo.findUserAccessLevel(42, 8)).resolves.toBeNull();
    expect(calls.map(({ params }) => params)).toEqual([
      [42, 7, 1],
      [43, 7, 1],
      [42, 7, 1],
      [42, 8, 1],
    ]);
    for (const query of calls) {
      expect(query.text).toContain('"userLibraryAccess"."user_id" =');
      expect(query.text).toContain('"userLibraryAccess"."library_id" =');
    }
  });
  it('lists one library grants with their access levels', async () => {
    responses.push([
      [42, 7, 'viewer'],
      [43, 7, 'owner'],
    ]);
    await expect(repo.getAccess(7)).resolves.toEqual([
      { userId: 42, libraryId: 7, accessLevel: 'viewer' },
      { userId: 43, libraryId: 7, accessLevel: 'owner' },
    ]);
    expect(calls[0].params).toEqual([7]);
    expect(calls[0].text).toContain('"userLibraryAccess"."library_id" =');
  });
  it('upserts grants on the composite key and restricts changes and revocation to both keys', async () => {
    await repo.grantAccess(7, 42, 'owner');
    await repo.updateAccess(7, 42, 'editor');
    await repo.revokeAccess(7, 42);
    expect(calls[0].text).toContain('on conflict ("library_id","user_id") do update set "access_level" =');
    expect(calls[0].params).toEqual([42, 7, 'owner', 'owner']);
    expect(calls[1].params).toEqual(['editor', 7, 42]);
    expect(calls[2].params).toEqual([7, 42]);
    for (const query of calls.slice(1)) {
      expect(query.text).toContain('"user_library_access"."library_id" =');
      expect(query.text).toContain('"user_library_access"."user_id" =');
    }
  });
  it('lists active ungranted users and joins grant identities within the requested library', async () => {
    responses.push([[44, 'new-reader', 'New Reader']], [[42, 'owner', 'reader', 'Reader']]);
    await expect(repo.getUsersNotInLibrary(7)).resolves.toEqual([{ id: 44, username: 'new-reader', name: 'New Reader' }]);
    await expect(repo.getAccessWithUsers(7)).resolves.toEqual([{ userId: 42, accessLevel: 'owner', username: 'reader', name: 'Reader' }]);
    expect(calls[0].text).toContain('"users"."id" not in (');
    expect(calls[0].text).toContain('"users"."active" =');
    expect(calls[0].params).toEqual([true, 7]);
    expect(calls[1].text).toContain('inner join "users" on "users"."id" = "user_library_access"."user_id"');
    expect(calls[1].params).toEqual([7]);
  });
});
