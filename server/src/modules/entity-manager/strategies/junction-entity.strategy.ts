import { BadRequestException, Inject, NotFoundException } from '@nestjs/common';
import { and, asc, count, desc, eq, exists, inArray, notExists, or, sql } from 'drizzle-orm';
import type { NodePgDatabase } from 'drizzle-orm/node-postgres';
import type { PgColumn, PgTableWithColumns } from 'drizzle-orm/pg-core';

import { DB } from '../../../db';
import * as schema from '../../../db/schema';
import { books, bookMetadata } from '../../../db/schema';
import { buildContentFilterClauses } from '../../../common/utils/content-filter-sql.utils';
import { accentInsensitiveIlike } from '../../../common/utils/accent-insensitive-search.utils';
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

function escapeLike(s: string): string {
  return s.replace(/[%_\\]/g, '\\$&');
}

export abstract class JunctionEntityStrategy implements EntityStrategy {
  abstract readonly entityType: 'genre' | 'tag' | 'narrator';
  readonly isInline = false;

  protected abstract readonly entityTable: PgTableWithColumns<any>;
  protected abstract readonly junctionTable: PgTableWithColumns<any>;
  protected abstract readonly entityIdCol: PgColumn;
  protected abstract readonly junctionEntityIdCol: PgColumn;
  protected abstract readonly junctionBookIdCol: PgColumn;
  protected abstract readonly nameCol: PgColumn;
  protected abstract readonly rawTableName: string;
  protected abstract readonly rawJunctionTable: string;
  protected abstract readonly rawEntityIdCol: string;
  protected abstract readonly hasCascade: boolean;

  constructor(@Inject(DB) protected readonly db: Db) {}

  async findCandidatePairs(libraryIds: number[], minSimilarity: number): Promise<RawCandidatePair[]> {
    const similarityThreshold = Math.max(0.1, Math.min(1, minSimilarity));
    const t = sql.raw(this.rawTableName);
    const jt = sql.raw(this.rawJunctionTable);
    const ec = sql.raw(this.rawEntityIdCol);

    let libraryFilter = sql``;
    if (libraryIds.length > 0) {
      const idsLiteral = sql.raw(`(${libraryIds.join(',')})`);
      libraryFilter = sql`
        AND EXISTS (
          SELECT 1 FROM ${jt} jj JOIN books b ON jj.book_id = b.id
          WHERE jj.${ec} = e1.id AND b.library_id IN ${idsLiteral}
        )
        AND EXISTS (
          SELECT 1 FROM ${jt} jj JOIN books b ON jj.book_id = b.id
          WHERE jj.${ec} = e2.id AND b.library_id IN ${idsLiteral}
        )`;
    }

    const rows = await this.db.transaction(async (tx) => {
      await tx.execute(sql`SELECT set_config('pg_trgm.similarity_threshold', ${similarityThreshold.toString()}, true)`);
      return tx.execute<{
        idA: number;
        idB: number;
        nameA: string;
        nameB: string;
        simScore: number;
      }>(sql`
        SELECT
          e1.id AS "idA", e2.id AS "idB",
          e1.name AS "nameA", e2.name AS "nameB",
          similarity(e1.name, e2.name) AS "simScore"
        FROM ${t} e1
        JOIN ${t} e2 ON e1.id < e2.id AND e1.name % e2.name
        WHERE similarity(e1.name, e2.name) >= ${similarityThreshold}
        ${libraryFilter}
        ORDER BY similarity(e1.name, e2.name) DESC
      `);
    });

    return rows.rows;
  }

  async getAllEntityIds(): Promise<number[]> {
    const t = sql.raw(this.rawTableName);
    const rows = await this.db.execute<{ id: number }>(sql`SELECT id FROM ${t} ORDER BY id`);
    return rows.rows.map((r) => r.id);
  }

  async computeCandidatePairsForBatch(outerIds: number[], minSimilarity: number): Promise<RawCandidatePair[]> {
    const similarityThreshold = Math.max(0.1, Math.min(1, minSimilarity));
    const t = sql.raw(this.rawTableName);
    const idsArray = sql.raw(`ARRAY[${outerIds.join(',')}]::int[]`);

    const rows = await this.db.transaction(async (tx) => {
      await tx.execute(sql`SELECT set_config('pg_trgm.similarity_threshold', ${similarityThreshold.toString()}, true)`);
      return tx.execute<{
        idA: number;
        idB: number;
        nameA: string;
        nameB: string;
        simScore: number;
      }>(sql`
        SELECT
          e1.id AS "idA", e2.id AS "idB",
          e1.name AS "nameA", e2.name AS "nameB",
          similarity(e1.name, e2.name) AS "simScore"
        FROM (SELECT id, name FROM ${t} WHERE id = ANY(${idsArray})) e1
        JOIN ${t} e2 ON e1.id < e2.id AND e1.name % e2.name
        WHERE similarity(e1.name, e2.name) >= ${similarityThreshold}
      `);
    });

    return rows.rows;
  }

  async browse(params: BrowseParams): Promise<BrowseResult> {
    const cfClauses = params.contentFilters ? buildContentFilterClauses(params.contentFilters, this.db) : [];
    const bookSubquery =
      params.libraryIds.length > 0
        ? this.db
            .select({ id: books.id })
            .from(books)
            .where(and(inArray(books.libraryId, params.libraryIds), ...cfClauses))
        : null;

    const nameCondition = params.search ? (accentInsensitiveIlike(this.nameCol, `%${escapeLike(params.search)}%`) as any) : undefined;
    const joinCondition = bookSubquery
      ? and(eq(this.junctionEntityIdCol, this.entityIdCol), inArray(this.junctionBookIdCol, bookSubquery))
      : and(eq(this.junctionEntityIdCol, this.entityIdCol), sql`false`);
    const bookCountExpr = sql<number>`count(distinct ${this.junctionBookIdCol})::int`;

    const hasScopedBooks = bookSubquery
      ? exists(
          this.db
            .select({ one: sql`1` })
            .from(this.junctionTable)
            .where(and(eq(this.junctionEntityIdCol, this.entityIdCol), inArray(this.junctionBookIdCol, bookSubquery))),
        )
      : undefined;
    const isGloballyEmpty = notExists(
      this.db
        .select({ one: sql`1` })
        .from(this.junctionTable)
        .where(eq(this.junctionEntityIdCol, this.entityIdCol)),
    );
    const visibilityCondition =
      params.bookCount === 'empty' ? isGloballyEmpty : hasScopedBooks ? or(hasScopedBooks, isGloballyEmpty) : isGloballyEmpty;

    const countQuery = this.db
      .select({ total: sql<number>`count(distinct ${this.entityIdCol})::int` })
      .from(this.entityTable)
      .where(and(nameCondition, visibilityCondition));

    const itemQuery = this.db
      .select({ id: this.entityIdCol, name: this.nameCol, bookCount: bookCountExpr })
      .from(this.entityTable)
      .leftJoin(this.junctionTable, joinCondition)
      .where(and(nameCondition, visibilityCondition))
      .groupBy(this.entityIdCol, this.nameCol)
      .$dynamic();

    itemQuery
      .orderBy(
        params.sortBy === 'bookCount'
          ? params.sortOrder === 'asc'
            ? asc(bookCountExpr)
            : desc(bookCountExpr)
          : params.sortOrder === 'asc'
            ? asc(this.nameCol)
            : desc(this.nameCol),
      )
      .limit(params.pageSize)
      .offset((params.page - 1) * params.pageSize);

    const [countResult, itemRows] = await Promise.all([countQuery, itemQuery]);

    return {
      items: itemRows.map((r: any) => ({ id: r.id, name: r.name, bookCount: r.bookCount })),
      total: (countResult[0] as any)?.total ?? 0,
    };
  }

  async merge(input: MergeInput): Promise<StrategyMergeResult> {
    const targetId = input.targetId as number;
    const sourceIds = input.sourceIds as number[];

    await this.assertScopedRelations([targetId, ...sourceIds], input.libraryIds ?? [], input.contentFilters);

    const target = await this.findEntityById(targetId);
    if (!target) throw new NotFoundException(`${this.entityType} not found`);

    const scope = { libraryIds: input.libraryIds ?? [], contentFilters: input.contentFilters };
    return mutateEntityBooks(
      this.db,
      input,
      scope,
      this.selectMutationBooks(sourceIds, scope),
      async (tx) => {
        await this.insertMutationRelations(tx, targetId);
        await tx.delete(this.junctionTable).where(inArray(this.junctionEntityIdCol, sourceIds));
        await tx.delete(this.entityTable).where(inArray(this.entityIdCol, sourceIds));
      },
      (tx) => this.lockMutationEntities(tx, [targetId, ...sourceIds], scope),
    );
  }

  async rename(input: RenameInput): Promise<StrategyRenameResult> {
    const entityId = input.entityId as number;
    await this.assertScopedRelations([entityId], input.libraryIds, input.contentFilters);
    const [entity] = await this.db.select({ name: this.nameCol }).from(this.entityTable).where(eq(this.entityIdCol, entityId)).limit(1);
    if (!entity) throw new NotFoundException(`${this.entityType} not found`);

    const oldName = (entity as any).name as string;
    const trimmed = input.newName.trim();
    if (!trimmed) throw new BadRequestException('Name cannot be empty');

    const [existing] = await this.db.select({ id: this.entityIdCol }).from(this.entityTable).where(eq(this.nameCol, trimmed)).limit(1);
    if (existing && (existing as any).id !== entityId) {
      const existingId = (existing as any).id as number;
      const mergeResult = await this.merge({
        targetId: existingId,
        sourceIds: [entityId],
        userId: input.userId,
        libraryIds: input.libraryIds ?? [],
        contentFilters: input.contentFilters,
        onBooksChanged: input.onBooksChanged,
        spoolBookIds: input.spoolBookIds,
      });
      return { ...mergeResult, oldName, wasImplicitMerge: true, mergedEntityId: existingId };
    }

    const scope = { libraryIds: input.libraryIds, contentFilters: input.contentFilters };
    const result = await mutateEntityBooks(
      this.db,
      input,
      scope,
      this.selectMutationBooks([entityId], scope),
      async (tx) => {
        await tx.update(this.entityTable).set({ name: trimmed }).where(eq(this.entityIdCol, entityId));
      },
      (tx) => this.lockMutationEntities(tx, [entityId], scope),
    );
    return { ...result, oldName, wasImplicitMerge: false };
  }

  async deleteEntity(input: DeleteInput): Promise<StrategyDeleteResult> {
    const entityId = input.entityId as number;
    await this.assertScopedRelations([entityId], input.libraryIds, input.contentFilters);
    const [entity] = await this.db.select({ name: this.nameCol }).from(this.entityTable).where(eq(this.entityIdCol, entityId)).limit(1);
    if (!entity) throw new NotFoundException(`${this.entityType} not found`);

    const scope = { libraryIds: input.libraryIds, contentFilters: input.contentFilters };
    const result = await mutateEntityBooks(
      this.db,
      input,
      scope,
      this.selectMutationBooks([entityId], scope),
      async (tx) => {
        await tx.delete(this.junctionTable).where(eq(this.junctionEntityIdCol, entityId));
        if (input.mode !== 'soft') await tx.delete(this.entityTable).where(eq(this.entityIdCol, entityId));
      },
      (tx) => this.lockMutationEntities(tx, [entityId], scope),
    );
    return { ...result, name: (entity as any).name };
  }

  async split(input: SplitInput): Promise<StrategySplitResult> {
    await this.assertScopedRelations([input.entityId], input.libraryIds ?? [], input.contentFilters);
    const [entity] = await this.db.select({ name: this.nameCol }).from(this.entityTable).where(eq(this.entityIdCol, input.entityId)).limit(1);
    if (!entity) throw new NotFoundException(`${this.entityType} not found`);

    const newEntities: { id: number; name: string }[] = [];
    const scope = { libraryIds: input.libraryIds ?? [], contentFilters: input.contentFilters };
    const result = await mutateEntityBooks(
      this.db,
      input,
      scope,
      this.selectMutationBooks([input.entityId], scope),
      async (tx) => {
        for (const name of input.newNames) {
          const trimmed = name.trim();
          const [existing] = await tx.select({ id: this.entityIdCol }).from(this.entityTable).where(eq(this.nameCol, trimmed)).limit(1);
          if (existing) {
            newEntities.push({ id: (existing as any).id, name: trimmed });
          } else {
            const [inserted] = await tx.insert(this.entityTable).values({ name: trimmed }).returning({ id: this.entityIdCol });
            newEntities.push({ id: (inserted as any).id, name: trimmed });
          }
        }

        for (const newEntity of newEntities) {
          if (newEntity.id === input.entityId) throw new BadRequestException('Split names must differ from the original entity');
          await this.insertMutationRelations(tx, newEntity.id);
        }

        await tx.delete(this.junctionTable).where(eq(this.junctionEntityIdCol, input.entityId));
        await tx.delete(this.entityTable).where(eq(this.entityIdCol, input.entityId));
      },
      (tx) => this.lockMutationEntities(tx, [input.entityId], scope),
    );

    return { ...result, originalName: (entity as any).name, newEntities };
  }

  private selectMutationBooks(ids: number[], scope: EntityBookScope) {
    return sql`SELECT DISTINCT ${this.junctionBookIdCol} FROM ${this.junctionTable}
      JOIN ${books} ON ${books.id} = ${this.junctionBookIdCol}
      WHERE ${inArray(this.junctionEntityIdCol, ids)} AND ${and(...buildEntityBookScopeClauses(this.db, scope))}`;
  }

  private async lockMutationEntities(tx: Db, ids: number[], scope: EntityBookScope): Promise<void> {
    const rows = await tx
      .select({ id: this.entityIdCol })
      .from(this.entityTable)
      .where(inArray(this.entityIdCol, ids))
      .orderBy(this.entityIdCol)
      .for('update');
    if (rows.length !== new Set(ids).size) throw new NotFoundException(`${this.entityType} not found`);
    await assertEntityRelationsWithinLibraries(tx, this.rawJunctionTable, this.rawEntityIdCol, ids, scope.libraryIds, scope.contentFilters);
  }

  private async insertMutationRelations(tx: Db, entityId: number): Promise<void> {
    const orderColumn = this.entityType === 'narrator' ? sql`, display_order` : sql``;
    const orderValue = this.entityType === 'narrator' ? sql`, 0` : sql``;
    await tx.execute(sql`INSERT INTO ${this.junctionTable} (book_id, ${sql.identifier(this.rawEntityIdCol)}${orderColumn})
      SELECT book_id, ${entityId}${orderValue} FROM entity_mutation_books WHERE true ON CONFLICT DO NOTHING`);
  }

  async findAffectedBookIds(ids: (number | string)[]): Promise<number[]> {
    const numericIds = ids as number[];
    if (numericIds.length === 0) return [];
    const rows = await this.db
      .selectDistinct({ bookId: this.junctionBookIdCol })
      .from(this.junctionTable)
      .where(inArray(this.junctionEntityIdCol, numericIds));
    return rows.map((r: any) => r.bookId);
  }

  async getBookCount(id: number | string, scope?: EntityBookScope): Promise<number> {
    if (scope) {
      const [row] = await this.db
        .select({ count: count() })
        .from(this.junctionTable)
        .innerJoin(books, eq(books.id, this.junctionBookIdCol))
        .where(and(eq(this.junctionEntityIdCol, id as number), ...buildEntityBookScopeClauses(this.db, scope)));
      return row?.count ?? 0;
    }

    const [row] = await this.db
      .select({ count: count() })
      .from(this.junctionTable)
      .where(eq(this.junctionEntityIdCol, id as number));
    return row?.count ?? 0;
  }

  async getBookTitles(id: number | string, limit: number, scope?: EntityBookScope): Promise<string[]> {
    const rows = await this.db
      .select({ title: sql<string>`COALESCE(${bookMetadata.title}, 'Untitled')` })
      .from(this.junctionTable)
      .innerJoin(books, eq(books.id, this.junctionBookIdCol))
      .leftJoin(bookMetadata, eq(bookMetadata.bookId, books.id))
      .where(and(eq(this.junctionEntityIdCol, id as number), ...(scope ? buildEntityBookScopeClauses(this.db, scope) : [])))
      .orderBy(asc(bookMetadata.title))
      .limit(limit);
    return rows.map((r) => r.title);
  }

  async findEntityById(id: number | string): Promise<{ id: number; name: string } | null> {
    const [row] = await this.db
      .select({ id: this.entityIdCol, name: this.nameCol })
      .from(this.entityTable)
      .where(eq(this.entityIdCol, id as number))
      .limit(1);
    if (!row) return null;
    return { id: (row as any).id, name: (row as any).name };
  }

  protected abstract buildJunctionRow(bookId: number, entityId: number): Record<string, unknown>;

  assertMutationScope(ids: (number | string)[], scope: EntityBookScope): Promise<void> {
    return this.assertScopedRelations(ids as number[], scope.libraryIds, scope.contentFilters);
  }

  private assertScopedRelations(entityIds: number[], libraryIds: number[], contentFilters?: EntityBookScope['contentFilters']): Promise<void> {
    return assertEntityRelationsWithinLibraries(this.db, this.rawJunctionTable, this.rawEntityIdCol, entityIds, libraryIds, contentFilters);
  }
}
