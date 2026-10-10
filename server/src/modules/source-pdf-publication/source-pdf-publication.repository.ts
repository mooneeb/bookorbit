import { Inject, Injectable } from '@nestjs/common';
import { and, eq, inArray } from 'drizzle-orm';
import type { NodePgDatabase } from 'drizzle-orm/node-postgres';

import { DB } from '../../db';
import * as schema from '../../db/schema';

@Injectable()
export class SourcePdfPublicationRepository {
  constructor(@Inject(DB) private readonly db: NodePgDatabase<typeof schema>) {}

  async findInkCreators(bookId: number, fileId: number, annotationIds: number[]): Promise<Map<number, number>> {
    if (!annotationIds.length) return new Map();
    const rows = await this.db
      .select({ id: schema.annotations.id, userId: schema.annotations.userId })
      .from(schema.annotations)
      .innerJoin(schema.annotationPositions, eq(schema.annotationPositions.annotationId, schema.annotations.id))
      .where(
        and(
          inArray(schema.annotations.id, annotationIds),
          eq(schema.annotations.bookId, bookId),
          eq(schema.annotations.kind, 'pdf_ink'),
          eq(schema.annotationPositions.bookFileId, fileId),
          eq(schema.annotationPositions.format, 'pdf'),
        ),
      );
    return new Map(rows.map((row) => [row.id, row.userId]));
  }

  async updatePublishedFile(
    bookId: number,
    fileId: number,
    fields: { fileHash: string; mtime: Date; sizeBytes: number; ino: bigint },
  ): Promise<void> {
    await this.db
      .update(schema.bookFiles)
      .set({ ...fields, updatedAt: new Date() })
      .where(and(eq(schema.bookFiles.id, fileId), eq(schema.bookFiles.bookId, bookId)));
  }
}
