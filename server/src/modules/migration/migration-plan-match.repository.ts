import { BadRequestException } from '@nestjs/common';
import { and, asc, eq, inArray, sql } from 'drizzle-orm';
import type { NodePgDatabase } from 'drizzle-orm/node-postgres';

import * as schema from '../../db/schema';
import type { PlannedBookMatch } from './planner/planner.types';

type MatchDb = Pick<NodePgDatabase<typeof schema>, 'select' | 'insert' | 'delete' | 'execute'>;
export const MIGRATION_MATCH_PAGE_SIZE = 100;

export class MigrationPlanMatchRepository {
  constructor(private readonly db: MatchDb) {}

  async replace(artifactId: number, userId: number, matches: PlannedBookMatch[]): Promise<void> {
    await this.db
      .delete(schema.migrationPlanBookMatches)
      .where(and(eq(schema.migrationPlanBookMatches.artifactId, artifactId), eq(schema.migrationPlanBookMatches.userId, userId)));
    await this.append(artifactId, userId, matches);
  }

  async append(artifactId: number, userId: number, matches: PlannedBookMatch[]): Promise<void> {
    if (matches.length === 0) return;
    const table = schema.migrationPlanBookMatches;
    const [row] = await this.db
      .select({ nextPosition: sql<number>`COALESCE(MAX(${table.position}), -1) + 1` })
      .from(table)
      .where(and(eq(table.artifactId, artifactId), eq(table.userId, userId)));
    const nextPosition = Number(row?.nextPosition ?? 0);
    for (let offset = 0; offset < matches.length; offset += MIGRATION_MATCH_PAGE_SIZE) {
      await this.db
        .insert(table)
        .values(
          matches
            .slice(offset, offset + MIGRATION_MATCH_PAGE_SIZE)
            .map((match, index) => ({ artifactId, userId, position: nextPosition + offset + index, ...match })),
        )
        .onConflictDoNothing({ target: [table.artifactId, table.userId, table.sourceBookId] });
    }
  }

  async pageForOwner(artifactId: number, userId: number, offset: number, limit: number) {
    const table = schema.migrationPlanBookMatches;
    const predicate = and(eq(table.artifactId, artifactId), eq(table.userId, userId));
    const [count] = await this.db
      .select({ total: sql<number>`COUNT(*)::integer` })
      .from(table)
      .where(predicate);
    const items = await this.db
      .select({ sourceBookId: table.sourceBookId, targetBookId: table.targetBookId, strategy: table.strategy })
      .from(table)
      .where(predicate)
      .orderBy(asc(table.position))
      .limit(boundedLimit(limit))
      .offset(boundedOffset(offset));
    return { total: Number(count?.total ?? 0), items: items as PlannedBookMatch[] };
  }

  async page(artifactId: number, offset: number, limit = MIGRATION_MATCH_PAGE_SIZE) {
    const artifact = await this.artifactStorage(artifactId);
    if (!artifact) return null;
    if (artifact.batched && artifact.userId !== null) return this.pageForOwner(artifactId, artifact.userId, offset, limit);
    const table = schema.migrationPlanArtifacts;
    const rows = sql`CASE WHEN jsonb_typeof(${table.plan}->'matchedBooks') = 'array' THEN ${table.plan}->'matchedBooks' ELSE '[]'::jsonb END`;
    const pageOffset = boundedOffset(offset);
    const pageLimit = boundedLimit(limit);
    const result = await this.db.execute<{ total: number; items: PlannedBookMatch[] }>(sql`
      SELECT jsonb_array_length(${rows}) AS total,
        COALESCE((SELECT jsonb_agg(${rows}->i ORDER BY i)
          FROM generate_series(${pageOffset}::integer, LEAST(${pageOffset + pageLimit - 1}::integer, jsonb_array_length(${rows}) - 1)) i), '[]'::jsonb) AS items
      FROM ${table} WHERE ${table.id} = ${artifactId}
        AND ${table.createdByUserId} IS NOT DISTINCT FROM ${artifact.userId}`);
    return result.rows[0] ?? null;
  }

  async forSourceBooks(artifactId: number, sourceBookIds: string[]): Promise<PlannedBookMatch[]> {
    if (sourceBookIds.length > MIGRATION_MATCH_PAGE_SIZE) throw new BadRequestException('Migration match lookups support at most 100 source books');
    const ids = [...new Set(sourceBookIds)];
    if (ids.length === 0) return [];
    const artifact = await this.artifactStorage(artifactId);
    if (!artifact) return [];
    if (artifact.batched && artifact.userId !== null) {
      const table = schema.migrationPlanBookMatches;
      const items = await this.db
        .select({ sourceBookId: table.sourceBookId, targetBookId: table.targetBookId, strategy: table.strategy })
        .from(table)
        .where(and(eq(table.artifactId, artifactId), eq(table.userId, artifact.userId), inArray(table.sourceBookId, ids)))
        .orderBy(asc(table.position))
        .limit(ids.length);
      return items as PlannedBookMatch[];
    }
    const table = schema.migrationPlanArtifacts;
    const result = await this.db.execute<{ match: PlannedBookMatch }>(sql`
      SELECT match FROM ${table}, LATERAL jsonb_array_elements(
        CASE WHEN jsonb_typeof(${table.plan}->'matchedBooks') = 'array' THEN ${table.plan}->'matchedBooks' ELSE '[]'::jsonb END) match
      WHERE ${table.id} = ${artifactId} AND ${table.createdByUserId} IS NOT DISTINCT FROM ${artifact.userId}
        AND match->>'sourceBookId' = ANY(${sql.param(ids)}::text[]) LIMIT ${ids.length}`);
    return result.rows.map((row) => row.match);
  }

  private async artifactStorage(artifactId: number) {
    const table = schema.migrationPlanArtifacts;
    const [row] = await this.db
      .select({ userId: table.createdByUserId, batched: sql<boolean>`COALESCE(${table.plan}->>'matchedBooksBatched' = 'true', false)` })
      .from(table)
      .where(eq(table.id, artifactId))
      .limit(1);
    return row ?? null;
  }
}

function boundedLimit(limit: number): number {
  return Number.isFinite(limit) ? Math.min(Math.max(Math.floor(limit), 1), MIGRATION_MATCH_PAGE_SIZE) : MIGRATION_MATCH_PAGE_SIZE;
}

function boundedOffset(offset: number): number {
  return Number.isFinite(offset) ? Math.min(Math.max(Math.floor(offset), 0), 2_147_483_547) : 0;
}
