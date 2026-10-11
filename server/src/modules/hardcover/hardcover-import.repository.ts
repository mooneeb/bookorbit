import { Inject, Injectable } from '@nestjs/common';
import type { ContentFilterRules, ReadStatus } from '@bookorbit/types';
import { and, asc, eq, exists, inArray, or, sql, type SQL } from 'drizzle-orm';
import type { NodePgDatabase } from 'drizzle-orm/node-postgres';
import { buildContentFilterClauses } from '../../common/utils/content-filter-sql.utils';
import { DB } from '../../db';
import * as schema from '../../db/schema';
import type { HardcoverImportLocalBook } from './hardcover.repository';

type Db = NodePgDatabase<typeof schema>;
const CANDIDATE_LIMIT = 2000;

export interface HardcoverImportIdentity {
  hardcoverId: number;
  slug: string | null;
  isbns: string[];
  title: string | null;
  authors: string[];
}

@Injectable()
export class HardcoverImportRepository {
  constructor(@Inject(DB) private readonly db: Db) {}

  async findCandidates(userId: number, libraryIds: number[], filters: ContentFilterRules | undefined, identities: HardcoverImportIdentity[]) {
    if (!libraryIds.length || !identities.length) return { books: [], exactTruncated: false, fuzzyTruncated: false };
    const ids = identities.map((identity) => identity.hardcoverId);
    const metadataIds = identities.flatMap((identity) => [String(identity.hardcoverId), ...(identity.slug ? [identity.slug.toLowerCase()] : [])]);
    const isbns = identities.flatMap((identity) => identity.isbns);
    const exact = or(
      inArray(sql`lower(trim(${schema.bookMetadata.hardcoverId}))`, metadataIds),
      ...(isbns.length
        ? [
            inArray(sql`regexp_replace(upper(${schema.bookMetadata.isbn13}), '[^0-9X]', '', 'g')`, isbns),
            inArray(sql`regexp_replace(upper(${schema.bookMetadata.isbn10}), '[^0-9X]', '', 'g')`, isbns),
          ]
        : []),
      exists(
        this.db
          .select({ id: schema.hardcoverBookState.bookId })
          .from(schema.hardcoverBookState)
          .where(
            and(
              eq(schema.hardcoverBookState.bookId, schema.books.id),
              eq(schema.hardcoverBookState.userId, userId),
              inArray(schema.hardcoverBookState.hardcoverBookId, ids),
              sql`${schema.hardcoverBookState.matchError} is null`,
            ),
          ),
      ),
    )!;
    const fuzzyClauses: SQL[] = identities.flatMap((identity) => {
      if (!identity.title || !identity.authors.length) return [];
      const clauses: SQL[] = [sql`${schema.bookMetadata.title} % ${identity.title}`];
      for (const author of identity.authors) {
        const token = author
          .toLowerCase()
          .match(/[\p{L}\p{N}]+/gu)
          ?.filter((word) => word.length >= 3)
          .at(-1);
        if (!token) continue;
        clauses.push(
          exists(
            this.db
              .select({ id: schema.bookAuthors.bookId })
              .from(schema.bookAuthors)
              .innerJoin(schema.authors, eq(schema.authors.id, schema.bookAuthors.authorId))
              .where(
                and(
                  eq(schema.bookAuthors.bookId, schema.books.id),
                  or(sql`${schema.authors.name} % ${author}`, sql`strpos(lower(${schema.authors.name}), ${token}) > 0`),
                ),
              ),
          ),
        );
      }
      return clauses;
    });
    const filtersSql = filters ? buildContentFilterClauses(filters, this.db) : [];
    const findIds = (condition: SQL) =>
      this.db
        .select({ id: schema.books.id })
        .from(schema.books)
        .leftJoin(schema.bookMetadata, eq(schema.bookMetadata.bookId, schema.books.id))
        .where(and(inArray(schema.books.libraryId, libraryIds), eq(schema.books.status, 'present'), ...filtersSql, condition))
        .orderBy(asc(schema.books.id))
        .limit(CANDIDATE_LIMIT + 1);
    const exactIds = await findIds(exact);
    const fuzzyIds = fuzzyClauses.length ? await findIds(or(...fuzzyClauses)!) : [];
    const candidateIds = [...new Set([...exactIds.slice(0, CANDIDATE_LIMIT), ...fuzzyIds.slice(0, CANDIDATE_LIMIT)].map((row) => row.id))];
    return {
      books: await this.findImportCandidateBooks(userId, libraryIds, filters, candidateIds),
      exactTruncated: exactIds.length > CANDIDATE_LIMIT,
      fuzzyTruncated: fuzzyIds.length > CANDIDATE_LIMIT,
    };
  }

  private async findImportCandidateBooks(
    userId: number,
    accessibleLibraryIds: number[],
    contentFilters: ContentFilterRules | undefined,
    candidateIds: number[],
  ): Promise<HardcoverImportLocalBook[]> {
    if (accessibleLibraryIds.length === 0 || candidateIds.length === 0) return [];

    const contentFilterClauses = contentFilters ? buildContentFilterClauses(contentFilters, this.db) : [];
    const maxProgressSq = this.db
      .select({
        bookId: schema.bookFiles.bookId,
        maxProgress: sql<number>`max(${schema.readingProgress.percentage})`.as('max_progress'),
      })
      .from(schema.bookFiles)
      .innerJoin(schema.readingProgress, and(eq(schema.readingProgress.bookFileId, schema.bookFiles.id), eq(schema.readingProgress.userId, userId)))
      .where(inArray(schema.bookFiles.bookId, candidateIds))
      .groupBy(schema.bookFiles.bookId)
      .as('import_max_progress_sq');

    const rows = await this.db
      .select({
        bookId: schema.books.id,
        primaryFileId: schema.books.primaryFileId,
        primaryFileFormat: schema.bookFiles.format,
        title: schema.bookMetadata.title,
        isbn13: schema.bookMetadata.isbn13,
        isbn10: schema.bookMetadata.isbn10,
        hardcoverMetadataId: schema.bookMetadata.hardcoverId,
        authorsCsv: sql<string>`coalesce(string_agg(${schema.authors.name}, '||' order by ${schema.bookAuthors.displayOrder}, ${schema.bookAuthors.authorId}), '')`,
        status: schema.userBookStatus.status,
        startedAt: schema.userBookStatus.startedAt,
        finishedAt: schema.userBookStatus.finishedAt,
        progress: maxProgressSq.maxProgress,
      })
      .from(schema.books)
      .leftJoin(schema.bookMetadata, eq(schema.bookMetadata.bookId, schema.books.id))
      .leftJoin(schema.bookAuthors, eq(schema.bookAuthors.bookId, schema.books.id))
      .leftJoin(schema.authors, eq(schema.authors.id, schema.bookAuthors.authorId))
      .leftJoin(schema.userBookStatus, and(eq(schema.userBookStatus.bookId, schema.books.id), eq(schema.userBookStatus.userId, userId)))
      .leftJoin(schema.bookFiles, eq(schema.bookFiles.id, schema.books.primaryFileId))
      .leftJoin(maxProgressSq, eq(maxProgressSq.bookId, schema.books.id))
      .where(
        and(
          inArray(schema.books.libraryId, accessibleLibraryIds),
          eq(schema.books.status, 'present'),
          inArray(schema.books.id, candidateIds),
          ...contentFilterClauses,
        ),
      )
      .groupBy(
        schema.books.id,
        schema.books.primaryFileId,
        schema.bookFiles.format,
        schema.bookMetadata.title,
        schema.bookMetadata.isbn13,
        schema.bookMetadata.isbn10,
        schema.bookMetadata.hardcoverId,
        schema.userBookStatus.status,
        schema.userBookStatus.startedAt,
        schema.userBookStatus.finishedAt,
        maxProgressSq.maxProgress,
      );

    return rows.map((row) => ({
      bookId: row.bookId,
      primaryFileId: row.primaryFileId,
      primaryFileFormat: row.primaryFileFormat,
      title: row.title,
      isbn13: row.isbn13,
      isbn10: row.isbn10,
      hardcoverMetadataId: row.hardcoverMetadataId,
      authors: row.authorsCsv ? row.authorsCsv.split('||').filter((author) => author.length > 0) : [],
      status: row.status as ReadStatus | null,
      startedAt: row.startedAt,
      finishedAt: row.finishedAt,
      progress: row.progress,
    }));
  }
}
