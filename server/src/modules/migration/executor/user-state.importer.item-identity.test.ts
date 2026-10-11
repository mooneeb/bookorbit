import { Test } from '@nestjs/testing';

import type { SourceAnnotation, SourceBookmark } from '../adapters/source-adapter.types';
import { MigrationRepository } from '../migration.repository';
import type { PlannerResult } from '../planner/planner.types';
import { ReadingAttemptEventsService } from '../../user-book-status/reading-attempt-events.service';
import { MigrationImportRepository } from './migration-import.repository';
import { UserStateImporter } from './user-state.importer';

const bookmark: SourceBookmark = {
  sourceUserId: 'reader',
  sourceBookId: 'book',
  title: 'Bookmark',
  cfi: null,
  positionSeconds: 15,
  createdAt: null,
};

const annotation: SourceAnnotation = {
  sourceUserId: 'reader',
  sourceBookId: 'book',
  cfi: 'epubcfi(/6/2)',
  text: 'A passage',
  note: 'First note',
  color: null,
  style: null,
  chapterTitle: null,
  createdAt: null,
  updatedAt: null,
};

async function makeImporter(bookmarks: SourceBookmark[], annotations: SourceAnnotation[]) {
  const savedBookmarks = new Map<string, { clientId: string }>();
  const savedAnnotations = new Map<string, { clientId: string }>();
  const importRepo = {
    fetchTargetBookPrimaryFiles: vi.fn().mockResolvedValue({ primaryFilesByBookId: new Map() }),
    fetchTargetBookFiles: vi.fn().mockResolvedValue(new Map()),
    withTransaction: vi.fn().mockImplementation(async (handler: (repo: typeof importRepo) => Promise<void>) => handler(importRepo)),
    batchInsertBookmarks: vi.fn().mockImplementation((rows: Array<{ clientId: string }>) => {
      for (const row of rows) if (!savedBookmarks.has(row.clientId)) savedBookmarks.set(row.clientId, row);
      return Promise.resolve();
    }),
    batchInsertAnnotations: vi.fn().mockImplementation((rows: Array<{ clientId: string }>) => {
      for (const row of rows) if (!savedAnnotations.has(row.clientId)) savedAnnotations.set(row.clientId, row);
      return Promise.resolve();
    }),
  };
  const module = await Test.createTestingModule({
    providers: [
      UserStateImporter,
      { provide: MigrationRepository, useValue: { setRunMetric: vi.fn().mockResolvedValue(undefined) } },
      { provide: MigrationImportRepository, useValue: importRepo },
      { provide: ReadingAttemptEventsService, useValue: {} },
    ],
  }).compile();
  const planned = {
    plan: {
      itemIdentityVersion: 2,
      snapshot: { sourceType: 'booklore' },
      userMappings: [{ sourceUserId: 'reader', targetUserId: 10 }],
      pathMappings: [],
    },
    execution: {
      matchedBooks: [{ sourceBookId: 'book', targetBookId: 200 }],
      sourceData: {
        books: [],
        bookmarks,
        annotations,
        availableDomains: {
          userBookStatuses: false,
          readingProgress: false,
          readingSessions: false,
          bookmarks: true,
          annotations: true,
          shelves: false,
        },
      },
    },
  } as unknown as PlannerResult;
  const importer = module.get(UserStateImporter);
  return { planned, savedBookmarks, savedAnnotations, importRepo, run: () => importer.import(1, planned, () => Promise.resolve()) };
}

describe('migration item identity', () => {
  it('retries preexisting legacy artifact IDs without inserting additional rows', async () => {
    const { run, planned, savedBookmarks, savedAnnotations, importRepo } = await makeImporter([bookmark], [annotation]);
    delete planned.plan.itemIdentityVersion;
    const legacyBookmarkId = 'c67b8f63-5651-5d7c-a7c0-0b1fd647f002';
    const legacyAnnotationId = 'c1cd9adf-3011-5786-a375-0add0bbd37df';
    savedBookmarks.set(legacyBookmarkId, { clientId: legacyBookmarkId });
    savedAnnotations.set(legacyAnnotationId, { clientId: legacyAnnotationId });

    await run();

    expect([...savedBookmarks.keys()]).toEqual([legacyBookmarkId]);
    expect([...savedAnnotations.keys()]).toEqual([legacyAnnotationId]);
    expect(importRepo.batchInsertBookmarks).toHaveBeenCalledWith([expect.objectContaining({ clientId: legacyBookmarkId })]);
    expect(importRepo.batchInsertAnnotations).toHaveBeenCalledWith([expect.objectContaining({ clientId: legacyAnnotationId })]);
  });

  it('preserves bookmarks on different audio tracks at the same offset without timestamps', async () => {
    const { run, savedBookmarks } = await makeImporter(
      [
        { ...bookmark, sourceFileId: 'track-one', trackIndex: 0 },
        { ...bookmark, sourceFileId: 'track-two', trackIndex: 1 },
      ],
      [],
    );

    await run();

    expect(savedBookmarks.size).toBe(2);
  });

  it('preserves distinct passage notes with the same CFI and no timestamps', async () => {
    const { run, savedAnnotations } = await makeImporter([], [annotation, { ...annotation, note: 'Second note' }]);

    await run();

    expect(savedAnnotations.size).toBe(2);
  });

  it('replays a batch with the same IDs without inserting extra rows', async () => {
    const { run, planned, savedBookmarks, savedAnnotations, importRepo } = await makeImporter(
      [{ ...bookmark, sourceItemId: 'bookmark-one' }, { ...bookmark, sourceItemId: 'bookmark-two' }, bookmark],
      [{ ...annotation, sourceItemId: 'note-one' }, { ...annotation, sourceItemId: 'note-two' }, annotation],
    );

    await run();
    const bookmarkIds = [...savedBookmarks.keys()];
    const annotationIds = [...savedAnnotations.keys()];
    planned.execution.sourceData.bookmarks.reverse();
    planned.execution.sourceData.annotations.reverse();
    planned.execution.sourceData.bookmarks.find((row) => row.sourceItemId === 'bookmark-one')!.title = 'Renamed bookmark';
    planned.execution.sourceData.annotations.find((row) => row.sourceItemId === 'note-one')!.note = 'Edited note';

    await run();

    expect(savedBookmarks.size).toBe(3);
    expect(savedAnnotations.size).toBe(3);
    expect(importRepo.batchInsertBookmarks.mock.calls[1][0].map((row: { clientId: string }) => row.clientId)).toEqual(bookmarkIds.toReversed());
    expect(importRepo.batchInsertAnnotations.mock.calls[1][0].map((row: { clientId: string }) => row.clientId)).toEqual(annotationIds.toReversed());
  });
});
