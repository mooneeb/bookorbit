import { BadRequestException, Inject, Injectable, NotFoundException } from '@nestjs/common';
import { and, asc, desc, eq, gt, inArray, notInArray, sql } from 'drizzle-orm';
import type { NodePgDatabase } from 'drizzle-orm/node-postgres';

import { DB } from '../../db';
import * as schema from '../../db/schema';
import { MigrationPlanMatchRepository } from './migration-plan-match.repository';
import type { PlannedBookMatch } from './planner/planner.types';
import { MigrationPlanningRepository } from './planner/migration-planning.repository';

type Db = NodePgDatabase<typeof schema>;
type MigrationRunState = 'draft' | 'preflight_failed' | 'dry_run_ready' | 'running' | 'failed' | 'completed';
export type MigrationBatchMetric = Pick<
  typeof schema.migrationRunMetrics.$inferSelect,
  'entityType' | 'processed' | 'imported' | 'skipped' | 'unresolved' | 'failed'
>;
const ACTIVE_RUN_STATES: MigrationRunState[] = ['running'];
const BATCH_CHUNK_SIZE = 500;

function chunk<T>(items: T[], size: number): T[][] {
  const chunks: T[][] = [];
  for (let i = 0; i < items.length; i += size) {
    chunks.push(items.slice(i, i + size));
  }
  return chunks;
}

@Injectable()
export class MigrationRepository {
  constructor(@Inject(DB) private readonly db: Db) {}

  planningStore(artifactId: number, userId: number) {
    return new MigrationPlanningRepository(this.db, artifactId, userId);
  }

  listSources(userId?: number) {
    return this.db
      .select()
      .from(schema.migrationSources)
      .where(userId === undefined ? undefined : eq(schema.migrationSources.createdByUserId, userId))
      .orderBy(desc(schema.migrationSources.id))
      .limit(100);
  }

  async createSource(values: Pick<schema.NewMigrationSource, 'type' | 'name' | 'connectionConfig' | 'capabilities' | 'createdByUserId'>) {
    const [row] = await this.db.insert(schema.migrationSources).values(values).returning();
    return row;
  }

  async updateSource(id: number, values: Pick<schema.NewMigrationSource, 'type' | 'name' | 'connectionConfig' | 'capabilities' | 'createdByUserId'>) {
    const [row] = await this.db
      .update(schema.migrationSources)
      .set({
        type: values.type,
        name: values.name,
        connectionConfig: values.connectionConfig,
        capabilities: values.capabilities,
        createdByUserId: values.createdByUserId,
      })
      .where(eq(schema.migrationSources.id, id))
      .returning();
    return row ?? null;
  }

  async updateSourceValidation(id: number, patch: Pick<schema.NewMigrationSource, 'capabilities' | 'lastValidatedAt'>) {
    const [row] = await this.db
      .update(schema.migrationSources)
      .set({ capabilities: patch.capabilities, lastValidatedAt: patch.lastValidatedAt })
      .where(eq(schema.migrationSources.id, id))
      .returning();
    return row ?? null;
  }

  findSourceById(id: number) {
    return this.db.query.migrationSources.findFirst({ where: eq(schema.migrationSources.id, id) });
  }

  async deleteSource(id: number) {
    const [row] = await this.db.delete(schema.migrationSources).where(eq(schema.migrationSources.id, id)).returning();
    return row ?? null;
  }

  listTargetUsersForMapping(userId?: number) {
    return this.db
      .select({
        id: schema.users.id,
        username: schema.users.username,
        name: schema.users.name,
        email: schema.users.email,
      })
      .from(schema.users)
      .where(and(eq(schema.users.active, true), userId === undefined ? undefined : eq(schema.users.id, userId)))
      .orderBy(asc(schema.users.username));
  }

  async findExistingBookFilePaths(paths: string[], actorUserId: number): Promise<Set<string>> {
    const uniquePaths = [...new Set(paths.filter((value) => value.trim().length > 0))];
    if (uniquePaths.length === 0) return new Set();

    const out = new Set<string>();

    for (const batch of chunk(uniquePaths, BATCH_CHUNK_SIZE)) {
      const rows = await this.db
        .select({ absolutePath: schema.bookFiles.absolutePath })
        .from(schema.bookFiles)
        .where(
          and(
            inArray(schema.bookFiles.absolutePath, batch),
            sql`exists (
          select 1 from ${schema.books}
          inner join ${schema.users} on ${schema.users.id} = ${actorUserId}
          where ${schema.books.id} = ${schema.bookFiles.bookId}
            and (${schema.users.isSuperuser} or exists (
              select 1 from ${schema.userLibraryAccess}
              where ${schema.userLibraryAccess.userId} = ${actorUserId}
                and ${schema.userLibraryAccess.libraryId} = ${schema.books.libraryId}
                and ${schema.userLibraryAccess.accessLevel} in ('editor', 'owner')
            ))
        )`,
          ),
        );
      for (const row of rows) out.add(row.absolutePath);
    }

    return out;
  }

  listProfiles(sourceId?: number, ownerUserId?: number) {
    return this.db
      .select()
      .from(schema.migrationProfiles)
      .where(
        and(
          sourceId === undefined ? undefined : eq(schema.migrationProfiles.sourceId, sourceId),
          ownerUserId === undefined ? undefined : eq(schema.migrationProfiles.createdByUserId, ownerUserId),
        ),
      )
      .orderBy(desc(schema.migrationProfiles.id))
      .limit(100);
  }

  async createProfile(values: Pick<schema.NewMigrationProfile, 'sourceId' | 'name' | 'userMappings' | 'pathMappings' | 'scope' | 'createdByUserId'>) {
    return this.db.transaction(async (tx) => {
      const [versionRow] = await tx.select({ maxVersion: sql<number>`COALESCE(MAX(version), 0)` }).from(
        tx
          .select({ version: schema.migrationProfiles.version })
          .from(schema.migrationProfiles)
          .where(and(eq(schema.migrationProfiles.sourceId, values.sourceId), eq(schema.migrationProfiles.name, values.name)))
          .for('update')
          .as('locked'),
      );

      const nextVersion = (versionRow?.maxVersion ?? 0) + 1;
      const [row] = await tx
        .insert(schema.migrationProfiles)
        .values({ ...values, version: nextVersion })
        .returning();
      return row;
    });
  }

  findProfileById(id: number) {
    return this.db.query.migrationProfiles.findFirst({ where: eq(schema.migrationProfiles.id, id) });
  }

  async updateProfileScope(id: number, scope: unknown) {
    const [row] = await this.db.update(schema.migrationProfiles).set({ scope }).where(eq(schema.migrationProfiles.id, id)).returning();
    return row ?? null;
  }

  async createPlanArtifact(
    values: Pick<
      schema.NewMigrationPlanArtifact,
      'sourceId' | 'profileId' | 'sourceSnapshotHash' | 'profileHash' | 'planHash' | 'plan' | 'sourceData' | 'summary' | 'createdByUserId'
    >,
  ) {
    const [row] = await this.db.insert(schema.migrationPlanArtifacts).values(values).returning();
    return row;
  }

  listPlanArtifacts(sourceId?: number, ownerUserId?: number) {
    return this.db
      .select()
      .from(schema.migrationPlanArtifacts)
      .where(
        and(
          sourceId === undefined ? undefined : eq(schema.migrationPlanArtifacts.sourceId, sourceId),
          ownerUserId === undefined ? undefined : eq(schema.migrationPlanArtifacts.createdByUserId, ownerUserId),
        ),
      )
      .orderBy(desc(schema.migrationPlanArtifacts.id))
      .limit(100);
  }

  findPlanArtifactById(id: number) {
    return this.db.query.migrationPlanArtifacts.findFirst({ where: eq(schema.migrationPlanArtifacts.id, id) });
  }

  async findPlanArtifactOwnershipById(id: number) {
    const [row] = await this.db
      .select({
        id: schema.migrationPlanArtifacts.id,
        profileId: schema.migrationPlanArtifacts.profileId,
        createdByUserId: schema.migrationPlanArtifacts.createdByUserId,
      })
      .from(schema.migrationPlanArtifacts)
      .where(eq(schema.migrationPlanArtifacts.id, id));
    return row;
  }

  async updatePlanArtifact(
    id: number,
    values: {
      plan: unknown;
      sourceData?: unknown;
      summary: unknown;
      sourceSnapshotHash?: string;
      profileHash?: string;
      planHash?: string;
      matchedBookAdditions?: PlannedBookMatch[];
    },
  ) {
    const { matchedBookAdditions, ...artifactValues } = values;
    const plan = objectRecord(values.plan);
    if (!Array.isArray(plan.matchedBooks)) {
      const [row] = await this.db
        .update(schema.migrationPlanArtifacts)
        .set(artifactValues)
        .where(eq(schema.migrationPlanArtifacts.id, id))
        .returning();
      if (!row) throw new NotFoundException(`Migration plan artifact not found: ${id}`);
      return row;
    }
    return this.db.transaction(async (tx) => {
      const table = schema.migrationPlanArtifacts;
      const [artifact] = await tx
        .select({ userId: table.createdByUserId, batched: sql<boolean>`COALESCE(${table.plan}->>'matchedBooksBatched' = 'true', false)` })
        .from(table)
        .where(eq(table.id, id))
        .limit(1)
        .for('update');
      if (!artifact) throw new NotFoundException(`Migration plan artifact not found: ${id}`);
      if (artifact.userId === null) throw new BadRequestException('Plan artifact is missing an owner. Create a new dry-run plan.');
      const matches = new MigrationPlanMatchRepository(tx);
      if (matchedBookAdditions !== undefined && artifact.batched) await matches.append(id, artifact.userId, matchedBookAdditions);
      else await matches.replace(id, artifact.userId, plan.matchedBooks as PlannedBookMatch[]);
      const preview = await matches.pageForOwner(id, artifact.userId, 0, 40);
      const [row] = await tx
        .update(table)
        .set({
          ...artifactValues,
          plan: {
            ...plan,
            matchedBooks: preview.items,
            matchedBooksBatched: true,
            previewPagination: {
              ...objectRecord(plan.previewPagination),
              matchedBooks: { total: preview.total, limit: 40, nextOffset: preview.total > 40 ? 40 : null },
            },
          },
          summary: { ...objectRecord(values.summary), matchedBooks: preview.total },
        })
        .where(and(eq(table.id, id), eq(table.createdByUserId, artifact.userId)))
        .returning();
      if (!row) throw new NotFoundException(`Migration plan artifact not found: ${id}`);
      return row;
    });
  }

  findPlanMatchesForBooks(artifactId: number, sourceBookIds: string[]): Promise<PlannedBookMatch[]> {
    return new MigrationPlanMatchRepository(this.db).forSourceBooks(artifactId, sourceBookIds);
  }

  async listPlanMatchedBooks(artifactId: number, offset: number, limit = 100): Promise<PlannedBookMatch[]> {
    return (await new MigrationPlanMatchRepository(this.db).page(artifactId, offset, limit))?.items ?? [];
  }

  async deletePlanArtifact(id: number): Promise<void> {
    await this.db.delete(schema.migrationPlanArtifacts).where(eq(schema.migrationPlanArtifacts.id, id));
  }

  async appendPlanSourceBatch(artifactId: number, batchIndex: number, sourceData: unknown, bookOverlays: boolean): Promise<void> {
    await this.db.insert(schema.migrationPlanSourceBatches).values({ artifactId, batchIndex, sourceData, bookOverlays: bookOverlays ? 1 : 0 });
  }

  listPlanSourceBatches(artifactId: number, afterBatchIndex = -1, limit = 1) {
    return this.db
      .select()
      .from(schema.migrationPlanSourceBatches)
      .where(and(eq(schema.migrationPlanSourceBatches.artifactId, artifactId), gt(schema.migrationPlanSourceBatches.batchIndex, afterBatchIndex)))
      .orderBy(asc(schema.migrationPlanSourceBatches.batchIndex))
      .limit(Math.min(Math.max(limit, 1), 10));
  }

  findBatchCheckpoint(runId: number, stage: string) {
    return this.db.query.migrationRunBatchCheckpoints.findFirst({
      where: and(eq(schema.migrationRunBatchCheckpoints.runId, runId), eq(schema.migrationRunBatchCheckpoints.stage, stage)),
    });
  }

  async commitBatchCheckpoint(runId: number, stage: string, batchIndex: number, metrics: MigrationBatchMetric[]): Promise<void> {
    await this.db.transaction(async (tx) => {
      for (const metric of metrics) {
        await tx
          .insert(schema.migrationRunMetrics)
          .values({ runId, stage, ...metric })
          .onConflictDoUpdate({
            target: [schema.migrationRunMetrics.runId, schema.migrationRunMetrics.stage, schema.migrationRunMetrics.entityType],
            set: { ...metric, updatedAt: new Date() },
          });
      }
      await tx
        .insert(schema.migrationRunBatchCheckpoints)
        .values({ runId, stage, batchIndex, metrics })
        .onConflictDoUpdate({
          target: [schema.migrationRunBatchCheckpoints.runId, schema.migrationRunBatchCheckpoints.stage],
          set: { batchIndex, metrics, updatedAt: new Date() },
        });
    });
  }

  async purgeRunState(sourceId: number): Promise<void> {
    await this.db
      .delete(schema.migrationRuns)
      .where(and(eq(schema.migrationRuns.sourceId, sourceId), sql`${schema.migrationRuns.state} != 'completed'`));

    const completedRuns = await this.db
      .select({ planArtifactId: schema.migrationRuns.planArtifactId })
      .from(schema.migrationRuns)
      .where(and(eq(schema.migrationRuns.sourceId, sourceId), eq(schema.migrationRuns.state, 'completed')));
    const retainedArtifactIds = completedRuns.map((row) => row.planArtifactId).filter((id): id is number => id != null);

    if (retainedArtifactIds.length === 0) {
      await this.db.delete(schema.migrationPlanArtifacts).where(eq(schema.migrationPlanArtifacts.sourceId, sourceId));
      return;
    }

    await this.db
      .delete(schema.migrationPlanArtifacts)
      .where(and(eq(schema.migrationPlanArtifacts.sourceId, sourceId), notInArray(schema.migrationPlanArtifacts.id, retainedArtifactIds)));
  }

  async findBookTitlesByIds(ids: number[]): Promise<Map<number, string | null>> {
    const targetIds = [...new Set(ids.filter((id) => Number.isFinite(id)))];
    const titles = new Map<number, string | null>();
    if (targetIds.length === 0) return titles;

    for (const batch of chunk(targetIds, BATCH_CHUNK_SIZE)) {
      const rows = await this.db
        .select({ bookId: schema.bookMetadata.bookId, title: schema.bookMetadata.title })
        .from(schema.bookMetadata)
        .where(inArray(schema.bookMetadata.bookId, batch));
      for (const row of rows) titles.set(row.bookId, row.title ?? null);
    }

    return titles;
  }

  async createRunWithLock(
    values: Pick<
      schema.NewMigrationRun,
      'sourceId' | 'profileId' | 'planArtifactId' | 'targetKey' | 'state' | 'currentStage' | 'triggeredByUserId' | 'startedAt'
    >,
  ): Promise<{ run: typeof schema.migrationRuns.$inferSelect | null; activeRun: typeof schema.migrationRuns.$inferSelect | null }> {
    const targetKey = values.targetKey ?? 'bookorbit';
    return this.db.transaction(async (tx) => {
      await tx.execute(sql`SELECT pg_advisory_xact_lock(hashtext(${buildRunLockKey()}))`);

      const [activeRun] = await tx
        .select()
        .from(schema.migrationRuns)
        .where(inArray(schema.migrationRuns.state, ACTIVE_RUN_STATES))
        .orderBy(desc(schema.migrationRuns.id))
        .limit(1);

      if (activeRun) return { run: null, activeRun };

      await tx
        .delete(schema.migrationRuns)
        .where(and(eq(schema.migrationRuns.sourceId, values.sourceId), sql`${schema.migrationRuns.state} != 'completed'`));

      const [run] = await tx
        .insert(schema.migrationRuns)
        .values({ ...values, targetKey })
        .returning();
      return { run, activeRun: null };
    });
  }

  listRuns(sourceId?: number, ownerUserId?: number) {
    return this.db
      .select()
      .from(schema.migrationRuns)
      .where(
        and(
          sourceId === undefined ? undefined : eq(schema.migrationRuns.sourceId, sourceId),
          ownerUserId === undefined ? undefined : eq(schema.migrationRuns.triggeredByUserId, ownerUserId),
        ),
      )
      .orderBy(desc(schema.migrationRuns.id))
      .limit(100);
  }

  findRunById(id: number) {
    return this.db.query.migrationRuns.findFirst({ where: eq(schema.migrationRuns.id, id) });
  }

  async updateRunState(
    runId: number,
    state: MigrationRunState,
    patch: Partial<Pick<schema.NewMigrationRun, 'currentStage' | 'startedAt' | 'endedAt' | 'errorMessage'>>,
    expectedState: MigrationRunState,
  ) {
    const [row] = await this.db
      .update(schema.migrationRuns)
      .set({ ...patch, state })
      .where(and(eq(schema.migrationRuns.id, runId), eq(schema.migrationRuns.state, expectedState)))
      .returning();
    return row ?? null;
  }

  async setRunMetric(
    runId: number,
    stage: string,
    entityType: string,
    values: Partial<Pick<typeof schema.migrationRunMetrics.$inferInsert, 'processed' | 'imported' | 'skipped' | 'unresolved' | 'failed'>>,
  ) {
    const [row] = await this.db
      .insert(schema.migrationRunMetrics)
      .values({
        runId,
        stage,
        entityType,
        processed: values.processed ?? 0,
        imported: values.imported ?? 0,
        skipped: values.skipped ?? 0,
        unresolved: values.unresolved ?? 0,
        failed: values.failed ?? 0,
      })
      .onConflictDoUpdate({
        target: [schema.migrationRunMetrics.runId, schema.migrationRunMetrics.stage, schema.migrationRunMetrics.entityType],
        set: {
          processed: sql`excluded.processed`,
          imported: sql`excluded.imported`,
          skipped: sql`excluded.skipped`,
          unresolved: sql`excluded.unresolved`,
          failed: sql`excluded.failed`,
          updatedAt: sql`now()`,
        },
      })
      .returning();
    return row;
  }

  async clearStageMetrics(runId: number, stage: string): Promise<void> {
    await this.db
      .delete(schema.migrationRunMetrics)
      .where(and(eq(schema.migrationRunMetrics.runId, runId), eq(schema.migrationRunMetrics.stage, stage)));
  }

  async hasStageMetrics(runId: number, stage: string): Promise<boolean> {
    const rows = await this.db
      .select({ id: schema.migrationRunMetrics.id })
      .from(schema.migrationRunMetrics)
      .where(and(eq(schema.migrationRunMetrics.runId, runId), eq(schema.migrationRunMetrics.stage, stage)))
      .limit(1);
    return rows.length > 0;
  }

  listRunMetrics(runId: number) {
    return this.db
      .select()
      .from(schema.migrationRunMetrics)
      .where(eq(schema.migrationRunMetrics.runId, runId))
      .orderBy(asc(schema.migrationRunMetrics.stage), asc(schema.migrationRunMetrics.entityType));
  }
}

function buildRunLockKey(): string {
  return 'migration-run-lock:global';
}

function objectRecord(value: unknown): Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value) ? (value as Record<string, unknown>) : {};
}
