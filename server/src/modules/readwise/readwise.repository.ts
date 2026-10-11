import { Inject, Injectable } from '@nestjs/common';
import { Permission } from '@bookorbit/types';
import { and, asc, eq, exists, gt, isNotNull, isNull, lt, ne, or, sql } from 'drizzle-orm';
import type { NodePgDatabase } from 'drizzle-orm/node-postgres';

import { DB } from '../../db';
import { buildContentFilterClauses } from '../../common/utils/content-filter-sql.utils';
import * as schema from '../../db/schema';
import type { NewReadwiseUserSetting, ReadwiseUserSetting } from '../../db/schema';

type Db = NodePgDatabase<typeof schema>;

export interface NewHighlightRow {
  annotationId: number;
  bookId: number;
  text: string;
  note: string | null;
  createdAt: Date;
  title: string | null;
  author: string; // joined, may be ''
  isbn13: string | null;
  isbn10: string | null;
}

@Injectable()
export class ReadwiseRepository {
  constructor(@Inject(DB) private readonly db: Db) {}

  async findSettings(userId: number): Promise<ReadwiseUserSetting | undefined> {
    return this.db.query.readwiseUserSettings.findFirst({
      where: eq(schema.readwiseUserSettings.userId, userId),
    });
  }

  async findLatestAnnotationId(userId: number): Promise<number> {
    const [row] = await this.db
      .select({ latestAnnotationId: sql<number>`coalesce(max(${schema.annotations.id}), 0)::int` })
      .from(schema.annotations)
      .where(eq(schema.annotations.userId, userId))
      .limit(1);

    return row?.latestAnnotationId ?? 0;
  }

  async upsertSettings(
    userId: number,
    data: Partial<Omit<ReadwiseUserSetting, 'id' | 'userId' | 'createdAt' | 'updatedAt'>>,
  ): Promise<ReadwiseUserSetting> {
    const [row] = await this.db
      .insert(schema.readwiseUserSettings)
      .values({ userId, ...data } as NewReadwiseUserSetting)
      .onConflictDoUpdate({
        target: schema.readwiseUserSettings.userId,
        set: { ...data, updatedAt: new Date() },
      })
      .returning();
    return row!;
  }

  async userHasReadwiseSyncPermission(userId: number): Promise<boolean> {
    const [row] = await this.db
      .select({
        isSuperuser: schema.users.isSuperuser,
        permissionName: schema.userPermissions.permissionName,
      })
      .from(schema.users)
      .leftJoin(
        schema.userPermissions,
        and(eq(schema.userPermissions.userId, schema.users.id), eq(schema.userPermissions.permissionName, Permission.ReadwiseSync)),
      )
      .where(and(eq(schema.users.id, userId), eq(schema.users.active, true)))
      .limit(1);
    return row?.isSuperuser === true || row?.permissionName === Permission.ReadwiseSync;
  }

  async findNewHighlights(userId: number, afterId: number, limit: number): Promise<NewHighlightRow[]> {
    const eligibility = await this.highlightEligibility(userId, afterId);
    const rows = await this.db
      .select({
        annotationId: schema.annotations.id,
        bookId: schema.annotations.bookId,
        text: schema.annotations.text,
        note: schema.annotations.note,
        createdAt: schema.annotations.createdAt,
        title: schema.bookMetadata.title,
        isbn13: schema.bookMetadata.isbn13,
        isbn10: schema.bookMetadata.isbn10,
        authorsCsv: sql<string>`coalesce(string_agg(${schema.authors.name}, '||' order by ${schema.bookAuthors.displayOrder}, ${schema.bookAuthors.authorId}), '')`,
      })
      .from(schema.annotations)
      .innerJoin(schema.books, eq(schema.books.id, schema.annotations.bookId))
      .leftJoin(schema.bookMetadata, eq(schema.bookMetadata.bookId, schema.annotations.bookId))
      .leftJoin(schema.bookAuthors, eq(schema.bookAuthors.bookId, schema.annotations.bookId))
      .leftJoin(schema.authors, eq(schema.authors.id, schema.bookAuthors.authorId))
      .where(eligibility)
      .groupBy(
        schema.annotations.id,
        schema.annotations.bookId,
        schema.annotations.text,
        schema.annotations.note,
        schema.annotations.createdAt,
        schema.bookMetadata.title,
        schema.bookMetadata.isbn13,
        schema.bookMetadata.isbn10,
      )
      .orderBy(asc(schema.annotations.id))
      .limit(limit);

    return rows.map((r) => ({
      annotationId: r.annotationId,
      bookId: r.bookId,
      text: r.text,
      note: r.note,
      createdAt: r.createdAt,
      title: r.title,
      isbn13: r.isbn13,
      isbn10: r.isbn10,
      author: r.authorsCsv
        ? r.authorsCsv
            .split('||')
            .filter((a) => a.length > 0)
            .join(', ')
        : '',
    }));
  }

  async countPendingHighlights(userId: number, afterId: number): Promise<number> {
    const eligibility = await this.highlightEligibility(userId, afterId);
    const [row] = await this.db
      .select({ count: sql<number>`count(*)::int` })
      .from(schema.annotations)
      .innerJoin(schema.books, eq(schema.books.id, schema.annotations.bookId))
      .where(eligibility);
    return row?.count ?? 0;
  }

  async claimSync(userId: number): Promise<ReadwiseUserSetting | undefined> {
    const now = new Date();
    const [row] = await this.db
      .update(schema.readwiseUserSettings)
      .set({
        syncState: 'running',
        syncError: null,
        syncStartedAt: now,
        syncFinishedAt: null,
        syncExportedHighlights: 0,
        syncLeaseUntil: new Date(now.getTime() + 5 * 60_000),
      })
      .where(
        and(
          eq(schema.readwiseUserSettings.userId, userId),
          eq(schema.readwiseUserSettings.enabled, true),
          isNotNull(schema.readwiseUserSettings.apiToken),
          or(isNull(schema.readwiseUserSettings.syncLeaseUntil), lt(schema.readwiseUserSettings.syncLeaseUntil, now)),
        ),
      )
      .returning();
    return row;
  }

  async findSyncCandidates(afterUserId: number, limit: number): Promise<number[]> {
    const rows = await this.db
      .select({ userId: schema.readwiseUserSettings.userId })
      .from(schema.readwiseUserSettings)
      .where(
        and(
          gt(schema.readwiseUserSettings.userId, afterUserId),
          eq(schema.readwiseUserSettings.enabled, true),
          isNotNull(schema.readwiseUserSettings.apiToken),
          or(isNull(schema.readwiseUserSettings.syncLeaseUntil), lt(schema.readwiseUserSettings.syncLeaseUntil, new Date())),
          exists(
            this.db
              .select({ one: sql`1` })
              .from(schema.annotations)
              .where(
                and(
                  eq(schema.annotations.userId, schema.readwiseUserSettings.userId),
                  gt(schema.annotations.id, schema.readwiseUserSettings.lastSyncedAnnotationId),
                  isNull(schema.annotations.deletedAt),
                  ne(schema.annotations.text, ''),
                ),
              ),
          ),
        ),
      )
      .orderBy(asc(schema.readwiseUserSettings.userId))
      .limit(limit);
    return rows.map((row) => row.userId);
  }

  private async highlightEligibility(userId: number, afterId: number) {
    const [user] = await this.db
      .select({ isSuperuser: schema.users.isSuperuser, active: schema.users.active, seeOwnRequestedBooks: schema.users.seeOwnRequestedBooks })
      .from(schema.users)
      .where(eq(schema.users.id, userId))
      .limit(1);
    if (!user?.active) return sql`false`;
    const clauses = [
      eq(schema.annotations.userId, userId),
      gt(schema.annotations.id, afterId),
      ne(schema.annotations.text, ''),
      isNull(schema.annotations.deletedAt),
    ];
    if (!user.isSuperuser) {
      clauses.push(
        exists(
          this.db
            .select({ one: sql`1` })
            .from(schema.userLibraryAccess)
            .where(and(eq(schema.userLibraryAccess.userId, userId), eq(schema.userLibraryAccess.libraryId, schema.books.libraryId))),
        ),
      );
      const [tags, genres] = await Promise.all([
        this.db.select().from(schema.userContentFilterTags).where(eq(schema.userContentFilterTags.userId, userId)),
        this.db.select().from(schema.userContentFilterGenres).where(eq(schema.userContentFilterGenres.userId, userId)),
      ]);
      clauses.push(
        ...buildContentFilterClauses(
          {
            includeTagIds: tags.filter((t) => t.filterType === 'include').map((t) => t.tagId),
            excludeTagIds: tags.filter((t) => t.filterType === 'exclude').map((t) => t.tagId),
            includeGenreIds: genres.filter((g) => g.filterType === 'include').map((g) => g.genreId),
            excludeGenreIds: genres.filter((g) => g.filterType === 'exclude').map((g) => g.genreId),
            ...(user.seeOwnRequestedBooks ? { exemptRequestsFromUserId: userId } : {}),
          },
          this.db,
        ),
      );
    }
    return and(...clauses)!;
  }
}
