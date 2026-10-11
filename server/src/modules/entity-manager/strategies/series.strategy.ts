import { BadRequestException, Inject, Injectable, NotFoundException } from '@nestjs/common';
import { SQL, and, asc, count, desc, eq, exists, inArray, notExists, or, sql } from 'drizzle-orm';
import type { NodePgDatabase } from 'drizzle-orm/node-postgres';

import { buildContentFilterClauses } from '../../../common/utils/content-filter-sql.utils';
import { accentInsensitiveIlike } from '../../../common/utils/accent-insensitive-search.utils';
import { normalizeMetadataText, normalizeMetadataTextKey } from '../../../common/utils/metadata-text-normalize.utils';
import { DB } from '../../../db';
import * as schema from '../../../db/schema';
import { bookMetadata, books, bookSeries, bookSeriesMemberships } from '../../../db/schema';
import type {
  BrowseParams,
  BrowseResult,
  DeleteInput,
  EntityStrategy,
  MergeInput,
  RawCandidatePair,
  RenameInput,
  StrategyDeleteResult,
  StrategyMergeResult,
  StrategyRenameResult,
  StrategySplitResult,
  EntityBookScope,
} from './entity-strategy.interface';
import { assertEntityRelationsWithinLibraries, buildEntityBookScopeClauses } from './entity-book-scope';
import { mutateEntityBooks } from './entity-mutation-books';

type Db = NodePgDatabase<typeof schema>;

function escapeLike(s: string): string {
  return s.replace(/[%_\\]/g, '\\$&');
}

function numericIds(ids: (number | string)[]): number[] {
  return [...new Set(ids.map((id) => Number(id)).filter((id) => Number.isInteger(id) && id > 0))];
}

function sqlNumberList(ids: number[]): SQL {
  return sql.join(
    ids.map((id) => sql`${id}`),
    sql`, `,
  );
}

@Injectable()
export class SeriesStrategy implements EntityStrategy {
  readonly entityType = 'series' as const;
  readonly isInline = false;

  constructor(@Inject(DB) private readonly db: Db) {}

  async findCandidatePairs(libraryIds: number[], minSimilarity: number): Promise<RawCandidatePair[]> {
    const scopedLibraryIds = numericIds(libraryIds);
    if (scopedLibraryIds.length === 0) return [];
    const similarityThreshold = Math.max(0.1, Math.min(1, minSimilarity));
    const libraryIdList = sqlNumberList(scopedLibraryIds);

    const rows = await this.db.transaction(async (tx) => {
      await tx.execute(sql`SELECT set_config('pg_trgm.similarity_threshold', ${similarityThreshold.toString()}, true)`);
      return tx.execute<{ idA: number; idB: number; nameA: string; nameB: string; simScore: number }>(sql`
        SELECT
          s1.id AS "idA",
          s2.id AS "idB",
          s1.name AS "nameA",
          s2.name AS "nameB",
          similarity(s1.name, s2.name) AS "simScore"
        FROM book_series s1
        JOIN book_series s2 ON s1.id < s2.id AND s1.name % s2.name
        WHERE similarity(s1.name, s2.name) >= ${similarityThreshold}
          AND EXISTS (
            SELECT 1 FROM book_series_memberships bsm
            JOIN books b ON b.id = bsm.book_id
            WHERE bsm.series_id = s1.id AND b.library_id IN (${libraryIdList})
          )
          AND EXISTS (
            SELECT 1 FROM book_series_memberships bsm
            JOIN books b ON b.id = bsm.book_id
            WHERE bsm.series_id = s2.id AND b.library_id IN (${libraryIdList})
          )
        ORDER BY similarity(s1.name, s2.name) DESC
      `);
    });

    return rows.rows;
  }

  async getAllEntityIds(): Promise<number[]> {
    const rows = await this.db.select({ id: bookSeries.id }).from(bookSeries).orderBy(bookSeries.id);
    return rows.map((row) => row.id);
  }

  async computeCandidatePairsForBatch(outerIds: number[], minSimilarity: number): Promise<RawCandidatePair[]> {
    const batchIds = numericIds(outerIds);
    if (batchIds.length === 0) return [];
    const similarityThreshold = Math.max(0.1, Math.min(1, minSimilarity));
    const batchIdList = sqlNumberList(batchIds);

    const rows = await this.db.transaction(async (tx) => {
      await tx.execute(sql`SELECT set_config('pg_trgm.similarity_threshold', ${similarityThreshold.toString()}, true)`);
      return tx.execute<{ idA: number; idB: number; nameA: string; nameB: string; simScore: number }>(sql`
        SELECT
          s1.id AS "idA",
          s2.id AS "idB",
          s1.name AS "nameA",
          s2.name AS "nameB",
          similarity(s1.name, s2.name) AS "simScore"
        FROM (SELECT id, name FROM book_series WHERE id IN (${batchIdList})) s1
        JOIN book_series s2 ON s1.id < s2.id AND s1.name % s2.name
        WHERE similarity(s1.name, s2.name) >= ${similarityThreshold}
      `);
    });

    return rows.rows;
  }

  async browse(params: BrowseParams): Promise<BrowseResult> {
    const filterClauses = params.contentFilters ? buildContentFilterClauses(params.contentFilters, this.db) : [];
    const bookSubquery =
      params.libraryIds.length > 0
        ? this.db
            .select({ id: books.id })
            .from(books)
            .where(and(inArray(books.libraryId, params.libraryIds), ...filterClauses))
        : null;
    const nameCondition = params.search ? (accentInsensitiveIlike(bookSeries.name, `%${escapeLike(params.search)}%`) as never) : undefined;
    const joinCondition = bookSubquery
      ? and(eq(bookSeriesMemberships.seriesId, bookSeries.id), inArray(bookSeriesMemberships.bookId, bookSubquery))
      : and(eq(bookSeriesMemberships.seriesId, bookSeries.id), sql`false`);
    const bookCountExpr = sql<number>`count(distinct ${bookSeriesMemberships.bookId})::int`;

    const hasScopedBooks = bookSubquery
      ? exists(
          this.db
            .select({ one: sql`1` })
            .from(bookSeriesMemberships)
            .where(and(eq(bookSeriesMemberships.seriesId, bookSeries.id), inArray(bookSeriesMemberships.bookId, bookSubquery))),
        )
      : undefined;
    const isGloballyEmpty = notExists(
      this.db
        .select({ one: sql`1` })
        .from(bookSeriesMemberships)
        .where(eq(bookSeriesMemberships.seriesId, bookSeries.id)),
    );
    const visibilityCondition =
      params.bookCount === 'empty' ? isGloballyEmpty : hasScopedBooks ? or(hasScopedBooks, isGloballyEmpty) : isGloballyEmpty;

    const countQuery = this.db
      .select({ total: sql<number>`count(distinct ${bookSeries.id})::int` })
      .from(bookSeries)
      .where(and(nameCondition, visibilityCondition));

    const itemQuery = this.db
      .select({ id: bookSeries.id, name: bookSeries.name, bookCount: bookCountExpr })
      .from(bookSeries)
      .leftJoin(bookSeriesMemberships, joinCondition)
      .where(and(nameCondition, visibilityCondition))
      .groupBy(bookSeries.id, bookSeries.name)
      .$dynamic();

    itemQuery
      .orderBy(
        params.sortBy === 'bookCount'
          ? params.sortOrder === 'asc'
            ? asc(bookCountExpr)
            : desc(bookCountExpr)
          : params.sortOrder === 'asc'
            ? asc(bookSeries.name)
            : desc(bookSeries.name),
      )
      .limit(params.pageSize)
      .offset((params.page - 1) * params.pageSize);

    const [countResult, itemRows] = await Promise.all([countQuery, itemQuery]);

    return {
      items: itemRows.map((row) => ({ id: row.id, name: row.name, bookCount: row.bookCount })),
      total: countResult[0]?.total ?? 0,
    };
  }

  assertMutationScope(ids: (number | string)[], scope: EntityBookScope): Promise<void> {
    return assertEntityRelationsWithinLibraries(this.db, 'book_series_memberships', 'series_id', ids, scope.libraryIds, scope.contentFilters, true);
  }

  async merge(input: MergeInput): Promise<StrategyMergeResult> {
    const targetId = Number(input.targetId);
    const sourceIds = numericIds(input.sourceIds).filter((id) => id !== targetId);
    if (!Number.isInteger(targetId) || targetId <= 0 || sourceIds.length === 0) return { affectedBookIds: [] };

    const scope = { libraryIds: input.libraryIds ?? [], contentFilters: input.contentFilters };
    const target = await this.findEntityById(targetId);
    if (!target) throw new NotFoundException('series not found');
    return mutateEntityBooks(
      this.db,
      input,
      scope,
      this.selectMutationBooks(sourceIds, scope),
      async (tx) => {
        await this.mergeMemberships(sourceIds, targetId, tx);
        await this.syncPrimaryMetadataForBooks(tx);
        await this.deleteUnusedSeriesRows(sourceIds, tx);
      },
      (tx) => this.lockMutationEntities(tx, [targetId, ...sourceIds], scope),
    );
  }

  async rename(input: RenameInput): Promise<StrategyRenameResult> {
    const entityId = Number(input.entityId);
    const current = await this.findEntityById(entityId);
    if (!current) throw new NotFoundException('series not found');
    const newName = normalizeMetadataText(input.newName);
    if (!newName) throw new BadRequestException('Name cannot be empty');

    const scope = { libraryIds: input.libraryIds, contentFilters: input.contentFilters };
    let target: { id: number; name: string } | undefined;
    let wasImplicitMerge = false;
    const affected = await mutateEntityBooks(
      this.db,
      input,
      scope,
      this.selectMutationBooks([entityId], scope),
      async (tx) => {
        const snapshot = await tx.execute<{ exists: boolean }>(sql`SELECT EXISTS (SELECT 1 FROM entity_mutation_books) AS "exists"`);
        if (!snapshot.rows[0]?.exists) return;
        target = await this.upsertSeries(newName, tx);
        await this.lockMutationEntities(tx, [target.id], scope);
        wasImplicitMerge = target.id !== entityId;
        if (wasImplicitMerge) await this.mergeMemberships([entityId], target.id, tx);
        else {
          await assertEntityRelationsWithinLibraries(tx, 'book_series_memberships', 'series_id', [entityId], input.libraryIds, input.contentFilters);
          await tx.update(bookSeries).set({ name: newName, updatedAt: new Date() }).where(eq(bookSeries.id, entityId));
        }
        await this.syncPrimaryMetadataForBooks(tx);
        await this.deleteUnusedSeriesRows([entityId], tx);
      },
      (tx) => this.lockMutationEntities(tx, [entityId], scope),
    );
    return { oldName: current.name, ...affected, wasImplicitMerge, mergedEntityId: wasImplicitMerge ? target?.id : undefined };
  }

  async deleteEntity(input: DeleteInput): Promise<StrategyDeleteResult> {
    const entityId = Number(input.entityId);
    const entity = await this.findEntityById(entityId);
    if (!entity) throw new NotFoundException('series not found');
    const scope = { libraryIds: input.libraryIds, contentFilters: input.contentFilters };
    const affected = await mutateEntityBooks(
      this.db,
      input,
      scope,
      this.selectMutationBooks([entityId], scope),
      async (tx) => {
        await tx.execute(sql`DELETE FROM book_series_memberships
        WHERE series_id = ${entityId} AND book_id IN (SELECT book_id FROM entity_mutation_books)`);
        await this.syncPrimaryMetadataForBooks(tx);
        if (input.mode === 'hard') await this.deleteUnusedSeriesRows([entityId], tx);
      },
      (tx) => this.lockMutationEntities(tx, [entityId], scope),
    );
    return { name: entity.name, ...affected };
  }

  private selectMutationBooks(ids: number[], scope: EntityBookScope): SQL {
    return sql`SELECT DISTINCT ${bookSeriesMemberships.bookId} FROM ${bookSeriesMemberships}
      JOIN ${books} ON ${books.id} = ${bookSeriesMemberships.bookId}
      WHERE ${inArray(bookSeriesMemberships.seriesId, ids)} AND ${and(...buildEntityBookScopeClauses(this.db, scope))}`;
  }

  private async lockMutationEntities(tx: Db, ids: number[], scope: EntityBookScope): Promise<void> {
    const rows = await tx.select({ id: bookSeries.id }).from(bookSeries).where(inArray(bookSeries.id, ids)).orderBy(bookSeries.id).for('update');
    if (rows.length !== new Set(ids).size) throw new NotFoundException('series not found');
    await assertEntityRelationsWithinLibraries(tx, 'book_series_memberships', 'series_id', ids, scope.libraryIds, scope.contentFilters, true);
  }

  split(): Promise<StrategySplitResult> {
    throw new BadRequestException('Split is not supported for series');
  }

  async findAffectedBookIds(ids: (number | string)[]): Promise<number[]> {
    const seriesIds = numericIds(ids);
    if (seriesIds.length === 0) return [];
    const rows = await this.db
      .select({ bookId: bookSeriesMemberships.bookId })
      .from(bookSeriesMemberships)
      .where(inArray(bookSeriesMemberships.seriesId, seriesIds));
    return [...new Set(rows.map((row) => row.bookId))];
  }

  async getBookCount(id: number | string, scope?: EntityBookScope): Promise<number> {
    if (scope) {
      const [row] = await this.db
        .select({ count: count() })
        .from(bookSeriesMemberships)
        .innerJoin(books, eq(books.id, bookSeriesMemberships.bookId))
        .where(and(eq(bookSeriesMemberships.seriesId, Number(id)), ...buildEntityBookScopeClauses(this.db, scope)));
      return row?.count ?? 0;
    }

    const [row] = await this.db
      .select({ count: count() })
      .from(bookSeriesMemberships)
      .where(eq(bookSeriesMemberships.seriesId, Number(id)));
    return row?.count ?? 0;
  }

  async getBookTitles(id: number | string, limit: number, scope?: EntityBookScope): Promise<string[]> {
    const baseQuery = this.db.select({ title: sql<string>`COALESCE(${bookMetadata.title}, 'Untitled')` }).from(bookSeriesMemberships);
    const rows = scope
      ? await baseQuery
          .innerJoin(books, eq(books.id, bookSeriesMemberships.bookId))
          .innerJoin(bookMetadata, eq(bookMetadata.bookId, bookSeriesMemberships.bookId))
          .where(and(eq(bookSeriesMemberships.seriesId, Number(id)), ...buildEntityBookScopeClauses(this.db, scope)))
          .orderBy(asc(bookMetadata.title))
          .limit(limit)
      : await baseQuery
          .innerJoin(bookMetadata, eq(bookMetadata.bookId, bookSeriesMemberships.bookId))
          .where(eq(bookSeriesMemberships.seriesId, Number(id)))
          .orderBy(asc(bookMetadata.title))
          .limit(limit);
    return rows.map((row) => row.title);
  }

  async findEntityById(id: number | string): Promise<{ id: number; name: string } | null> {
    const [row] = await this.db
      .select({ id: bookSeries.id, name: bookSeries.name })
      .from(bookSeries)
      .where(eq(bookSeries.id, Number(id)))
      .limit(1);
    return row ?? null;
  }

  private async upsertSeries(name: string, db: Db = this.db): Promise<{ id: number; name: string }> {
    const displayName = normalizeMetadataText(name);
    const normalized = normalizeMetadataTextKey(displayName);
    if (!displayName || !normalized) throw new BadRequestException('Name cannot be empty');
    await db.insert(bookSeries).values({ name: displayName, normalizedName: normalized }).onConflictDoNothing();
    const [row] = await db
      .select({ id: bookSeries.id, name: bookSeries.name })
      .from(bookSeries)
      .where(eq(bookSeries.normalizedName, normalized))
      .limit(1);
    if (!row) throw new BadRequestException('Unable to resolve series');
    return row;
  }

  private async mergeMemberships(sourceIds: number[], targetId: number, db: Db): Promise<void> {
    const sourceIdList = sqlNumberList(numericIds(sourceIds));
    await db.execute(sql`WITH chosen AS (
      SELECT DISTINCT ON (bsm.book_id) bsm.book_id, bsm.series_id
      FROM book_series_memberships bsm JOIN entity_mutation_books affected ON affected.book_id = bsm.book_id
      WHERE bsm.series_id IN (${sourceIdList}) ORDER BY bsm.book_id, bsm.display_order, bsm.series_id
    ) UPDATE book_series_memberships bsm SET series_id = ${targetId}, updated_at = now()
      FROM chosen WHERE bsm.book_id = chosen.book_id AND bsm.series_id = chosen.series_id
        AND NOT EXISTS (SELECT 1 FROM book_series_memberships existing WHERE existing.book_id = bsm.book_id AND existing.series_id = ${targetId})`);
    await db.execute(sql`DELETE FROM book_series_memberships
      WHERE book_id IN (SELECT book_id FROM entity_mutation_books) AND series_id IN (${sourceIdList})`);
  }

  private async syncPrimaryMetadataForBooks(db: Db): Promise<void> {
    await db.execute(sql`UPDATE book_series_memberships SET display_order = display_order + 100000
      WHERE book_id IN (SELECT book_id FROM entity_mutation_books)`);
    await db.execute(sql`WITH ranked AS (
      SELECT book_id, series_id, row_number() OVER (PARTITION BY book_id ORDER BY display_order ASC, series_id ASC) - 1 AS next_display_order
      FROM book_series_memberships WHERE book_id IN (SELECT book_id FROM entity_mutation_books)
    ) UPDATE book_series_memberships bsm SET display_order = ranked.next_display_order, updated_at = now()
      FROM ranked WHERE bsm.book_id = ranked.book_id AND bsm.series_id = ranked.series_id`);
    await db.execute(sql`UPDATE book_metadata bm SET series_id = bsm.series_id, series_name = bs.name,
      series_index = bsm.series_index, updated_at = now()
      FROM book_series_memberships bsm JOIN book_series bs ON bs.id = bsm.series_id
      WHERE bm.book_id = bsm.book_id AND bsm.display_order = 0
        AND bm.book_id IN (SELECT book_id FROM entity_mutation_books)`);
    await db.execute(sql`UPDATE book_metadata bm SET series_id = NULL, series_name = NULL, series_index = NULL, updated_at = now()
      WHERE bm.book_id IN (SELECT book_id FROM entity_mutation_books)
        AND NOT EXISTS (SELECT 1 FROM book_series_memberships bsm WHERE bsm.book_id = bm.book_id)`);
    await db.execute(sql`UPDATE books SET updated_at = now() WHERE id IN (SELECT book_id FROM entity_mutation_books)`);
  }

  private async deleteUnusedSeriesRows(seriesIds: number[], db: Db): Promise<void> {
    const unusedSeriesIds = numericIds(seriesIds);
    if (unusedSeriesIds.length === 0) return;
    const seriesIdList = sqlNumberList(unusedSeriesIds);
    await db.execute(sql`
      DELETE FROM book_series s
      WHERE s.id IN (${seriesIdList})
        AND NOT EXISTS (
          SELECT 1 FROM book_series_memberships bsm
          WHERE bsm.series_id = s.id
        )
    `);
  }
}
