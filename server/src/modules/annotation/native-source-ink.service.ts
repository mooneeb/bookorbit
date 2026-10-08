import { BadRequestException, Inject, Injectable } from '@nestjs/common';
import type { NativeAnnotationDelta, NativeAnnotationOperationsRequest, NativeAnnotationOperationsResponse } from '@bookorbit/types';
import { and, asc, eq, gt, sql } from 'drizzle-orm';
import type { NodePgDatabase } from 'drizzle-orm/node-postgres';
import type { RequestUser } from '../../common/types/request-user';
import { DB } from '../../db';
import * as schema from '../../db/schema';
import { BookService } from '../book/book.service';
import { NativeAnnotationService } from './native-annotation.service';
import type { NativeSourceInkQueryDto, NativeSourceInkScopeDto } from './dto/native-source-ink.dto';

@Injectable()
export class NativeSourceInkService {
  constructor(
    @Inject(DB) private readonly db: NodePgDatabase<typeof schema>,
    private readonly bookService: BookService,
    private readonly annotations: NativeAnnotationService,
  ) {}

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
