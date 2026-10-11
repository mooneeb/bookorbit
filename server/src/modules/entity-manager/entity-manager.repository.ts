import { ConflictException, Inject, Injectable, NotFoundException } from '@nestjs/common';
import { and, eq, inArray, isNull, lt, or, sql } from 'drizzle-orm';
import type { NodePgDatabase } from 'drizzle-orm/node-postgres';

import type { ClusterEntity, DismissedPairInfo, EntityType, FirstClassEntityType } from '@bookorbit/types';
import { DB } from '../../db';
import * as schema from '../../db/schema';
import { books, entityFileWrites, entityFileWriteBooks, dismissedDuplicatePairs, dismissedInlineDuplicatePairs } from '../../db/schema';
import { buildEntityBookScopeClauses } from './strategies/entity-book-scope';
import { ENTITY_DUPLICATE_TABLES, scopedBookCondition, scopedEntityCondition } from './entity-duplicate-query';
import type { EntityBookScope } from './strategies/entity-strategy.interface';

type Db = NodePgDatabase<typeof schema>;

@Injectable()
export class EntityManagerRepository {
  constructor(@Inject(DB) private readonly db: Db) {}

  async listFileWriteRecovery(userId: number, entityType: EntityType) {
    return this.db
      .select({ operationId: entityFileWrites.id })
      .from(entityFileWrites)
      .where(and(eq(entityFileWrites.userId, userId), eq(entityFileWrites.entityType, entityType)))
      .orderBy(
        sql`coalesce((select max(attempted_at) from ${entityFileWriteBooks} where operation_id = ${entityFileWrites.id}), ${entityFileWrites.createdAt})`,
        entityFileWrites.createdAt,
      )
      .limit(20);
  }

  async resumeFileWrites(
    operationId: string,
    userId: number,
    entityType: EntityType,
    write: (ids: number[]) => Promise<number[]>,
    attemptedBefore?: Date,
  ) {
    return this.db.transaction(async (tx) => {
      const lock = await tx.execute<{ acquired: boolean }>(sql`SELECT pg_try_advisory_xact_lock(hashtext(${operationId})) AS acquired`);
      if (!lock.rows[0]?.acquired) throw new ConflictException('File updates are already running');
      const [receipt] = await tx
        .select()
        .from(entityFileWrites)
        .where(and(eq(entityFileWrites.id, operationId), eq(entityFileWrites.userId, userId), eq(entityFileWrites.entityType, entityType)))
        .limit(1);
      if (!receipt) throw new NotFoundException('File update operation not found');
      const rows = await tx
        .select({ bookId: entityFileWriteBooks.bookId })
        .from(entityFileWriteBooks)
        .where(
          and(
            eq(entityFileWriteBooks.operationId, operationId),
            attemptedBefore ? or(isNull(entityFileWriteBooks.attemptedAt), lt(entityFileWriteBooks.attemptedAt, attemptedBefore)) : undefined,
          ),
        )
        .orderBy(sql`${entityFileWriteBooks.attemptedAt} ASC NULLS FIRST`, entityFileWriteBooks.bookId)
        .limit(50);
      const completed = await write(rows.map((row) => row.bookId));
      if (rows.length)
        await tx
          .update(entityFileWriteBooks)
          .set({ attemptedAt: new Date() })
          .where(
            and(
              eq(entityFileWriteBooks.operationId, operationId),
              inArray(
                entityFileWriteBooks.bookId,
                rows.map((row) => row.bookId),
              ),
            ),
          );
      if (completed.length)
        await tx
          .delete(entityFileWriteBooks)
          .where(and(eq(entityFileWriteBooks.operationId, operationId), inArray(entityFileWriteBooks.bookId, completed)));
      const remaining = await tx.execute<{ count: number }>(
        sql`SELECT count(*)::int AS count FROM ${entityFileWriteBooks} WHERE operation_id = ${operationId}::uuid`,
      );
      const pendingBookCount = remaining.rows[0]?.count ?? 0;
      if (!pendingBookCount) await tx.delete(entityFileWrites).where(eq(entityFileWrites.id, operationId));
      return { operationId, pendingBookCount, processed: rows.length, completed: completed.length };
    });
  }

  async filterBookIdsByScope(bookIds: number[], scope: EntityBookScope): Promise<number[]> {
    if (bookIds.length === 0 || scope.libraryIds.length === 0) return [];
    const rows = await this.db
      .select({ id: books.id })
      .from(books)
      .where(and(inArray(books.id, bookIds), ...buildEntityBookScopeClauses(this.db, scope)));
    return rows.map((row) => row.id);
  }

  async insertDismissedPair(entityType: EntityType, idA: number, idB: number, reason: string | undefined, dismissedBy: number): Promise<void> {
    const [canonA, canonB] = idA < idB ? [idA, idB] : [idB, idA];
    await this.db
      .insert(dismissedDuplicatePairs)
      .values({ entityType, entityIdA: canonA, entityIdB: canonB, reason: reason ?? null, dismissedBy })
      .onConflictDoNothing();
  }

  async deleteDismissedPair(entityType: EntityType, idA: number, idB: number): Promise<void> {
    const [canonA, canonB] = idA < idB ? [idA, idB] : [idB, idA];
    await this.db
      .delete(dismissedDuplicatePairs)
      .where(
        and(
          eq(dismissedDuplicatePairs.entityType, entityType),
          eq(dismissedDuplicatePairs.entityIdA, canonA),
          eq(dismissedDuplicatePairs.entityIdB, canonB),
        ),
      );
  }

  async deleteDismissedPairsForEntity(entityType: EntityType, entityId: number): Promise<void> {
    await this.db.execute(sql`
      DELETE FROM ${dismissedDuplicatePairs}
      WHERE ${dismissedDuplicatePairs.entityType} = ${entityType}
      AND (${dismissedDuplicatePairs.entityIdA} = ${entityId} OR ${dismissedDuplicatePairs.entityIdB} = ${entityId})
    `);
  }

  async findDismissedPairs(
    entityType: EntityType,
  ): Promise<{ id: number; entityIdA: number; entityIdB: number; reason: string | null; dismissedAt: Date }[]> {
    return this.db
      .select({
        id: dismissedDuplicatePairs.id,
        entityIdA: dismissedDuplicatePairs.entityIdA,
        entityIdB: dismissedDuplicatePairs.entityIdB,
        reason: dismissedDuplicatePairs.reason,
        dismissedAt: dismissedDuplicatePairs.dismissedAt,
      })
      .from(dismissedDuplicatePairs)
      .where(eq(dismissedDuplicatePairs.entityType, entityType));
  }

  async findDismissedPairsPage(
    entityType: EntityType,
    scope: EntityBookScope,
    page: number,
    pageSize: number,
  ): Promise<{ items: DismissedPairInfo[]; total: number }> {
    if (scope.libraryIds.length === 0) return { items: [], total: 0 };
    const inline = entityType === 'publisher' || entityType === 'language';
    const table = inline ? dismissedInlineDuplicatePairs : dismissedDuplicatePairs;
    const identityA = sql.raw(inline ? 'd.value_a' : 'd.entity_id_a');
    const identityB = sql.raw(inline ? 'd.value_b' : 'd.entity_id_b');
    const visibility = sql`d.entity_type = ${entityType}
      AND ${scopedEntityCondition(this.db, entityType, identityA, scope)}
      AND ${scopedEntityCondition(this.db, entityType, identityB, scope)}`;
    const count = await this.db.execute<{ total: number }>(sql`SELECT count(*)::int AS total FROM ${table} d WHERE ${visibility}`);
    const total = count.rows[0]?.total ?? 0;
    const entityTable = inline ? null : sql.raw(ENTITY_DUPLICATE_TABLES[entityType as FirstClassEntityType].table);
    const names = inline ? sql`d.value_a AS "nameA", d.value_b AS "nameB"` : sql`a.name AS "nameA", b.name AS "nameB"`;
    const joins = entityTable ? sql`JOIN ${entityTable} a ON a.id = d.entity_id_a JOIN ${entityTable} b ON b.id = d.entity_id_b` : sql``;
    const result = await this.db.execute<Omit<DismissedPairInfo, 'entityType' | 'dismissedAt'> & { dismissedAt: string }>(sql`
      SELECT d.id, ${identityA} AS "idA", ${identityB} AS "idB", ${names}, d.reason, d.dismissed_at AS "dismissedAt"
      FROM ${table} d ${joins} WHERE ${visibility}
      ORDER BY d.dismissed_at DESC, d.id DESC LIMIT ${pageSize} OFFSET ${(page - 1) * pageSize}`);
    return { items: result.rows.map((row) => ({ ...row, entityType, dismissedAt: new Date(row.dismissedAt).toISOString() })), total };
  }

  async findClusterEntities(entityType: EntityType, identities: (number | string)[], scope: EntityBookScope): Promise<ClusterEntity[]> {
    if (identities.length === 0 || scope.libraryIds.length === 0) return [];
    const inline = entityType === 'publisher' || entityType === 'language';
    const definition = inline ? null : ENTITY_DUPLICATE_TABLES[entityType as FirstClassEntityType];
    const identity = sql.raw(inline ? `bm.${entityType}` : `r.${definition!.column}`);
    const values = sql.join(
      identities.map((id) => sql`${id}`),
      sql`, `,
    );
    const relations = inline
      ? sql`book_metadata bm JOIN books ON books.id = bm.book_id`
      : sql`${sql.raw(definition!.relation)} r JOIN books ON books.id = r.book_id LEFT JOIN book_metadata bm ON bm.book_id = books.id`;
    const entityJoin = definition ? sql`JOIN ${sql.raw(definition.table)} e ON e.id = selected.id` : sql``;
    const name = inline ? sql`selected.id` : sql`e.name`;
    const sortName = entityType === 'author' || entityType === 'narrator' ? sql`e.sort_name` : sql`NULL::text`;
    const photo = entityType === 'author' ? sql`e.has_photo` : sql`false`;
    const result = await this.db.execute<ClusterEntity & Record<string, unknown>>(sql`
      WITH scoped AS MATERIALIZED (
        SELECT DISTINCT ${identity} AS id, books.id AS book_id, left(COALESCE(bm.title, 'Untitled'), 120) AS title
        FROM ${relations} WHERE ${identity} IN (${values}) AND ${scopedBookCondition(this.db, scope)}
      ), selected AS (
        SELECT id, count(*)::int AS book_count FROM scoped GROUP BY id
      ), titles AS (
        SELECT id, title, row_number() OVER (PARTITION BY id ORDER BY title, book_id) AS position FROM scoped
      )
      SELECT selected.id, ${name} AS name, selected.book_count AS "bookCount", ${sortName} AS "sortName", ${photo} AS "hasPhoto",
        COALESCE(previews.titles, ARRAY[]::text[]) AS "bookTitles"
      FROM selected ${entityJoin} LEFT JOIN (SELECT id, array_agg(title ORDER BY position) AS titles FROM titles WHERE position <= 5 GROUP BY id) previews ON previews.id = selected.id ORDER BY selected.id`);
    return result.rows;
  }

  async getDismissedPairSet(entityType: EntityType): Promise<Set<string>> {
    const pairs = await this.findDismissedPairs(entityType);
    const set = new Set<string>();
    for (const pair of pairs) {
      set.add(`${pair.entityIdA}:${pair.entityIdB}`);
      set.add(`${pair.entityIdB}:${pair.entityIdA}`);
    }
    return set;
  }

  // Inline dismissals

  async insertInlineDismissedPair(
    entityType: EntityType,
    valueA: string,
    valueB: string,
    reason: string | undefined,
    dismissedBy: number,
  ): Promise<void> {
    const [canonA, canonB] = valueA < valueB ? [valueA, valueB] : [valueB, valueA];
    await this.db
      .insert(dismissedInlineDuplicatePairs)
      .values({ entityType, valueA: canonA, valueB: canonB, reason: reason ?? null, dismissedBy })
      .onConflictDoNothing();
  }

  async deleteInlineDismissedPair(entityType: EntityType, valueA: string, valueB: string): Promise<void> {
    const [canonA, canonB] = valueA < valueB ? [valueA, valueB] : [valueB, valueA];
    await this.db
      .delete(dismissedInlineDuplicatePairs)
      .where(
        and(
          eq(dismissedInlineDuplicatePairs.entityType, entityType),
          eq(dismissedInlineDuplicatePairs.valueA, canonA),
          eq(dismissedInlineDuplicatePairs.valueB, canonB),
        ),
      );
  }

  async deleteInlineDismissedPairsForValue(entityType: EntityType, value: string): Promise<void> {
    await this.db
      .delete(dismissedInlineDuplicatePairs)
      .where(
        and(
          eq(dismissedInlineDuplicatePairs.entityType, entityType),
          or(eq(dismissedInlineDuplicatePairs.valueA, value), eq(dismissedInlineDuplicatePairs.valueB, value)),
        ),
      );
  }

  async findInlineDismissedPairs(
    entityType: EntityType,
  ): Promise<{ id: number; valueA: string; valueB: string; reason: string | null; dismissedAt: Date }[]> {
    return this.db
      .select({
        id: dismissedInlineDuplicatePairs.id,
        valueA: dismissedInlineDuplicatePairs.valueA,
        valueB: dismissedInlineDuplicatePairs.valueB,
        reason: dismissedInlineDuplicatePairs.reason,
        dismissedAt: dismissedInlineDuplicatePairs.dismissedAt,
      })
      .from(dismissedInlineDuplicatePairs)
      .where(eq(dismissedInlineDuplicatePairs.entityType, entityType));
  }

  async getInlineDismissedPairSet(entityType: EntityType): Promise<Set<string>> {
    const pairs = await this.findInlineDismissedPairs(entityType);
    const set = new Set<string>();
    for (const pair of pairs) {
      set.add(`${pair.valueA}:${pair.valueB}`);
      set.add(`${pair.valueB}:${pair.valueA}`);
    }
    return set;
  }
}
