import { BadRequestException, ConflictException, Injectable, Logger, NotFoundException } from '@nestjs/common';
import { stat } from 'node:fs/promises';
import {
  FORMAT_TO_GROUP,
  READER_OPENABLE_FORMATS,
  type EpubBookmarkNavigationItem,
  type EpubBookmarkNavigationPage,
  type EpubBookmarkSort,
} from '@bookorbit/types';
import type { RequestUser } from '../../common/types/request-user';
import { sanitizeLogValue } from '../../common/utils/log-sanitize.utils';
import { BookService } from '../book/book.service';
import { BookmarkRepository, type EpubNavigationSelection } from './bookmark.repository';
import { EpubBookmarkContextService } from './epub-bookmark-context.service';
import { bookmarkCfiKey, bookmarkLocationLabel } from './epub-bookmark-location';
import { BookmarkResponseDto } from './dto/bookmark-response.dto';
import { EpubBookmarkNavigationDto } from './dto/epub-bookmark-navigation.dto';

interface NavigationCursor {
  version: 1;
  userId: number;
  bookId: number;
  fileId: number;
  query: string;
  sort: EpubBookmarkSort;
  revision: string;
  snapshotId: number;
  afterId: number;
}

@Injectable()
export class EpubBookmarkNavigationService {
  private readonly logger = new Logger(EpubBookmarkNavigationService.name);

  constructor(
    private readonly bookmarks: BookmarkRepository,
    private readonly books: BookService,
    private readonly context: EpubBookmarkContextService,
  ) {}

  async page(bookId: number, user: RequestUser, dto: EpubBookmarkNavigationDto): Promise<EpubBookmarkNavigationPage> {
    const startedAt = Date.now();
    const query = dto.query?.trim().toLowerCase() ?? '';
    const sort = dto.sort ?? 'location';
    this.logger.log(
      `[bookmark.query] [start] bookId=${bookId} userId=${user.id} fileId=${dto.fileId} queryLength=${query.length} sort=${sort} continued=${dto.cursor != null} - bookmark query started`,
    );
    try {
      await this.books.verifyBookAccess(bookId, user);
      const file = await this.books.verifyFileAccess(dto.fileId, user);
      if (file.bookId !== bookId) throw new NotFoundException(`No file with id ${dto.fileId} for book ${bookId}`);
      const format = file.format?.toLowerCase() ?? '';
      if (!READER_OPENABLE_FORMATS.has(format) || FORMAT_TO_GROUP[format] !== 'epub') {
        throw new BadRequestException('Bookmark navigation requires an ebook file');
      }
      const currentKey = dto.currentCfi == null ? null : bookmarkCfiKey(dto.currentCfi);
      if (dto.currentCfi != null && !currentKey) throw new BadRequestException('Invalid current EPUB location');
      const before = await this.sourceRevision(file.absolutePath);
      const contexts = format === 'epub' ? await this.context.get(bookId, dto.fileId, user) : '[]';
      const source = await this.sourceRevision(file.absolutePath);
      if (before !== source) throw new ConflictException('The ebook file changed. Reopen the book.');
      const revision = this.context.revision(contexts, JSON.stringify([file.fileHash, source]));
      const after = dto.cursor ? this.decodeCursor(dto.cursor, { userId: user.id, bookId, fileId: dto.fileId, query, sort, revision }) : null;
      const snapshotId = after?.snapshotId ?? (await this.bookmarks.epubSnapshotId(bookId, user.id));
      const selection: EpubNavigationSelection = { bookId, userId: user.id, snapshotId, contextJSON: contexts };
      const anchor = after ? await this.bookmarks.epubNavigationAnchor(selection, after.afterId) : null;
      if (after && (!anchor || !anchor.cfiOrder)) throw new BadRequestException('The bookmark page expired. Start from the first page.');
      const limit = dto.limit ?? 40;
      const scanLimit = query ? 400 : limit;
      const [rows, currentBookmarkId] = await Promise.all([
        this.bookmarks.epubNavigationPage(selection, sort, scanLimit + 1, anchor),
        currentKey ? this.bookmarks.currentEpubBookmarkId(selection, currentKey) : Promise.resolve(null),
      ]);
      const items: EpubBookmarkNavigationItem[] = [];
      let scannedCount = 0;
      // Database locale folding differs from the sidebar's ECMAScript lowercase.
      // A finite scan preserves literal Unicode substring semantics with continuation.
      for (const row of rows.slice(0, scanLimit)) {
        scannedCount += 1;
        const formatted = bookmarkLocationLabel(row.cfi);
        const locationLabel = formatted ?? 'Location unavailable';
        const contextLine =
          [row.chapterTitle, row.contextPercentage == null ? null : `${row.contextPercentage}%`].filter(Boolean).join(' - ') || locationLabel;
        if (query && !`${row.title} ${contextLine} ${formatted ?? ''}`.toLowerCase().includes(query)) continue;
        items.push({ ...BookmarkResponseDto.from(row), chapterTitle: row.chapterTitle, contextPercentage: row.contextPercentage, locationLabel });
        if (items.length === limit) break;
      }
      const hasNext = scannedCount < rows.length;
      const scanLimited = Boolean(query) && scannedCount === scanLimit && items.length < limit && hasNext;
      const cursor: NavigationCursor | null =
        hasNext && scannedCount > 0
          ? { version: 1, userId: user.id, bookId, fileId: dto.fileId, query, sort, revision, snapshotId, afterId: rows[scannedCount - 1].id }
          : null;
      this.logger.log(
        `[bookmark.query] [end] bookId=${bookId} userId=${user.id} fileId=${dto.fileId} durationMs=${Date.now() - startedAt} scanned=${scannedCount} items=${items.length} scanLimited=${scanLimited} hasNext=${cursor != null} - bookmark query completed`,
      );
      return {
        bookId,
        fileId: dto.fileId,
        fileRevision: revision,
        query,
        sort,
        items,
        currentBookmarkId,
        scannedCount,
        scanLimited,
        nextCursor: cursor ? Buffer.from(JSON.stringify(cursor)).toString('base64url') : null,
      };
    } catch (error) {
      this.logger.warn(
        `[bookmark.query] [fail] bookId=${bookId} userId=${user.id} fileId=${dto.fileId} durationMs=${Date.now() - startedAt} errorClass=${error instanceof Error ? error.name : 'Unknown'} error="${sanitizeLogValue(error instanceof Error ? error.message : 'unknown error')}" - bookmark query failed`,
      );
      throw error;
    }
  }

  private async sourceRevision(path: string): Promise<string> {
    const source = await stat(path).catch(() => {
      throw new NotFoundException('The ebook file is unavailable');
    });
    if (!source.isFile()) throw new NotFoundException('The ebook file is unavailable');
    return JSON.stringify([source.ino, source.size, source.mtimeMs, source.birthtimeMs]);
  }

  private decodeCursor(
    encoded: string,
    expected: Pick<NavigationCursor, 'userId' | 'bookId' | 'fileId' | 'query' | 'sort' | 'revision'>,
  ): NavigationCursor {
    try {
      if (!/^[A-Za-z0-9_-]+$/.test(encoded) || encoded.length > 2048) throw new BadRequestException('Invalid bookmark page');
      const value: unknown = JSON.parse(Buffer.from(encoded, 'base64url').toString('utf8'));
      if (!value || typeof value !== 'object' || Array.isArray(value)) throw new BadRequestException('Invalid bookmark page');
      const cursor = value as NavigationCursor;
      const keys = ['version', 'userId', 'bookId', 'fileId', 'query', 'sort', 'revision', 'snapshotId', 'afterId'];
      if (
        Object.keys(cursor).length !== keys.length ||
        keys.some((key) => !Object.hasOwn(cursor, key)) ||
        cursor.version !== 1 ||
        Object.entries(expected).some(([key, target]) => cursor[key as keyof NavigationCursor] !== target) ||
        !Number.isInteger(cursor.snapshotId) ||
        cursor.snapshotId < 1 ||
        cursor.snapshotId > 2147483647 ||
        !Number.isInteger(cursor.afterId) ||
        cursor.afterId < 1 ||
        cursor.afterId > cursor.snapshotId
      ) {
        throw new BadRequestException('The bookmark page changed. Start from the first page.');
      }
      return cursor;
    } catch (error) {
      if (error instanceof BadRequestException) throw error;
      throw new BadRequestException('Invalid bookmark page');
    }
  }
}
