import { Inject, Injectable } from '@nestjs/common';
import type { BroadReadingGenre, ReadingInsightsSharingLevel, ReadingSessionSource } from '@bookorbit/types';
import { and, desc, eq, exists, gte, gt, inArray, lte, ne, sql } from 'drizzle-orm';
import type { NodePgDatabase } from 'drizzle-orm/node-postgres';

import type { RequestUser } from '../../common/types/request-user';
import { buildContentFilterClauses } from '../../common/utils/content-filter-sql.utils';
import { DB } from '../../db';
import * as schema from '../../db/schema';

type Db = NodePgDatabase<typeof schema>;

@Injectable()
export class SharedReadingInsightsRepository {
  constructor(@Inject(DB) private readonly db: Db) {}

  getSharingSettings(userId: number) {
    return this.db.query.users.findFirst({
      columns: { id: true, readingInsightsSharingLevel: true, readingInsightsConsentedAt: true },
      where: eq(schema.users.id, userId),
    });
  }

  async updateSharingSettings(userId: number, sharingLevel: ReadingInsightsSharingLevel, consentedAt: Date | null) {
    return this.db.transaction(async (tx) => {
      const [row] = await tx
        .update(schema.users)
        .set({ readingInsightsSharingLevel: sharingLevel, readingInsightsConsentedAt: consentedAt })
        .where(eq(schema.users.id, userId))
        .returning({
          sharingLevel: schema.users.readingInsightsSharingLevel,
          consentedAt: schema.users.readingInsightsConsentedAt,
        });
      if (row && sharingLevel === 'private') {
        await tx.delete(schema.sharedReadingInsightViewSessions).where(eq(schema.sharedReadingInsightViewSessions.subjectUserId, userId));
      }
      return row;
    });
  }

  createViewSession(values: typeof schema.sharedReadingInsightViewSessions.$inferInsert) {
    return this.db.transaction(async (tx) => {
      const [subject] = await tx
        .select({ sharingLevel: schema.users.readingInsightsSharingLevel })
        .from(schema.users)
        .where(eq(schema.users.id, values.subjectUserId))
        .for('share');
      if (!subject || subject.sharingLevel === 'private' || subject.sharingLevel !== values.sharingLevel) return false;
      const expiredSessions = tx
        .select({ id: schema.sharedReadingInsightViewSessions.id })
        .from(schema.sharedReadingInsightViewSessions)
        .where(lte(schema.sharedReadingInsightViewSessions.expiresAt, new Date()))
        .limit(1000);
      await tx.delete(schema.sharedReadingInsightViewSessions).where(inArray(schema.sharedReadingInsightViewSessions.id, expiredSessions));
      await tx.insert(schema.sharedReadingInsightViewSessions).values(values);
      return true;
    });
  }

  getViewSession(id: string, viewerUserId: number, subjectUserId: number) {
    return this.db.query.sharedReadingInsightViewSessions.findFirst({
      where: and(
        eq(schema.sharedReadingInsightViewSessions.id, id),
        eq(schema.sharedReadingInsightViewSessions.viewerUserId, viewerUserId),
        eq(schema.sharedReadingInsightViewSessions.subjectUserId, subjectUserId),
        gt(schema.sharedReadingInsightViewSessions.expiresAt, new Date()),
      ),
    });
  }

  async getSummary(userId: number, days: number, viewer?: RequestUser) {
    const since = this.since(days);
    const bookScope = this.bookScope(viewer);
    const broadGenre = sql<BroadReadingGenre>`case
      when lower(${schema.genres.name}) ~ '(science[ -]?fiction|sci[ -]?fi|wissenschaftliche fiktion|znanstvena fantastika)' then 'science_fiction'
      when lower(${schema.genres.name}) ~ '(fantasy|fantastik|fantasie|fantaz)' then 'fantasy'
      when lower(${schema.genres.name}) ~ '(mystery|thriller|crime|krimi|misdaad|misterij|triler)' then 'mystery_thriller'
      when lower(${schema.genres.name}) ~ '(romance|romantik|romantiek|ljubezen)' then 'romance'
      when lower(${schema.genres.name}) ~ '(horror|grozljiv)' then 'horror'
      when lower(${schema.genres.name}) ~ '(history|histor|geschichte|geschiedenis|zgodovin|biograph|biograf|memoir)' then 'history_biography'
      when lower(${schema.genres.name}) ~ '(science|wissenschaft|wetenschap|znanost|technology|technologie|tehnolog)' then 'science_technology'
      when lower(${schema.genres.name}) ~ '(business|wirtschaft|bedrijf|poslov|econom|ökonom|ekonom)' then 'business_economics'
      when lower(${schema.genres.name}) ~ '(self[ -]?help|personal development|selbsthilfe|zelfhulp|samopomoč)' then 'self_development'
      when lower(${schema.genres.name}) ~ '(society|culture|gesellschaft|maatschapp|družb|kultur|politic|politik|philos|relig)' then 'society_culture'
      when lower(${schema.genres.name}) ~ '(children|young adult|kinder|jugend|kinderen|jeugd|otro|mladin)' then 'children_young_adult'
      when lower(${schema.genres.name}) ~ '(comic|graphic novel|strip|risoroman)' then 'comics_graphic_novels'
      when lower(${schema.genres.name}) ~ '(poetry|lyrik|poëzie|poez)' then 'poetry'
      else 'other'
    end`;
    const genreSessions = this.db
      .select({
        sessionId: schema.readingSessions.id,
        name: broadGenre.as('name'),
        readingSeconds: schema.readingSessions.durationSeconds,
      })
      .from(schema.readingSessions)
      .innerJoin(schema.bookGenres, eq(schema.bookGenres.bookId, schema.readingSessions.bookId))
      .innerJoin(schema.genres, eq(schema.genres.id, schema.bookGenres.genreId))
      .where(
        and(
          eq(schema.readingSessions.userId, userId),
          gte(schema.readingSessions.startedAt, since),
          inArray(schema.readingSessions.bookId, bookScope),
        ),
      )
      .groupBy(schema.readingSessions.id, schema.readingSessions.durationSeconds, broadGenre)
      .as('genre_sessions');
    const [daily, statusRows, formats, genres, sources] = await Promise.all([
      this.db
        .select({
          day: sql<string>`to_char(${schema.readingSessions.startedAt} at time zone 'UTC', 'YYYY-MM-DD')`,
          readingSeconds: sql<number>`coalesce(sum(${schema.readingSessions.durationSeconds}), 0)::int`,
          sessionsCount: sql<number>`count(*)::int`,
        })
        .from(schema.readingSessions)
        .where(
          and(
            eq(schema.readingSessions.userId, userId),
            gte(schema.readingSessions.startedAt, since),
            inArray(schema.readingSessions.bookId, bookScope),
          ),
        )
        .groupBy(sql`to_char(${schema.readingSessions.startedAt} at time zone 'UTC', 'YYYY-MM-DD')`)
        .orderBy(sql`to_char(${schema.readingSessions.startedAt} at time zone 'UTC', 'YYYY-MM-DD')`),
      this.db
        .select({
          booksStarted: sql<number>`count(*) filter (where ${schema.userBookStatus.startedAt} >= ${since})::int`,
          booksCompleted: sql<number>`count(*) filter (where ${schema.userBookStatus.finishedAt} >= ${since})::int`,
        })
        .from(schema.userBookStatus)
        .where(and(eq(schema.userBookStatus.userId, userId), inArray(schema.userBookStatus.bookId, bookScope))),
      this.db
        .select({
          name: sql<string>`coalesce(upper(${schema.bookFiles.format}), 'UNKNOWN')`,
          readingSeconds: sql<number>`sum(${schema.readingSessions.durationSeconds})::int`,
        })
        .from(schema.readingSessions)
        .leftJoin(schema.bookFiles, eq(schema.bookFiles.id, schema.readingSessions.bookFileId))
        .where(
          and(
            eq(schema.readingSessions.userId, userId),
            gte(schema.readingSessions.startedAt, since),
            inArray(schema.readingSessions.bookId, bookScope),
          ),
        )
        .groupBy(sql`coalesce(upper(${schema.bookFiles.format}), 'UNKNOWN')`)
        .orderBy(desc(sql`sum(${schema.readingSessions.durationSeconds})`))
        .limit(10),
      this.db
        .select({
          name: genreSessions.name,
          readingSeconds: sql<number>`sum(${genreSessions.readingSeconds})::int`,
        })
        .from(genreSessions)
        .groupBy(genreSessions.name)
        .orderBy(desc(sql`sum(${genreSessions.readingSeconds})`))
        .limit(14),
      this.db
        .select({
          source: sql<ReadingSessionSource | 'unknown'>`coalesce(${schema.readingSessions.source}, 'unknown')`,
          readingSeconds: sql<number>`sum(${schema.readingSessions.durationSeconds})::int`,
          sessionsCount: sql<number>`count(*)::int`,
        })
        .from(schema.readingSessions)
        .where(
          and(
            eq(schema.readingSessions.userId, userId),
            gte(schema.readingSessions.startedAt, since),
            inArray(schema.readingSessions.bookId, bookScope),
          ),
        )
        .groupBy(schema.readingSessions.source)
        .orderBy(desc(sql`sum(${schema.readingSessions.durationSeconds})`)),
    ]);

    return { daily, status: statusRows[0] ?? { booksStarted: 0, booksCompleted: 0 }, formats, genres, sources };
  }

  async getDetail(userId: number, days: number, viewer?: RequestUser) {
    const since = this.since(days);
    const bookScope = this.bookScope(viewer);
    const [topBooks, recentBooks, topAuthors, topGenres, topSeries, topNarrators] = await Promise.all([
      this.bookRanking(userId, since, 'reading', viewer),
      this.bookRanking(userId, since, 'recent', viewer),
      this.db
        .select({ name: schema.authors.name, readingSeconds: sql<number>`sum(${schema.readingSessions.durationSeconds})::int` })
        .from(schema.readingSessions)
        .innerJoin(schema.bookAuthors, eq(schema.bookAuthors.bookId, schema.readingSessions.bookId))
        .innerJoin(schema.authors, eq(schema.authors.id, schema.bookAuthors.authorId))
        .where(
          and(
            eq(schema.readingSessions.userId, userId),
            gte(schema.readingSessions.startedAt, since),
            inArray(schema.readingSessions.bookId, bookScope),
          ),
        )
        .groupBy(schema.authors.id, schema.authors.name)
        .orderBy(desc(sql`sum(${schema.readingSessions.durationSeconds})`))
        .limit(10),
      this.db
        .select({ name: schema.genres.name, readingSeconds: sql<number>`sum(${schema.readingSessions.durationSeconds})::int` })
        .from(schema.readingSessions)
        .innerJoin(schema.bookGenres, eq(schema.bookGenres.bookId, schema.readingSessions.bookId))
        .innerJoin(schema.genres, eq(schema.genres.id, schema.bookGenres.genreId))
        .where(
          and(
            eq(schema.readingSessions.userId, userId),
            gte(schema.readingSessions.startedAt, since),
            inArray(schema.readingSessions.bookId, bookScope),
          ),
        )
        .groupBy(schema.genres.id, schema.genres.name)
        .orderBy(desc(sql`sum(${schema.readingSessions.durationSeconds})`))
        .limit(10),
      this.db
        .select({ name: schema.bookSeries.name, readingSeconds: sql<number>`sum(${schema.readingSessions.durationSeconds})::int` })
        .from(schema.readingSessions)
        .innerJoin(schema.bookSeriesMemberships, eq(schema.bookSeriesMemberships.bookId, schema.readingSessions.bookId))
        .innerJoin(schema.bookSeries, eq(schema.bookSeries.id, schema.bookSeriesMemberships.seriesId))
        .where(
          and(
            eq(schema.readingSessions.userId, userId),
            gte(schema.readingSessions.startedAt, since),
            inArray(schema.readingSessions.bookId, bookScope),
          ),
        )
        .groupBy(schema.bookSeries.id, schema.bookSeries.name)
        .orderBy(desc(sql`sum(${schema.readingSessions.durationSeconds})`))
        .limit(10),
      this.db
        .select({ name: schema.narrators.name, readingSeconds: sql<number>`sum(${schema.readingSessions.durationSeconds})::int` })
        .from(schema.readingSessions)
        .innerJoin(schema.bookNarrators, eq(schema.bookNarrators.bookId, schema.readingSessions.bookId))
        .innerJoin(schema.narrators, eq(schema.narrators.id, schema.bookNarrators.narratorId))
        .where(
          and(
            eq(schema.readingSessions.userId, userId),
            gte(schema.readingSessions.startedAt, since),
            inArray(schema.readingSessions.bookId, bookScope),
          ),
        )
        .groupBy(schema.narrators.id, schema.narrators.name)
        .orderBy(desc(sql`sum(${schema.readingSessions.durationSeconds})`))
        .limit(10),
    ]);
    return { topBooks, recentBooks, topAuthors, topGenres, topSeries, topNarrators };
  }

  private bookRanking(userId: number, since: Date, order: 'reading' | 'recent', viewer?: RequestUser) {
    const bookScope = this.bookScope(viewer);
    const readingSeconds = sql<number>`sum(${schema.readingSessions.durationSeconds})::int`;
    const lastReadAt = sql<Date>`max(${schema.readingSessions.endedAt})`;
    return this.db
      .select({
        bookId: schema.readingSessions.bookId,
        title: schema.bookMetadata.title,
        readingSeconds,
        lastReadAt,
        status: schema.userBookStatus.status,
      })
      .from(schema.readingSessions)
      .leftJoin(schema.bookMetadata, eq(schema.bookMetadata.bookId, schema.readingSessions.bookId))
      .leftJoin(schema.userBookStatus, and(eq(schema.userBookStatus.bookId, schema.readingSessions.bookId), eq(schema.userBookStatus.userId, userId)))
      .where(
        and(
          eq(schema.readingSessions.userId, userId),
          gte(schema.readingSessions.startedAt, since),
          inArray(schema.readingSessions.bookId, bookScope),
        ),
      )
      .groupBy(schema.readingSessions.bookId, schema.bookMetadata.title, schema.userBookStatus.status)
      .orderBy(desc(order === 'reading' ? readingSeconds : lastReadAt))
      .limit(10);
  }

  private bookScope(viewer?: RequestUser) {
    const clauses = [ne(schema.books.status, 'processing')];
    if (viewer && !viewer.isSuperuser) {
      clauses.push(
        exists(
          this.db
            .select({ one: sql`1` })
            .from(schema.userLibraryAccess)
            .where(and(eq(schema.userLibraryAccess.userId, viewer.id), eq(schema.userLibraryAccess.libraryId, schema.books.libraryId))),
        ),
        ...buildContentFilterClauses(viewer.contentFilters, this.db),
      );
    }
    return this.db
      .select({ id: schema.books.id })
      .from(schema.books)
      .where(and(...clauses));
  }

  private since(days: number): Date {
    const since = new Date();
    since.setUTCHours(0, 0, 0, 0);
    since.setUTCDate(since.getUTCDate() - (days - 1));
    return since;
  }
}
