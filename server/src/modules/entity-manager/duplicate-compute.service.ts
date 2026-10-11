import { Inject, Injectable, Logger } from '@nestjs/common';
import { eq, sql, type SQL } from 'drizzle-orm';
import type { NodePgDatabase } from 'drizzle-orm/node-postgres';

import type { EntityType, FirstClassEntityType } from '@bookorbit/types';
import { INLINE_ENTITY_TYPES } from '@bookorbit/types';
import { buildContentFilterClauses } from '../../common/utils/content-filter-sql.utils';
import { sanitizeLogValue } from '../../common/utils/log-sanitize.utils';
import { ENTITY_DUPLICATE_TABLES, scopedBookCondition } from './entity-duplicate-query';
import { DB } from '../../db';
import * as schema from '../../db/schema';
import { books, entityDuplicateCandidates, entityDuplicateScanStatus } from '../../db/schema';
import type { EntityBookScope, EntityStrategy, RawCandidatePair } from './strategies/entity-strategy.interface';

type Db = NodePgDatabase<typeof schema>;

const BATCH_SIZE = 1000;

const ENTITY_BOOK_RELATIONS: Record<FirstClassEntityType, { table: string; entityIdColumn: string }> = {
  author: { table: 'book_authors', entityIdColumn: 'author_id' },
  genre: { table: 'book_genres', entityIdColumn: 'genre_id' },
  tag: { table: 'book_tags', entityIdColumn: 'tag_id' },
  narrator: { table: 'book_narrators', entityIdColumn: 'narrator_id' },
  series: { table: 'book_series_memberships', entityIdColumn: 'series_id' },
};

@Injectable()
export class DuplicateComputeService {
  private readonly logger = new Logger(DuplicateComputeService.name);
  private readonly runningJobs = new Set<EntityType>();

  constructor(@Inject(DB) private readonly db: Db) {}

  private isInline(entityType: EntityType): boolean {
    return INLINE_ENTITY_TYPES.includes(entityType as any);
  }

  async getStatus(entityType: EntityType): Promise<typeof entityDuplicateScanStatus.$inferSelect | null> {
    const rows = await this.db.select().from(entityDuplicateScanStatus).where(eq(entityDuplicateScanStatus.entityType, entityType));
    return rows[0] ?? null;
  }

  triggerCompute(entityType: EntityType, strategy: EntityStrategy, threshold: number): void {
    if (this.isInline(entityType)) return;
    if (this.runningJobs.has(entityType)) return;

    this.runningJobs.add(entityType);
    void this.runComputeJob(entityType, strategy, threshold).finally(() => {
      this.runningJobs.delete(entityType);
    });
  }

  async invalidateCandidatesForEntities(entityType: EntityType, entityIds: number[]): Promise<void> {
    if (entityIds.length === 0) return;
    const idsArray = sql.raw(`ARRAY[${entityIds.join(',')}]::int[]`);
    await this.db.execute(sql`
      DELETE FROM ${entityDuplicateCandidates}
      WHERE ${entityDuplicateCandidates.entityType} = ${entityType}
        AND (
          ${entityDuplicateCandidates.entityIdA} = ANY(${idsArray})
          OR ${entityDuplicateCandidates.entityIdB} = ANY(${idsArray})
        )
    `);
  }

  async readCandidatePairs(
    entityType: EntityType,
    minSimilarity: number,
    scope: EntityBookScope,
  ): Promise<
    {
      idA: number;
      idB: number;
      simScore: number;
    }[]
  > {
    if (scope.libraryIds.length === 0 || this.isInline(entityType)) return [];

    const relation = ENTITY_BOOK_RELATIONS[entityType as FirstClassEntityType];
    const relationTable = sql.raw(relation.table);
    const relationEntityId = sql.raw(`scoped_relation.${relation.entityIdColumn}`);
    const relationBookId = sql.raw('scoped_relation.book_id');
    const scopeClauses = [
      sql`${books.libraryId} IN (${sql.join(
        scope.libraryIds.map((id) => sql`${id}`),
        sql`, `,
      )})`,
    ];
    if (scope.contentFilters) {
      scopeClauses.push(...buildContentFilterClauses(scope.contentFilters, this.db));
    }
    const bookScope = sql.join(scopeClauses, sql` AND `);

    const rows = await this.db.execute<{ idA: number; idB: number; simScore: number }>(sql`
      SELECT
        c.entity_id_a AS "idA",
        c.entity_id_b AS "idB",
        c.sim_score AS "simScore"
      FROM entity_duplicate_candidates c
      WHERE c.entity_type = ${entityType}
        AND c.sim_score >= ${minSimilarity}
        AND EXISTS (
          SELECT 1
          FROM ${relationTable} scoped_relation
          JOIN ${books} ON ${relationBookId} = ${books.id}
          WHERE ${relationEntityId} = c.entity_id_a
            AND ${bookScope}
        )
        AND EXISTS (
          SELECT 1
          FROM ${relationTable} scoped_relation
          JOIN ${books} ON ${relationBookId} = ${books.id}
          WHERE ${relationEntityId} = c.entity_id_b
            AND ${bookScope}
        )
        AND NOT EXISTS (
          SELECT 1 FROM dismissed_duplicate_pairs d
          WHERE d.entity_type = ${entityType}
            AND d.entity_id_a = c.entity_id_a
            AND d.entity_id_b = c.entity_id_b
        )
      ORDER BY c.sim_score DESC, c.entity_id_a, c.entity_id_b
      LIMIT ${BATCH_SIZE}
    `);
    return rows.rows;
  }

  async withCandidateBatches<T = void>(
    entityType: EntityType,
    minSimilarity: number,
    scope: EntityBookScope,
    consume: (pairs: RawCandidatePair[]) => void,
    afterRead?: (replay: (consumer: (pairs: RawCandidatePair[]) => void) => Promise<void>) => Promise<T>,
  ): Promise<T | undefined> {
    if (scope.libraryIds.length === 0) return afterRead?.(async () => {});
    return this.db.transaction(
      async (tx) => {
        await tx.execute(sql`SELECT set_config('pg_trgm.similarity_threshold', ${String(minSimilarity)}, true)`);
        let query: SQL;
        if (this.isInline(entityType)) {
          const value = sql.raw(`bm.${entityType}`);
          await tx.execute(sql`CREATE TEMP TABLE entity_duplicate_values (value text PRIMARY KEY) ON COMMIT DROP`);
          await tx.execute(sql`INSERT INTO entity_duplicate_values(value)
            SELECT DISTINCT ${value} FROM book_metadata bm JOIN books ON books.id = bm.book_id
            WHERE ${value} IS NOT NULL AND ${value} <> '' AND ${scopedBookCondition(this.db, scope)}`);
          await tx.execute(sql`CREATE INDEX ON entity_duplicate_values USING gin (lower(value) gin_trgm_ops)`);
          await tx.execute(sql`ANALYZE entity_duplicate_values`);
          query = sql`SELECT a.value AS "idA", b.value AS "idB", a.value AS "nameA", b.value AS "nameB", similarity(lower(a.value), lower(b.value)) AS "simScore"
          FROM entity_duplicate_values a JOIN entity_duplicate_values b ON a.value < b.value AND lower(a.value) % lower(b.value)
          WHERE similarity(lower(a.value), lower(b.value)) >= ${minSimilarity}
            AND NOT EXISTS (SELECT 1 FROM dismissed_inline_duplicate_pairs d WHERE d.entity_type = ${entityType} AND ((d.value_a = a.value AND d.value_b = b.value) OR (d.value_a = b.value AND d.value_b = a.value)))
          ORDER BY a.value, b.value`;
        } else {
          const definition = ENTITY_DUPLICATE_TABLES[entityType as FirstClassEntityType];
          query = sql`WITH scoped_entities AS MATERIALIZED (
            SELECT DISTINCT ${sql.raw(`r.${definition.column}`)} AS id FROM ${sql.raw(definition.relation)} r JOIN books ON books.id = r.book_id
            WHERE ${scopedBookCondition(this.db, scope)}
          ) SELECT c.entity_id_a AS "idA", c.entity_id_b AS "idB", '' AS "nameA", '' AS "nameB", c.sim_score AS "simScore"
          FROM entity_duplicate_candidates c JOIN scoped_entities a ON a.id = c.entity_id_a JOIN scoped_entities b ON b.id = c.entity_id_b
          WHERE c.entity_type = ${entityType} AND c.sim_score >= ${minSimilarity}
            AND NOT EXISTS (SELECT 1 FROM dismissed_duplicate_pairs d WHERE d.entity_type = ${entityType} AND d.entity_id_a = c.entity_id_a AND d.entity_id_b = c.entity_id_b)
          ORDER BY c.entity_id_a, c.entity_id_b`;
        }
        const read = async (consumer: (pairs: RawCandidatePair[]) => void) => {
          await tx.execute(sql`DECLARE entity_candidate_cursor NO SCROLL CURSOR FOR ${query}`);
          try {
            while (true) {
              const batch = await tx.execute<RawCandidatePair & Record<string, unknown>>(
                sql`FETCH FORWARD ${sql.raw(String(BATCH_SIZE))} FROM entity_candidate_cursor`,
              );
              if (batch.rows.length === 0) break;
              consumer(batch.rows);
            }
          } finally {
            await tx.execute(sql`CLOSE entity_candidate_cursor`);
          }
        };
        await read(consume);
        return afterRead?.(read);
      },
      { isolationLevel: 'repeatable read' },
    );
  }

  async countScopedCandidates(entityType: EntityType, scope: EntityBookScope): Promise<number> {
    if (scope.libraryIds.length === 0 || this.isInline(entityType)) return 0;
    const definition = ENTITY_DUPLICATE_TABLES[entityType as FirstClassEntityType];
    const result = await this.db.execute<{ total: number }>(sql`WITH scoped_entities AS MATERIALIZED (
      SELECT DISTINCT ${sql.raw(`r.${definition.column}`)} AS id FROM ${sql.raw(definition.relation)} r JOIN books ON books.id = r.book_id
      WHERE ${scopedBookCondition(this.db, scope)}
    ) SELECT count(*)::int AS total FROM entity_duplicate_candidates c
      JOIN scoped_entities a ON a.id = c.entity_id_a JOIN scoped_entities b ON b.id = c.entity_id_b
      WHERE c.entity_type = ${entityType}`);
    return result.rows[0]?.total ?? 0;
  }

  private async runComputeJob(entityType: EntityType, _strategy: EntityStrategy, threshold: number): Promise<void> {
    const event = 'entity_duplicates.compute';
    const startedAt = Date.now();
    try {
      this.logger.log(`[${event}] [start] entityType=${entityType} threshold=${threshold} - compute started`);
      const table = sql.raw(ENTITY_DUPLICATE_TABLES[entityType as FirstClassEntityType].table);
      await this.db
        .insert(entityDuplicateScanStatus)
        .values({ entityType, isComputing: true, threshold, processedCount: 0, errorMessage: null })
        .onConflictDoUpdate({
          target: entityDuplicateScanStatus.entityType,
          set: { isComputing: true, computedAt: null, threshold, processedCount: 0, totalCount: null, totalPairs: null, errorMessage: null },
        });
      await this.db.execute(sql`DELETE FROM ${entityDuplicateCandidates} WHERE ${entityDuplicateCandidates.entityType} = ${entityType}`);
      const counts = await this.db.execute<{ total: number }>(sql`SELECT count(*)::int AS total FROM ${table}`);
      const totalCount = counts.rows[0]?.total ?? 0;
      await this.db.update(entityDuplicateScanStatus).set({ totalCount }).where(eq(entityDuplicateScanStatus.entityType, entityType));
      let afterId = 0;
      let processedCount = 0;
      let totalPairs = 0;
      while (true) {
        const batch = await this.db.execute<{ id: number }>(sql`SELECT id FROM ${table} WHERE id > ${afterId} ORDER BY id LIMIT ${BATCH_SIZE}`);
        if (batch.rows.length === 0) break;
        const ids = sql.join(
          batch.rows.map((row) => sql`${row.id}`),
          sql`, `,
        );
        const inserted = await this.db.transaction(async (tx) => {
          await tx.execute(sql`SELECT set_config('pg_trgm.similarity_threshold', ${String(threshold)}, true)`);
          return tx.execute<{ total: number }>(sql`WITH inserted AS (
            INSERT INTO entity_duplicate_candidates (entity_type, entity_id_a, entity_id_b, sim_score)
            SELECT ${entityType}, a.id, b.id, similarity(a.name, b.name) FROM ${table} a
            JOIN ${table} b ON a.id < b.id AND a.name % b.name
            WHERE a.id IN (${ids}) AND similarity(a.name, b.name) >= ${threshold}
            ON CONFLICT DO NOTHING RETURNING 1
          ) SELECT count(*)::int AS total FROM inserted`);
        });
        totalPairs += inserted.rows[0]?.total ?? 0;
        processedCount += batch.rows.length;
        afterId = batch.rows[batch.rows.length - 1]!.id;
        await this.db.update(entityDuplicateScanStatus).set({ processedCount }).where(eq(entityDuplicateScanStatus.entityType, entityType));
      }
      await this.db
        .update(entityDuplicateScanStatus)
        .set({ isComputing: false, computedAt: new Date(), totalPairs, processedCount })
        .where(eq(entityDuplicateScanStatus.entityType, entityType));
      this.logger.log(
        `[${event}] [end] entityType=${entityType} durationMs=${Date.now() - startedAt} totalPairs=${totalPairs} processedCount=${processedCount} - compute completed`,
      );
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      const errorClass = err instanceof Error ? err.name : 'Unknown';
      this.logger.warn(
        `[${event}] [fail] entityType=${entityType} durationMs=${Date.now() - startedAt} errorClass=${errorClass} error="${sanitizeLogValue(msg)}" - compute failed`,
      );
      await this.db
        .update(entityDuplicateScanStatus)
        .set({ isComputing: false, computedAt: null, errorMessage: msg.slice(0, 500) })
        .where(eq(entityDuplicateScanStatus.entityType, entityType))
        .catch(() => {});
    }
  }
}
