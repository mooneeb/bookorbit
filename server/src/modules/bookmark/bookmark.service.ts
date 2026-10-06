import { BadRequestException, ConflictException, Injectable, Logger, NotFoundException } from '@nestjs/common';
import type { BookmarksPage } from '@bookorbit/types';

import type { RequestUser } from '../../common/types/request-user';
import { sanitizeLogValue } from '../../common/utils/log-sanitize.utils';
import type { NewBookmark } from '../../db/schema';
import { BookService } from '../book/book.service';
import { BookmarkRepository } from './bookmark.repository';
import { BookmarkResponseDto } from './dto/bookmark-response.dto';
import { CreateBookmarkDto } from './dto/create-bookmark.dto';
import { BookmarkPageDto } from './dto/bookmark-page.dto';
import { CreateFixedPageBookmarkDto } from './dto/create-fixed-page-bookmark.dto';

const BOOKMARK_CONFLICT_MESSAGE = 'Bookmark already exists';

@Injectable()
export class BookmarkService {
  private readonly logger = new Logger(BookmarkService.name);
  constructor(
    private readonly bookmarkRepo: BookmarkRepository,
    private readonly bookService: BookService,
  ) {}

  async getBookmarks(bookId: number, user: RequestUser): Promise<BookmarkResponseDto[]> {
    await this.bookService.verifyBookAccess(bookId, user);
    const rows = await this.bookmarkRepo.findByBookId(bookId, user.id);
    return rows.map((row) => BookmarkResponseDto.from(row));
  }

  async createBookmark(bookId: number, user: RequestUser, dto: CreateBookmarkDto): Promise<BookmarkResponseDto> {
    return this.mutate('bookmark.create', bookId, user.id, async () => {
      await this.bookService.verifyBookAccess(bookId, user);
      return this.persist(bookId, user.id, this.buildCreateData(dto));
    });
  }

  async getPage(bookId: number, user: RequestUser, dto: BookmarkPageDto): Promise<BookmarksPage> {
    await this.verifyFixedFile(bookId, dto.fileId, user);
    const limit = dto.limit ?? 40;
    const rows = await this.bookmarkRepo.findFilePage(bookId, user.id, dto.fileId, limit + 1, dto.beforeId);
    const items = rows.slice(0, limit).map((row) => BookmarkResponseDto.from(row));
    return { items, nextCursor: rows.length > limit ? items.at(-1)!.id : null };
  }

  async createFixedPageBookmark(bookId: number, user: RequestUser, dto: CreateFixedPageBookmarkDto): Promise<BookmarkResponseDto> {
    return this.mutate('bookmark.create_fixed_page', bookId, user.id, async () => {
      await this.verifyFixedFile(bookId, dto.fileId, user);
      return this.persist(bookId, user.id, {
        cfi: null,
        positionSeconds: null,
        fileId: dto.fileId,
        pageNumber: dto.pageNumber,
        title: dto.title,
      });
    });
  }

  private async verifyFixedFile(bookId: number, fileId: number, user: RequestUser): Promise<void> {
    await this.bookService.verifyBookAccess(bookId, user);
    const file = await this.bookService.verifyFileAccess(fileId, user);
    if (file.bookId !== bookId) throw new NotFoundException(`No file with id ${fileId} for book ${bookId}`);
    if (!['pdf', 'cbz', 'cbr', 'cb7'].includes(file.format?.toLowerCase() ?? '')) {
      throw new BadRequestException('Fixed-page bookmarks require a PDF or comic file');
    }
  }

  private async persist(
    bookId: number,
    userId: number,
    createData: Pick<NewBookmark, 'cfi' | 'title' | 'positionSeconds' | 'fileId' | 'pageNumber'>,
  ): Promise<BookmarkResponseDto> {
    const location = {
      cfi: createData.cfi,
      positionSeconds: createData.positionSeconds,
      fileId: createData.fileId,
      pageNumber: createData.pageNumber,
    };

    const existing = await this.bookmarkRepo.findLiveByLocation(userId, bookId, location);
    if (existing) return BookmarkResponseDto.from(existing);

    const row = await this.bookmarkRepo.create(userId, bookId, createData);
    if (row) return BookmarkResponseDto.from(row);

    // The insert conflicted: either a tombstone still owns this location and has to
    // come back to life, or another request created the same bookmark first.
    const restored = await this.bookmarkRepo.restoreAtLocation(userId, bookId, location, {
      title: createData.title,
      origin: 'web',
      devicePos: null,
      pageno: null,
    });
    if (restored) return BookmarkResponseDto.from(restored);

    const concurrent = await this.bookmarkRepo.findLiveByLocation(userId, bookId, location);
    if (concurrent) return BookmarkResponseDto.from(concurrent);
    throw new ConflictException(BOOKMARK_CONFLICT_MESSAGE);
  }

  async deleteBookmark(bookId: number, bookmarkId: number, user: RequestUser): Promise<void> {
    await this.mutate('bookmark.delete', bookId, user.id, async () => {
      await this.bookService.verifyBookAccess(bookId, user);
      const deleted = await this.bookmarkRepo.softDelete(bookId, bookmarkId, user.id);
      if (!deleted) throw new NotFoundException(this.notFoundMessage(bookId, bookmarkId));
    });
  }

  private async mutate<T>(event: string, bookId: number, userId: number, operation: () => Promise<T>): Promise<T> {
    const startedAt = Date.now();
    this.logger.log(`[${event}] [start] bookId=${bookId} userId=${userId} - bookmark mutation started`);
    try {
      const result = await operation();
      this.logger.log(
        `[${event}] [end] bookId=${bookId} userId=${userId} durationMs=${Date.now() - startedAt} saved=true - bookmark mutation completed`,
      );
      return result;
    } catch (error) {
      this.logger.warn(
        `[${event}] [fail] bookId=${bookId} userId=${userId} durationMs=${Date.now() - startedAt} errorClass=${error instanceof Error ? error.name : 'Unknown'} error="${sanitizeLogValue(error instanceof Error ? error.message : 'unknown error')}" - bookmark mutation failed`,
      );
      throw error;
    }
  }

  private buildCreateData(dto: CreateBookmarkDto): Pick<NewBookmark, 'cfi' | 'title' | 'positionSeconds'> {
    return {
      cfi: dto.cfi,
      title: dto.title,
      positionSeconds: null,
    };
  }

  private notFoundMessage(bookId: number, bookmarkId: number): string {
    return `Bookmark ${bookmarkId} not found for book ${bookId}`;
  }
}
