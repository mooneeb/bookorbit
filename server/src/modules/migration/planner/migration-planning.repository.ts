import { BadRequestException, NotFoundException } from '@nestjs/common';
import { and, eq, getTableColumns, inArray, sql } from 'drizzle-orm';
import type { NodePgDatabase } from 'drizzle-orm/node-postgres';

import * as schema from '../../../db/schema';
import { arrayPage, duplicatePreview } from '../reporting/migration-report.repository';
import type { MigrationPlanningStore, PlannedMigration, PlannerResult } from './planner.types';

export class MigrationPlanningRepository implements MigrationPlanningStore {
  constructor(
    private readonly db: NodePgDatabase<typeof schema>,
    private readonly artifactId: number,
    private readonly userId: number,
  ) {}

  async knownSourceBookIds(sourceBookIds: string[]) {
    this.assertBound(sourceBookIds);
    if (sourceBookIds.length === 0) return new Set<string>();
    const t = schema.migrationPlanSourceBooks;
    const rows = await this.db
      .select({ sourceBookId: t.sourceBookId })
      .from(t)
      .where(and(eq(t.artifactId, this.artifactId), eq(t.userId, this.userId), inArray(t.sourceBookId, sourceBookIds)))
      .limit(sourceBookIds.length);
    return new Set(rows.map((row) => row.sourceBookId));
  }

  async appendCandidates(
    books: Parameters<MigrationPlanningStore['appendCandidates']>[0],
    matched: Parameters<MigrationPlanningStore['appendCandidates']>[1],
  ) {
    this.assertBound(books);
    if (books.length === 0) return;
    const matches = new Map(matched.matches.map((row) => [row.sourceBookId, row]));
    const unresolved = new Map(matched.unresolved.map((row) => [row.sourceBookId, row]));
    const t = schema.migrationPlanSourceBooks;
    await this.db
      .insert(t)
      .values(
        books.map((book) => ({
          artifactId: this.artifactId,
          userId: this.userId,
          sourceBookId: book.sourceBookId,
          title: book.title,
          author: book.author,
          filePath: book.filePath,
          targetBookId: matches.get(book.sourceBookId)?.targetBookId ?? null,
          strategy: matches.get(book.sourceBookId)?.strategy ?? null,
          unresolvedReason: unresolved.get(book.sourceBookId)?.reason ?? null,
        })),
      )
      .onConflictDoNothing({ target: [t.artifactId, t.userId, t.sourceBookId] });
  }

  async appendPreviewCounts(rows: Parameters<MigrationPlanningStore['appendPreviewCounts']>[0]) {
    this.assertBound(rows);
    if (rows.length === 0) return;
    const t = schema.migrationPlanPreviewCounts;
    await this.db
      .insert(t)
      .values(
        rows.map((row) => ({
          artifactId: this.artifactId,
          userId: this.userId,
          sourceBookId: row.sourceBookId,
          sourceUserId: row.sourceUserId,
          ...row.counts,
        })),
      )
      .onConflictDoUpdate({
        target: [t.artifactId, t.userId, t.sourceBookId, t.sourceUserId],
        set: {
          statuses: sql`${t.statuses} + excluded.statuses`,
          fileProgress: sql`${t.fileProgress} + excluded.file_progress`,
          readingSessions: sql`${t.readingSessions} + excluded.reading_sessions`,
          bookmarks: sql`${t.bookmarks} + excluded.bookmarks`,
          annotations: sql`${t.annotations} + excluded.annotations`,
          shelves: sql`${t.shelves} + excluded.shelves`,
        },
      });
  }

  private candidates() {
    const t = schema.migrationPlanSourceBooks;
    return sql`SELECT *, COUNT(*) OVER (PARTITION BY target_book_id) AS target_count FROM ${t}
      WHERE ${t.artifactId} = ${this.artifactId} AND ${t.userId} = ${this.userId}`;
  }

  async totals(): ReturnType<MigrationPlanningStore['totals']> {
    const counts = schema.migrationPlanPreviewCounts;
    const summary = await this.db.execute<NonNullable<PlannerResult['durableSummary']>>(sql`
      WITH candidates AS (${this.candidates()}) SELECT
        COUNT(*) FILTER (WHERE target_book_id IS NOT NULL AND target_count = 1)::integer AS "matchedBooks",
        COUNT(*) FILTER (WHERE unresolved_reason IS NOT NULL)::integer AS "unresolvedBooks",
        COUNT(DISTINCT target_book_id) FILTER (WHERE target_count > 1)::integer AS "duplicateBookMatches",
        COALESCE((SELECT jsonb_object_agg(reason, total) FROM (SELECT unresolved_reason AS reason, COUNT(*)::integer AS total
          FROM candidates WHERE unresolved_reason IS NOT NULL GROUP BY unresolved_reason) reasons), '{}'::jsonb) AS "unresolvedByReason"
      FROM candidates`);
    const users = await this.db.execute<{
      sourceUserId: string;
      counts: Awaited<ReturnType<MigrationPlanningStore['totals']>>['users'][number]['counts'];
    }>(sql`
      WITH candidates AS (${this.candidates()}) SELECT ${counts.sourceUserId} AS "sourceUserId", jsonb_build_object(
        'statuses', SUM(${counts.statuses}), 'fileProgress', SUM(${counts.fileProgress}), 'readingSessions', SUM(${counts.readingSessions}),
        'bookmarks', SUM(${counts.bookmarks}), 'annotations', SUM(${counts.annotations}), 'shelves', SUM(${counts.shelves})) AS counts
      FROM ${counts} INNER JOIN candidates ON candidates.source_book_id = ${counts.sourceBookId}
      WHERE ${counts.artifactId} = ${this.artifactId} AND ${counts.userId} = ${this.userId}
        AND candidates.target_book_id IS NOT NULL AND candidates.target_count = 1 GROUP BY ${counts.sourceUserId}`);
    return { summary: summary.rows[0], users: users.rows };
  }

  async finalize(values: { plan: PlannedMigration; summary: unknown; sourceSnapshotHash: string; profileHash: string; planHash: string }) {
    const t = schema.migrationPlanArtifacts;
    const m = schema.migrationPlanBookMatches;
    await this.db.transaction(async (tx) => {
      await tx.execute(sql`WITH candidates AS (${this.candidates()}) INSERT INTO ${m} (artifact_id, user_id, position, source_book_id, target_book_id, strategy)
        SELECT ${this.artifactId}, ${this.userId}, (ROW_NUMBER() OVER (ORDER BY id) - 1)::integer, source_book_id, target_book_id, strategy
        FROM candidates WHERE target_book_id IS NOT NULL AND target_count = 1`);
      await tx.execute(sql`WITH candidates AS (${this.candidates()}), duplicates AS (
        SELECT target_book_id, jsonb_build_object('targetBookId', target_book_id, 'reason', 'duplicate_target_match',
          'sourceBookIds', jsonb_agg(source_book_id ORDER BY id), 'strategies', jsonb_agg(strategy ORDER BY id),
          'matches', jsonb_agg(jsonb_build_object('sourceBookId', source_book_id, 'targetBookId', target_book_id, 'strategy', strategy) ORDER BY id),
          'sourceCandidates', jsonb_agg(jsonb_build_object('sourceBookId', source_book_id, 'title', title, 'author', author, 'filePath', file_path, 'strategy', strategy) ORDER BY id)) AS entry
        FROM candidates WHERE target_book_id IS NOT NULL AND target_count > 1 GROUP BY target_book_id)
        UPDATE ${t} SET plan = ${sql.param(JSON.stringify({ ...values.plan, matchedBooksBatched: true, sourceBooksIndexed: true }))}::jsonb || jsonb_build_object(
          'matchedBooks', COALESCE((SELECT jsonb_agg(entry ORDER BY position) FROM (SELECT position, jsonb_build_object('sourceBookId', source_book_id, 'targetBookId', target_book_id, 'strategy', strategy) AS entry FROM ${m} WHERE artifact_id = ${this.artifactId} AND user_id = ${this.userId} ORDER BY position LIMIT 40) preview), '[]'::jsonb),
          'unresolvedBooks', COALESCE((SELECT jsonb_agg(jsonb_build_object('sourceBookId', source_book_id, 'title', title, 'reason', unresolved_reason) ORDER BY id) FROM candidates WHERE unresolved_reason IS NOT NULL), '[]'::jsonb),
          'duplicateBookMatches', COALESCE((SELECT jsonb_agg(entry ORDER BY target_book_id) FROM duplicates), '[]'::jsonb)),
          summary = ${sql.param(JSON.stringify(values.summary))}::jsonb, source_snapshot_hash = ${values.sourceSnapshotHash}, profile_hash = ${values.profileHash}, plan_hash = ${values.planHash}, updated_at = NOW()
        WHERE ${t.id} = ${this.artifactId} AND ${t.createdByUserId} = ${this.userId}`);
      await tx.execute(sql`UPDATE ${t} SET summary = jsonb_set(summary, '{artifactSizeBytes}', jsonb_build_object(
        'plan', OCTET_LENGTH(plan::text), 'sourceData', COALESCE((summary->'artifactSizeBytes'->>'sourceData')::bigint, 0),
        'total', OCTET_LENGTH(plan::text) + COALESCE((summary->'artifactSizeBytes'->>'sourceData')::bigint, 0)))
        WHERE ${t.id} = ${this.artifactId} AND ${t.createdByUserId} = ${this.userId}`);
    });
    const duplicateRows = sql`${t.plan}->'duplicateBookMatches'`;
    const [artifact] = await this.db
      .select({
        ...getTableColumns(t),
        plan: sql<unknown>`(${t.plan} - 'unresolvedBooks' - 'duplicateBookMatches') || jsonb_build_object(
      'unresolvedBooks', ${arrayPage(sql`${t.plan}->'unresolvedBooks'`, 0, 40)},
      'duplicateBookMatches', COALESCE((SELECT jsonb_agg(${duplicatePreview(sql`${duplicateRows}->i`, 40)} ORDER BY i)
        FROM generate_series(0, LEAST(39, jsonb_array_length(${duplicateRows}) - 1)) i), '[]'::jsonb),
      'previewPagination', jsonb_build_object(
        'matchedBooks', jsonb_build_object('total', ${t.summary}->'matchedBooks'),
        'unresolvedBooks', jsonb_build_object('total', ${t.summary}->'unresolvedBooks'),
        'duplicateBookMatches', jsonb_build_object('total', ${t.summary}->'duplicateBookMatches')))`,
      })
      .from(t)
      .where(and(eq(t.id, this.artifactId), eq(t.createdByUserId, this.userId)))
      .limit(1);
    if (!artifact) throw new NotFoundException(`Migration plan artifact not found: ${this.artifactId}`);
    return artifact;
  }

  private assertBound(rows: unknown[]) {
    if (rows.length > 100) throw new BadRequestException('Migration planning writes and lookups support at most 100 rows');
  }
}
