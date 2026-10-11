import { BadRequestException, Inject, Injectable } from '@nestjs/common';
import { and, eq, inArray, sql, type SQL } from 'drizzle-orm';
import type { NodePgDatabase } from 'drizzle-orm/node-postgres';

import { DB } from '../../../db';
import * as schema from '../../../db/schema';
import { MigrationPlanMatchRepository } from '../migration-plan-match.repository';

export const PLAN_ARRAY_FIELDS = ['matchedBooks', 'unresolvedBooks', 'duplicateBookMatches', 'userPreview', 'userMappings'] as const;
export type PlanArrayField = (typeof PLAN_ARRAY_FIELDS)[number];
export type DuplicateArrayField = 'sourceBookIds' | 'strategies' | 'matches' | 'sourceCandidates';

function arrayValue(value: SQL): SQL {
  return sql`CASE WHEN jsonb_typeof(${value}) = 'array' THEN ${value} ELSE '[]'::jsonb END`;
}

export function arrayPage(value: SQL, offset: number, limit: number): SQL<unknown[]> {
  const rows = arrayValue(value);
  return sql<unknown[]>`COALESCE((SELECT jsonb_agg(${rows}->i ORDER BY i)
    FROM generate_series(${offset}::integer, LEAST(${offset + limit - 1}::integer, jsonb_array_length(${rows}) - 1)) i), '[]'::jsonb)`;
}

export function duplicatePreview(value: SQL, limit: number): SQL {
  return sql`((${value}) - 'sourceBookIds' - 'strategies' - 'matches' - 'sourceCandidates') || jsonb_build_object(
    'sourceBookIds', ${arrayPage(sql`${value}->'sourceBookIds'`, 0, limit)},
    'strategies', ${arrayPage(sql`${value}->'strategies'`, 0, limit)},
    'matches', ${arrayPage(sql`${value}->'matches'`, 0, limit)},
    'sourceCandidates', ${arrayPage(sql`${value}->'sourceCandidates'`, 0, limit)},
    'candidatePagination', jsonb_build_object('total', jsonb_array_length(${arrayValue(sql`${value}->'sourceBookIds'`)}),
      'limit', ${limit}::integer, 'nextOffset', CASE WHEN jsonb_array_length(${arrayValue(sql`${value}->'sourceBookIds'`)}) > ${limit} THEN ${limit}::integer ELSE NULL END))`;
}

@Injectable()
export class MigrationReportRepository {
  constructor(@Inject(DB) private readonly db: NodePgDatabase<typeof schema>) {}

  async findArtifact(id: number) {
    const table = schema.migrationPlanArtifacts;
    const [row] = await this.db
      .select({
        id: table.id,
        createdByUserId: table.createdByUserId,
        plan: sql<unknown>`CASE WHEN jsonb_typeof(${table.plan}) = 'object' THEN ${table.plan} - 'matchedBooks' - 'unresolvedBooks' - 'duplicateBookMatches' - 'userPreview' - 'userMappings' ELSE NULL END`,
        planFields: sql<
          PlanArrayField[]
        >`ARRAY(SELECT key FROM jsonb_object_keys(CASE WHEN jsonb_typeof(${table.plan}) = 'object' THEN ${table.plan} ELSE '{}'::jsonb END) key WHERE key IN ('matchedBooks', 'unresolvedBooks', 'duplicateBookMatches', 'userPreview', 'userMappings'))`,
        summary: sql<unknown>`CASE WHEN jsonb_typeof(${table.summary}) = 'object' THEN ${table.summary} - 'perUserPreview' ELSE NULL END`,
        hasUserPreview: sql<boolean>`jsonb_typeof(${table.plan}->'userPreview') = 'array'`,
        hasSummaryPreview: sql<boolean>`jsonb_typeof(${table.summary}->'perUserPreview') = 'array'`,
      })
      .from(table)
      .where(eq(table.id, id));
    return row ?? null;
  }

  async planPage(id: number, field: PlanArrayField | 'perUserPreview', offset: number, limit: number, previewDuplicates = true) {
    if (field === 'matchedBooks') return new MigrationPlanMatchRepository(this.db).page(id, offset, limit);
    const table = schema.migrationPlanArtifacts;
    const value = field === 'perUserPreview' ? sql`${table.summary}->${field}` : sql`${table.plan}->${field}`;
    const rows = arrayValue(value);
    const items =
      field === 'duplicateBookMatches' && previewDuplicates
        ? sql<unknown[]>`COALESCE((SELECT jsonb_agg(${duplicatePreview(sql`${rows}->group_index`, 40)} ORDER BY group_index)
          FROM generate_series(${offset}::integer, LEAST(${offset + limit - 1}::integer, jsonb_array_length(${rows}) - 1)) group_index), '[]'::jsonb)`
        : arrayPage(value, offset, limit);
    const [row] = await this.db
      .select({ total: sql<number>`jsonb_array_length(${rows})`, items })
      .from(table)
      .where(eq(table.id, id));
    return row ?? null;
  }

  async duplicateGroup(id: number, targetBookId: number) {
    const result = await this.db.execute<{ base: Record<string, unknown>; total: number; fields: string[] }>(sql`
      SELECT entry - 'sourceBookIds' - 'strategies' - 'matches' - 'sourceCandidates' AS base,
        jsonb_array_length(${arrayValue(sql`entry->'sourceBookIds'`)}) AS total,
        ARRAY(SELECT key FROM jsonb_object_keys(entry) key WHERE key IN ('sourceBookIds', 'strategies', 'matches', 'sourceCandidates')) AS fields
      FROM ${schema.migrationPlanArtifacts}, LATERAL jsonb_array_elements(${arrayValue(sql`${schema.migrationPlanArtifacts.plan}->'duplicateBookMatches'`)}) entry
      WHERE ${schema.migrationPlanArtifacts.id} = ${id} AND entry->>'targetBookId' = ${String(targetBookId)} LIMIT 1`);
    return result.rows[0] ?? null;
  }

  async duplicatePage(id: number, targetBookId: number, field: DuplicateArrayField, offset: number, limit: number) {
    const result = await this.db.execute<{ items: unknown[] }>(sql`
      SELECT ${arrayPage(sql`entry->${field}`, offset, limit)} AS items
      FROM ${schema.migrationPlanArtifacts}, LATERAL jsonb_array_elements(${arrayValue(sql`${schema.migrationPlanArtifacts.plan}->'duplicateBookMatches'`)}) entry
      WHERE ${schema.migrationPlanArtifacts.id} = ${id} AND entry->>'targetBookId' = ${String(targetBookId)} LIMIT 1`);
    return result.rows[0]?.items ?? [];
  }

  async sourceBooks(id: number, sourceBookIds: string[]) {
    if (sourceBookIds.length > 100) throw new BadRequestException('Migration source metadata lookups support at most 100 books');
    if (sourceBookIds.length === 0) return new Map<string, { title: string | null; author: string | null; filePath: string | null }>();
    const artifact = schema.migrationPlanArtifacts;
    const [storage] = await this.db
      .select({ userId: artifact.createdByUserId, indexed: sql<boolean>`COALESCE(${artifact.plan}->>'sourceBooksIndexed' = 'true', false)` })
      .from(artifact)
      .where(eq(artifact.id, id))
      .limit(1);
    if (storage?.indexed && storage.userId !== null) {
      const t = schema.migrationPlanSourceBooks;
      const rows = await this.db
        .select({ sourceBookId: t.sourceBookId, title: t.title, author: t.author, filePath: t.filePath })
        .from(t)
        .where(and(eq(t.artifactId, id), eq(t.userId, storage.userId), inArray(t.sourceBookId, sourceBookIds)))
        .limit(sourceBookIds.length);
      return new Map(rows.map((row) => [row.sourceBookId, row]));
    }
    const rows = await this.db.execute<{ sourceBookId: string; title: string | null; author: string | null; filePath: string | null }>(sql`
      SELECT DISTINCT ON (book->>'sourceBookId') book->>'sourceBookId' AS "sourceBookId",
        book->>'title' AS title, book->>'author' AS author, book->>'filePath' AS "filePath"
      FROM (
        SELECT ${schema.migrationPlanSourceBatches.sourceData} AS data FROM ${schema.migrationPlanSourceBatches}
        WHERE ${schema.migrationPlanSourceBatches.artifactId} = ${id}
        UNION ALL
        SELECT ${schema.migrationPlanArtifacts.sourceData} AS data FROM ${schema.migrationPlanArtifacts}
        WHERE ${schema.migrationPlanArtifacts.id} = ${id} AND ${schema.migrationPlanArtifacts.sourceData} IS NOT NULL
      ) batches, LATERAL jsonb_array_elements(${arrayValue(sql`data->'books'`)}) book
      WHERE book->>'sourceBookId' = ANY(${sql.param(sourceBookIds)}::text[])
      ORDER BY book->>'sourceBookId' LIMIT ${sourceBookIds.length}`);
    return new Map(rows.rows.map((row) => [row.sourceBookId, row]));
  }
}
