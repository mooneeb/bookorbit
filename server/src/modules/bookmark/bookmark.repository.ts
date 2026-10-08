import { Inject, Injectable } from '@nestjs/common';
import { and, asc, desc, eq, gt, gte, inArray, isNotNull, isNull, lt, lte, or, sql, type SQL } from 'drizzle-orm';
import type { EpubBookmarkSort } from '@bookorbit/types';
import { NodePgDatabase } from 'drizzle-orm/node-postgres';

import { DB } from '../../db';
import * as schema from '../../db/schema';
import { bookmarks, type BookmarkRow, type NewBookmark } from '../../db/schema';

type EpubNavigationAnchor = NonNullable<Awaited<ReturnType<BookmarkRepository['epubNavigationAnchor']>>>;

export interface EpubNavigationSelection {
  bookId: number;
  userId: number;
  snapshotId: number;
  contextJSON: string;
}

type Db = NodePgDatabase<typeof schema>;

/** What a device-originated bookmark carries beyond the shared location/title pair. */
export interface DeviceBookmarkFields {
  cfi: string;
  title: string;
  devicePos: string;
  pageno: number | null;
}

@Injectable()
export class BookmarkRepository {
  constructor(@Inject(DB) private readonly db: Db) {}

  async epubSnapshotId(bookId: number, userId: number): Promise<number> {
    const [row] = await this.db
      .select({ id: bookmarks.id })
      .from(bookmarks)
      .where(this.epubScope(bookId, userId))
      .orderBy(desc(bookmarks.id))
      .limit(1);
    return row?.id ?? 0;
  }

  async epubNavigationAnchor(selection: EpubNavigationSelection, id: number) {
    const [row] = await this.db
      .select({ id: bookmarks.id, createdAt: sql<string>`${bookmarks.createdAt}::text`, cfiOrder: bookmarks.cfiOrder })
      .from(bookmarks)
      .where(and(this.epubScope(selection.bookId, selection.userId, true), eq(bookmarks.id, id), lte(bookmarks.id, selection.snapshotId)))
      .limit(1);
    return row ?? null;
  }

  async epubNavigationPage(selection: EpubNavigationSelection, sort: EpubBookmarkSort, limit: number, anchor: EpubNavigationAnchor | null) {
    const order = sql`(${bookmarks.cfiOrder})[1:32]`;
    let seek: SQL | undefined;
    if (anchor) {
      if (sort === 'location') {
        const key = sql`${JSON.stringify(anchor.cfiOrder)}::jsonb`;
        const numbers = sql`array(select jsonb_array_elements_text(${key}))::numeric[]`;
        seek = and(
          gte(order, sql`(${numbers})[1:32]`),
          or(
            gt(bookmarks.cfiOrder, numbers),
            and(
              eq(bookmarks.cfiOrder, numbers),
              or(
                gt(bookmarks.createdAt, sql`${anchor.createdAt}::timestamptz`),
                and(eq(bookmarks.createdAt, sql`${anchor.createdAt}::timestamptz`), gt(bookmarks.id, anchor.id)),
              ),
            ),
          ),
        );
      } else {
        const compare = sort === 'newest' ? lt : gt;
        seek = or(
          compare(bookmarks.createdAt, sql`${anchor.createdAt}::timestamptz`),
          and(eq(bookmarks.createdAt, sql`${anchor.createdAt}::timestamptz`), compare(bookmarks.id, anchor.id)),
        );
      }
    }
    const ordering =
      sort === 'location'
        ? [asc(order), asc(bookmarks.cfiOrder), asc(bookmarks.createdAt), asc(bookmarks.id)]
        : sort === 'newest'
          ? [desc(bookmarks.createdAt), desc(bookmarks.id)]
          : [asc(bookmarks.createdAt), asc(bookmarks.id)];
    return this.epubNavigationRows(selection, seek)
      .orderBy(...ordering)
      .limit(limit);
  }

  async currentEpubBookmarkId(selection: EpubNavigationSelection, currentKey: string[]): Promise<number | null> {
    const startKey = currentKey.slice(0, currentKey.indexOf('-3'));
    const key = sql`array(select jsonb_array_elements_text(${JSON.stringify([...startKey, '0'])}::jsonb))::numeric[]`;
    const prefix = sql`(${bookmarks.cfiOrder})[1:32]`;
    const [previous] = await this.epubNavigationRows(selection, and(lte(prefix, sql`(${key})[1:32]`), lt(bookmarks.cfiOrder, key)))
      .orderBy(desc(prefix), desc(bookmarks.cfiOrder), desc(bookmarks.createdAt), desc(bookmarks.id))
      .limit(1);
    if (previous) return previous.id;
    const [first] = await this.epubNavigationRows(selection)
      .orderBy(asc(prefix), asc(bookmarks.cfiOrder), asc(bookmarks.createdAt), asc(bookmarks.id))
      .limit(1);
    return first?.id ?? null;
  }

  private epubNavigationRows(selection: EpubNavigationSelection, seek?: SQL) {
    const context = sql`jsonb_to_recordset(${selection.contextJSON}::jsonb) as bookmark_context("spineStep" numeric, "startKey" numeric[], "endKey" numeric[], "chapterTitle" text, percentage integer)`;
    const title = sql<string | null>`bookmark_context."chapterTitle"`;
    const percentage = sql<number | null>`bookmark_context.percentage`;
    // Foliate's contents lookup chooses the last heading at or before a range's end.
    const end = sql`(${bookmarks.cfiOrder})[array_position(${bookmarks.cfiOrder}, -3::numeric) + 1:array_length(${bookmarks.cfiOrder}, 1)]`;
    const contextOrder = sql`(array[0]::numeric[] || ${end} || array[-3]::numeric[] || ${end})`;
    return this.db
      .select({
        id: bookmarks.id,
        bookId: bookmarks.bookId,
        cfi: bookmarks.cfi,
        title: bookmarks.title,
        positionSeconds: bookmarks.positionSeconds,
        fileId: bookmarks.fileId,
        pageNumber: bookmarks.pageNumber,
        createdAt: bookmarks.createdAt,
        chapterTitle: title,
        contextPercentage: percentage,
      })
      .from(bookmarks)
      .leftJoin(
        context,
        sql`${bookmarks.cfiOrder}[1] = 0 and ${bookmarks.cfiOrder}[2] = 6
      and ${bookmarks.cfiOrder}[3] = bookmark_context."spineStep" and ${contextOrder} >= bookmark_context."startKey"
      and (bookmark_context."endKey" is null or ${contextOrder} < bookmark_context."endKey")`,
      )
      .where(and(this.epubScope(selection.bookId, selection.userId), lte(bookmarks.id, selection.snapshotId), seek));
  }

  private epubScope(bookId: number, userId: number, includesDeleted = false) {
    return and(
      eq(bookmarks.bookId, bookId),
      eq(bookmarks.userId, userId),
      isNull(bookmarks.fileId),
      isNotNull(bookmarks.cfi),
      includesDeleted ? undefined : isNull(bookmarks.deletedAt),
    );
  }

  async findByBookId(bookId: number, userId: number) {
    return this.db
      .select()
      .from(bookmarks)
      .where(and(eq(bookmarks.bookId, bookId), eq(bookmarks.userId, userId), isNotNull(bookmarks.cfi), isNull(bookmarks.deletedAt)))
      .orderBy(asc(bookmarks.createdAt), asc(bookmarks.id));
  }

  async findFilePage(bookId: number, userId: number, fileId: number, limit: number, beforeId?: number) {
    return this.db
      .select()
      .from(bookmarks)
      .where(
        and(
          eq(bookmarks.bookId, bookId),
          eq(bookmarks.userId, userId),
          eq(bookmarks.fileId, fileId),
          isNull(bookmarks.deletedAt),
          beforeId == null ? undefined : lt(bookmarks.id, beforeId),
        ),
      )
      .orderBy(desc(bookmarks.id))
      .limit(limit);
  }

  async findEpubPage(bookId: number, userId: number, limit: number, beforeId?: number) {
    return this.db
      .select({
        id: bookmarks.id,
        bookId: bookmarks.bookId,
        cfi: bookmarks.cfi,
        title: bookmarks.title,
        positionSeconds: bookmarks.positionSeconds,
        fileId: bookmarks.fileId,
        pageNumber: bookmarks.pageNumber,
        createdAt: bookmarks.createdAt,
      })
      .from(bookmarks)
      .where(
        and(
          eq(bookmarks.bookId, bookId),
          eq(bookmarks.userId, userId),
          isNull(bookmarks.fileId),
          isNotNull(bookmarks.cfi),
          isNull(bookmarks.deletedAt),
          beforeId == null ? undefined : lt(bookmarks.id, beforeId),
        ),
      )
      .orderBy(desc(bookmarks.id))
      .limit(limit);
  }

  async findLiveByLocation(
    userId: number,
    bookId: number,
    data: Pick<NewBookmark, 'cfi' | 'positionSeconds' | 'fileId' | 'pageNumber'>,
  ): Promise<BookmarkRow | null> {
    if (data.fileId != null && data.pageNumber != null) {
      const [row] = await this.db
        .select()
        .from(bookmarks)
        .where(
          and(
            eq(bookmarks.userId, userId),
            eq(bookmarks.bookId, bookId),
            eq(bookmarks.fileId, data.fileId),
            eq(bookmarks.pageNumber, data.pageNumber),
            isNull(bookmarks.deletedAt),
          ),
        )
        .limit(1);
      return row ?? null;
    }
    if (data.cfi != null) {
      const [row] = await this.db
        .select()
        .from(bookmarks)
        .where(and(eq(bookmarks.userId, userId), eq(bookmarks.bookId, bookId), eq(bookmarks.cfi, data.cfi), isNull(bookmarks.deletedAt)))
        .orderBy(asc(bookmarks.createdAt), asc(bookmarks.id))
        .limit(1);
      return row ?? null;
    }

    if (data.positionSeconds != null) {
      const [row] = await this.db
        .select()
        .from(bookmarks)
        .where(
          and(
            eq(bookmarks.userId, userId),
            eq(bookmarks.bookId, bookId),
            eq(bookmarks.positionSeconds, data.positionSeconds),
            isNull(bookmarks.cfi),
            isNull(bookmarks.deletedAt),
          ),
        )
        .orderBy(asc(bookmarks.createdAt), asc(bookmarks.id))
        .limit(1);
      return row ?? null;
    }

    return null;
  }

  async create(userId: number, bookId: number, data: Pick<NewBookmark, 'cfi' | 'title' | 'positionSeconds' | 'fileId' | 'pageNumber'>) {
    const [row] = await this.db
      .insert(bookmarks)
      .values({
        userId,
        bookId,
        cfi: data.cfi ?? null,
        title: data.title,
        positionSeconds: data.positionSeconds ?? null,
        fileId: data.fileId ?? null,
        pageNumber: data.pageNumber ?? null,
      })
      .onConflictDoNothing()
      .returning();
    return row ?? null;
  }

  /**
   * Re-activates the tombstoned row that owns this location. The unique location
   * indexes still cover tombstoned rows, so inserting at a deleted bookmark's CFI
   * would conflict instead of recreating it.
   */
  async restoreAtLocation(
    userId: number,
    bookId: number,
    data: Pick<NewBookmark, 'cfi' | 'positionSeconds' | 'fileId' | 'pageNumber'>,
    values: Pick<NewBookmark, 'title' | 'origin' | 'devicePos' | 'pageno'>,
  ): Promise<BookmarkRow | null> {
    const location =
      data.fileId != null && data.pageNumber != null
        ? and(eq(bookmarks.fileId, data.fileId), eq(bookmarks.pageNumber, data.pageNumber))
        : data.cfi != null
          ? eq(bookmarks.cfi, data.cfi)
          : data.positionSeconds != null
            ? and(eq(bookmarks.positionSeconds, data.positionSeconds), isNull(bookmarks.cfi))
            : null;
    if (!location) return null;

    const [row] = await this.db
      .update(bookmarks)
      .set({
        title: values.title,
        origin: values.origin ?? 'web',
        devicePos: values.devicePos ?? null,
        pageno: values.pageno ?? null,
        deletedAt: null,
      })
      .where(and(eq(bookmarks.userId, userId), eq(bookmarks.bookId, bookId), location, isNotNull(bookmarks.deletedAt)))
      .returning();
    return row ?? null;
  }

  /** Soft delete: devices still holding the bookmark learn about it on their next exchange. */
  async softDelete(bookId: number, bookmarkId: number, userId: number) {
    const result = await this.db
      .update(bookmarks)
      .set({ deletedAt: new Date() })
      .where(and(eq(bookmarks.id, bookmarkId), eq(bookmarks.bookId, bookId), eq(bookmarks.userId, userId), isNull(bookmarks.deletedAt)))
      .returning({ id: bookmarks.id });
    return result.length > 0;
  }

  // Sync-facing operations. The bookmarks table stays owned here; the KOReader
  // module drives these through BookmarkSyncService.

  /** Every row of one book, tombstones included, so a sync can see deletions too. */
  async listForSync(userId: number, bookId: number, limit: number): Promise<BookmarkRow[]> {
    return this.db
      .select()
      .from(bookmarks)
      .where(and(eq(bookmarks.userId, userId), eq(bookmarks.bookId, bookId)))
      .orderBy(asc(bookmarks.id))
      .limit(limit);
  }

  async createFromDevice(userId: number, bookId: number, fields: DeviceBookmarkFields): Promise<BookmarkRow | null> {
    const [row] = await this.db
      .insert(bookmarks)
      .values({
        userId,
        bookId,
        cfi: fields.cfi,
        title: fields.title,
        origin: 'koreader',
        devicePos: fields.devicePos,
        pageno: fields.pageno,
      })
      .onConflictDoNothing()
      .returning();
    return row ?? null;
  }

  async updateFromDevice(
    userId: number,
    bookmarkId: number,
    values: Partial<Pick<NewBookmark, 'title' | 'devicePos' | 'pageno'>>,
  ): Promise<BookmarkRow | null> {
    const [row] = await this.db
      .update(bookmarks)
      .set(values)
      .where(and(eq(bookmarks.id, bookmarkId), eq(bookmarks.userId, userId), isNull(bookmarks.deletedAt)))
      .returning();
    return row ?? null;
  }

  async tombstone(userId: number, bookmarkIds: number[]): Promise<number> {
    if (bookmarkIds.length === 0) return 0;
    const rows = await this.db
      .update(bookmarks)
      .set({ deletedAt: new Date() })
      .where(and(eq(bookmarks.userId, userId), inArray(bookmarks.id, bookmarkIds), isNull(bookmarks.deletedAt)))
      .returning({ id: bookmarks.id });
    return rows.length;
  }

  async listPurgeableTombstones(userId: number, deletedBefore: Date, limit: number): Promise<number[]> {
    const rows = await this.db
      .select({ id: bookmarks.id })
      .from(bookmarks)
      .where(and(eq(bookmarks.userId, userId), isNotNull(bookmarks.deletedAt), lt(bookmarks.deletedAt, deletedBefore)))
      .orderBy(asc(bookmarks.deletedAt))
      .limit(limit);
    return rows.map((row) => row.id);
  }

  async purge(userId: number, bookmarkIds: number[]): Promise<number> {
    if (bookmarkIds.length === 0) return 0;
    const rows = await this.db
      .delete(bookmarks)
      .where(and(eq(bookmarks.userId, userId), inArray(bookmarks.id, bookmarkIds), isNotNull(bookmarks.deletedAt)))
      .returning({ id: bookmarks.id });
    return rows.length;
  }
}
