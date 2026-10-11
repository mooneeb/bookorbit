import { BadRequestException, ConflictException, Injectable, Logger, NotFoundException, OnModuleDestroy } from '@nestjs/common';
import { dirname } from 'path';
import { BulkRenamePreviewStore } from './bulk-rename-preview-store';

import type { BulkRenamePreviewItem, BulkRenamePreviewPage, BulkRenameProgressEvent, BulkRenameStatus } from '@bookorbit/types';
import { NotificationType } from '@bookorbit/types';
import { sanitizeLogValue } from '../../common/utils/log-sanitize.utils';
import { AppSettingsService } from '../app-settings/app-settings.service';
import { NotificationService } from '../notification/notification.service';
import { FileRenameService } from '../file-write/file-rename.service';
import { FileRenameRepository } from '../file-write/file-rename.repository';
import { FileWatcherService } from '../scanner/file-watcher.service';
import type { BulkRenameBookData } from '../file-write/bulk-rename.repository';
import { BulkRenameRepository } from '../file-write/bulk-rename.repository';
import { bookRenameInputVersion, findSiblingOccupiedTarget, resolveBookFileTargets } from '../file-write/book-file-targets';

const CACHE_TTL_MS = 60_000;

interface BulkRenameStreamOptions {
  previewToken: string;
  onProgress: (event: BulkRenameProgressEvent) => void;
  isCancelled: () => boolean;
  /** Books the reviewer skipped. Ids outside the candidate set are simply not present. */
  excludeBookIds?: number[];
  /** Books the reviewer picked, when the selection started empty. Mutually exclusive with the above. */
  includeBookIds?: number[];
}

interface BulkRenameSummary {
  processed: number;
  succeeded: number;
  failed: number;
  skipped: number;
  cancelled: boolean;
}

@Injectable()
export class BulkRenameService implements OnModuleDestroy {
  private readonly logger = new Logger(BulkRenameService.name);
  private readonly previewCache = new Map<number, BulkRenamePreviewStore>();
  private readonly previewBuilds = new Map<number, Promise<BulkRenamePreviewStore>>();
  private readonly cleanupTimer = setInterval(() => this.removeExpiredPreviews(), CACHE_TTL_MS).unref();
  private readonly runningLibraries = new Set<number>();

  constructor(
    private readonly bulkRenameRepo: BulkRenameRepository,
    private readonly fileRenameRepo: FileRenameRepository,
    private readonly fileRenameService: FileRenameService,
    private readonly appSettings: AppSettingsService,
    private readonly notificationService: NotificationService,
    private readonly fileWatcherService: FileWatcherService,
  ) {}

  async getPreview(
    libraryId: number,
    page: number,
    pageSize: number,
    statusFilter?: BulkRenameStatus,
    search?: string,
  ): Promise<BulkRenamePreviewPage> {
    if (!Number.isInteger(page) || page < 1 || !Number.isInteger(pageSize) || pageSize < 1 || pageSize > 200) {
      throw new BadRequestException('Preview page size must be between 1 and 200.');
    }
    this.removeExpiredPreviews();
    let preview = this.previewCache.get(libraryId);
    if (!preview) {
      let pending = this.previewBuilds.get(libraryId);
      if (!pending) {
        pending = this.computeFullPreview(libraryId);
        this.previewBuilds.set(libraryId, pending);
      }
      try {
        preview = await pending;
        this.previewCache.set(libraryId, preview);
      } finally {
        this.previewBuilds.delete(libraryId);
      }
    }
    const result = preview.getPage(page, pageSize, statusFilter, search);
    while (this.previewCache.size > 4) this.invalidateCache(this.previewCache.keys().next().value!);
    return result;
  }

  private removeExpiredPreviews(): void {
    for (const [libraryId, preview] of this.previewCache) {
      if (Date.now() - preview.createdAt >= CACHE_TTL_MS) this.invalidateCache(libraryId);
    }
  }

  async onModuleDestroy(): Promise<void> {
    clearInterval(this.cleanupTimer);
    const previews = new Set([...this.previewCache.values(), ...(await Promise.all(this.previewBuilds.values()))]);
    this.previewCache.clear();
    await Promise.all([...previews].map((preview) => preview.close()));
  }

  async execute(libraryId: number, userId: number, options: BulkRenameStreamOptions): Promise<BulkRenameSummary> {
    const event = 'library.bulk_rename';
    const startedAt = Date.now();

    if (this.runningLibraries.has(libraryId)) {
      throw new BadRequestException('A bulk rename is already running for this library.');
    }

    this.runningLibraries.add(libraryId);
    let settings: NonNullable<Awaited<ReturnType<BulkRenameRepository['findLibrarySettings']>>>;
    try {
      const found = await this.bulkRenameRepo.findLibrarySettings(libraryId);
      if (!found) throw new NotFoundException('Library not found');
      if (!found.fileRenameEnabled) throw new BadRequestException('File rename is not enabled for this library.');
      settings = found;
    } catch (error) {
      this.runningLibraries.delete(libraryId);
      throw error;
    }

    let preview: BulkRenamePreviewStore | undefined;
    const included = options.includeBookIds ? new Set(options.includeBookIds) : undefined;
    const excluded = new Set(options.excludeBookIds ?? []);
    const isSelected = (bookId: number) => (included ? included.has(bookId) : !excluded.has(bookId));
    let candidateCount = 0;
    let selectedCount = 0;
    try {
      this.removeExpiredPreviews();
      const cached = this.previewCache.get(libraryId);
      if (!cached || cached.token !== options.previewToken) {
        throw new ConflictException('Rename preview expired or changed. Review the preview again.');
      }
      preview = cached;
      this.previewCache.delete(libraryId);
      const pattern =
        settings.fileNamingPattern ??
        (settings.organizationMode === 'book_per_folder'
          ? await this.appSettings.getUploadPatternBookPerFolder()
          : await this.appSettings.getUploadPattern());
      const sanitizeForCrossPlatform = await this.appSettings.isCrossPlatformPathSanitizationEnabled();
      if (
        preview.settingsVersion !== JSON.stringify([settings.fileNamingPattern, pattern ?? '', settings.organizationMode, sanitizeForCrossPlatform])
      ) {
        throw new ConflictException('Rename settings changed. Review the preview again.');
      }
      let afterBookId = 0;
      while (true) {
        const batch = preview.candidateBatch(afterBookId, 250);
        if (!batch.length) break;
        candidateCount += batch.length;
        const selected = batch.filter((item) => isSelected(item.bookId));
        const books = await this.bulkRenameRepo.findBooksForLibraryIds(
          libraryId,
          selected.map((item) => item.bookId),
        );
        const versions = new Map(
          books.map((book) => [book.bookId, bookRenameInputVersion({ ...book, pattern: pattern ?? '', sanitizeForCrossPlatform })]),
        );
        if (selected.some((item) => versions.get(item.bookId) !== item.inputVersion)) {
          throw new ConflictException('Books changed after the rename preview. Review the preview again.');
        }
        selectedCount += selected.length;
        afterBookId = batch[batch.length - 1].bookId;
      }
      this.logger.log(
        `[${event}] [start] libraryId=${libraryId} userId=${userId} candidateCount=${candidateCount} excludedCount=${candidateCount - selectedCount} - bulk rename started`,
      );
      options.onProgress({ started: true, total: selectedCount });
    } catch (err) {
      await preview?.close();
      this.runningLibraries.delete(libraryId);
      throw err;
    }

    let watcherWasPaused = false;
    let succeeded = 0;
    let failed = 0;
    let skipped = 0;

    try {
      if (settings.watch) {
        watcherWasPaused = this.fileWatcherService.pauseWatcher(libraryId);
      }

      let afterBookId = 0;
      while (!options.isCancelled()) {
        const batch = preview.candidateBatch(afterBookId, 250);
        if (!batch.length) break;
        for (const item of batch) {
          if (options.isCancelled()) break;
          afterBookId = item.bookId;
          if (!isSelected(item.bookId)) continue;
          try {
            const result = await this.fileRenameService.performRename(item.bookId, userId, false, true, {
              libraryId,
              currentPath: item.currentPath,
              targetPath: item.newPath!,
              preserveBook: true,
              inputVersion: item.inputVersion,
            });
            if (result.status === 'success') succeeded++;
            else if (result.status === 'failed') failed++;
            else skipped++;
            options.onProgress({ bookId: item.bookId, status: result.status, reason: result.reason });
          } catch (err) {
            failed++;
            options.onProgress({ bookId: item.bookId, status: 'failed', reason: getErrorMessage(err) });
          }
        }
      }

      const cancelled = options.isCancelled();
      const durationMs = Date.now() - startedAt;
      this.logger.log(
        `[${event}] [end] libraryId=${libraryId} userId=${userId} durationMs=${durationMs} succeeded=${succeeded} failed=${failed} skipped=${skipped} cancelled=${cancelled} - bulk rename completed`,
      );

      await this.notifyCompletion(userId, libraryId, succeeded, failed);

      return { processed: succeeded + failed + skipped, succeeded, failed, skipped, cancelled };
    } catch (err) {
      const durationMs = Date.now() - startedAt;
      const errorClass = err instanceof Error ? err.name : 'Error';
      const errorMessage = sanitizeLogValue(getErrorMessage(err));
      this.logger.error(
        `[${event}] [fail] libraryId=${libraryId} userId=${userId} durationMs=${durationMs} errorClass=${errorClass} error="${errorMessage}" - bulk rename failed`,
      );

      await this.notifyFailure(userId, libraryId, getErrorMessage(err));
      throw err;
    } finally {
      // Resuming re-arms the existing watcher, so it costs nothing and cannot hold back the
      // completion event. Anything the watcher saw during the run is intentionally discarded:
      // every change was ours, and the database already records it.
      if (watcherWasPaused) this.fileWatcherService.resumeWatcher(libraryId);
      this.runningLibraries.delete(libraryId);
      await preview.close();
      this.invalidateCache(libraryId);
    }
  }

  isRunning(libraryId: number): boolean {
    return this.runningLibraries.has(libraryId);
  }

  invalidateCache(libraryId: number): void {
    const preview = this.previewCache.get(libraryId);
    this.previewCache.delete(libraryId);
    if (preview) void preview.close().catch(() => {});
  }

  private async computeFullPreview(libraryId: number): Promise<BulkRenamePreviewStore> {
    const event = 'library.bulk_rename_preview';
    const startedAt = Date.now();
    const settings = await this.bulkRenameRepo.findLibrarySettings(libraryId);
    if (!settings) throw new NotFoundException('Library not found');
    const pattern =
      settings.fileNamingPattern ??
      (settings.organizationMode === 'book_per_folder'
        ? await this.appSettings.getUploadPatternBookPerFolder()
        : await this.appSettings.getUploadPattern());
    const sanitizeForCrossPlatform = await this.appSettings.isCrossPlatformPathSanitizationEnabled();
    const preview = await BulkRenamePreviewStore.create(
      pattern ?? '',
      JSON.stringify([settings.fileNamingPattern, pattern ?? '', settings.organizationMode, sanitizeForCrossPlatform]),
    );
    const upToBookId = await this.bulkRenameRepo.findLastBookId(libraryId);
    let afterBookId = 0;
    let bookCount = 0;
    this.logger.log(`[${event}] [start] libraryId=${libraryId} - bulk rename preview started`);
    try {
      while (true) {
        const books = await this.bulkRenameRepo.findBooksPageForLibrary(libraryId, afterBookId, upToBookId, 250);
        if (!books.length) break;
        const items = books.map((book) => {
          const item = this.computePreviewItem(book, pattern, sanitizeForCrossPlatform);
          const targetFolder =
            settings.organizationMode === 'book_per_folder' && item.newPath && dirname(item.newPath) !== book.bookFolderPath
              ? dirname(item.newPath)
              : null;
          return { ...item, targetFolder, inputVersion: bookRenameInputVersion({ ...book, pattern: pattern ?? '', sanitizeForCrossPlatform }) };
        });
        const targets = books.flatMap((book) => {
          if (!pattern) return [];
          const item = items.find((item) => item.bookId === book.bookId)!;
          if (!item.newPath) return [];
          return [...resolveBookFileTargets({ ...book, pattern, sanitizeForCrossPlatform }).values()].map((path) => ({ path, bookId: book.bookId }));
        });
        preview.addBatch(items, targets);
        for (let index = 0; index < targets.length; index += 250) {
          const batch = targets.slice(index, index + 250);
          const owners = await this.fileRenameRepo.findExistingPaths(batch.map((target) => target.path));
          for (const target of batch) {
            const owner = owners.get(target.path);
            if (owner !== undefined && owner !== target.bookId) preview.markCollision(target.bookId, 'Path already taken by another book');
          }
        }
        const folderItems = items.filter((item) => item.status === 'will_rename' && item.targetFolder);
        if (folderItems.length) {
          const owners = await this.fileRenameRepo.findFolderOwners(
            libraryId,
            folderItems.map((item) => item.targetFolder!),
          );
          for (const item of folderItems) {
            const owner = owners.get(item.targetFolder!);
            if (owner && owner.bookId !== item.bookId) preview.markCollision(item.bookId, 'Target folder belongs to another book');
          }
        }
        bookCount += books.length;
        afterBookId = books[books.length - 1].bookId;
      }
      preview.markSharedTargets(settings.organizationMode === 'book_per_folder');
      this.logger.log(
        `[${event}] [end] libraryId=${libraryId} durationMs=${Date.now() - startedAt} bookCount=${bookCount} - bulk rename preview completed`,
      );
      return preview;
    } catch (error) {
      await preview.close();
      this.logger.error(
        `[${event}] [fail] libraryId=${libraryId} durationMs=${Date.now() - startedAt} errorClass=${error instanceof Error ? error.name : 'Error'} error="${sanitizeLogValue(getErrorMessage(error))}" - bulk rename preview failed`,
      );
      throw error;
    }
  }

  private computePreviewItem(book: BulkRenameBookData, pattern: string | null, sanitizeForCrossPlatform: boolean): BulkRenamePreviewItem {
    const baseItem: BulkRenamePreviewItem = {
      bookId: book.bookId,
      title: book.title ?? 'Untitled',
      currentPath: book.absolutePath,
      newPath: null,
      status: 'unchanged',
    };

    if (!pattern) {
      return { ...baseItem, status: 'no_pattern', reason: 'No naming pattern configured' };
    }

    try {
      // Fall back to the primary file alone when a book somehow has no file rows, so the preview
      // still resolves rather than silently reporting every book as unchanged.
      const files =
        book.files.length > 0
          ? book.files
          : [{ id: book.primaryFileId, absolutePath: book.absolutePath, format: book.format, role: 'content', sortOrder: null }];

      const targets = resolveBookFileTargets({
        primaryFileId: book.primaryFileId,
        files,
        metadata: book.metadata,
        authors: book.authors,
        narrators: book.narrators,
        libraryName: book.libraryName,
        libraryFolderPath: book.libraryFolderPath,
        bookFolderPath: book.bookFolderPath,
        organizationMode: book.organizationMode,
        pattern,
        sanitizeForCrossPlatform,
      });

      const targetPath = targets.get(book.primaryFileId) ?? null;

      if (!targetPath) {
        return { ...baseItem, status: 'no_pattern', reason: 'Pattern resolved to empty' };
      }

      if (targetPath === book.absolutePath && files.every((file) => targets.get(file.id) === file.absolutePath)) {
        return { ...baseItem, newPath: targetPath, status: 'unchanged' };
      }

      const occupied = findSiblingOccupiedTarget(files, targets);
      if (occupied) {
        return {
          ...baseItem,
          newPath: targetPath,
          status: 'collision',
          reason: 'Renaming would overwrite another file in this book',
        };
      }

      return { ...baseItem, newPath: targetPath, status: 'will_rename' };
    } catch (err) {
      return { ...baseItem, status: 'error', reason: getErrorMessage(err) };
    }
  }

  private async notifyCompletion(userId: number, libraryId: number, succeeded: number, failed: number): Promise<void> {
    const type = failed > 0 ? NotificationType.BulkRenameFailed : NotificationType.BulkRenameCompleted;
    const title = failed > 0 ? 'Bulk rename completed with errors' : 'Bulk rename completed';
    const message = `${succeeded} renamed, ${failed} failed`;

    await this.notificationService
      .notify({
        type,
        title,
        message,
        scope: { kind: 'user', userId },
        meta: { libraryId, succeeded, failed },
      })
      .catch(() => {});
  }

  private async notifyFailure(userId: number, libraryId: number, error: string): Promise<void> {
    await this.notificationService
      .notify({
        type: NotificationType.BulkRenameFailed,
        title: 'Bulk rename failed',
        message: error.slice(0, 200),
        scope: { kind: 'user', userId },
        meta: { libraryId },
      })
      .catch(() => {});
  }
}

function getErrorMessage(error: unknown): string {
  if (error instanceof Error) return error.message;
  return String(error);
}
