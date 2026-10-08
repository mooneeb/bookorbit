import type { BookmarkRow } from '../../../db/schema';
import type { BookmarkResponse } from '@bookorbit/types';

export class BookmarkResponseDto implements BookmarkResponse {
  id!: number;
  bookId!: number;
  cfi!: string | null;
  title!: string;
  positionSeconds!: number | null;
  fileId!: number | null;
  pageNumber!: number | null;
  createdAt!: string;
  note!: string | null;
  updatedAt!: string;
  clientId!: string;
  origin!: string;
  chapterId!: string | null;

  static from(row: Pick<BookmarkRow, keyof BookmarkResponse>): BookmarkResponseDto {
    const dto = new BookmarkResponseDto();
    dto.id = row.id;
    dto.bookId = row.bookId;
    dto.cfi = row.cfi ?? null;
    dto.title = row.title;
    dto.positionSeconds = row.positionSeconds ?? null;
    dto.fileId = row.fileId ?? null;
    dto.pageNumber = row.pageNumber ?? null;
    dto.createdAt = row.createdAt.toISOString();
    dto.note = row.note ?? null;
    dto.updatedAt = row.updatedAt.toISOString();
    dto.clientId = row.clientId;
    dto.origin = row.origin;
    dto.chapterId = row.chapterId ?? null;
    return dto;
  }
}
