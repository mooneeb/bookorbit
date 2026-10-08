import { BadRequestException, ConflictException, Injectable, Logger, NotFoundException } from '@nestjs/common';
import type { BookmarksPage } from '@bookorbit/types';

import type { RequestUser } from '../../common/types/request-user';
import { sanitizeLogValue } from '../../common/utils/log-sanitize.utils';
import type { BookmarkRow, NewBookmark } from '../../db/schema';
import { BookService } from '../book/book.service';
import { BookmarkRepository } from './bookmark.repository';
import { BookmarkResponseDto } from './dto/bookmark-response.dto';
import { CreateBookmarkDto } from './dto/create-bookmark.dto';
import { BookmarkPageDto } from './dto/bookmark-page.dto';
import { EpubBookmarkPageDto } from './dto/epub-bookmark-page.dto';
import { CreateFixedPageBookmarkDto } from './dto/create-fixed-page-bookmark.dto';
import { UpdateBookmarkDto } from './dto/update-bookmark.dto';

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

  async getEpubPage(bookId: number, user: RequestUser, dto: EpubBookmarkPageDto): Promise<BookmarksPage> {
    await this.bookService.verifyBookAccess(bookId, user);
    const limit = dto.limit ?? 40;
    const rows = await this.bookmarkRepo.findEpubPage(bookId, user.id, limit + 1, dto.beforeId);
    const items = rows.slice(0, limit).map((row) => BookmarkResponseDto.from(row));
    return { items, nextCursor: rows.length > limit ? items.at(-1)!.id : null };
  }

  async createFixedPageBookmark(bookId: number, user: RequestUser, dto: CreateFixedPageBookmarkDto): Promise<BookmarkResponseDto> {
    return this.mutate('bookmark.create_fixed_page', bookId, user.id, async () => {
      await this.verifyFixedFile(bookId, dto.fileId, user);
      return this.persist(bookId, user.id, {
        clientId: dto.clientId,
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
    createData: Pick<NewBookmark, 'clientId' | 'cfi' | 'title' | 'positionSeconds' | 'fileId' | 'pageNumber'>,
  ): Promise<BookmarkResponseDto> {
    const location = {
      cfi: createData.cfi,
      positionSeconds: createData.positionSeconds,
      fileId: createData.fileId,
      pageNumber: createData.pageNumber,
    };

    if (createData.clientId) {
      const previous = await this.bookmarkRepo.findByClientId(userId, bookId, createData.clientId);
      if (previous) return this.creationRetry(previous, createData);
    } else {
      const existing = await this.bookmarkRepo.findLiveByLocation(userId, bookId, location);
      if (existing) return BookmarkResponseDto.from(existing);
    }

    const row = await this.bookmarkRepo.create(userId, bookId, createData);
    if (row) return BookmarkResponseDto.from(row);

    if (createData.clientId) {
      const concurrent = await this.bookmarkRepo.findByClientId(userId, bookId, createData.clientId);
      if (concurrent) return this.creationRetry(concurrent, createData);
    } else {
      const concurrent = await this.bookmarkRepo.findLiveByLocation(userId, bookId, location);
      if (concurrent) return BookmarkResponseDto.from(concurrent);
    }
    throw new ConflictException(BOOKMARK_CONFLICT_MESSAGE);
  }

  private creationRetry(row: BookmarkRow, createData: Pick<NewBookmark, 'cfi' | 'positionSeconds' | 'fileId' | 'pageNumber'>): BookmarkResponseDto {
    if (row.deletedAt) throw new ConflictException('This bookmark creation was already deleted; use a new clientId for an explicit new bookmark');
    if (
      row.cfi !== (createData.cfi ?? null) ||
      row.positionSeconds !== (createData.positionSeconds ?? null) ||
      row.fileId !== (createData.fileId ?? null) ||
      row.pageNumber !== (createData.pageNumber ?? null)
    ) {
      throw new ConflictException('Bookmark identity cannot be reused for a different location');
    }
    return BookmarkResponseDto.from(row);
  }

  /**
   * Renames a bookmark or edits its note. A KOReader device that already holds the dogear does not
   * receive the change: bookmark exchange pushes only bookmarks a device has never seen.
   */
  async updateBookmark(bookId: number, bookmarkId: number, user: RequestUser, dto: UpdateBookmarkDto): Promise<BookmarkResponseDto> {
    return this.mutate('bookmark.update', bookId, user.id, async () => {
      await this.bookService.verifyBookAccess(bookId, user);
      const patch = {
        ...(dto.title !== undefined && { title: dto.title }),
        ...(dto.note !== undefined && { note: dto.note }),
      };
      const row =
        Object.keys(patch).length === 0
          ? await this.bookmarkRepo.findLive(bookId, bookmarkId, user.id)
          : await this.bookmarkRepo.update(bookId, bookmarkId, user.id, patch);
      if (!row) throw new NotFoundException(this.notFoundMessage(bookId, bookmarkId));
      return BookmarkResponseDto.from(row);
    });
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

  private buildCreateData(dto: CreateBookmarkDto): Pick<NewBookmark, 'clientId' | 'cfi' | 'title' | 'positionSeconds'> {
    return {
      clientId: dto.clientId,
      cfi: dto.cfi,
      title: dto.title,
      positionSeconds: null,
    };
  }

  private notFoundMessage(bookId: number, bookmarkId: number): string {
    return `Bookmark ${bookmarkId} not found for book ${bookId}`;
  }
}
