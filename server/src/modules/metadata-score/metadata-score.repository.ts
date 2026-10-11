import { Inject, Injectable } from '@nestjs/common';
import { asc, count, eq, gt, inArray, sql } from 'drizzle-orm';
import type { NodePgDatabase } from 'drizzle-orm/node-postgres';

import { DB } from '../../db';
import * as schema from '../../db/schema';
import { bookAuthors, bookGenres, bookMetadata, bookTags } from '../../db/schema';
import type { ScoreData } from './metadata-score.scorer';

type Db = NodePgDatabase<typeof schema>;
export type MetadataScoreExecutor = Pick<Db, 'execute'>;

const METADATA_SCORE_BASE_SELECT = {
  title: bookMetadata.title,
  subtitle: bookMetadata.subtitle,
  description: bookMetadata.description,
  isbn10: bookMetadata.isbn10,
  isbn13: bookMetadata.isbn13,
  publisher: bookMetadata.publisher,
  publishedYear: bookMetadata.publishedYear,
  language: bookMetadata.language,
  pageCount: bookMetadata.pageCount,
  seriesName: bookMetadata.seriesName,
  seriesIndex: bookMetadata.seriesIndex,
  rating: bookMetadata.rating,
  coverSource: bookMetadata.coverSource,
  googleBooksId: bookMetadata.googleBooksId,
  goodreadsId: bookMetadata.goodreadsId,
  amazonId: bookMetadata.amazonId,
  hardcoverId: bookMetadata.hardcoverId,
  openLibraryId: bookMetadata.openLibraryId,
  itunesId: bookMetadata.itunesId,
  koboId: bookMetadata.koboId,
  aladinId: bookMetadata.aladinId,
} as const;

export type ScorePage = {
  rows: { bookId: number; data: ScoreData }[];
  nextCursor: number | null;
};

@Injectable()
export class MetadataScoreRepository {
  constructor(@Inject(DB) private readonly db: Db) {}

  async loadScoreData(bookId: number): Promise<ScoreData | null> {
    const [metaRow] = await this.db.select(METADATA_SCORE_BASE_SELECT).from(bookMetadata).where(eq(bookMetadata.bookId, bookId)).limit(1);
    if (!metaRow) return null;

    const [[{ authorCount }], [{ genreCount }], [{ tagCount }]] = await Promise.all([
      this.db.select({ authorCount: count() }).from(bookAuthors).where(eq(bookAuthors.bookId, bookId)),
      this.db.select({ genreCount: count() }).from(bookGenres).where(eq(bookGenres.bookId, bookId)),
      this.db.select({ tagCount: count() }).from(bookTags).where(eq(bookTags.bookId, bookId)),
    ]);

    return {
      ...metaRow,
      authorCount: Number(authorCount),
      genreCount: Number(genreCount),
      tagCount: Number(tagCount),
    };
  }

  async loadScoreDataPage(afterBookId: number | null, pageSize: number): Promise<ScorePage> {
    const selectShape = { bookId: bookMetadata.bookId, ...METADATA_SCORE_BASE_SELECT };
    const metaRows =
      afterBookId === null
        ? await this.db.select(selectShape).from(bookMetadata).orderBy(asc(bookMetadata.bookId)).limit(pageSize)
        : await this.db
            .select(selectShape)
            .from(bookMetadata)
            .where(gt(bookMetadata.bookId, afterBookId))
            .orderBy(asc(bookMetadata.bookId))
            .limit(pageSize);

    if (metaRows.length === 0) {
      return { rows: [], nextCursor: null };
    }

    const bookIds = metaRows.map((row) => row.bookId);
    const [authorCounts, genreCounts, tagCounts] = await Promise.all([
      this.db
        .select({ bookId: bookAuthors.bookId, cnt: count() })
        .from(bookAuthors)
        .where(inArray(bookAuthors.bookId, bookIds))
        .groupBy(bookAuthors.bookId),
      this.db
        .select({ bookId: bookGenres.bookId, cnt: count() })
        .from(bookGenres)
        .where(inArray(bookGenres.bookId, bookIds))
        .groupBy(bookGenres.bookId),
      this.db.select({ bookId: bookTags.bookId, cnt: count() }).from(bookTags).where(inArray(bookTags.bookId, bookIds)).groupBy(bookTags.bookId),
    ]);

    const authorMap = new Map(authorCounts.map((row) => [row.bookId, Number(row.cnt)]));
    const genreMap = new Map(genreCounts.map((row) => [row.bookId, Number(row.cnt)]));
    const tagMap = new Map(tagCounts.map((row) => [row.bookId, Number(row.cnt)]));

    const rows = metaRows.map((row) => ({
      bookId: row.bookId,
      data: {
        ...row,
        authorCount: authorMap.get(row.bookId) ?? 0,
        genreCount: genreMap.get(row.bookId) ?? 0,
        tagCount: tagMap.get(row.bookId) ?? 0,
      },
    }));

    return {
      rows,
      nextCursor: rows[rows.length - 1]?.bookId ?? null,
    };
  }

  async updateMetadataScore(bookId: number, score: number): Promise<void> {
    await this.db.update(bookMetadata).set({ metadataScore: score }).where(eq(bookMetadata.bookId, bookId));
  }

  async loadScoreDataMany(bookIds: number[], executor: MetadataScoreExecutor = this.db): Promise<ScorePage['rows']> {
    if (bookIds.length === 0) return [];
    const ids = sql.join(
      bookIds.map((id) => sql`${id}`),
      sql`, `,
    );
    const textFields = Object.entries(METADATA_SCORE_BASE_SELECT)
      .filter(([name]) => !['publishedYear', 'pageCount', 'seriesIndex', 'rating'].includes(name))
      .map(
        ([name, column]) =>
          sql`CASE WHEN length(btrim(selected.${sql.identifier(column.name)}, ${' \t\r\n\v\f\u00a0\u1680\u2000\u2001\u2002\u2003\u2004\u2005\u2006\u2007\u2008\u2009\u200a\u2028\u2029\u202f\u205f\u3000\ufeff'})) > 0 THEN 'present' ELSE NULL END AS ${sql.identifier(name)}`,
      );
    const result = await executor.execute<ScoreData & { bookId: number }>(sql`
      WITH selected AS MATERIALIZED (SELECT book_id, ${sql.join(
        Object.values(METADATA_SCORE_BASE_SELECT).map((column) => sql.identifier(column.name)),
        sql`, `,
      )} FROM book_metadata WHERE book_id IN (${ids})),
      author_counts AS (SELECT book_id, count(*)::int AS amount FROM book_authors WHERE book_id IN (${ids}) GROUP BY book_id),
      genre_counts AS (SELECT book_id, count(*)::int AS amount FROM book_genres WHERE book_id IN (${ids}) GROUP BY book_id),
      tag_counts AS (SELECT book_id, count(*)::int AS amount FROM book_tags WHERE book_id IN (${ids}) GROUP BY book_id)
      SELECT selected.book_id AS "bookId", ${sql.join(textFields, sql`, `)},
        selected.published_year AS "publishedYear", selected.page_count AS "pageCount",
        selected.series_index AS "seriesIndex", selected.rating,
        COALESCE(author_counts.amount, 0) AS "authorCount", COALESCE(genre_counts.amount, 0) AS "genreCount", COALESCE(tag_counts.amount, 0) AS "tagCount"
      FROM selected
      LEFT JOIN author_counts USING (book_id) LEFT JOIN genre_counts USING (book_id) LEFT JOIN tag_counts USING (book_id)
    `);
    return result.rows.map(({ bookId, ...data }) => ({ bookId, data }));
  }

  async updateMetadataScores(scores: { bookId: number; score: number }[], executor: MetadataScoreExecutor = this.db): Promise<void> {
    if (scores.length === 0) return;
    const values = sql.join(
      scores.map(({ bookId, score }) => sql`(${bookId}::int, ${score}::int)`),
      sql`, `,
    );
    await executor.execute(sql`UPDATE book_metadata SET metadata_score = scores.score
      FROM (VALUES ${values}) AS scores(book_id, score) WHERE book_metadata.book_id = scores.book_id`);
  }
}
