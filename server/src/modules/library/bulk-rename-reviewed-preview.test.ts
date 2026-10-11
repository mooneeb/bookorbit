import { ConflictException } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { BulkRenameService } from './bulk-rename.service';
import { BulkRenameRepository, type BulkRenameBookData } from '../file-write/bulk-rename.repository';
import { FileRenameRepository } from '../file-write/file-rename.repository';
import { FileRenameService } from '../file-write/file-rename.service';
import { AppSettingsService } from '../app-settings/app-settings.service';
import { NotificationService } from '../notification/notification.service';
import { FileWatcherService } from '../scanner/file-watcher.service';

function book(bookId: number): BulkRenameBookData {
  const absolutePath = `/library/old/${bookId}.epub`;
  return {
    bookId,
    title: `Book ${bookId}`,
    primaryFileId: bookId,
    absolutePath,
    relPath: `old/${bookId}.epub`,
    format: 'epub',
    libraryFolderPath: '/library',
    libraryName: 'Library',
    organizationMode: 'book_per_file',
    fileNamingPattern: '{title}',
    bookFolderPath: absolutePath,
    metadata: {
      title: `Book ${bookId}`,
      subtitle: null,
      publisher: null,
      language: null,
      isbn10: null,
      isbn13: null,
      publishedYear: null,
      seriesName: null,
      seriesIndex: null,
    },
    authors: [],
    narrators: [],
    files: [{ id: bookId, absolutePath, format: 'epub', role: 'content', sortOrder: null }],
  };
}

describe('reviewed bulk rename preview', () => {
  let service: BulkRenameService;
  let books: BulkRenameBookData[];
  let settings: { fileRenameEnabled: boolean; fileNamingPattern: string; organizationMode: string; watch: boolean };
  const performRename = vi.fn();
  const onProgress = vi.fn();

  beforeEach(async () => {
    vi.resetAllMocks();
    books = [book(1), book(2)];
    settings = { fileRenameEnabled: true, fileNamingPattern: '{title}', organizationMode: 'book_per_file', watch: false };
    performRename.mockResolvedValue({ status: 'success' });
    const module = await Test.createTestingModule({
      providers: [
        BulkRenameService,
        {
          provide: BulkRenameRepository,
          useValue: {
            findLibrarySettings: vi.fn(() => Promise.resolve(settings)),
            findLastBookId: vi.fn().mockResolvedValue(2),
            findBooksPageForLibrary: vi.fn((_libraryId, afterBookId) => Promise.resolve(books.filter((item) => item.bookId > afterBookId))),
            findBooksForLibraryIds: vi.fn((_libraryId, ids: number[]) => Promise.resolve(books.filter((item) => ids.includes(item.bookId)))),
          },
        },
        {
          provide: FileRenameRepository,
          useValue: { findExistingPaths: vi.fn().mockResolvedValue(new Map()), findFolderOwners: vi.fn().mockResolvedValue(new Map()) },
        },
        { provide: FileRenameService, useValue: { performRename } },
        { provide: AppSettingsService, useValue: { isCrossPlatformPathSanitizationEnabled: vi.fn().mockResolvedValue(false) } },
        { provide: NotificationService, useValue: { notify: vi.fn().mockResolvedValue(undefined) } },
        { provide: FileWatcherService, useValue: {} },
      ],
    }).compile();
    service = module.get(BulkRenameService);
  });

  afterEach(async () => service.onModuleDestroy());

  it('returns 409 before starting when a selected title changed after Preview', async () => {
    const preview = await service.getPreview(1, 1, 40);
    books[0].metadata.title = 'Unreviewed title';
    await expect(
      service.execute(1, 42, { previewToken: preview.previewToken, includeBookIds: [1], onProgress, isCancelled: () => false }),
    ).rejects.toBeInstanceOf(ConflictException);
    expect(performRename).not.toHaveBeenCalled();
    expect(onProgress).not.toHaveBeenCalled();
  });

  it('returns 409 before starting when the naming pattern changed after Preview', async () => {
    const preview = await service.getPreview(1, 1, 40);
    settings.fileNamingPattern = '{authors}/{title}';
    await expect(
      service.execute(1, 42, { previewToken: preview.previewToken, includeBookIds: [1], onProgress, isCancelled: () => false }),
    ).rejects.toBeInstanceOf(ConflictException);
    expect(performRename).not.toHaveBeenCalled();
    expect(onProgress).not.toHaveBeenCalled();
  });

  it('applies only selected unchanged reviewed targets', async () => {
    const preview = await service.getPreview(1, 1, 40);
    books[1].metadata.title = 'Unselected title changed';
    const result = await service.execute(1, 42, { previewToken: preview.previewToken, includeBookIds: [1], onProgress, isCancelled: () => false });
    expect(result.succeeded).toBe(1);
    expect(performRename).toHaveBeenCalledExactlyOnceWith(
      1,
      42,
      false,
      true,
      expect.objectContaining({
        currentPath: preview.items[0].currentPath,
        targetPath: preview.items[0].newPath,
        inputVersion: expect.any(String),
        preserveBook: true,
      }),
    );
    expect(onProgress).toHaveBeenCalledWith({ started: true, total: 1 });
  });
});
