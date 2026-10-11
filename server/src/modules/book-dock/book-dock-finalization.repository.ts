import { Inject, Injectable } from '@nestjs/common';
import { and, asc, count, eq, inArray, sql } from 'drizzle-orm';
import { NodePgDatabase } from 'drizzle-orm/node-postgres';
import { DB } from '../../db';
import * as schema from '../../db/schema';
import type { BookDockFinalizeFileResult, BookDockFinalizeJobRequest } from '@bookorbit/types';
import { bookDockFinalizations, bookDockFinalizeJobs, bookDockFinalizeJobItems } from '../../db/schema';
import type { BookDockFinalizeIntent } from '../../db/schema';

type Db = NodePgDatabase<typeof schema>;

@Injectable()
export class BookDockFinalizationRepository {
  constructor(@Inject(DB) private readonly db: Db) {}

  async locked<T>(namespace: number, id: number, operation: () => Promise<T>): Promise<T> {
    return this.db.transaction(async (tx) => {
      await tx.execute(sql`select pg_advisory_xact_lock(${namespace}, ${id})`);
      return operation();
    });
  }

  async find(fileId: number) {
    const [row] = await this.db.select().from(bookDockFinalizations).where(eq(bookDockFinalizations.fileId, fileId)).limit(1);
    return row;
  }

  async begin(fileId: number, userId: number, intent: BookDockFinalizeIntent) {
    const [row] = await this.db
      .insert(bookDockFinalizations)
      .values({ fileId, userId, libraryId: intent.libraryId, intent })
      .onConflictDoNothing()
      .returning();
    return row ?? (await this.find(fileId))!;
  }

  async update(fileId: number, patch: Partial<typeof bookDockFinalizations.$inferInsert>) {
    await this.db
      .update(bookDockFinalizations)
      .set({ ...patch, updatedAt: new Date() })
      .where(eq(bookDockFinalizations.fileId, fileId));
  }

  async unfinished(afterId: number) {
    return this.db
      .select()
      .from(bookDockFinalizations)
      .where(and(sql`${bookDockFinalizations.fileId} > ${afterId}`, inArray(bookDockFinalizations.state, ['placing', 'committed'])))
      .orderBy(asc(bookDockFinalizations.fileId))
      .limit(100);
  }

  async createJob(userId: number, request: BookDockFinalizeJobRequest) {
    const [row] = await this.db
      .insert(bookDockFinalizeJobs)
      .values({ userId, idempotencyKey: request.idempotencyKey, request })
      .onConflictDoNothing()
      .returning();
    if (row) return row;
    const [existing] = await this.db
      .select()
      .from(bookDockFinalizeJobs)
      .where(and(eq(bookDockFinalizeJobs.userId, userId), eq(bookDockFinalizeJobs.idempotencyKey, request.idempotencyKey)))
      .limit(1);
    return existing!;
  }

  async findJob(id: number, userId: number) {
    const [row] = await this.db
      .select()
      .from(bookDockFinalizeJobs)
      .where(and(eq(bookDockFinalizeJobs.id, id), eq(bookDockFinalizeJobs.userId, userId)))
      .limit(1);
    return row;
  }

  async unfinishedJobs() {
    return this.db
      .select()
      .from(bookDockFinalizeJobs)
      .where(inArray(bookDockFinalizeJobs.state, ['queued', 'running']))
      .orderBy(asc(bookDockFinalizeJobs.id))
      .limit(100);
  }

  async addItems(jobId: number, fileIds: number[]) {
    if (fileIds.length)
      await this.db
        .insert(bookDockFinalizeJobItems)
        .values(fileIds.map((fileId) => ({ jobId, fileId })))
        .onConflictDoNothing();
  }

  async countItems(jobId: number) {
    const [row] = await this.db.select({ total: count() }).from(bookDockFinalizeJobItems).where(eq(bookDockFinalizeJobItems.jobId, jobId));
    return row.total;
  }

  async nextItems(jobId: number) {
    return this.db
      .select()
      .from(bookDockFinalizeJobItems)
      .where(and(eq(bookDockFinalizeJobItems.jobId, jobId), eq(bookDockFinalizeJobItems.state, 'pending')))
      .orderBy(asc(bookDockFinalizeJobItems.id))
      .limit(100);
  }

  async results(jobId: number) {
    const byState = (state: 'failed' | 'succeeded') =>
      this.db
        .select({ result: bookDockFinalizeJobItems.result })
        .from(bookDockFinalizeJobItems)
        .where(and(eq(bookDockFinalizeJobItems.jobId, jobId), eq(bookDockFinalizeJobItems.state, state)))
        .orderBy(asc(bookDockFinalizeJobItems.id))
        .limit(100);
    const [failed, succeeded] = await Promise.all([byState('failed'), byState('succeeded')]);
    return [...failed, ...succeeded].slice(0, 100);
  }

  async recordItem(jobId: number, id: number, result: BookDockFinalizeFileResult) {
    await this.db.transaction(async (tx) => {
      const written = await tx
        .update(bookDockFinalizeJobItems)
        .set({ state: result.success ? 'succeeded' : 'failed', result })
        .where(and(eq(bookDockFinalizeJobItems.id, id), eq(bookDockFinalizeJobItems.state, 'pending')))
        .returning({ id: bookDockFinalizeJobItems.id });
      if (!written.length) return;
      await tx
        .update(bookDockFinalizeJobs)
        .set({
          succeeded: sql`${bookDockFinalizeJobs.succeeded} + ${result.success ? 1 : 0}`,
          failed: sql`${bookDockFinalizeJobs.failed} + ${result.success ? 0 : 1}`,
          updatedAt: new Date(),
        })
        .where(eq(bookDockFinalizeJobs.id, jobId));
    });
  }

  async updateJob(id: number, patch: Partial<typeof bookDockFinalizeJobs.$inferInsert>) {
    await this.db
      .update(bookDockFinalizeJobs)
      .set({ ...patch, updatedAt: new Date() })
      .where(eq(bookDockFinalizeJobs.id, id));
  }

  async retryJob(id: number) {
    await this.db.transaction(async (tx) => {
      await tx
        .update(bookDockFinalizeJobItems)
        .set({ state: 'pending', result: null })
        .where(and(eq(bookDockFinalizeJobItems.jobId, id), eq(bookDockFinalizeJobItems.state, 'failed')));
      await tx
        .update(bookDockFinalizeJobs)
        .set({ state: 'queued', failed: 0, error: null, updatedAt: new Date() })
        .where(eq(bookDockFinalizeJobs.id, id));
    });
  }
}
