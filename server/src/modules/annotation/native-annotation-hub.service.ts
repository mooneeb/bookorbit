import { BadRequestException, ForbiddenException, Inject, Injectable, Logger, NotFoundException } from '@nestjs/common';
import { and, asc, desc, eq, exists, gt, ilike, inArray, isNotNull, isNull, lt, or, sql, type SQL } from 'drizzle-orm';
import type { NodePgDatabase } from 'drizzle-orm/node-postgres';
import type {
  NativeAnnotationItem,
  NativeAnnotationDraftResponse,
  NativeAnnotationHubDeviceResponse,
  NativeAnnotationHubResponse,
  NativeAnnotationOperationsRequest,
} from '@bookorbit/types';

import { DB } from '../../db';
import * as schema from '../../db/schema';
import {
  annotationPositions,
  annotations,
  authors,
  bookAuthors,
  bookFiles,
  bookMetadata,
  books,
  nativeAnnotationAcks,
  nativeAnnotationDrafts,
  nativeAnnotationOperations,
} from '../../db/schema';
import type { RequestUser } from '../../common/types/request-user';
import { sanitizeLogValue } from '../../common/utils/log-sanitize.utils';
import { NativeAnnotationService } from './native-annotation.service';
import type {
  NativeAnnotationHubDevicesQueryDto,
  NativeAnnotationHubExportQueryDto,
  NativeAnnotationHubQueryDto,
} from './dto/native-annotation-hub.dto';

@Injectable()
export class NativeAnnotationHubService {
  private readonly logger = new Logger(NativeAnnotationHubService.name);

  constructor(
    @Inject(DB) private readonly db: NodePgDatabase<typeof schema>,
    private readonly nativeAnnotations: NativeAnnotationService,
  ) {}

  async list(userId: number, query: NativeAnnotationHubQueryDto): Promise<NativeAnnotationHubResponse> {
    const limit = query.limit ?? 40;
    const group = this.groupExpression(query.groupBy);
    const conditions = this.conditions(userId, query);
    if (query.cursor !== undefined) {
      const [cursor] = await this.db
        .select({ id: annotations.id, group })
        .from(annotations)
        .where(and(eq(annotations.userId, userId), eq(annotations.id, query.cursor)))
        .limit(1);
      if (!cursor) throw new BadRequestException('Annotation cursor is unavailable; restart this search');
      const afterGroup = query.groupBy === 'month' ? lt(group, cursor.group) : gt(group, cursor.group);
      conditions.push(query.groupBy ? or(afterGroup, and(eq(group, cursor.group), lt(annotations.id, cursor.id)))! : lt(annotations.id, cursor.id));
    }
    const rows = await this.queryRows(conditions, group)
      .orderBy(...(query.groupBy ? [query.groupBy === 'month' ? desc(group) : asc(group)] : []), desc(annotations.id))
      .limit(limit + 1);
    return this.hydrate(userId, rows.slice(0, limit), rows.length > limit);
  }

  async export(userId: number, query: NativeAnnotationHubExportQueryDto) {
    const started = Date.now();
    this.logger.log(
      `[annotation.native_export] [start] userId=${userId} selected=${query.ids?.length ?? 0} limit=${query.limit ?? 40} - annotation export started`,
    );
    try {
      let page: NativeAnnotationHubResponse;
      if (query.ids) {
        const ids = [...new Set(query.ids)];
        const rows = await this.queryRows([eq(annotations.userId, userId), inArray(annotations.id, ids)], this.groupExpression(query.groupBy))
          .orderBy(desc(annotations.id))
          .limit(100);
        if (rows.length !== ids.length) throw new ForbiddenException('Annotation selection includes unavailable items');
        page = await this.hydrate(userId, rows, false);
      } else {
        page = await this.list(userId, query);
      }
      const drafts = query.status === 'recovery' ? await this.drafts(userId, query, query.ids) : undefined;
      const content = JSON.stringify(
        { format: 'bookorbit-annotations-v1', ...page, ...(drafts ? { drafts: drafts.items, nextDraftCursor: drafts.nextCursor } : {}) },
        null,
        2,
      );
      this.logger.log(
        `[annotation.native_export] [end] userId=${userId} durationMs=${Date.now() - started} items=${page.items.length} drafts=${drafts?.items.length ?? 0} - annotation export completed`,
      );
      return { contentType: 'application/json; charset=utf-8', filename: 'bookorbit-annotations.json', content };
    } catch (error) {
      this.logFailure('annotation.native_export', userId, started, error);
      throw error;
    }
  }

  async drafts(userId: number, query: NativeAnnotationHubQueryDto, annotationIds?: number[]): Promise<NativeAnnotationDraftResponse> {
    const limit = query.limit ?? 40;
    const conditions: SQL[] = [eq(nativeAnnotationDrafts.userId, userId)];
    if (annotationIds) conditions.push(inArray(nativeAnnotationDrafts.annotationId, annotationIds));
    if (query.cursor !== undefined) conditions.push(lt(nativeAnnotationDrafts.id, query.cursor));
    if (query.bookId !== undefined) conditions.push(eq(nativeAnnotationDrafts.bookId, query.bookId));
    if (query.kind)
      conditions.push(
        sql`coalesce(${nativeAnnotationOperations.result}->'recoverySnapshot'->>'kind', ${nativeAnnotationDrafts.payload}->'payload'->>'kind') = ${query.kind}`,
      );
    if (query.fileId !== undefined)
      conditions.push(
        sql`coalesce((${nativeAnnotationOperations.result}->'recoverySnapshot'->>'jumpFileId')::integer, (${nativeAnnotationDrafts.payload}->'payload'->>'bookFileId')::integer) = ${query.fileId}`,
      );
    if (query.search) {
      const pattern = this.searchPattern(query.search);
      conditions.push(
        or(
          sql`coalesce(${nativeAnnotationOperations.result}->'recoverySnapshot'->>'text', ${nativeAnnotationDrafts.payload}->'payload'->>'text') ilike ${pattern}`,
          sql`coalesce(${nativeAnnotationOperations.result}->'recoverySnapshot'->>'note', ${nativeAnnotationDrafts.payload}->'payload'->>'note') ilike ${pattern}`,
          ilike(bookMetadata.title, pattern),
        )!,
      );
    }
    const rows = await this.db
      .select({
        id: nativeAnnotationDrafts.id,
        bookId: nativeAnnotationDrafts.bookId,
        annotationId: nativeAnnotationDrafts.annotationId,
        operationId: nativeAnnotationDrafts.operationId,
        reason: nativeAnnotationDrafts.reason,
        payload: nativeAnnotationDrafts.payload,
        createdAt: nativeAnnotationDrafts.createdAt,
        snapshot: sql<NativeAnnotationItem | null>`${nativeAnnotationOperations.result}->'recoverySnapshot'`,
        snapshotUnavailableReason: sql<string | null>`${nativeAnnotationOperations.result}->>'recoverySnapshotUnavailableReason'`,
        canonicalKind: sql<string | null>`${nativeAnnotationOperations.result}->'annotation'->>'kind'`,
      })
      .from(nativeAnnotationDrafts)
      .leftJoin(
        nativeAnnotationOperations,
        and(
          eq(nativeAnnotationOperations.userId, nativeAnnotationDrafts.userId),
          eq(nativeAnnotationOperations.operationId, nativeAnnotationDrafts.operationId),
        ),
      )
      .leftJoin(bookMetadata, eq(bookMetadata.bookId, nativeAnnotationDrafts.bookId))
      .where(and(...conditions))
      .orderBy(desc(nativeAnnotationDrafts.id))
      .limit(limit + 1);
    const page = rows.slice(0, limit);
    const missing = page.filter((row) => !row.snapshot);
    const recovered = await this.nativeAnnotations.recoverySnapshots(
      userId,
      missing.map((row) => ({ ...row.payload, ...(row.annotationId ? { annotationId: row.annotationId } : {}) })),
      missing.filter((row) => row.canonicalKind === 'pdf_ink').map((row) => row.operationId),
    );
    const items = page.map((row) => ({
      id: row.id,
      bookId: row.bookId,
      annotationId: row.annotationId,
      operationId: row.operationId,
      reason: row.reason,
      payload: row.payload,
      createdAt: row.createdAt.toISOString(),
      snapshot: row.snapshot ?? recovered.get(row.operationId),
      ...(!(row.snapshot ?? recovered.get(row.operationId))
        ? { snapshotUnavailableReason: row.snapshotUnavailableReason ?? 'retained_base_unavailable' }
        : {}),
    }));
    return { items, nextCursor: rows.length > limit ? items.at(-1)!.id : null };
  }

  async devices(userId: number, query: NativeAnnotationHubDevicesQueryDto): Promise<NativeAnnotationHubDeviceResponse> {
    const limit = query.limit ?? 40;
    const conditions: SQL[] = [eq(nativeAnnotationAcks.userId, userId)];
    if (query.bookId !== undefined) conditions.push(eq(nativeAnnotationAcks.bookId, query.bookId));
    if (query.cursor) {
      const cursor = this.deviceCursor(query.cursor);
      conditions.push(
        or(
          gt(nativeAnnotationAcks.deviceId, cursor.deviceId),
          and(eq(nativeAnnotationAcks.deviceId, cursor.deviceId), gt(nativeAnnotationAcks.bookId, cursor.bookId)),
        )!,
      );
    }
    const rows = await this.db
      .select({
        deviceId: nativeAnnotationAcks.deviceId,
        bookId: nativeAnnotationAcks.bookId,
        cursor: nativeAnnotationAcks.cursor,
        updatedAt: nativeAnnotationAcks.updatedAt,
      })
      .from(nativeAnnotationAcks)
      .where(and(...conditions))
      .orderBy(asc(nativeAnnotationAcks.deviceId), asc(nativeAnnotationAcks.bookId))
      .limit(limit + 1);
    const items = rows.slice(0, limit).map((row) => ({ ...row, updatedAt: row.updatedAt.toISOString() }));
    const last = items.at(-1);
    return {
      items,
      nextCursor:
        rows.length > limit && last ? Buffer.from(JSON.stringify({ deviceId: last.deviceId, bookId: last.bookId })).toString('base64url') : null,
    };
  }

  async bulk(user: RequestUser, request: NativeAnnotationOperationsRequest) {
    if (request.operations.length === 0 || request.operations.some((operation) => operation.action !== 'delete' && operation.action !== 'restore')) {
      throw new BadRequestException('Bulk actions require delete or restore operations');
    }
    return this.mutate('annotation.native_bulk', user, request);
  }

  async repair(user: RequestUser, annotationId: number, request: NativeAnnotationOperationsRequest) {
    if (request.operations.length !== 1 || request.operations[0].action !== 'repair' || request.operations[0].annotationId !== annotationId) {
      throw new BadRequestException('Repair requires one explicit repair operation for this annotation');
    }
    if (!(await this.nativeAnnotations.getItem(annotationId, user.id))) throw new NotFoundException('Annotation not found');
    return this.mutate('annotation.native_repair', user, request);
  }

  private async mutate(event: string, user: RequestUser, request: NativeAnnotationOperationsRequest) {
    const started = Date.now();
    this.logger.log(`[${event}] [start] userId=${user.id} requested=${request.operations.length} - annotation operations started`);
    try {
      const result = await this.nativeAnnotations.operations(user, request);
      this.logger.log(
        `[${event}] [end] userId=${user.id} durationMs=${Date.now() - started} applied=${result.results.filter((item) => item.status === 'applied').length} recovery=${result.results.filter((item) => item.status === 'recovery').length} conflicts=${result.results.filter((item) => item.status === 'conflict').length} - annotation operations completed`,
      );
      return result;
    } catch (error) {
      this.logFailure(event, user.id, started, error);
      throw error;
    }
  }

  private queryRows(conditions: SQL[], group: SQL<string | number>) {
    const fileId = sql<
      number | null
    >`coalesce((select ap.book_file_id from annotation_positions ap where ap.annotation_id = ${annotations.id} and ap.user_id = ${annotations.userId} and ap.book_file_id is not null order by ap.id limit 1), ${books.primaryFileId})`;
    return this.db
      .select({
        id: annotations.id,
        bookTitle: bookMetadata.title,
        author: sql<
          string | null
        >`(select string_agg(${authors.name}, ', ' order by ${bookAuthors.displayOrder}) from ${bookAuthors} inner join ${authors} on ${authors.id} = ${bookAuthors.authorId} where ${bookAuthors.bookId} = ${annotations.bookId})`,
        fileFormat: sql<string | null>`(select ${bookFiles.format} from ${bookFiles} where ${bookFiles.id} = ${fileId})`,
        groupKey: group,
      })
      .from(annotations)
      .leftJoin(books, eq(books.id, annotations.bookId))
      .leftJoin(bookMetadata, eq(bookMetadata.bookId, annotations.bookId))
      .where(and(...conditions));
  }

  private async hydrate(
    userId: number,
    rows: { id: number; bookTitle: string | null; author: string | null; fileFormat: string | null; groupKey: string | number }[],
    hasMore: boolean,
  ): Promise<NativeAnnotationHubResponse> {
    const canonical = await this.nativeAnnotations.getItems(
      rows.map((row) => row.id),
      userId,
    );
    const byId = new Map(canonical.map((item) => [item.id, item]));
    return {
      items: rows.flatMap(({ id, ...metadata }) => {
        const item = byId.get(id);
        return item ? [{ ...item, ...metadata, groupKey: String(metadata.groupKey) }] : [];
      }),
      nextCursor: hasMore ? rows.at(-1)!.id : null,
    };
  }

  private conditions(userId: number, query: NativeAnnotationHubQueryDto): SQL[] {
    const conditions: SQL[] = [eq(annotations.userId, userId)];
    if (query.status === 'recovery') {
      conditions.push(
        exists(
          this.db
            .select({ id: nativeAnnotationDrafts.id })
            .from(nativeAnnotationDrafts)
            .where(and(eq(nativeAnnotationDrafts.userId, userId), eq(nativeAnnotationDrafts.annotationId, annotations.id))),
        ),
      );
    } else {
      conditions.push(query.status === 'trashed' ? isNotNull(annotations.deletedAt) : isNull(annotations.deletedAt));
    }
    if (query.bookId !== undefined) conditions.push(eq(annotations.bookId, query.bookId));
    if (query.kind) conditions.push(eq(annotations.kind, query.kind));
    if (query.fileId !== undefined)
      conditions.push(
        exists(
          this.db
            .select({ id: annotationPositions.id })
            .from(annotationPositions)
            .where(
              and(
                eq(annotationPositions.annotationId, annotations.id),
                eq(annotationPositions.userId, userId),
                eq(annotationPositions.bookFileId, query.fileId),
              ),
            ),
        ),
      );
    if (query.search) {
      const pattern = this.searchPattern(query.search);
      conditions.push(
        or(
          ilike(annotations.text, pattern),
          ilike(annotations.note, pattern),
          ilike(annotations.chapterTitle, pattern),
          ilike(bookMetadata.title, pattern),
        )!,
      );
    }
    return conditions;
  }

  private groupExpression(groupBy: NativeAnnotationHubQueryDto['groupBy']): SQL<string | number> {
    if (groupBy === 'book') return sql<number>`${annotations.bookId}`;
    if (groupBy === 'month') return sql<string>`to_char(${annotations.createdAt} at time zone 'UTC', 'YYYY-MM')`;
    if (groupBy === 'kind') return sql<string>`${annotations.kind}`;
    if (groupBy === 'source') return sql<string>`${annotations.origin}`;
    return sql<string>`''`;
  }

  private searchPattern(search: string) {
    return `%${search.replace(/[\\%_]/g, '\\$&')}%`;
  }

  private deviceCursor(value: string): { deviceId: string; bookId: number } {
    try {
      const parsed: unknown = JSON.parse(Buffer.from(value, 'base64url').toString('utf8'));
      if (
        typeof parsed !== 'object' ||
        parsed === null ||
        !('deviceId' in parsed) ||
        !('bookId' in parsed) ||
        typeof parsed.deviceId !== 'string' ||
        parsed.deviceId.length === 0 ||
        parsed.deviceId.length > 100 ||
        typeof parsed.bookId !== 'number' ||
        !Number.isSafeInteger(parsed.bookId) ||
        parsed.bookId < 1
      )
        throw new BadRequestException('Invalid device cursor');
      return { deviceId: parsed.deviceId, bookId: parsed.bookId };
    } catch {
      throw new BadRequestException('Invalid device cursor');
    }
  }

  private logFailure(event: string, userId: number, started: number, error: unknown) {
    this.logger.error(
      `[${event}] [fail] userId=${userId} durationMs=${Date.now() - started} errorClass=${error instanceof Error ? error.name : 'UnknownError'} error="${sanitizeLogValue(error instanceof Error ? error.message : 'Unknown error')}" - annotation operation failed`,
    );
  }
}
