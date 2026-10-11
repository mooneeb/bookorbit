import { randomUUID } from 'node:crypto';
import { and, asc, eq, or, sql } from 'drizzle-orm';
import type { NodePgDatabase } from 'drizzle-orm/node-postgres';

import * as schema from '../../../db/schema';
import { decodeSyncToken } from './kobo-sync-token';

type Db = NodePgDatabase<typeof schema>;
type SnapshotRow = typeof schema.koboSnapshotBooks.$inferSelect;
type PendingPage = NonNullable<typeof schema.koboLibrarySnapshots.$inferSelect.pendingPage>;

export async function acknowledgeKoboPage(db: Db, userId: number, deviceId: number, rawToken?: string): Promise<number[]> {
  const token = decodeSyncToken(rawToken);
  if (!token.pageToken || token.snapshotId === undefined) return [];
  return db.transaction(async (tx) => {
    const [snapshot] = await tx
      .select()
      .from(schema.koboLibrarySnapshots)
      .where(
        and(
          eq(schema.koboLibrarySnapshots.id, token.snapshotId!),
          eq(schema.koboLibrarySnapshots.userId, userId),
          eq(schema.koboLibrarySnapshots.deviceId, deviceId),
        ),
      )
      .for('update');
    if (!snapshot?.pendingPage || snapshot.pendingPage.token !== token.pageToken) return [];
    const page = snapshot.pendingPage;
    const rowMatch = (row: PendingPage['rows'][number]) =>
      and(
        eq(schema.koboSnapshotBooks.snapshotId, snapshot.id),
        eq(schema.koboSnapshotBooks.bookId, row.bookId),
        eq(schema.koboSnapshotBooks.synced, false),
        eq(schema.koboSnapshotBooks.pendingDelete, row.pendingDelete),
        eq(schema.koboSnapshotBooks.isNew, row.isNew),
        sql`${schema.koboSnapshotBooks.fileHash} IS NOT DISTINCT FROM ${row.fileHash}`,
        sql`${schema.koboSnapshotBooks.deliveryHash} IS NOT DISTINCT FROM ${row.deliveryHash}`,
        sql`${schema.koboSnapshotBooks.metadataHash} IS NOT DISTINCT FROM ${row.metadataHash}`,
      );
    const removed = page.rows.filter((row) => row.pendingDelete);
    const delivered = page.rows.filter((row) => !row.pendingDelete);
    const completedIds: number[] = [];
    if (removed.length) {
      const completed = await tx
        .delete(schema.koboSnapshotBooks)
        .where(or(...removed.map(rowMatch)))
        .returning({ bookId: schema.koboSnapshotBooks.bookId });
      completedIds.push(...completed.map((row) => row.bookId));
    }
    if (delivered.length) {
      const completed = await tx
        .update(schema.koboSnapshotBooks)
        .set({ synced: true })
        .where(or(...delivered.map(rowMatch)))
        .returning({ bookId: schema.koboSnapshotBooks.bookId });
      completedIds.push(...completed.map((row) => row.bookId));
    }
    await tx.update(schema.koboLibrarySnapshots).set({ pendingPage: null }).where(eq(schema.koboLibrarySnapshots.id, snapshot.id));
    return page.legacyRemovalBookIds.filter((bookId) => completedIds.includes(bookId));
  });
}

export async function stageKoboPage(
  db: Db,
  userId: number,
  snapshotId: number,
  rows: SnapshotRow[],
  legacyRemovalBookIds: number[],
): Promise<string | null> {
  return db.transaction(async (tx) => {
    const [snapshot] = await tx
      .select()
      .from(schema.koboLibrarySnapshots)
      .where(and(eq(schema.koboLibrarySnapshots.id, snapshotId), eq(schema.koboLibrarySnapshots.userId, userId)))
      .for('update');
    const currentRows = await tx
      .select()
      .from(schema.koboSnapshotBooks)
      .where(and(eq(schema.koboSnapshotBooks.snapshotId, snapshotId), eq(schema.koboSnapshotBooks.synced, false)))
      .orderBy(asc(schema.koboSnapshotBooks.bookId))
      .limit(50);
    const fingerprint = (items: PendingPage['rows']) =>
      JSON.stringify(
        items.map(({ bookId, pendingDelete, isNew, fileHash, deliveryHash, metadataHash }) => ({
          bookId,
          pendingDelete,
          isNew,
          fileHash,
          deliveryHash,
          metadataHash,
        })),
      );
    if (fingerprint(currentRows) !== fingerprint(rows)) return null;
    if (snapshot.pendingPage && fingerprint(snapshot.pendingPage.rows) === fingerprint(rows)) return snapshot.pendingPage.token;
    const pendingPage: PendingPage = {
      token: randomUUID(),
      rows: rows.map(({ bookId, pendingDelete, isNew, fileHash, deliveryHash, metadataHash }) => ({
        bookId,
        pendingDelete,
        isNew,
        fileHash,
        deliveryHash,
        metadataHash,
      })),
      legacyRemovalBookIds,
    };
    await tx.update(schema.koboLibrarySnapshots).set({ pendingPage }).where(eq(schema.koboLibrarySnapshots.id, snapshotId));
    return pendingPage.token;
  });
}
