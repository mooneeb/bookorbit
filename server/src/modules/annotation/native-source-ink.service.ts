import { BadRequestException, Inject, Injectable } from '@nestjs/common';
import type {
  NativeAnnotationDelta,
  NativeAnnotationItem,
  NativeAnnotationOperationsRequest,
  NativeAnnotationOperationsResponse,
  NativeSourceInkWindowResponse,
} from '@bookorbit/types';
import { and, asc, count, eq, gt, isNull, sql } from 'drizzle-orm';
import type { NodePgDatabase } from 'drizzle-orm/node-postgres';
import type { RequestUser } from '../../common/types/request-user';
import { DB } from '../../db';
import * as schema from '../../db/schema';
import { BookService } from '../book/book.service';
import { NativeAnnotationService } from './native-annotation.service';
import type { NativeSourceInkQueryDto, NativeSourceInkScopeDto, NativeSourceInkWindowQueryDto } from './dto/native-source-ink.dto';

@Injectable()
export class NativeSourceInkService {
  constructor(
    @Inject(DB) private readonly db: NodePgDatabase<typeof schema>,
    private readonly bookService: BookService,
    private readonly annotations: NativeAnnotationService,
  ) {}

  async window(user: RequestUser, query: NativeSourceInkWindowQueryDto): Promise<NativeSourceInkWindowResponse> {
    await this.bookService.verifyBookAccess(query.bookId, user);
    const file = await this.bookService.verifyFileAccess(query.bookFileId, user);
    if (file.bookId !== query.bookId || file.format !== 'pdf') {
      throw new BadRequestException('Source ink requires the selected PDF file');
    }
    const window = query.window ?? 1;
    const limit = query.limit ?? 100;
    const conditions = and(
      eq(schema.annotations.bookId, query.bookId),
      eq(schema.annotations.kind, 'pdf_ink'),
      isNull(schema.annotations.deletedAt),
      eq(schema.annotationPositions.bookFileId, query.bookFileId),
      eq(schema.annotationPositions.format, 'pdf'),
      sql`${schema.annotationPositions.extras}->>'pageno' = ${String(query.page + 1)}`,
    );
    const join = eq(schema.annotationPositions.annotationId, schema.annotations.id);
    const rows = await this.db
      .select({
        id: schema.annotations.id,
        bookId: schema.annotations.bookId,
        clientId: schema.annotations.clientId,
        kind: schema.annotations.kind,
        version: schema.annotations.version,
        sourceRevision: schema.annotations.sourceRevision,
        pageFingerprint: schema.annotations.pageFingerprint,
        color: schema.annotations.color,
        style: schema.annotations.style,
        origin: schema.annotations.origin,
        createdAt: schema.annotations.createdAt,
        updatedAt: schema.annotations.updatedAt,
        sourceCreatedAt: schema.annotations.sourceCreatedAt,
        pdf: schema.annotationPositions.pos0,
        positionStatus: schema.annotationPositions.status,
        total: sql<number>`count(*) over()`,
      })
      .from(schema.annotations)
      .innerJoin(schema.annotationPositions, join)
      .where(conditions)
      .orderBy(asc(schema.annotations.id))
      .limit(limit)
      .offset((window - 1) * limit);
    let total = Number(rows[0]?.total ?? 0);
    if (!rows.length && window > 1) {
      const [result] = await this.db
        .select({ total: count() })
        .from(schema.annotations)
        .innerJoin(schema.annotationPositions, join)
        .where(conditions);
      total = result?.total ?? 0;
    }
    const items = rows.map((row): NativeAnnotationItem => {
      let pdf: NativeAnnotationItem['pdf'];
      try {
        pdf = row.pdf ? JSON.parse(row.pdf) : null;
      } catch {
        pdf = null;
      }
      return {
        id: row.id,
        bookId: row.bookId,
        clientId: row.clientId,
        kind: row.kind,
        version: row.version,
        drawing: null,
        deletedAt: null,
        sourceRevision: row.sourceRevision,
        pageFingerprint: row.pageFingerprint,
        pdf,
        pageno: query.page + 1,
        jumpFileId: query.bookFileId,
        cfi: null,
        text: '',
        note: null,
        chapterTitle: null,
        chapterIndex: null,
        starredAt: null,
        color: row.color,
        style: row.style,
        origin: row.origin,
        positionStatus: row.positionStatus,
        highlightedAt: (row.sourceCreatedAt ?? row.createdAt).toISOString(),
        createdAt: row.createdAt.toISOString(),
        updatedAt: row.updatedAt.toISOString(),
      };
    });
    return { items, total, window, limit };
  }

  async delta(user: RequestUser, query: NativeSourceInkQueryDto): Promise<NativeAnnotationDelta> {
    await this.bookService.verifyBookAccess(query.bookId, user);
    const file = await this.bookService.verifyFileAccess(query.bookFileId, user);
    if (file.bookId !== query.bookId || file.format !== 'pdf') {
      throw new BadRequestException('Source ink requires the selected PDF file');
    }
    const cursor = Number(query.cursor ?? 0);
    const limit = Math.min(query.limit ?? 100, 100);
    const rows = await this.db
      .select({ id: schema.annotations.id, sequence: schema.annotations.changeSequence })
      .from(schema.annotations)
      .innerJoin(schema.annotationPositions, eq(schema.annotationPositions.annotationId, schema.annotations.id))
      .where(
        and(
          eq(schema.annotations.bookId, query.bookId),
          eq(schema.annotations.kind, 'pdf_ink'),
          gt(schema.annotations.changeSequence, cursor),
          eq(schema.annotationPositions.bookFileId, query.bookFileId),
          eq(schema.annotationPositions.format, 'pdf'),
          ...(query.page !== undefined ? [sql`${schema.annotationPositions.extras}->>'pageno' = ${String(query.page + 1)}`] : []),
        ),
      )
      .orderBy(asc(schema.annotations.changeSequence))
      .limit(limit + 1);
    const page = rows.slice(0, limit);
    const items = await this.annotations.getSourceItems(
      query.bookId,
      page.map((item) => item.id),
      user,
    );
    return {
      items: items.filter((item) => item.jumpFileId === query.bookFileId && (query.page === undefined || item.pdf?.page === query.page)),
      nextCursor: String(page.at(-1)?.sequence ?? cursor),
      hasMore: rows.length > limit,
    };
  }

  operations(user: RequestUser, scope: NativeSourceInkScopeDto, dto: NativeAnnotationOperationsRequest): Promise<NativeAnnotationOperationsResponse> {
    return this.annotations.sourceInkOperations(user, scope, dto);
  }
}
