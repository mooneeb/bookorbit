import { BadRequestException, Inject, Injectable, NotFoundException } from '@nestjs/common';
import { and, asc, count, desc, eq, exists, inArray, notExists, or, sql } from 'drizzle-orm';
import type { NodePgDatabase } from 'drizzle-orm/node-postgres';

import { DB } from '../../../db';
import { refreshPrimaryAuthorSortNamesForBookSelection } from '../../../db/book-author-sort-key';
import * as schema from '../../../db/schema';
import { authors, bookAuthors, books, bookMetadata } from '../../../db/schema';
import { buildContentFilterClauses } from '../../../common/utils/content-filter-sql.utils';
import { accentInsensitiveIlike } from '../../../common/utils/accent-insensitive-search.utils';
import {
  chooseCanonicalMetadataTextRow,
  normalizeMetadataText,
  normalizeMetadataTextKey,
  normalizeMetadataTextKeySql,
} from '../../../common/utils/metadata-text-normalize.utils';
import { AuthorImageStorageService } from '../../authors/author-image-storage.service';
import { AuthorsRepository } from '../../authors/authors.repository';
import { AuthorEnrichmentOrchestratorService } from '../../authors/author-enrichment-orchestrator.service';
import type {
  BrowseParams,
  BrowseResult,
  DeleteInput,
  EntityStrategy,
  MergeInput,
  RawCandidatePair,
  RenameInput,
  SplitInput,
  StrategyDeleteResult,
  StrategyMergeResult,
  StrategyRenameResult,
  StrategySplitResult,
  EntityBookScope,
} from './entity-strategy.interface';
import { assertEntityRelationsWithinLibraries, buildEntityBookScopeClauses } from './entity-book-scope';
import { mutateEntityBooks } from './entity-mutation-books';

type Db = NodePgDatabase<typeof schema>;

const AUTHOR_ENRICHMENT_REASONS = { AUTHOR_MERGE_TARGET: 'author_merge_target' as const };
const NORMALIZED_AUTHOR_NAME_SQL = normalizeMetadataTextKeySql(authors.name);

function escapeLike(s: string): string {
  return s.replace(/[%_\\]/g, '\\$&');
}

@Injectable()
export class AuthorStrategy implements EntityStrategy {
  readonly entityType = 'author' as const;
  readonly isInline = false;

  constructor(
    @Inject(DB) private readonly db: Db,
    private readonly authorsRepo: AuthorsRepository,
    private readonly authorImageStorage: AuthorImageStorageService,
    private readonly enrichmentOrchestrator: AuthorEnrichmentOrchestratorService,
  ) {}

  async findCandidatePairs(libraryIds: number[], minSimilarity: number): Promise<RawCandidatePair[]> {
    const similarityThreshold = Math.max(0.1, Math.min(1, minSimilarity));

    let libraryFilter = sql``;
    if (libraryIds.length > 0) {
      const idsLiteral = sql.raw(`(${libraryIds.join(',')})`);
      libraryFilter = sql` AND EXISTS (
        SELECT 1 FROM book_authors ba JOIN books b ON ba.book_id = b.id
        WHERE ba.author_id = a1.id AND b.library_id IN ${idsLiteral}
      )
      AND EXISTS (
        SELECT 1 FROM book_authors ba JOIN books b ON ba.book_id = b.id
        WHERE ba.author_id = a2.id AND b.library_id IN ${idsLiteral}
      )`;
    }

    const rows = await this.db.transaction(async (tx) => {
      await tx.execute(sql`SELECT set_config('pg_trgm.similarity_threshold', ${similarityThreshold.toString()}, true)`);
      return tx.execute<{
        idA: number;
        idB: number;
        nameA: string;
        nameB: string;
        sortNameA: string | null;
        sortNameB: string | null;
        hasPhotoA: boolean;
        hasPhotoB: boolean;
        simScore: number;
      }>(sql`
        SELECT
          a1.id AS "idA", a2.id AS "idB",
          a1.name AS "nameA", a2.name AS "nameB",
          a1.sort_name AS "sortNameA", a2.sort_name AS "sortNameB",
          a1.has_photo AS "hasPhotoA", a2.has_photo AS "hasPhotoB",
          similarity(a1.name, a2.name) AS "simScore"
        FROM authors a1
        JOIN authors a2 ON a1.id < a2.id AND a1.name % a2.name
        WHERE similarity(a1.name, a2.name) >= ${similarityThreshold}
        ${libraryFilter}
        ORDER BY similarity(a1.name, a2.name) DESC
      `);
    });

    return rows.rows;
  }

  async getAllEntityIds(): Promise<number[]> {
    const rows = await this.db.execute<{ id: number }>(sql`SELECT id FROM authors ORDER BY id`);
    return rows.rows.map((r) => r.id);
  }

  async computeCandidatePairsForBatch(outerIds: number[], minSimilarity: number): Promise<RawCandidatePair[]> {
    const similarityThreshold = Math.max(0.1, Math.min(1, minSimilarity));
    const idsArray = sql.raw(`ARRAY[${outerIds.join(',')}]::int[]`);

    const rows = await this.db.transaction(async (tx) => {
      await tx.execute(sql`SELECT set_config('pg_trgm.similarity_threshold', ${similarityThreshold.toString()}, true)`);
      return tx.execute<{
        idA: number;
        idB: number;
        nameA: string;
        nameB: string;
        sortNameA: string | null;
        sortNameB: string | null;
        hasPhotoA: boolean;
        hasPhotoB: boolean;
        simScore: number;
      }>(sql`
        SELECT
          a1.id AS "idA", a2.id AS "idB",
          a1.name AS "nameA", a2.name AS "nameB",
          a1.sort_name AS "sortNameA", a2.sort_name AS "sortNameB",
          a1.has_photo AS "hasPhotoA", a2.has_photo AS "hasPhotoB",
          similarity(a1.name, a2.name) AS "simScore"
        FROM (SELECT id, name, sort_name, has_photo FROM authors WHERE id = ANY(${idsArray})) a1
        JOIN authors a2 ON a1.id < a2.id AND a1.name % a2.name
        WHERE similarity(a1.name, a2.name) >= ${similarityThreshold}
      `);
    });

    return rows.rows;
  }

  async browse(params: BrowseParams): Promise<BrowseResult> {
    const bookCountExpr = sql<number>`count(distinct ${bookAuthors.bookId})::int`;

    const nameCondition = params.search ? accentInsensitiveIlike(authors.name, `%${escapeLike(params.search)}%`) : undefined;

    const cfClauses = params.contentFilters ? buildContentFilterClauses(params.contentFilters, this.db) : [];
    const libraryBookIds =
      params.libraryIds.length > 0
        ? this.db
            .select({ id: books.id })
            .from(books)
            .where(and(inArray(books.libraryId, params.libraryIds), ...cfClauses))
        : null;

    const joinCondition = libraryBookIds
      ? and(eq(bookAuthors.authorId, authors.id), inArray(bookAuthors.bookId, libraryBookIds))
      : and(eq(bookAuthors.authorId, authors.id), sql`false`);

    const hasScopedBooks = libraryBookIds
      ? exists(
          this.db
            .select({ one: sql`1` })
            .from(bookAuthors)
            .where(and(eq(bookAuthors.authorId, authors.id), inArray(bookAuthors.bookId, libraryBookIds))),
        )
      : undefined;
    const isGloballyEmpty = notExists(
      this.db
        .select({ one: sql`1` })
        .from(bookAuthors)
        .where(eq(bookAuthors.authorId, authors.id)),
    );
    const visibilityCondition =
      params.bookCount === 'empty' ? isGloballyEmpty : hasScopedBooks ? or(hasScopedBooks, isGloballyEmpty) : isGloballyEmpty;

    const countQuery = this.db
      .select({ total: sql<number>`count(distinct ${authors.id})::int` })
      .from(authors)
      .where(and(nameCondition, visibilityCondition));

    const itemQuery = this.db
      .select({
        id: authors.id,
        name: authors.name,
        sortName: authors.sortName,
        hasPhoto: authors.hasPhoto,
        bookCount: bookCountExpr,
      })
      .from(authors)
      .leftJoin(bookAuthors, joinCondition)
      .where(and(nameCondition, visibilityCondition))
      .groupBy(authors.id, authors.name, authors.sortName, authors.hasPhoto)
      .$dynamic();

    itemQuery
      .orderBy(
        params.sortBy === 'bookCount'
          ? params.sortOrder === 'asc'
            ? asc(bookCountExpr)
            : desc(bookCountExpr)
          : params.sortOrder === 'asc'
            ? asc(authors.name)
            : desc(authors.name),
      )
      .limit(params.pageSize)
      .offset((params.page - 1) * params.pageSize);

    const [countResult, itemRows] = await Promise.all([countQuery, itemQuery]);

    return {
      items: itemRows.map((r) => ({ id: r.id, name: r.name, bookCount: r.bookCount, sortName: r.sortName, hasPhoto: r.hasPhoto })),
      total: countResult[0]?.total ?? 0,
    };
  }

  async merge(input: MergeInput): Promise<StrategyMergeResult> {
    const targetId = input.targetId as number;
    const sourceIds = input.sourceIds as number[];
    const fieldsResolved: string[] = [];

    await this.assertScopedRelations([targetId, ...sourceIds], input.libraryIds ?? [], input.contentFilters);

    let imagePromoted = false;
    let targetHasPhoto = true;

    const scope = { libraryIds: input.libraryIds ?? [], contentFilters: input.contentFilters };
    const result = await mutateEntityBooks(
      this.db,
      input,
      scope,
      this.selectMutationBooks(sourceIds, scope),
      async (tx) => {
        const authorRows = await tx
          .select({ id: authors.id, sortName: authors.sortName, description: authors.description, hasPhoto: authors.hasPhoto })
          .from(authors)
          .where(inArray(authors.id, [targetId, ...sourceIds]));
        const target = authorRows.find((row) => row.id === targetId);
        if (!target) throw new NotFoundException('Target author not found');
        targetHasPhoto = target.hasPhoto;
        const updates: Partial<{ sortName: string | null; description: string | null }> = {};
        for (const sourceId of sourceIds) {
          const source = authorRows.find((row) => row.id === sourceId);
          if (!source) throw new NotFoundException('Source author not found');
          if (!target.sortName && source.sortName) {
            updates.sortName = source.sortName;
            target.sortName = source.sortName;
            fieldsResolved.push('sortName');
          }
          if (!target.description && source.description) {
            updates.description = source.description;
            target.description = source.description;
            fieldsResolved.push('description');
          }
        }
        if (Object.keys(updates).length > 0) await tx.update(authors).set(updates).where(eq(authors.id, targetId));

        await tx.execute(sql`INSERT INTO book_authors (book_id, author_id, display_order)
        SELECT DISTINCT ON (source.book_id) source.book_id, ${targetId}, source.display_order
        FROM book_authors source JOIN entity_mutation_books affected ON affected.book_id = source.book_id
        WHERE ${inArray(sql`source.author_id`, sourceIds)} ORDER BY source.book_id, source.display_order, source.author_id
        ON CONFLICT DO NOTHING`);
        await tx.delete(bookAuthors).where(inArray(bookAuthors.authorId, sourceIds));
        await tx.delete(authors).where(inArray(authors.id, sourceIds));
        await refreshPrimaryAuthorSortNamesForBookSelection(tx, sql`SELECT book_id FROM entity_mutation_books`);
      },
      (tx) => this.lockMutationEntities(tx, [targetId, ...sourceIds], scope),
    );

    try {
      if (!targetHasPhoto) {
        for (const sourceId of sourceIds) {
          if (await this.authorImageStorage.promoteImage(sourceId, targetId)) {
            await this.db.update(authors).set({ hasPhoto: true }).where(eq(authors.id, targetId));
            imagePromoted = true;
            fieldsResolved.push('photo');
            break;
          }
        }
      }
      for (const sourceId of sourceIds) await this.authorImageStorage.deleteAuthorDir(sourceId);
      await this.enrichmentOrchestrator.schedule(targetId, AUTHOR_ENRICHMENT_REASONS.AUTHOR_MERGE_TARGET);
      return { ...result, imagePromoted, fieldsResolved: [...new Set(fieldsResolved)] };
    } catch (error) {
      await result.disposeAffectedBooks?.();
      throw error;
    }
  }

  async rename(input: RenameInput): Promise<StrategyRenameResult> {
    const entityId = input.entityId as number;
    await this.assertScopedRelations([entityId], input.libraryIds, input.contentFilters);
    const [entity] = await this.db.select({ name: authors.name }).from(authors).where(eq(authors.id, entityId)).limit(1);
    if (!entity) throw new NotFoundException('Author not found');

    const oldName = entity.name;
    const displayName = normalizeMetadataText(input.newName);
    const normalizedName = normalizeMetadataTextKey(displayName);
    if (!displayName || !normalizedName) throw new BadRequestException('Name cannot be empty');

    const existingRows = await this.db
      .select({ id: authors.id, name: authors.name })
      .from(authors)
      .where(eq(NORMALIZED_AUTHOR_NAME_SQL, normalizedName));
    const mergeTarget = this.selectPreferredAuthorMatch(existingRows, entityId, displayName);
    if (mergeTarget) {
      const mergeResult = await this.merge({
        targetId: mergeTarget.id,
        sourceIds: [entityId],
        userId: input.userId,
        libraryIds: input.libraryIds ?? [],
        contentFilters: input.contentFilters,
        onBooksChanged: input.onBooksChanged,
        spoolBookIds: input.spoolBookIds,
      });
      return { ...mergeResult, oldName, wasImplicitMerge: true, mergedEntityId: mergeTarget.id };
    }

    const scope = { libraryIds: input.libraryIds, contentFilters: input.contentFilters };
    const result = await mutateEntityBooks(
      this.db,
      input,
      scope,
      this.selectMutationBooks([entityId], scope),
      async (tx) => {
        await tx.update(authors).set({ name: displayName }).where(eq(authors.id, entityId));
        await refreshPrimaryAuthorSortNamesForBookSelection(tx, sql`SELECT book_id FROM entity_mutation_books`);
      },
      (tx) => this.lockMutationEntities(tx, [entityId], scope),
    );
    return { ...result, oldName, wasImplicitMerge: false };
  }

  async deleteEntity(input: DeleteInput): Promise<StrategyDeleteResult> {
    const entityId = input.entityId as number;
    await this.assertScopedRelations([entityId], input.libraryIds, input.contentFilters);
    const [entity] = await this.db.select({ name: authors.name }).from(authors).where(eq(authors.id, entityId)).limit(1);
    if (!entity) throw new NotFoundException('Author not found');

    const scope = { libraryIds: input.libraryIds, contentFilters: input.contentFilters };
    const result = await mutateEntityBooks(
      this.db,
      input,
      scope,
      this.selectMutationBooks([entityId], scope),
      async (tx) => {
        await tx.delete(bookAuthors).where(eq(bookAuthors.authorId, entityId));
        if (input.mode !== 'soft') await tx.delete(authors).where(eq(authors.id, entityId));
        await refreshPrimaryAuthorSortNamesForBookSelection(tx, sql`SELECT book_id FROM entity_mutation_books`);
      },
      (tx) => this.lockMutationEntities(tx, [entityId], scope),
    );
    if (input.mode !== 'soft') await this.authorImageStorage.deleteAuthorDir(entityId);
    return { ...result, name: entity.name };
  }

  async split(input: SplitInput): Promise<StrategySplitResult> {
    await this.assertScopedRelations([input.entityId], input.libraryIds ?? [], input.contentFilters);
    const [entity] = await this.db.select({ name: authors.name }).from(authors).where(eq(authors.id, input.entityId)).limit(1);
    if (!entity) throw new NotFoundException('Author not found');

    const newEntities: { id: number; name: string }[] = [];
    const scope = { libraryIds: input.libraryIds ?? [], contentFilters: input.contentFilters };
    const result = await mutateEntityBooks(
      this.db,
      input,
      scope,
      this.selectMutationBooks([input.entityId], scope),
      async (tx) => {
        const seenNewNames = new Set<string>();
        for (const name of input.newNames) {
          const displayName = normalizeMetadataText(name);
          const normalizedName = normalizeMetadataTextKey(displayName);
          if (!displayName || !normalizedName) continue;
          if (seenNewNames.has(normalizedName)) continue;
          seenNewNames.add(normalizedName);

          const existingRows = await tx
            .select({ id: authors.id, name: authors.name })
            .from(authors)
            .where(eq(NORMALIZED_AUTHOR_NAME_SQL, normalizedName));
          const existing = this.selectPreferredAuthorMatch(existingRows, input.entityId as number, displayName);
          if (existing) {
            newEntities.push({ id: existing.id, name: existing.name });
          } else {
            const [inserted] = await tx.insert(authors).values({ name: displayName }).returning({ id: authors.id });
            newEntities.push({ id: inserted!.id, name: displayName });
          }
        }
        if (newEntities.length === 0) throw new BadRequestException('At least one name is required');

        for (const newEntity of newEntities) {
          await tx.execute(sql`INSERT INTO book_authors (book_id, author_id, display_order)
          SELECT source.book_id, ${newEntity.id}, source.display_order FROM book_authors source
          JOIN entity_mutation_books affected ON affected.book_id = source.book_id
          WHERE source.author_id = ${input.entityId} ON CONFLICT DO NOTHING`);
        }

        await tx.delete(bookAuthors).where(eq(bookAuthors.authorId, input.entityId));
        await tx.delete(authors).where(eq(authors.id, input.entityId));
        await refreshPrimaryAuthorSortNamesForBookSelection(tx, sql`SELECT book_id FROM entity_mutation_books`);
      },
      (tx) => this.lockMutationEntities(tx, [input.entityId], scope),
    );

    await this.authorImageStorage.deleteAuthorDir(input.entityId);

    return { ...result, originalName: entity.name, newEntities };
  }

  private selectMutationBooks(ids: number[], scope: EntityBookScope) {
    return sql`SELECT DISTINCT ${bookAuthors.bookId} FROM ${bookAuthors}
      JOIN ${books} ON ${books.id} = ${bookAuthors.bookId}
      WHERE ${inArray(bookAuthors.authorId, ids)} AND ${and(...buildEntityBookScopeClauses(this.db, scope))}`;
  }

  private async lockMutationEntities(tx: Db, ids: number[], scope: EntityBookScope): Promise<void> {
    const rows = await tx.select({ id: authors.id }).from(authors).where(inArray(authors.id, ids)).orderBy(authors.id).for('update');
    if (rows.length !== new Set(ids).size) throw new NotFoundException('Author not found');
    await assertEntityRelationsWithinLibraries(tx, 'book_authors', 'author_id', ids, scope.libraryIds, scope.contentFilters);
  }

  private selectPreferredAuthorMatch(
    rows: { id: number; name: string }[],
    excludedAuthorId: number,
    displayName: string,
  ): { id: number; name: string } | null {
    return chooseCanonicalMetadataTextRow(rows, { desiredName: displayName, excludedId: excludedAuthorId });
  }

  assertMutationScope(ids: (number | string)[], scope: EntityBookScope): Promise<void> {
    return this.assertScopedRelations(ids as number[], scope.libraryIds, scope.contentFilters);
  }

  private assertScopedRelations(entityIds: number[], libraryIds: number[], contentFilters?: EntityBookScope['contentFilters']): Promise<void> {
    return assertEntityRelationsWithinLibraries(this.db, 'book_authors', 'author_id', entityIds, libraryIds, contentFilters);
  }

  async findAffectedBookIds(ids: (number | string)[]): Promise<number[]> {
    const numericIds = ids as number[];
    if (numericIds.length === 0) return [];
    const rows = await this.db.selectDistinct({ bookId: bookAuthors.bookId }).from(bookAuthors).where(inArray(bookAuthors.authorId, numericIds));
    return rows.map((r) => r.bookId);
  }

  async getBookCount(id: number | string, scope?: EntityBookScope): Promise<number> {
    if (scope) {
      const [row] = await this.db
        .select({ count: count() })
        .from(bookAuthors)
        .innerJoin(books, eq(books.id, bookAuthors.bookId))
        .where(and(eq(bookAuthors.authorId, id as number), ...buildEntityBookScopeClauses(this.db, scope)));
      return row?.count ?? 0;
    }

    const [row] = await this.db
      .select({ count: count() })
      .from(bookAuthors)
      .where(eq(bookAuthors.authorId, id as number));
    return row?.count ?? 0;
  }

  async getBookTitles(id: number | string, limit: number, scope?: EntityBookScope): Promise<string[]> {
    const rows = await this.db
      .select({ title: sql<string>`COALESCE(${bookMetadata.title}, 'Untitled')` })
      .from(bookAuthors)
      .innerJoin(books, eq(books.id, bookAuthors.bookId))
      .leftJoin(bookMetadata, eq(bookMetadata.bookId, books.id))
      .where(and(eq(bookAuthors.authorId, id as number), ...(scope ? buildEntityBookScopeClauses(this.db, scope) : [])))
      .orderBy(asc(bookMetadata.title))
      .limit(limit);
    return rows.map((r) => r.title);
  }

  async findEntityById(id: number | string): Promise<{ id: number; name: string } | null> {
    const [row] = await this.db
      .select({ id: authors.id, name: authors.name })
      .from(authors)
      .where(eq(authors.id, id as number))
      .limit(1);
    return row ?? null;
  }
}
