import { createHash } from 'node:crypto';
import { Injectable, Logger } from '@nestjs/common';
import { sanitizeLogValue } from '../../../common/utils/log-sanitize.utils';

import type { MigrationProfile, MigrationSource } from '../../../db/schema';
import { SourceAdapterRegistry } from '../adapters/source-adapter.registry';
import type { SourceExportData } from '../adapters/source-adapter.types';
import { parseConnectionConfig } from '../core/connection-config';
import { asRecord, asString, asNumber } from '../core/coerce';
import { MatchingService } from './matching.service';
import type {
  PathMapping,
  PlannedBookMatch,
  PlannedDuplicateBookMatch,
  PlannedDuplicateSourceCandidate,
  PlannerResult,
  PlannedMigration,
  PlannedUserPreview,
  UserMapping,
  MigrationPlanningStore,
} from './planner.types';

const MATCHING_PRIORITY = ['isbn', 'asin', 'file_hash', 'path_mapping', 'title_author'] as const;

@Injectable()
export class MigrationPlannerService {
  private readonly logger = new Logger(MigrationPlannerService.name);
  constructor(
    private readonly adapterRegistry: SourceAdapterRegistry,
    private readonly matchingService: MatchingService,
  ) {}

  async buildPlan(params: {
    source: MigrationSource;
    profile: MigrationProfile;
    scopeOverride?: Record<string, unknown>;
    actorUserId?: number;
    onSourceBatch?: (batch: SourceExportData) => Promise<void>;
    planningStore?: MigrationPlanningStore;
  }): Promise<PlannerResult> {
    const { source, profile, scopeOverride } = params;
    const adapter = this.adapterRegistry.get(source.type);

    const connectionConfig = parseConnectionConfig(source.type, source.connectionConfig);
    const snapshot = await adapter.snapshot(connectionConfig);

    const userMappings = parseUserMappings(profile.userMappings);
    const pathMappings = parsePathMappings(profile.pathMappings);

    const scope = { ...asRecord(profile.scope), ...(scopeOverride ?? {}) };

    if (params.planningStore && params.onSourceBatch) {
      return this.buildPersistedPlan({
        ...params,
        planningStore: params.planningStore,
        onSourceBatch: params.onSourceBatch,
        connectionConfig,
        adapter,
        snapshot,
        userMappings,
        pathMappings,
        scope,
      });
    }

    const startMs = Date.now();
    this.logger.log(
      `[migration.plan] [start] sourceId=${source.id} profileId=${profile.id} streamed=${!!params.onSourceBatch} - migration planning started`,
    );
    const sourceData = emptySourceData();
    const matches: PlannedBookMatch[] = [];
    const unresolved: PlannedMigration['unresolvedBooks'] = [];
    const sourceBooksById = new Map<string, { title: string | null; author: string | null; filePath: string | null }>();
    const mappedUsers = new Map(
      userMappings
        .filter((entry): entry is UserMapping & { targetUserId: number } => entry.targetUserId !== null)
        .map((entry) => [entry.sourceUserId, entry.targetUserId]),
    );
    const previewCounts = new Map<string, Map<string, PlannedUserPreview['counts']>>();
    const sourceUsers = new Map<string, SourceExportData['users'][number]>();
    let batchCount = 0;
    let sourceBookCount = 0;
    const batches =
      params.onSourceBatch && adapter.exportDataBatches
        ? adapter.exportDataBatches(connectionConfig)
        : singleSourceBatch(() => adapter.exportData(connectionConfig));
    try {
      for await (const batch of batches) {
        const uniqueBooks = batch.books.filter((book) => !sourceBooksById.has(book.sourceBookId));
        for (const book of uniqueBooks) sourceBooksById.set(book.sourceBookId, { title: book.title, author: book.author, filePath: book.filePath });
        for (const user of batch.users) sourceUsers.set(user.sourceUserId, user);
        const matched = await this.matchingService.matchBooks(uniqueBooks, pathMappings, params.actorUserId);
        matches.push(...matched.matches);
        unresolved.push(...matched.unresolved);
        collectPreviewCounts(batch, mappedUsers, previewCounts);
        if (params.onSourceBatch) await params.onSourceBatch(batch);
        else appendSourceData(sourceData, batch);
        batchCount++;
        sourceBookCount += uniqueBooks.length;
        if (batchCount % 50 === 0)
          this.logger.log(
            `[migration.plan] [start] sourceId=${source.id} profileId=${profile.id} batches=${batchCount} sourceBooks=${sourceBookCount} - migration planning progress`,
          );
      }
    } catch (error) {
      this.logger.error(
        `[migration.plan] [fail] sourceId=${source.id} profileId=${profile.id} durationMs=${Date.now() - startMs} errorClass=${error instanceof Error ? error.name : 'Unknown'} error="${sanitizeLogValue(error instanceof Error ? error.message : String(error))}" - migration planning failed`,
      );
      throw error;
    }
    const { executableMatches, duplicateBookMatches } = splitDuplicateMatches(matches, sourceBooksById);
    const matchedBookIds = new Set(executableMatches.map((entry) => entry.sourceBookId));
    const totals = new Map<string, PlannedUserPreview['counts']>();
    for (const [bookId, users] of previewCounts) {
      if (!matchedBookIds.has(bookId)) continue;
      for (const [sourceUserId, counts] of users) {
        const total = totals.get(sourceUserId) ?? emptyPreviewCounts();
        for (const key of Object.keys(total) as Array<keyof typeof total>) total[key] += counts[key];
        totals.set(sourceUserId, total);
      }
    }
    const userPreview = [...mappedUsers].map(([sourceUserId, targetUserId]) => ({
      sourceUserId,
      targetUserId,
      username: sourceUsers.get(sourceUserId)?.username ?? sourceUserId,
      counts: totals.get(sourceUserId) ?? emptyPreviewCounts(),
    }));
    this.logger.log(
      `[migration.plan] [end] sourceId=${source.id} profileId=${profile.id} durationMs=${Date.now() - startMs} batches=${batchCount} sourceBooks=${sourceBookCount} matched=${executableMatches.length} unresolved=${unresolved.length} duplicates=${duplicateBookMatches.length} - migration planning completed`,
    );

    const plan: PlannedMigration = {
      itemIdentityVersion: 2,
      generatedAt: new Date().toISOString(),
      snapshot,
      matchingPriority: [...MATCHING_PRIORITY],
      userMappings,
      pathMappings,
      scope,
      matchedBooks: executableMatches,
      unresolvedBooks: unresolved,
      duplicateBookMatches,
      userPreview,
    };

    return {
      plan,
      execution: {
        sourceData,
        matchedBooks: executableMatches,
        unresolvedBooks: unresolved,
        duplicateBookMatches,
      },
    };
  }

  private async buildPersistedPlan(params: {
    source: MigrationSource;
    profile: MigrationProfile;
    actorUserId?: number;
    planningStore: MigrationPlanningStore;
    onSourceBatch: (batch: SourceExportData) => Promise<void>;
    connectionConfig: Parameters<ReturnType<SourceAdapterRegistry['get']>['snapshot']>[0];
    adapter: ReturnType<SourceAdapterRegistry['get']>;
    snapshot: PlannedMigration['snapshot'];
    userMappings: UserMapping[];
    pathMappings: PathMapping[];
    scope: Record<string, unknown>;
  }): Promise<PlannerResult> {
    const startMs = Date.now();
    const { source, profile, planningStore, adapter, connectionConfig, userMappings, pathMappings } = params;
    const mappedUsers = new Map(
      userMappings
        .filter((row): row is UserMapping & { targetUserId: number } => row.targetUserId !== null)
        .map((row) => [row.sourceUserId, row.targetUserId]),
    );
    const usernames = new Map<string, string>();
    const matchingContentHash = createHash('sha256');
    let batchCount = 0;
    let sourceBookCount = 0;
    this.logger.log(`[migration.plan] [start] sourceId=${source.id} profileId=${profile.id} streamed=true - migration planning started`);
    try {
      const batches = adapter.exportDataBatches
        ? adapter.exportDataBatches(connectionConfig)
        : singleSourceBatch(() => adapter.exportData(connectionConfig));
      for await (const batch of batches) {
        for (let offset = 0; offset < batch.books.length; offset += 100) {
          const books = [...new Map(batch.books.slice(offset, offset + 100).map((book) => [book.sourceBookId, book])).values()];
          const known = await planningStore.knownSourceBookIds(books.map((book) => book.sourceBookId));
          const unseen = books.filter((book) => !known.has(book.sourceBookId));
          if (unseen.length > 0) {
            const matched = await this.matchingService.matchBooks(unseen, pathMappings, params.actorUserId);
            matchingContentHash.update(JSON.stringify(matched));
            await planningStore.appendCandidates(unseen, matched);
            sourceBookCount += unseen.length;
          }
        }
        for (const user of batch.users) if (mappedUsers.has(user.sourceUserId)) usernames.set(user.sourceUserId, user.username);
        const counts = new Map<string, Map<string, PlannedUserPreview['counts']>>();
        collectPreviewCounts(batch, mappedUsers, counts);
        const rows = [...counts].flatMap(([sourceBookId, users]) =>
          [...users].map(([sourceUserId, counts]) => ({ sourceBookId, sourceUserId, counts })),
        );
        for (let offset = 0; offset < rows.length; offset += 100) await planningStore.appendPreviewCounts(rows.slice(offset, offset + 100));
        await params.onSourceBatch(batch);
        batchCount++;
        if (batchCount % 50 === 0)
          this.logger.log(
            `[migration.plan] [start] sourceId=${source.id} profileId=${profile.id} batches=${batchCount} sourceBooks=${sourceBookCount} - migration planning progress`,
          );
      }
      const totals = await planningStore.totals();
      const countsByUser = new Map(totals.users.map((row) => [row.sourceUserId, row.counts]));
      const plan: PlannedMigration = {
        itemIdentityVersion: 2,
        matchingContentHash: matchingContentHash.digest('hex'),
        generatedAt: new Date().toISOString(),
        snapshot: params.snapshot,
        matchingPriority: [...MATCHING_PRIORITY],
        userMappings,
        pathMappings,
        scope: params.scope,
        matchedBooks: [],
        unresolvedBooks: [],
        duplicateBookMatches: [],
        userPreview: [...mappedUsers].map(([sourceUserId, targetUserId]) => ({
          sourceUserId,
          targetUserId,
          username: usernames.get(sourceUserId) ?? sourceUserId,
          counts: countsByUser.get(sourceUserId) ?? emptyPreviewCounts(),
        })),
      };
      this.logger.log(
        `[migration.plan] [end] sourceId=${source.id} profileId=${profile.id} durationMs=${Date.now() - startMs} batches=${batchCount} sourceBooks=${sourceBookCount} matched=${totals.summary.matchedBooks} unresolved=${totals.summary.unresolvedBooks} duplicates=${totals.summary.duplicateBookMatches} - migration planning completed`,
      );
      return {
        plan,
        durableSummary: totals.summary,
        execution: { sourceData: emptySourceData(), matchedBooks: [], unresolvedBooks: [], duplicateBookMatches: [] },
      };
    } catch (error) {
      this.logger.error(
        `[migration.plan] [fail] sourceId=${source.id} profileId=${profile.id} durationMs=${Date.now() - startMs} errorClass=${error instanceof Error ? error.name : 'Unknown'} error="${sanitizeLogValue(error instanceof Error ? error.message : String(error))}" - migration planning failed`,
      );
      throw error;
    }
  }
}

function splitDuplicateMatches(
  matches: PlannedBookMatch[],
  sourceBooksById: Map<string, { title: string | null; author: string | null; filePath: string | null }>,
): {
  executableMatches: PlannedBookMatch[];
  duplicateBookMatches: PlannedDuplicateBookMatch[];
} {
  const byTarget = new Map<number, PlannedBookMatch[]>();
  for (const match of matches) {
    const rows = byTarget.get(match.targetBookId) ?? [];
    rows.push(match);
    byTarget.set(match.targetBookId, rows);
  }

  const duplicateTargetIds = new Set<number>();
  const duplicateBookMatches: PlannedDuplicateBookMatch[] = [];
  for (const [targetBookId, rows] of byTarget) {
    if (rows.length < 2) continue;
    duplicateTargetIds.add(targetBookId);
    const sourceCandidates: PlannedDuplicateSourceCandidate[] = rows.map((row) => {
      const sourceBook = sourceBooksById.get(row.sourceBookId);
      return {
        sourceBookId: row.sourceBookId,
        title: sourceBook?.title ?? null,
        author: sourceBook?.author ?? null,
        filePath: sourceBook?.filePath ?? null,
        strategy: row.strategy,
      };
    });
    duplicateBookMatches.push({
      targetBookId,
      matches: rows,
      sourceBookIds: rows.map((row) => row.sourceBookId),
      strategies: rows.map((row) => row.strategy),
      sourceCandidates,
      reason: 'duplicate_target_match',
    });
  }

  return {
    executableMatches: matches.filter((match) => !duplicateTargetIds.has(match.targetBookId)),
    duplicateBookMatches,
  };
}

function parseUserMappings(raw: unknown): UserMapping[] {
  if (!Array.isArray(raw)) return [];

  const out: UserMapping[] = [];
  for (const item of raw) {
    if (!item || typeof item !== 'object') continue;

    const sourceUserId = asString((item as Record<string, unknown>).sourceUserId ?? (item as Record<string, unknown>).source_user_id);
    const record = item as Record<string, unknown>;
    const rawTargetUserId = 'targetUserId' in record ? record.targetUserId : record.target_user_id;
    const targetUserId = asNumber(rawTargetUserId);
    if (!sourceUserId || (rawTargetUserId !== null && !targetUserId)) continue;

    out.push({ sourceUserId, targetUserId });
  }

  return out;
}

function parsePathMappings(raw: unknown): PathMapping[] {
  if (!Array.isArray(raw)) return [];

  const out: PathMapping[] = [];
  for (const item of raw) {
    if (!item || typeof item !== 'object') continue;

    const sourcePrefix = asString((item as Record<string, unknown>).sourcePrefix ?? (item as Record<string, unknown>).source_prefix);
    const targetPrefix = asString((item as Record<string, unknown>).targetPrefix ?? (item as Record<string, unknown>).target_prefix);
    if (!sourcePrefix || !targetPrefix) continue;

    out.push({ sourcePrefix, targetPrefix });
  }

  return out;
}

export function buildUserPreview(sourceData: SourceExportData, mappedUsers: Map<string, number>, matchedBookIds: Set<string>): PlannedUserPreview[] {
  const usersById = new Map(sourceData.users.map((user) => [user.sourceUserId, user]));
  const countsBySourceUser = new Map<
    string,
    { statuses: number; fileProgress: number; readingSessions: number; bookmarks: number; annotations: number; shelves: number }
  >();

  const increment = (sourceUserId: string, key: 'statuses' | 'fileProgress' | 'readingSessions' | 'bookmarks' | 'annotations' | 'shelves') => {
    const current = countsBySourceUser.get(sourceUserId) ?? {
      statuses: 0,
      fileProgress: 0,
      readingSessions: 0,
      bookmarks: 0,
      annotations: 0,
      shelves: 0,
    };
    current[key] += 1;
    countsBySourceUser.set(sourceUserId, current);
  };

  for (const row of sourceData.userBookStatuses) {
    if (mappedUsers.has(row.sourceUserId) && matchedBookIds.has(row.sourceBookId)) increment(row.sourceUserId, 'statuses');
  }
  for (const row of sourceData.userFileProgress) {
    if (mappedUsers.has(row.sourceUserId) && matchedBookIds.has(row.sourceBookId)) increment(row.sourceUserId, 'fileProgress');
  }
  for (const row of sourceData.readingSessions ?? []) {
    if (mappedUsers.has(row.sourceUserId) && matchedBookIds.has(row.sourceBookId)) increment(row.sourceUserId, 'readingSessions');
  }
  for (const row of sourceData.bookmarks) {
    if (mappedUsers.has(row.sourceUserId) && matchedBookIds.has(row.sourceBookId)) increment(row.sourceUserId, 'bookmarks');
  }
  for (const row of sourceData.annotations) {
    if (mappedUsers.has(row.sourceUserId) && matchedBookIds.has(row.sourceBookId)) increment(row.sourceUserId, 'annotations');
  }

  const shelfById = new Map(sourceData.shelves.map((row) => [row.sourceShelfId, row]));
  for (const row of sourceData.shelfBooks) {
    if (!matchedBookIds.has(row.sourceBookId)) continue;
    const shelf = shelfById.get(row.sourceShelfId);
    const sourceUserId = row.sourceUserId || shelf?.sourceUserId;
    if (!sourceUserId) continue;
    if (!mappedUsers.has(sourceUserId)) continue;
    increment(sourceUserId, 'shelves');
  }

  return [...mappedUsers.entries()].map(([sourceUserId, targetUserId]) => {
    const sourceUser = usersById.get(sourceUserId);
    const counts = countsBySourceUser.get(sourceUserId) ?? {
      statuses: 0,
      fileProgress: 0,
      readingSessions: 0,
      bookmarks: 0,
      annotations: 0,
      shelves: 0,
    };
    return {
      sourceUserId,
      targetUserId,
      username: sourceUser?.username ?? sourceUserId,
      counts,
    };
  });
}

function emptySourceData(): SourceExportData {
  return {
    users: [],
    books: [],
    userBookStatuses: [],
    userFileProgress: [],
    readingSessions: [],
    bookmarks: [],
    annotations: [],
    shelves: [],
    shelfBooks: [],
  };
}

async function* singleSourceBatch(load: () => Promise<SourceExportData>): AsyncGenerator<SourceExportData> {
  yield await load();
}

function appendSourceData(target: SourceExportData, batch: SourceExportData) {
  const keys = [
    'users',
    'books',
    'userBookStatuses',
    'userFileProgress',
    'readingSessions',
    'bookmarks',
    'annotations',
    'shelves',
    'shelfBooks',
  ] as const;
  for (const key of keys) {
    const rows = target[key] as unknown[];
    for (const row of batch[key] ?? []) rows.push(row);
  }
  target.availableDomains = batch.availableDomains ?? target.availableDomains;
}

function emptyPreviewCounts(): PlannedUserPreview['counts'] {
  return { statuses: 0, fileProgress: 0, readingSessions: 0, bookmarks: 0, annotations: 0, shelves: 0 };
}

function collectPreviewCounts(
  data: SourceExportData,
  mappedUsers: Map<string, number>,
  counts: Map<string, Map<string, PlannedUserPreview['counts']>>,
) {
  const increment = (bookId: string, userId: string, key: keyof PlannedUserPreview['counts']) => {
    if (!mappedUsers.has(userId)) return;
    const users = counts.get(bookId) ?? new Map<string, PlannedUserPreview['counts']>();
    const current = users.get(userId) ?? emptyPreviewCounts();
    current[key]++;
    users.set(userId, current);
    counts.set(bookId, users);
  };
  for (const row of data.userBookStatuses) increment(row.sourceBookId, row.sourceUserId, 'statuses');
  for (const row of data.userFileProgress) increment(row.sourceBookId, row.sourceUserId, 'fileProgress');
  for (const row of data.readingSessions ?? []) increment(row.sourceBookId, row.sourceUserId, 'readingSessions');
  for (const row of data.bookmarks) increment(row.sourceBookId, row.sourceUserId, 'bookmarks');
  for (const row of data.annotations) increment(row.sourceBookId, row.sourceUserId, 'annotations');
  const shelves = new Map(data.shelves.map((row) => [row.sourceShelfId, row.sourceUserId]));
  for (const row of data.shelfBooks) increment(row.sourceBookId, row.sourceUserId || shelves.get(row.sourceShelfId) || '', 'shelves');
}
