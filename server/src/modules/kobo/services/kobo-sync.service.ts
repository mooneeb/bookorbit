import { createHash } from 'crypto';
import { Inject, Injectable, InternalServerErrorException, Logger } from '@nestjs/common';
import { SQL, and, asc, eq, gt, inArray, isNull, lte, or, sql } from 'drizzle-orm';
import { NodePgDatabase } from 'drizzle-orm/node-postgres';

import type { GroupRule } from '@bookorbit/types';
import { DB } from '../../../db/db.module';
import * as schema from '../../../db/schema';
import { mapWithConcurrency } from '../../../common/utils/batch.utils';
import { buildContentFilterClauses } from '../../../common/utils/content-filter-sql.utils';
import { sanitizeLogValue } from '../../../common/utils/log-sanitize.utils';
import { resolveTimeZone } from '../../../common/utils/timezone.utils';
import { ContentFilterRepository } from '../../user/content-filter.repository';
import { BookQueryBuilder } from '../../book/book-query-builder.service';
import { MetadataExtractionService } from '../../metadata/metadata-extraction.service';
import { SmartScopeService } from '../../smart-scope/smart-scope.service';
import { KoboBookAccessService } from './kobo-book-access.service';
import { KoboBookIdentityService } from './kobo-book-identity.service';
import { normalizeKoboLanguage, selectKoboIsbn } from './kobo-metadata.utils';
import { KoboReadingStateService } from './kobo-reading-state.service';
import { encodeSyncToken } from './kobo-sync-token';
import { acknowledgeKoboPage, stageKoboPage } from './kobo-sync-page';

type Db = NodePgDatabase<typeof schema>;
type KoboCatalogExecutor = Pick<Db, 'select' | 'insert' | 'update'>;

// A device pauses between sync rounds, so wall-clock time for a long delta tracks the number of
// round trips rather than the work inside each one: at five books a page, re-announcing a few
// hundred books cost users tens of minutes of waiting on a mostly idle server.
export const SYNC_PAGE_SIZE = 50;
const SNAPSHOT_RECONCILE_BATCH_SIZE = 5000;
const SNAPSHOT_CREATE_BATCH_SIZE = 5000;
const METADATA_SERIALIZER_VERSION = 2;

// Fixed-layout detection opens the EPUB, so a sync never resolves the whole backlog at once.
// Each pass persists what it learns, so a library converges over successive syncs and every
// later sync reads the stored answer instead of touching the filesystem.
const FIXED_LAYOUT_BACKFILL_LIMIT = 500;
const FIXED_LAYOUT_BACKFILL_CONCURRENCY = 8;

type EligibleSnapshotRow = {
  bookId: number;
  fileHash: string | null;
  deliveryHash: string;
  metadataHash: string;
  needsLegacyNumericRemoval?: boolean;
};

type Snapshot = typeof schema.koboLibrarySnapshots.$inferSelect;

type LegacySnapshot = Pick<typeof schema.koboLegacyLibrarySnapshots.$inferSelect, 'id' | 'legacyDeviceCutoffAt'>;

type KoboDeliverySettings = {
  convertToKepub: boolean;
  forceEnableHyphenation: boolean;
  kepubConversionLimitMb: number;
};

// EPUB3FL tells the device to use its fixed-layout renderer, which is what makes a comic fill
// the screen instead of picking up the reflowable reading margins.
type KoboDeliveryFormat = 'EPUB3' | 'EPUB3FL' | 'KEPUB' | 'PDF';

type FixedLayoutCandidate = {
  fileId: number;
  fileAbsolutePath: string;
  fileFormat: string | null;
  isFixedLayout: boolean | null;
};

type KoboDeliveryInfo = {
  format: KoboDeliveryFormat;
  hash: string;
};

type UserSettingsWithTimeZone = { timezone?: unknown };
type SmartScopeMatch = { name: string; where: SQL | undefined };
// Scoped to a single getDelta/getBookMetadata call so results are shared across the
// fetchEligibleSnapshotRows/fetchEligibleBooksByIds/buildTagItems calls it makes, without
// caching across requests (this service is a singleton).
type SmartScopeMatchCache = Map<number, Promise<Map<number, SmartScopeMatch>>>;

type EligibleSnapshotBatches = AsyncIterable<EligibleSnapshotRow[]>;
type EligibleSnapshotBatchFactory = (executor: KoboCatalogExecutor) => EligibleSnapshotBatches;
type KoboTagItem = { RevisionId: string; Type: 'ProductRevisionTagItem' };
type KoboSyncTag = { id: string; name: string; items: AsyncIterable<KoboTagItem[]> };

export type KoboSyncResult = {
  entitlements: unknown[];
  hasMore: boolean;
  syncToken: string;
  tags?: AsyncIterable<KoboSyncTag>;
};

export interface KoboBookEntry {
  bookId: number;
  koboEntitlementId: string;
  koboCoverImageId: string;
  title: string;
  authors: string[];
  description: string | null;
  publisher: string | null;
  publishedDate: string | null;
  publishedYear: number | null;
  language: string;
  isbn: string | null;
  seriesName: string | null;
  seriesIndex: string | null;
  fileFormat: string;
  fileSizeBytes: number | null;
  fileHash: string | null;
  metadataHash: string;
  deliveryFormat: KoboDeliveryFormat;
  metadataUpdatedAt: Date | null;
  collectionNames: string[];
  addedAt: Date;
  updatedAt: Date;
}

/**
 * The size the kepub limit is judged by. A read-along is delivered with its narration stripped, which
 * the download measures after the rebuild; announcing by the size with audio would pick EPUB3 for a
 * book the download then streams as a kepub.
 */
function deliverySizeBytes(row: { fileSizeBytes: number | null; fileMediaOverlayAvailable: boolean | null }): number | null {
  return row.fileMediaOverlayAvailable ? null : row.fileSizeBytes;
}

@Injectable()
export class KoboSyncService {
  private readonly logger = new Logger(KoboSyncService.name);

  constructor(
    @Inject(DB) private readonly db: Db,
    private readonly bookAccessService: KoboBookAccessService,
    private readonly readingStateService: KoboReadingStateService,
    private readonly contentFilterRepository: ContentFilterRepository,
    private readonly bookIdentityService: KoboBookIdentityService,
    private readonly queryBuilder: BookQueryBuilder,
    private readonly smartScopeService: SmartScopeService,
    private readonly metadataExtractionService: MetadataExtractionService,
  ) {}

  async getDelta(userId: number, deviceId: number, deviceToken: string, baseUrl: string, incomingToken?: string): Promise<KoboSyncResult> {
    let snapshot = await this.findDeviceSnapshot(userId, deviceId);
    const acknowledgedLegacyIds = await acknowledgeKoboPage(this.db, userId, deviceId, incomingToken);
    if (snapshot && acknowledgedLegacyIds.length > 0) await this.completeLegacyNumericRemovals(userId, snapshot.id, acknowledgedLegacyIds);
    const smartScopeMatchCache: SmartScopeMatchCache = new Map();

    // Reconciling costs a pass over the whole library, so a device still working through its
    // pending rows skips it: those rows already say what it is owed, and whatever changed while
    // it paged is picked up by the reconcile that opens its next sync.
    if (snapshot && (await this.hasPendingSnapshotBooks(snapshot.id))) {
      return this.getPageFromSnapshot(userId, snapshot.id, deviceToken, baseUrl, smartScopeMatchCache);
    }

    const hadDeviceSnapshot = snapshot ? true : await this.hasDeviceSnapshot(userId);
    const legacySnapshot = snapshot ? undefined : await this.initializeLegacyBookIdentities(userId, deviceId);
    const eligibleSnapshotRows = await this.prepareEligibleSnapshotRows(userId, hadDeviceSnapshot, smartScopeMatchCache);

    if (!snapshot) {
      const created = await this.createSnapshot(userId, deviceId, eligibleSnapshotRows, legacySnapshot?.id);
      snapshot = created.snapshot;
      if (!created.created) {
        await this.reconcileSnapshot(snapshot.id, eligibleSnapshotRows);
      } else {
        await this.retireLegacySnapshotIfComplete(userId);
      }
    } else {
      await this.reconcileSnapshot(snapshot.id, eligibleSnapshotRows);
    }

    return this.getPageFromSnapshot(userId, snapshot.id, deviceToken, baseUrl, smartScopeMatchCache);
  }

  async getBookMetadata(userId: number, bookId: number, deviceToken: string, baseUrl: string): Promise<unknown[]> {
    const booksById = await this.fetchEligibleBooksByIds(userId, [bookId], await this.hasDeviceSnapshot(userId), new Map());
    const book = booksById.get(bookId) ?? null;
    if (!book) return [];
    return [this.buildBookMetadata(book, deviceToken, baseUrl)];
  }

  async removeBookFromSync(userId: number, deviceId: number, bookId: number): Promise<void> {
    const snapshot = await this.findDeviceSnapshot(userId, deviceId);
    if (!snapshot) return;

    const row = await this.db.query.koboSnapshotBooks.findFirst({
      where: and(eq(schema.koboSnapshotBooks.snapshotId, snapshot.id), eq(schema.koboSnapshotBooks.bookId, bookId)),
    });
    if (!row) return;

    if (row.pendingDelete) {
      await this.db
        .delete(schema.koboSnapshotBooks)
        .where(and(eq(schema.koboSnapshotBooks.snapshotId, snapshot.id), eq(schema.koboSnapshotBooks.bookId, bookId)));
    } else {
      await this.db
        .update(schema.koboSnapshotBooks)
        .set({ removedByDevice: true, synced: true })
        .where(and(eq(schema.koboSnapshotBooks.snapshotId, snapshot.id), eq(schema.koboSnapshotBooks.bookId, bookId)));
    }
  }

  private async findDeviceSnapshot(userId: number, deviceId: number): Promise<Snapshot | undefined> {
    return this.db.query.koboLibrarySnapshots.findFirst({
      where: and(eq(schema.koboLibrarySnapshots.userId, userId), eq(schema.koboLibrarySnapshots.deviceId, deviceId)),
    });
  }

  private async hasPendingSnapshotBooks(snapshotId: number): Promise<boolean> {
    const [row] = await this.db
      .select({ bookId: schema.koboSnapshotBooks.bookId })
      .from(schema.koboSnapshotBooks)
      .where(and(eq(schema.koboSnapshotBooks.snapshotId, snapshotId), eq(schema.koboSnapshotBooks.synced, false)))
      .limit(1);
    return Boolean(row);
  }

  private async hasDeviceSnapshot(userId: number): Promise<boolean> {
    const snapshot = await this.db.query.koboLibrarySnapshots.findFirst({
      where: eq(schema.koboLibrarySnapshots.userId, userId),
      columns: { id: true },
    });
    return Boolean(snapshot);
  }

  private async initializeLegacyBookIdentities(userId: number, deviceId: number): Promise<LegacySnapshot | undefined> {
    const legacySnapshot = await this.findLegacySnapshotForDevice(userId, deviceId);
    if (!legacySnapshot) return undefined;

    let afterBookId = 0;
    for (;;) {
      const legacyBooks = await this.db
        .select({ bookId: schema.koboLegacySnapshotBooks.bookId })
        .from(schema.koboLegacySnapshotBooks)
        .where(and(eq(schema.koboLegacySnapshotBooks.snapshotId, legacySnapshot.id), gt(schema.koboLegacySnapshotBooks.bookId, afterBookId)))
        .orderBy(asc(schema.koboLegacySnapshotBooks.bookId))
        .limit(SNAPSHOT_CREATE_BATCH_SIZE);
      if (legacyBooks.length === 0) break;
      await this.bookIdentityService.ensureForBooks(
        userId,
        legacyBooks.map((book) => book.bookId),
        true,
      );
      afterBookId = legacyBooks[legacyBooks.length - 1]!.bookId;
      if (legacyBooks.length < SNAPSHOT_CREATE_BATCH_SIZE) break;
    }

    return legacySnapshot;
  }

  private async findLegacySnapshotForDevice(userId: number, deviceId: number): Promise<LegacySnapshot | undefined> {
    const [legacySnapshot] = await this.db
      .select({
        id: schema.koboLegacyLibrarySnapshots.id,
        legacyDeviceCutoffAt: schema.koboLegacyLibrarySnapshots.legacyDeviceCutoffAt,
      })
      .from(schema.koboLegacyLibrarySnapshots)
      .innerJoin(
        schema.koboDevices,
        and(
          eq(schema.koboDevices.id, deviceId),
          eq(schema.koboDevices.userId, userId),
          lte(schema.koboDevices.createdAt, schema.koboLegacyLibrarySnapshots.legacyDeviceCutoffAt),
        ),
      )
      .where(eq(schema.koboLegacyLibrarySnapshots.userId, userId))
      .limit(1);
    return legacySnapshot;
  }

  private async retireLegacySnapshotIfComplete(userId: number): Promise<void> {
    const legacySnapshot = await this.db.query.koboLegacyLibrarySnapshots.findFirst({
      where: eq(schema.koboLegacyLibrarySnapshots.userId, userId),
      columns: { id: true, legacyDeviceCutoffAt: true },
    });
    if (!legacySnapshot || (await this.hasUninitializedLegacyDevices(userId, legacySnapshot.legacyDeviceCutoffAt))) return;

    await this.db
      .delete(schema.koboLegacyLibrarySnapshots)
      .where(and(eq(schema.koboLegacyLibrarySnapshots.id, legacySnapshot.id), eq(schema.koboLegacyLibrarySnapshots.userId, userId)));
  }

  private async hasUninitializedLegacyDevices(userId: number, legacyDeviceCutoffAt?: Date): Promise<boolean> {
    let cutoffAt = legacyDeviceCutoffAt;
    if (!cutoffAt) {
      const legacySnapshot = await this.db.query.koboLegacyLibrarySnapshots.findFirst({
        where: eq(schema.koboLegacyLibrarySnapshots.userId, userId),
        columns: { legacyDeviceCutoffAt: true },
      });
      if (!legacySnapshot) return false;
      cutoffAt = legacySnapshot.legacyDeviceCutoffAt;
    }

    const rows = await this.db
      .select({ id: schema.koboDevices.id })
      .from(schema.koboDevices)
      .leftJoin(schema.koboLibrarySnapshots, eq(schema.koboLibrarySnapshots.deviceId, schema.koboDevices.id))
      .where(and(eq(schema.koboDevices.userId, userId), lte(schema.koboDevices.createdAt, cutoffAt), isNull(schema.koboLibrarySnapshots.id)))
      .limit(1);
    return rows.length > 0;
  }

  private async createSnapshot(
    userId: number,
    deviceId: number,
    eligibleBooks: EligibleSnapshotBatches | EligibleSnapshotBatchFactory,
    legacySnapshotId?: number,
  ): Promise<{ snapshot: Snapshot; created: boolean }> {
    const created = await this.db.transaction(async (tx) => {
      const [snapshot] = await tx
        .insert(schema.koboLibrarySnapshots)
        .values({ userId, deviceId })
        .onConflictDoNothing({ target: schema.koboLibrarySnapshots.deviceId })
        .returning();
      if (!snapshot) return null;

      for await (const chunk of typeof eligibleBooks === 'function' ? eligibleBooks(tx) : eligibleBooks) {
        await tx
          .insert(schema.koboSnapshotBooks)
          .values(
            chunk.map((book) => ({
              snapshotId: snapshot.id,
              bookId: book.bookId,
              synced: false,
              pendingDelete: false,
              isNew: true,
              removedByDevice: false,
              needsLegacyNumericRemoval: book.needsLegacyNumericRemoval ?? false,
              fileHash: book.fileHash,
              deliveryHash: book.deliveryHash,
              metadataHash: book.metadataHash,
            })),
          )
          .onConflictDoNothing();
      }

      if (legacySnapshotId !== undefined) {
        await tx.execute(sql`
          INSERT INTO ${schema.koboSnapshotBooks}
            (snapshot_id, book_id, synced, pending_delete, is_new, removed_by_device, needs_legacy_numeric_removal, file_hash, delivery_hash, metadata_hash)
          SELECT ${snapshot.id}, legacy.book_id, false, true, false, false, true, NULL, NULL, NULL
          FROM ${schema.koboLegacySnapshotBooks} AS legacy
          INNER JOIN ${schema.koboLegacyLibrarySnapshots} AS legacy_snapshot
            ON legacy_snapshot.id = legacy.snapshot_id
          WHERE legacy.snapshot_id = ${legacySnapshotId}
            AND legacy_snapshot.user_id = ${userId}
          ON CONFLICT (snapshot_id, book_id)
          DO UPDATE SET needs_legacy_numeric_removal = true
        `);
      }

      await tx.execute(sql`
        INSERT INTO ${schema.koboSnapshotBooks}
          (snapshot_id, book_id, synced, pending_delete, is_new, removed_by_device, needs_legacy_numeric_removal, file_hash, delivery_hash, metadata_hash)
        SELECT ${snapshot.id}, entitlement.book_id, false, true, false, false, entitlement.needs_legacy_numeric_removal, NULL, NULL, NULL
        FROM ${schema.koboBookEntitlements} AS entitlement
        LEFT JOIN ${schema.koboSnapshotBooks} AS existing
          ON existing.snapshot_id = ${snapshot.id}
         AND existing.book_id = entitlement.book_id
        WHERE entitlement.user_id = ${userId}
          AND existing.book_id IS NULL
        ON CONFLICT DO NOTHING
      `);

      return snapshot;
    });

    if (created) return { snapshot: created, created: true };

    const snapshot = await this.findDeviceSnapshot(userId, deviceId);
    if (!snapshot) throw new InternalServerErrorException('Failed to create Kobo device snapshot');
    return { snapshot, created: false };
  }

  private async reconcileSnapshot(snapshotId: number, eligibleBooks: EligibleSnapshotBatches | EligibleSnapshotBatchFactory) {
    await this.db.transaction(async (tx) => {
      await tx.execute(sql`
        CREATE TEMP TABLE kobo_eligible_books_tmp (
          book_id integer PRIMARY KEY,
          file_hash varchar(64),
          delivery_hash varchar(64) NOT NULL,
          metadata_hash varchar(64) NOT NULL,
          needs_legacy_numeric_removal boolean NOT NULL
        ) ON COMMIT DROP
      `);

      for await (const chunk of typeof eligibleBooks === 'function' ? eligibleBooks(tx) : eligibleBooks) {
        const valueRows = sql.join(
          chunk.map((b) => sql`(${b.bookId}, ${b.fileHash}, ${b.deliveryHash}, ${b.metadataHash}, ${b.needsLegacyNumericRemoval ?? false})`),
          sql`, `,
        );

        await tx.execute(sql`
          INSERT INTO kobo_eligible_books_tmp (book_id, file_hash, delivery_hash, metadata_hash, needs_legacy_numeric_removal)
          VALUES ${valueRows}
          ON CONFLICT (book_id)
          DO UPDATE
          SET file_hash = EXCLUDED.file_hash,
              delivery_hash = EXCLUDED.delivery_hash,
              metadata_hash = EXCLUDED.metadata_hash,
              needs_legacy_numeric_removal = EXCLUDED.needs_legacy_numeric_removal
        `);
      }

      await tx.execute(sql`
        UPDATE ${schema.koboSnapshotBooks} AS sb
        SET pending_delete = true,
            synced = false
        WHERE sb.snapshot_id = ${snapshotId}
          AND sb.pending_delete = false
          AND sb.removed_by_device = false
          AND (sb.synced = true OR sb.needs_legacy_numeric_removal = true)
          AND NOT EXISTS (SELECT 1 FROM kobo_eligible_books_tmp e WHERE e.book_id = sb.book_id)
      `);

      await tx.execute(sql`
        DELETE FROM ${schema.koboSnapshotBooks} AS sb
        WHERE sb.snapshot_id = ${snapshotId}
          AND sb.pending_delete = false
          AND (sb.removed_by_device = true OR (sb.synced = false AND sb.needs_legacy_numeric_removal = false))
          AND NOT EXISTS (SELECT 1 FROM kobo_eligible_books_tmp e WHERE e.book_id = sb.book_id)
      `);

      await tx.execute(sql`
        INSERT INTO ${schema.koboSnapshotBooks}
          (snapshot_id, book_id, synced, pending_delete, is_new, removed_by_device, needs_legacy_numeric_removal, file_hash, delivery_hash, metadata_hash)
        SELECT ${snapshotId}, e.book_id, false, false, true, false, e.needs_legacy_numeric_removal, e.file_hash, e.delivery_hash, e.metadata_hash
        FROM kobo_eligible_books_tmp e
        LEFT JOIN ${schema.koboSnapshotBooks} sb
          ON sb.snapshot_id = ${snapshotId}
         AND sb.book_id = e.book_id
        WHERE sb.book_id IS NULL
      `);

      await tx.execute(sql`
        UPDATE ${schema.koboSnapshotBooks} AS sb
        SET pending_delete = false,
            synced = false,
            is_new = true,
            file_hash = e.file_hash,
            delivery_hash = e.delivery_hash,
            metadata_hash = e.metadata_hash
        FROM kobo_eligible_books_tmp e
        WHERE sb.snapshot_id = ${snapshotId}
          AND sb.book_id = e.book_id
          AND sb.pending_delete = true
          AND sb.removed_by_device = false
      `);

      await tx.execute(sql`
        UPDATE ${schema.koboSnapshotBooks} AS sb
        SET removed_by_device = false,
            synced = false,
            is_new = true,
            file_hash = e.file_hash,
            delivery_hash = e.delivery_hash,
            metadata_hash = e.metadata_hash
        FROM kobo_eligible_books_tmp e
        WHERE sb.snapshot_id = ${snapshotId}
          AND sb.book_id = e.book_id
          AND sb.removed_by_device = true
          AND sb.synced = true
          AND sb.pending_delete = false
      `);

      await tx.execute(sql`
        UPDATE ${schema.koboSnapshotBooks} AS sb
        SET delivery_hash = e.delivery_hash
        FROM kobo_eligible_books_tmp e
        WHERE sb.snapshot_id = ${snapshotId}
          AND sb.book_id = e.book_id
          AND sb.pending_delete = false
          AND sb.removed_by_device = false
          AND sb.delivery_hash IS NULL
          AND sb.file_hash IS NOT DISTINCT FROM e.file_hash
      `);

      await tx.execute(sql`
        UPDATE ${schema.koboSnapshotBooks} AS sb
        SET synced = false,
            is_new = true,
            file_hash = e.file_hash,
            delivery_hash = e.delivery_hash,
            metadata_hash = e.metadata_hash
        FROM kobo_eligible_books_tmp e
        WHERE sb.snapshot_id = ${snapshotId}
          AND sb.book_id = e.book_id
          AND sb.pending_delete = false
          AND sb.removed_by_device = false
          AND sb.synced = true
          AND (sb.file_hash IS DISTINCT FROM e.file_hash OR sb.delivery_hash IS DISTINCT FROM e.delivery_hash)
      `);

      await tx.execute(sql`
        UPDATE ${schema.koboSnapshotBooks} AS sb
        SET synced = false,
            is_new = false,
            file_hash = e.file_hash,
            delivery_hash = e.delivery_hash,
            metadata_hash = e.metadata_hash
        FROM kobo_eligible_books_tmp e
        WHERE sb.snapshot_id = ${snapshotId}
          AND sb.book_id = e.book_id
          AND sb.pending_delete = false
          AND sb.removed_by_device = false
          AND sb.synced = true
          AND sb.file_hash IS NOT DISTINCT FROM e.file_hash
          AND sb.delivery_hash IS NOT DISTINCT FROM e.delivery_hash
          AND sb.metadata_hash IS DISTINCT FROM e.metadata_hash
      `);
    });
  }

  /**
   * Pending book pages only query their own IDs. Tags resolve eligibility in SQL after the
   * device drains its catalog, without constructing a second library-wide set of IDs.
   */
  private async getPageFromSnapshot(
    userId: number,
    snapshotId: number,
    deviceToken: string,
    baseUrl: string,
    smartScopeMatchCache: SmartScopeMatchCache,
  ): Promise<KoboSyncResult> {
    const syncToken = encodeSyncToken(snapshotId);

    const pending = await this.db
      .select()
      .from(schema.koboSnapshotBooks)
      .where(and(eq(schema.koboSnapshotBooks.snapshotId, snapshotId), eq(schema.koboSnapshotBooks.synced, false)))
      .orderBy(asc(schema.koboSnapshotBooks.bookId))
      .limit(SYNC_PAGE_SIZE + 1);

    const page = pending.slice(0, SYNC_PAGE_SIZE);

    if (page.length === 0) {
      return { entitlements: [], tags: this.buildTagItems(userId, smartScopeMatchCache), hasMore: false, syncToken };
    }

    const entitlements: unknown[] = [];
    const identitiesById = await this.bookIdentityService.findByBookIds(
      userId,
      page.map((row) => row.bookId),
    );
    const legacyRemovalCompletedBookIds: number[] = [];
    const booksById = await this.fetchEligibleBooksByIds(
      userId,
      page.filter((row) => !row.pendingDelete).map((row) => row.bookId),
      false,
      smartScopeMatchCache,
    );
    const readingStatesById = await this.readingStateService.getRawStates(userId, [...booksById.keys()]);

    for (const row of page) {
      if (row.pendingDelete) {
        const identity = identitiesById.get(row.bookId) ?? null;
        if (identity) {
          if (row.needsLegacyNumericRemoval) {
            entitlements.push(this.buildRemovedEntitlement(row.bookId));
            legacyRemovalCompletedBookIds.push(row.bookId);
          }
          entitlements.push(this.buildRemovedEntitlement(identity.entitlementId));
        } else {
          entitlements.push(this.buildRemovedEntitlement(row.bookId));
        }
        continue;
      }

      const book = booksById.get(row.bookId) ?? null;
      if (!book) continue;

      const readingState = readingStatesById.get(row.bookId) ?? null;
      const defaultReadingState = readingState ?? this.buildDefaultReadingState(book.koboEntitlementId);

      if (row.isNew || row.needsLegacyNumericRemoval) {
        if (row.needsLegacyNumericRemoval) {
          entitlements.push(this.buildRemovedEntitlement(row.bookId));
          legacyRemovalCompletedBookIds.push(row.bookId);
        }
        entitlements.push({
          NewEntitlement: {
            BookEntitlement: this.buildBookEntitlement(book),
            BookMetadata: this.buildBookMetadata(book, deviceToken, baseUrl),
            ReadingState: defaultReadingState,
          },
        });
      } else {
        entitlements.push({
          ChangedProductMetadata: {
            BookEntitlement: this.buildBookEntitlement(book),
            BookMetadata: this.buildBookMetadata(book, deviceToken, baseUrl),
          },
        });
        if (readingState) {
          entitlements.push({
            ChangedReadingState: {
              ReadingState: readingState,
            },
          });
        }
      }
    }

    const pageToken = await stageKoboPage(this.db, userId, snapshotId, page, legacyRemovalCompletedBookIds);
    if (pageToken === null) return this.getPageFromSnapshot(userId, snapshotId, deviceToken, baseUrl, smartScopeMatchCache);
    return { entitlements, hasMore: true, syncToken: encodeSyncToken(snapshotId, undefined, pageToken) };
  }

  private async completeLegacyNumericRemovals(userId: number, snapshotId: number, bookIds: number[]): Promise<void> {
    const uniqueBookIds = [...new Set(bookIds)];
    if (uniqueBookIds.length === 0) return;

    await this.db
      .update(schema.koboSnapshotBooks)
      .set({ needsLegacyNumericRemoval: false })
      .where(
        and(
          eq(schema.koboSnapshotBooks.snapshotId, snapshotId),
          inArray(schema.koboSnapshotBooks.bookId, uniqueBookIds),
          eq(schema.koboSnapshotBooks.needsLegacyNumericRemoval, true),
        ),
      );

    const stillPendingRows = await this.db
      .select({ bookId: schema.koboSnapshotBooks.bookId })
      .from(schema.koboSnapshotBooks)
      .innerJoin(schema.koboLibrarySnapshots, eq(schema.koboLibrarySnapshots.id, schema.koboSnapshotBooks.snapshotId))
      .where(
        and(
          eq(schema.koboLibrarySnapshots.userId, userId),
          inArray(schema.koboSnapshotBooks.bookId, uniqueBookIds),
          eq(schema.koboSnapshotBooks.needsLegacyNumericRemoval, true),
        ),
      );

    const stillPendingBookIds = new Set(stillPendingRows.map((row) => row.bookId));
    const completedBookIds = uniqueBookIds.filter((bookId) => !stillPendingBookIds.has(bookId));
    if (completedBookIds.length === 0) return;
    if (await this.hasUninitializedLegacyDevices(userId)) return;

    await this.bookIdentityService.markLegacyNumericRemovalComplete(userId, completedBookIds);
  }

  async *serializeSyncResponse(result: KoboSyncResult, storeEntitlements: unknown[] = []): AsyncGenerator<string> {
    yield '[';
    let hasEntry = false;
    for (const entry of result.entitlements) {
      yield `${hasEntry ? ',' : ''}${JSON.stringify(entry)}`;
      hasEntry = true;
    }
    if (result.tags) {
      const now = new Date().toISOString();
      for await (const tag of result.tags) {
        const header = JSON.stringify({ Id: tag.id, Name: tag.name, Created: now, LastModified: now, Type: 'UserTag' });
        yield `${hasEntry ? ',' : ''}{"ChangedTag":{"Tag":${header.slice(0, -1)},"Items":[`;
        let hasItem = false;
        for await (const batch of tag.items) {
          if (batch.length === 0) continue;
          yield `${hasItem ? ',' : ''}${JSON.stringify(batch).slice(1, -1)}`;
          hasItem = true;
        }
        yield ']}}}';
        hasEntry = true;
      }
    }
    for (const entry of storeEntitlements) {
      yield `${hasEntry ? ',' : ''}${JSON.stringify(entry)}`;
      hasEntry = true;
    }
    yield ']';
  }

  private async *buildTagItems(userId: number, smartScopeMatchCache: SmartScopeMatchCache): AsyncGenerator<KoboSyncTag> {
    const whereClause = await this.buildEligibleBooksWhereClause(userId, smartScopeMatchCache);
    let afterCollectionId = 0;
    for (;;) {
      const collections = await this.db
        .select({ id: schema.collections.id, name: schema.collections.name })
        .from(schema.collections)
        .where(
          and(
            eq(schema.collections.userId, userId),
            eq(schema.collections.syncToKobo, true),
            eq(schema.collections.mediaType, 'books'),
            gt(schema.collections.id, afterCollectionId),
          ),
        )
        .orderBy(asc(schema.collections.id))
        .limit(SYNC_PAGE_SIZE);
      if (collections.length === 0) break;
      for (const collection of collections) {
        const membership = sql`EXISTS (
          SELECT 1 FROM ${schema.collectionBooks}
          WHERE ${schema.collectionBooks.collectionId} = ${collection.id}
            AND ${schema.collectionBooks.bookId} = ${schema.books.id}
        )`;
        yield { id: `col-${collection.id}`, name: collection.name, items: this.iterateTagItems(userId, and(whereClause, membership)) };
      }
      afterCollectionId = collections[collections.length - 1]!.id;
      if (collections.length < SYNC_PAGE_SIZE) break;
    }

    const [accessibleLibraryIds, timeZone] = await Promise.all([
      this.bookAccessService.getAccessibleLibraryIds(userId),
      this.getUserTimeZone(userId),
    ]);
    const scopes = await this.getSyncedSmartScopeMatchesCached(userId, accessibleLibraryIds, timeZone, smartScopeMatchCache);
    for (const [scopeId, scope] of scopes) {
      yield {
        id: `ss-${scopeId}`,
        name: scope.name,
        items: this.iterateTagItems(userId, scope.where ? and(whereClause, scope.where) : sql`false`),
      };
    }
  }

  private async *iterateTagItems(userId: number, where: SQL | undefined): AsyncGenerator<KoboTagItem[]> {
    if (!where) return;
    let afterBookId = 0;
    for (;;) {
      const rows = await this.db
        .select({ bookId: schema.books.id, entitlementId: schema.koboBookEntitlements.entitlementId })
        .from(schema.books)
        .innerJoin(schema.bookFiles, eq(schema.bookFiles.id, schema.books.primaryFileId))
        .leftJoin(schema.bookMetadata, eq(schema.bookMetadata.bookId, schema.books.id))
        .innerJoin(
          schema.koboBookEntitlements,
          and(eq(schema.koboBookEntitlements.bookId, schema.books.id), eq(schema.koboBookEntitlements.userId, userId)),
        )
        .where(and(where, gt(schema.books.id, afterBookId)))
        .orderBy(asc(schema.books.id))
        .limit(SNAPSHOT_RECONCILE_BATCH_SIZE);
      if (rows.length === 0) break;
      yield rows.map((row) => ({ RevisionId: row.entitlementId, Type: 'ProductRevisionTagItem' }));
      afterBookId = rows[rows.length - 1]!.bookId;
      if (rows.length < SNAPSHOT_RECONCILE_BATCH_SIZE) break;
    }
  }

  // Memoizes getSyncedSmartScopeMatches for the lifetime of a single request (see SmartScopeMatchCache);
  // buildEligibleBooksWhereClause and buildTagItems both need it and would otherwise repeat the same queries.
  private getSyncedSmartScopeMatchesCached(
    userId: number,
    accessibleLibraryIds: number[] | null,
    timeZone: string,
    cache: SmartScopeMatchCache,
  ): Promise<Map<number, SmartScopeMatch>> {
    let pending = cache.get(userId);
    if (!pending) {
      pending = this.getSyncedSmartScopeMatches(userId, accessibleLibraryIds, timeZone);
      cache.set(userId, pending);
    }
    return pending;
  }

  private async getSyncedSmartScopeMatches(
    userId: number,
    accessibleLibraryIds: number[] | null,
    timeZone: string,
  ): Promise<Map<number, SmartScopeMatch>> {
    const scopes = await this.smartScopeService.findKoboSyncScopes(userId);

    if (scopes.length === 0) return new Map();

    const libraryIds = accessibleLibraryIds ?? (await this.db.select({ id: schema.libraries.id }).from(schema.libraries)).map((row) => row.id);

    const matches = scopes.map((scope): [number, SmartScopeMatch] => {
      // A scope without a filter matches zero books everywhere else in the app
      // (SmartScopeService.findAll/prepareBooksQuery), so mirror that here rather
      // than syncing the whole library for an unconfigured scope.
      // Kobo holds books. The scope query already excludes podcast scopes, whose rules are not a
      // GroupRule; this second check keeps that guarantee local to where the filter is read.
      if (!scope.filter || scope.mediaType !== 'books') {
        return [scope.id, { name: scope.name, where: undefined }];
      }
      const where = this.queryBuilder.buildWhere(scope.filter as GroupRule, { accessibleLibraryIds: libraryIds, userId, timeZone });
      return [scope.id, { name: scope.name, where }];
    });

    return new Map<number, SmartScopeMatch>(matches);
  }

  private buildRemovedEntitlement(bookId: number | string) {
    const id = String(bookId);
    const now = new Date().toISOString();
    return {
      ChangedEntitlement: {
        BookEntitlement: {
          Accessibility: 'Full',
          ActivePeriod: { From: now },
          Created: now,
          CrossRevisionId: id,
          Id: id,
          IsRemoved: true,
          IsHiddenFromArchive: false,
          IsLocked: false,
          LastModified: now,
          OriginCategory: 'Imported',
          RevisionId: id,
          Status: 'Deleted',
          Type: 'ebook',
        },
        BookMetadata: { CrossRevisionId: id, RevisionId: id, EntitlementId: id, WorkId: id, Title: id },
      },
    };
  }

  private buildBookEntitlement(book: KoboBookEntry) {
    const id = book.koboEntitlementId;
    const addedAt = book.addedAt.toISOString();
    const updatedAt = book.updatedAt.toISOString();
    return {
      Accessibility: 'Full',
      ActivePeriod: { From: addedAt },
      Created: addedAt,
      CrossRevisionId: id,
      Id: id,
      IsRemoved: false,
      IsHiddenFromArchive: false,
      IsLocked: false,
      LastModified: updatedAt,
      OriginCategory: 'Imported',
      RevisionId: id,
      Status: 'Active',
      Type: 'ebook',
    };
  }

  private buildBookMetadata(book: KoboBookEntry, deviceToken: string, baseUrl: string) {
    const id = book.koboEntitlementId;
    const downloadUrl = `${baseUrl}/api/v1/kobo/${deviceToken}/v1/books/${id}/download`;
    const slug = book.title ? book.title.toLowerCase().replace(/[^a-z0-9]/g, '-') : id;
    const publicationDate = book.publishedDate
      ? `${book.publishedDate}T00:00:00.000Z`
      : book.publishedYear
        ? new Date(Date.UTC(book.publishedYear, 0, 1)).toISOString()
        : null;
    const publisher = book.publisher ? { Name: book.publisher, Imprint: book.publisher } : null;
    const series = book.seriesName
      ? {
          Id: `series_${book.seriesName}`,
          Name: book.seriesName,
          Number: book.seriesIndex ?? '1',
          NumberFloat: book.seriesIndex != null ? Number(book.seriesIndex) : 1.0,
        }
      : { Id: '', Name: '', Number: '', NumberFloat: 0.0 };

    return {
      CrossRevisionId: id,
      RevisionId: id,
      EntitlementId: id,
      WorkId: id,
      Title: book.title,
      Slug: slug,
      Description: book.description,
      Publisher: publisher,
      PublicationDate: publicationDate,
      Language: book.language,
      ...(book.isbn ? { ISBN: book.isbn } : {}),
      Genre: '00000000-0000-0000-0000-000000000001',
      CoverImageId: book.koboCoverImageId,
      Contributors: book.authors,
      ContributorRoles: [],
      Series: series,
      Categories: ['00000000-0000-0000-0000-000000000001'],
      IsSocialEnabled: true,
      ExternalIds: [],
      IsPreOrder: false,
      IsInternetArchive: false,
      IsEligibleForKoboLove: false,
      PhoneticPronunciations: {},
      CurrentDisplayPrice: { TotalAmount: 0, CurrencyCode: 'USD' },
      CurrentLoveDisplayPrice: { TotalAmount: 0 },
      DownloadUrls: [{ Format: book.deliveryFormat, Size: book.fileSizeBytes ?? 0, Url: downloadUrl, Platform: 'Generic', DrmType: 'None' }],
    };
  }

  private buildDefaultReadingState(entitlementId: string) {
    const id = entitlementId;
    const now = new Date().toISOString();
    return {
      EntitlementId: id,
      Created: now,
      LastModified: now,
      PriorityTimestamp: now,
      StatusInfo: { LastModified: now, Status: 'ReadyToRead', TimesStartedReading: 0 },
      Statistics: { LastModified: now },
      CurrentBookmark: { LastModified: now, ProgressPercent: 0 },
    };
  }

  private buildMetadataHash(params: {
    title: string | null;
    authors: string[];
    seriesName: string | null;
    seriesIndex: string | null;
    metadataUpdatedAt: Date | null;
    entitlementId: string;
    coverImageId: string;
    language: string;
    isbn: string | null;
  }): string {
    const metaStr = [
      METADATA_SERIALIZER_VERSION,
      params.title ?? '',
      params.authors.join(','),
      params.seriesName ?? '',
      String(params.seriesIndex ?? ''),
      String(params.metadataUpdatedAt ?? ''),
      params.entitlementId,
      params.coverImageId,
      params.language,
      params.isbn ?? '',
    ].join('|');
    return createHash('sha256').update(metaStr).digest('hex').slice(0, 16);
  }

  /**
   * `hyphenate` describes the bytes actually delivered, not the announced format, so a hyphenated
   * kepub and a plain one never collide even when both are announced as EPUB3FL.
   */
  private buildDeliveryHash(format: KoboDeliveryFormat, hyphenate: boolean): string {
    return createHash('sha256')
      .update([format, hyphenate ? 'hyphenate' : 'plain'].join('|'))
      .digest('hex')
      .slice(0, 16);
  }

  private getDeliveryInfo(
    fileFormat: string | null,
    fileSizeBytes: number | null,
    settings: KoboDeliverySettings,
    isFixedLayout: boolean | null,
  ): KoboDeliveryInfo {
    const normalizedFormat = (fileFormat ?? 'epub').toLowerCase();

    if (normalizedFormat === 'pdf') {
      return { format: 'PDF', hash: this.buildDeliveryHash('PDF', false) };
    }

    const limitBytes = settings.kepubConversionLimitMb * 1024 * 1024;
    const convertsToKepub = normalizedFormat === 'epub' && settings.convertToKepub && (!fileSizeBytes || fileSizeBytes <= limitBytes);
    const hyphenated = convertsToKepub && settings.forceEnableHyphenation;

    // Announcing EPUB3FL is what earns the full-screen renderer; the bytes are deliberately left
    // alone. A kepub renders full screen just the same once the format says fixed layout, and
    // keeping the conversion preserves the KoboSpan positions two-way progress sync depends on.
    if (isFixedLayout && (normalizedFormat === 'epub' || normalizedFormat === 'kepub')) {
      return { format: 'EPUB3FL', hash: this.buildDeliveryHash('EPUB3FL', hyphenated) };
    }

    if (normalizedFormat === 'kepub') {
      return { format: 'KEPUB', hash: this.buildDeliveryHash('KEPUB', false) };
    }

    if (convertsToKepub) {
      return { format: 'KEPUB', hash: this.buildDeliveryHash('KEPUB', hyphenated) };
    }

    return { format: 'EPUB3', hash: this.buildDeliveryHash('EPUB3', false) };
  }

  /**
   * Resolves the fixed-layout flag for eligible files that have never been checked, and stores what
   * it finds so later syncs read the column instead of the filesystem. Capped per sync because this
   * runs on the whole-library pass; anything left over is picked up by the next sync, which only
   * delays a comic's re-announcement rather than losing it.
   *
   * A file that cannot be read stays null so it is retried later: persisting a read failure as
   * `false` would permanently mark a comic reflowable.
   */
  private async backfillFixedLayout(
    rows: readonly FixedLayoutCandidate[],
    limit = FIXED_LAYOUT_BACKFILL_LIMIT,
    executor: KoboCatalogExecutor = this.db,
  ): Promise<Map<number, boolean>> {
    const pending = rows.filter((row) => row.isFixedLayout === null && (row.fileFormat === 'epub' || row.fileFormat === 'kepub')).slice(0, limit);
    const resolved = new Map<number, boolean>();
    if (pending.length === 0) return resolved;

    const startedAt = Date.now();
    const detected = await mapWithConcurrency(pending, FIXED_LAYOUT_BACKFILL_CONCURRENCY, async (row) => {
      try {
        return await this.metadataExtractionService.detectFixedLayout(row.fileAbsolutePath, row.fileFormat!);
      } catch {
        return null;
      }
    });

    const fileIdsByValue = new Map<boolean, number[]>();
    detected.forEach((value, index) => {
      if (value === null) return;
      const fileId = pending[index]!.fileId;
      resolved.set(fileId, value);
      const bucket = fileIdsByValue.get(value) ?? [];
      bucket.push(fileId);
      fileIdsByValue.set(value, bucket);
    });

    try {
      for (const [value, fileIds] of fileIdsByValue) {
        // Still-null guard: keeps the write idempotent, avoids clobbering a value a concurrent
        // scan just wrote, and keeps book_files.updatedAt (the KOReader library token and OPDS
        // entry timestamps) from being bumped by a sync that changed nothing.
        await executor
          .update(schema.bookFiles)
          .set({ isFixedLayout: value })
          .where(and(inArray(schema.bookFiles.id, fileIds), isNull(schema.bookFiles.isFixedLayout)));
      }
    } catch (err) {
      // The detected values are still returned, so this sync announces the right format either
      // way; only the persistence that saves the next sync the work is lost.
      const error = err instanceof Error ? err : new Error(String(err));
      this.logger.warn(
        `[kobo.fixed_layout_backfill] [fail] candidates=${pending.length} errorClass=${error.constructor.name} error="${sanitizeLogValue(error.message)}" - could not persist fixed layout flags`,
      );
      return resolved;
    }

    this.logger.debug(
      `[kobo.fixed_layout_backfill] [end] candidates=${pending.length} resolved=${resolved.size} fixedLayout=${fileIdsByValue.get(true)?.length ?? 0} durationMs=${Date.now() - startedAt} - fixed layout flags backfilled`,
    );
    return resolved;
  }

  private async getDeliverySettings(userId: number): Promise<KoboDeliverySettings> {
    const settings = await this.db.query.koboSyncSettings.findFirst({
      where: eq(schema.koboSyncSettings.userId, userId),
      columns: {
        convertToKepub: true,
        forceEnableHyphenation: true,
        kepubConversionLimitMb: true,
        twoWayProgressSync: true,
      },
    });

    return {
      convertToKepub: settings?.twoWayProgressSync ? true : (settings?.convertToKepub ?? true),
      forceEnableHyphenation: settings?.forceEnableHyphenation ?? false,
      kepubConversionLimitMb: settings?.kepubConversionLimitMb ?? 100,
    };
  }

  private async buildEligibleBooksWhereClause(userId: number, smartScopeMatchCache: SmartScopeMatchCache): Promise<SQL | undefined> {
    const [accessibleLibraryIds, contentFilters, timeZone] = await Promise.all([
      this.bookAccessService.getAccessibleLibraryIds(userId),
      this.contentFilterRepository.findByUserId(userId),
      this.getUserTimeZone(userId),
    ]);

    const libraryAccessFilter =
      accessibleLibraryIds === null
        ? undefined
        : accessibleLibraryIds.length === 0
          ? sql`false`
          : inArray(schema.books.libraryId, accessibleLibraryIds);

    const collectionMembershipFilter = sql`EXISTS (
      SELECT 1
      FROM ${schema.collectionBooks}
      INNER JOIN ${schema.collections}
        ON ${schema.collections.id} = ${schema.collectionBooks.collectionId}
      WHERE ${schema.collectionBooks.bookId} = ${schema.books.id}
        AND ${schema.collections.userId} = ${userId}
        AND ${schema.collections.syncToKobo} = true
    )`;

    const smartScopeMatches = await this.getSyncedSmartScopeMatchesCached(userId, accessibleLibraryIds, timeZone, smartScopeMatchCache);
    const smartScopeFilters = [...smartScopeMatches.values()].map((match) => match.where).filter((where): where is SQL => where !== undefined);
    const membershipFilter = smartScopeFilters.length > 0 ? or(collectionMembershipFilter, ...smartScopeFilters) : collectionMembershipFilter;

    const contentFilterClauses = accessibleLibraryIds !== null ? buildContentFilterClauses(contentFilters, this.db) : [];

    return and(
      eq(schema.books.status, 'present'),
      inArray(schema.bookFiles.format, ['epub', 'kepub', 'pdf']),
      libraryAccessFilter,
      membershipFilter,
      ...contentFilterClauses,
    );
  }

  private async getUserTimeZone(userId: number): Promise<string> {
    const user = await this.db.query.users.findFirst({
      where: eq(schema.users.id, userId),
      columns: { settings: true },
    });
    return resolveTimeZone((user?.settings as UserSettingsWithTimeZone | undefined)?.timezone, 'UTC');
  }

  private async fetchEligibleSnapshotRows(
    userId: number,
    needsLegacyNumericRemovalForNewMappings: boolean,
    smartScopeMatchCache: SmartScopeMatchCache,
    backfillFixedLayout = false,
    afterBookId = 0,
    fixedLayoutBackfillBudget = { remaining: FIXED_LAYOUT_BACKFILL_LIMIT },
    executor: KoboCatalogExecutor = this.db,
    preparedWhere?: SQL,
    preparedSettings?: KoboDeliverySettings,
  ): Promise<EligibleSnapshotRow[]> {
    const whereClause = preparedWhere ?? (await this.buildEligibleBooksWhereClause(userId, smartScopeMatchCache));
    if (!whereClause) return [];
    const deliverySettings = preparedSettings ?? (await this.getDeliverySettings(userId));

    const rows = await executor
      .select({
        bookId: schema.books.id,
        title: schema.bookMetadata.title,
        isbn10: schema.bookMetadata.isbn10,
        isbn13: schema.bookMetadata.isbn13,
        language: schema.bookMetadata.language,
        seriesName: schema.bookMetadata.seriesName,
        seriesIndex: schema.bookMetadata.seriesIndex,
        metadataUpdatedAt: schema.bookMetadata.updatedAt,
        coverUpdatedAt: schema.bookMetadata.coverUpdatedAt,
        fileFormat: schema.bookFiles.format,
        fileSizeBytes: schema.bookFiles.sizeBytes,
        fileMediaOverlayAvailable: schema.bookFiles.mediaOverlayAvailable,
        fileHash: schema.bookFiles.fileHash,
        fileId: schema.bookFiles.id,
        fileAbsolutePath: schema.bookFiles.absolutePath,
        isFixedLayout: schema.bookFiles.isFixedLayout,
        authorNamesCsv: sql<string>`coalesce(string_agg(${schema.authors.name}, ',' ORDER BY ${schema.bookAuthors.displayOrder}, ${schema.bookAuthors.authorId}), '')`,
      })
      .from(schema.books)
      .innerJoin(schema.bookFiles, eq(schema.bookFiles.id, schema.books.primaryFileId))
      .leftJoin(schema.bookMetadata, eq(schema.bookMetadata.bookId, schema.books.id))
      .leftJoin(schema.bookAuthors, eq(schema.bookAuthors.bookId, schema.books.id))
      .leftJoin(schema.authors, eq(schema.authors.id, schema.bookAuthors.authorId))
      .where(and(whereClause, gt(schema.books.id, afterBookId)))
      .groupBy(
        schema.books.id,
        schema.bookMetadata.title,
        schema.bookMetadata.isbn10,
        schema.bookMetadata.isbn13,
        schema.bookMetadata.language,
        schema.bookMetadata.seriesName,
        schema.bookMetadata.seriesIndex,
        schema.bookMetadata.updatedAt,
        schema.bookMetadata.coverUpdatedAt,
        schema.bookFiles.format,
        schema.bookFiles.sizeBytes,
        schema.bookFiles.fileHash,
        schema.bookFiles.id,
        schema.bookFiles.absolutePath,
        schema.bookFiles.isFixedLayout,
      )
      .orderBy(asc(schema.books.id))
      .limit(SNAPSHOT_RECONCILE_BATCH_SIZE);

    const identitiesById = await this.bookIdentityService.ensureForBooks(
      userId,
      rows.map((row) => row.bookId),
      needsLegacyNumericRemovalForNewMappings,
      executor,
    );

    const fixedLayoutByFileId = backfillFixedLayout
      ? await this.backfillFixedLayout(rows, fixedLayoutBackfillBudget.remaining, executor)
      : new Map<number, boolean>();
    if (backfillFixedLayout) {
      const candidateCount = rows.filter((row) => row.isFixedLayout === null && (row.fileFormat === 'epub' || row.fileFormat === 'kepub')).length;
      fixedLayoutBackfillBudget.remaining -= Math.min(fixedLayoutBackfillBudget.remaining, candidateCount);
    }

    return rows.map((row) => {
      const isFixedLayout = row.isFixedLayout ?? fixedLayoutByFileId.get(row.fileId) ?? null;
      const delivery = this.getDeliveryInfo(row.fileFormat, deliverySizeBytes(row), deliverySettings, isFixedLayout);
      const identity = identitiesById.get(row.bookId);
      const coverImageId = identity
        ? this.bookIdentityService.buildVersionedCoverImageId(identity.coverImageId, row.coverUpdatedAt)
        : String(row.bookId);
      return {
        bookId: row.bookId,
        fileHash: row.fileHash,
        deliveryHash: delivery.hash,
        metadataHash: this.buildMetadataHash({
          title: row.title,
          authors: row.authorNamesCsv ? row.authorNamesCsv.split(',').filter((name) => name.length > 0) : [],
          seriesName: row.seriesName,
          seriesIndex: row.seriesIndex,
          metadataUpdatedAt: row.metadataUpdatedAt,
          entitlementId: identity?.entitlementId ?? String(row.bookId),
          coverImageId,
          language: normalizeKoboLanguage(row.language),
          isbn: selectKoboIsbn(row.isbn13, row.isbn10),
        }),
        needsLegacyNumericRemoval: identity?.needsLegacyNumericRemoval ?? false,
      };
    });
  }

  private async *iterateEligibleSnapshotRows(
    userId: number,
    needsLegacyNumericRemovalForNewMappings: boolean,
    smartScopeMatchCache: SmartScopeMatchCache,
    executor: KoboCatalogExecutor = this.db,
    preparedWhere?: SQL,
    preparedSettings?: KoboDeliverySettings,
  ): AsyncGenerator<EligibleSnapshotRow[]> {
    let afterBookId = 0;
    const fixedLayoutBackfillBudget = { remaining: FIXED_LAYOUT_BACKFILL_LIMIT };
    const startedAt = Date.now();
    let bookCount = 0;
    let batchCount = 0;
    this.logger.debug(`[kobo.snapshot_catalog] [start] userId=${userId} batchSize=${SNAPSHOT_RECONCILE_BATCH_SIZE} - catalog scan started`);
    try {
      for (;;) {
        const batch = await this.fetchEligibleSnapshotRows(
          userId,
          needsLegacyNumericRemovalForNewMappings,
          smartScopeMatchCache,
          fixedLayoutBackfillBudget.remaining > 0,
          afterBookId,
          fixedLayoutBackfillBudget,
          executor,
          preparedWhere,
          preparedSettings,
        );
        if (batch.length === 0) break;
        batchCount++;
        bookCount += batch.length;
        yield batch;
        afterBookId = batch[batch.length - 1]!.bookId;
        if (batch.length < SNAPSHOT_RECONCILE_BATCH_SIZE) break;
      }
      this.logger.debug(
        `[kobo.snapshot_catalog] [end] userId=${userId} durationMs=${Date.now() - startedAt} books=${bookCount} batches=${batchCount} batchSize=${SNAPSHOT_RECONCILE_BATCH_SIZE} - catalog scan completed`,
      );
    } catch (error: unknown) {
      this.logger.error(
        `[kobo.snapshot_catalog] [fail] userId=${userId} durationMs=${Date.now() - startedAt} errorClass=${error instanceof Error ? error.name : 'UnknownError'} error="${sanitizeLogValue(error instanceof Error ? error.message : 'unknown error')}" - catalog scan failed`,
      );
      throw error;
    }
  }

  private async prepareEligibleSnapshotRows(
    userId: number,
    needsLegacyNumericRemovalForNewMappings: boolean,
    smartScopeMatchCache: SmartScopeMatchCache,
  ): Promise<EligibleSnapshotBatchFactory> {
    const [where, settings] = await Promise.all([this.buildEligibleBooksWhereClause(userId, smartScopeMatchCache), this.getDeliverySettings(userId)]);
    return (executor) =>
      this.iterateEligibleSnapshotRows(userId, needsLegacyNumericRemovalForNewMappings, smartScopeMatchCache, executor, where, settings);
  }

  private async fetchEligibleBooksByIds(
    userId: number,
    bookIds: number[],
    needsLegacyNumericRemovalForNewMappings: boolean,
    smartScopeMatchCache: SmartScopeMatchCache,
  ): Promise<Map<number, KoboBookEntry>> {
    const uniqueBookIds = [...new Set(bookIds)];
    if (uniqueBookIds.length === 0) return new Map();

    const whereClause = await this.buildEligibleBooksWhereClause(userId, smartScopeMatchCache);
    if (!whereClause) return new Map();
    const deliverySettings = await this.getDeliverySettings(userId);

    const rows = await this.db
      .select({
        bookId: schema.books.id,
        title: schema.bookMetadata.title,
        description: schema.bookMetadata.description,
        publisher: schema.bookMetadata.publisher,
        publishedDate: schema.bookMetadata.publishedDate,
        publishedYear: schema.bookMetadata.publishedYear,
        language: schema.bookMetadata.language,
        isbn10: schema.bookMetadata.isbn10,
        isbn13: schema.bookMetadata.isbn13,
        seriesName: schema.bookMetadata.seriesName,
        seriesIndex: schema.bookMetadata.seriesIndex,
        fileFormat: schema.bookFiles.format,
        fileSizeBytes: schema.bookFiles.sizeBytes,
        fileMediaOverlayAvailable: schema.bookFiles.mediaOverlayAvailable,
        fileHash: schema.bookFiles.fileHash,
        isFixedLayout: schema.bookFiles.isFixedLayout,
        metadataUpdatedAt: schema.bookMetadata.updatedAt,
        coverUpdatedAt: schema.bookMetadata.coverUpdatedAt,
        addedAt: schema.books.addedAt,
        updatedAt: schema.books.updatedAt,
      })
      .from(schema.books)
      .innerJoin(schema.bookFiles, eq(schema.bookFiles.id, schema.books.primaryFileId))
      .leftJoin(schema.bookMetadata, eq(schema.bookMetadata.bookId, schema.books.id))
      .where(and(whereClause, inArray(schema.books.id, uniqueBookIds)));

    if (rows.length === 0) return new Map();

    const fetchedBookIds = rows.map((row) => row.bookId);
    const [authorRows, collectionRows] = await Promise.all([
      this.db
        .select({ bookId: schema.bookAuthors.bookId, name: schema.authors.name })
        .from(schema.bookAuthors)
        .innerJoin(schema.authors, eq(schema.authors.id, schema.bookAuthors.authorId))
        .where(inArray(schema.bookAuthors.bookId, fetchedBookIds))
        .orderBy(schema.bookAuthors.displayOrder),
      this.db
        .select({ bookId: schema.collectionBooks.bookId, name: schema.collections.name })
        .from(schema.collectionBooks)
        .innerJoin(
          schema.collections,
          and(
            eq(schema.collections.id, schema.collectionBooks.collectionId),
            eq(schema.collections.userId, userId),
            eq(schema.collections.syncToKobo, true),
          ),
        )
        .where(inArray(schema.collectionBooks.bookId, fetchedBookIds)),
    ]);

    const authorsByBook = new Map<number, string[]>();
    for (const row of authorRows) {
      const names = authorsByBook.get(row.bookId) ?? [];
      names.push(row.name);
      authorsByBook.set(row.bookId, names);
    }

    const collectionsByBook = new Map<number, string[]>();
    for (const row of collectionRows) {
      const names = collectionsByBook.get(row.bookId) ?? [];
      if (!names.includes(row.name)) names.push(row.name);
      collectionsByBook.set(row.bookId, names);
    }

    const identitiesById = await this.bookIdentityService.ensureForBooks(userId, fetchedBookIds, needsLegacyNumericRemovalForNewMappings);
    const byId = new Map<number, KoboBookEntry>();
    for (const row of rows) {
      const authors = authorsByBook.get(row.bookId) ?? [];
      const delivery = this.getDeliveryInfo(row.fileFormat, deliverySizeBytes(row), deliverySettings, row.isFixedLayout);
      const identity = identitiesById.get(row.bookId);
      if (!identity) continue;
      const coverImageId = this.bookIdentityService.buildVersionedCoverImageId(identity.coverImageId, row.coverUpdatedAt);
      const language = normalizeKoboLanguage(row.language);
      const isbn = selectKoboIsbn(row.isbn13, row.isbn10);
      byId.set(row.bookId, {
        bookId: row.bookId,
        koboEntitlementId: identity.entitlementId,
        koboCoverImageId: coverImageId,
        title: row.title ?? `Book ${row.bookId}`,
        authors,
        description: row.description,
        publisher: row.publisher,
        publishedDate: row.publishedDate,
        publishedYear: row.publishedYear,
        language,
        isbn,
        seriesName: row.seriesName,
        seriesIndex: row.seriesIndex,
        fileFormat: row.fileFormat ?? 'epub',
        fileSizeBytes: row.fileSizeBytes,
        fileHash: row.fileHash,
        deliveryFormat: delivery.format,
        metadataHash: this.buildMetadataHash({
          title: row.title,
          authors,
          seriesName: row.seriesName,
          seriesIndex: row.seriesIndex,
          metadataUpdatedAt: row.metadataUpdatedAt,
          entitlementId: identity.entitlementId,
          coverImageId,
          language,
          isbn,
        }),
        metadataUpdatedAt: row.metadataUpdatedAt,
        collectionNames: collectionsByBook.get(row.bookId) ?? [],
        addedAt: row.addedAt,
        updatedAt: row.updatedAt,
      });
    }

    return byId;
  }
}
