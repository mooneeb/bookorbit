import { BadRequestException, Injectable, Logger, NotFoundException, PayloadTooLargeException } from '@nestjs/common';

import type {
  BrowseEntitiesResponse,
  DeleteResult,
  DismissedPairInfo,
  EntityDismissedPairsPage,
  EntityDuplicateClusterPage,
  DuplicateCluster,
  DuplicateScanResponse,
  DuplicateScanStatus,
  EntityInfo,
  EntityType,
  MergeResult,
  RenameResult,
  SplitResult,
  BulkDeleteResult,
} from '@bookorbit/types';
import type { RequestUser } from '../../common/types/request-user';
import { sanitizeLogValue } from '../../common/utils/log-sanitize.utils';
import { FileWriteService } from '../file-write/file-write.service';
import { LibraryService } from '../library/library.service';
import { MetadataScoreService } from '../metadata-score/metadata-score.service';
import { EntityManagerRepository } from './entity-manager.repository';
import { DuplicateComputeService } from './duplicate-compute.service';
import { DuplicateGraph } from './duplicate-graph';
import type { EntityBookScope, EntityStrategy, RawCandidatePair } from './strategies/entity-strategy.interface';
import { AuthorStrategy } from './strategies/author.strategy';
import { GenreStrategy } from './strategies/genre.strategy';
import { TagStrategy } from './strategies/tag.strategy';
import { NarratorStrategy } from './strategies/narrator.strategy';
import { PublisherStrategy } from './strategies/publisher.strategy';
import { LanguageStrategy } from './strategies/language.strategy';
import { SeriesStrategy } from './strategies/series.strategy';

const BOOK_TITLES_LIMIT = 5;
const DEFAULT_MIN_SIMILARITY = 0.5;
const DEFAULT_SCAN_PAGE = 1;
const DEFAULT_SCAN_PAGE_SIZE = 20;

function logErrorFields(err: unknown): { errorClass: string; error: string } {
  const error = err instanceof Error ? err : new Error(String(err));
  return { errorClass: error.name, error: sanitizeLogValue(error.message) };
}

@Injectable()
export class EntityManagerService {
  private readonly logger = new Logger(EntityManagerService.name);
  private readonly strategies: Map<EntityType, EntityStrategy>;

  constructor(
    private readonly repo: EntityManagerRepository,
    private readonly libraryService: LibraryService,
    private readonly fileWriteService: FileWriteService,
    private readonly metadataScoreService: MetadataScoreService,
    private readonly duplicateCompute: DuplicateComputeService,
    authorStrategy: AuthorStrategy,
    genreStrategy: GenreStrategy,
    tagStrategy: TagStrategy,
    narratorStrategy: NarratorStrategy,
    publisherStrategy: PublisherStrategy,
    languageStrategy: LanguageStrategy,
    seriesStrategy: SeriesStrategy,
  ) {
    this.strategies = new Map<EntityType, EntityStrategy>([
      ['author', authorStrategy],
      ['genre', genreStrategy],
      ['tag', tagStrategy],
      ['narrator', narratorStrategy],
      ['publisher', publisherStrategy],
      ['language', languageStrategy],
      ['series', seriesStrategy],
    ]);
  }

  getStrategy(entityType: EntityType): EntityStrategy {
    const strategy = this.strategies.get(entityType);
    if (!strategy) throw new BadRequestException(`Unknown entity type: ${entityType}`);
    return strategy;
  }

  async scanDuplicates(
    entityType: EntityType,
    user: RequestUser,
    libraryId?: number,
    minSimilarity?: number,
    page = DEFAULT_SCAN_PAGE,
    pageSize = DEFAULT_SCAN_PAGE_SIZE,
  ): Promise<DuplicateScanResponse> {
    const event = 'entity_manager.scan_duplicates';
    const startedAt = Date.now();
    this.logger.log(`[${event}] [start] userId=${user.id} entityType=${entityType} page=${page} pageSize=${pageSize} - duplicate scan started`);
    try {
      const result = await this.loadDuplicatePages(entityType, user, libraryId, minSimilarity ?? DEFAULT_MIN_SIMILARITY, page, pageSize);
      this.logger.log(
        `[${event}] [end] userId=${user.id} entityType=${entityType} durationMs=${Date.now() - startedAt} total=${result.total} page=${result.page} clusters=${result.clusters.length} - duplicate scan completed`,
      );
      return result;
    } catch (err) {
      const error = logErrorFields(err);
      this.logger.warn(
        `[${event}] [fail] userId=${user.id} entityType=${entityType} durationMs=${Date.now() - startedAt} errorClass=${error.errorClass} error="${error.error}" - duplicate scan failed`,
      );
      throw err;
    }
  }

  async getDuplicateClusterPage(
    entityType: EntityType,
    user: RequestUser,
    clusterId: string,
    page: number,
    pageSize: number,
  ): Promise<EntityDuplicateClusterPage> {
    let cursor: { root: string; minSimilarity: number; libraryId?: number };
    try {
      cursor = JSON.parse(Buffer.from(clusterId, 'base64url').toString('utf8'));
      if (
        typeof cursor.root !== 'string' ||
        !cursor.root ||
        !Number.isFinite(cursor.minSimilarity) ||
        cursor.minSimilarity < 0.1 ||
        cursor.minSimilarity > 1 ||
        (cursor.libraryId !== undefined && (!Number.isInteger(cursor.libraryId) || cursor.libraryId <= 0))
      )
        throw new BadRequestException('Invalid cluster cursor');
    } catch {
      throw new BadRequestException('Invalid cluster cursor');
    }
    const event = 'entity_manager.duplicate_cluster_page';
    const startedAt = Date.now();
    this.logger.log(
      `[${event}] [start] userId=${user.id} entityType=${entityType} page=${page} pageSize=${pageSize} - duplicate cluster page started`,
    );
    try {
      const result = await this.loadDuplicatePages(entityType, user, cursor.libraryId, cursor.minSimilarity, 1, 1, cursor.root, page, pageSize);
      const cluster = result.clusters[0];
      if (!cluster) throw new NotFoundException('Duplicate cluster no longer exists. Refresh the scan.');
      this.logger.log(
        `[${event}] [end] userId=${user.id} entityType=${entityType} durationMs=${Date.now() - startedAt} entityCount=${cluster.entities.length} pairCount=${cluster.pairDetails.length} - duplicate cluster page completed`,
      );
      return {
        clusterId: cluster.clusterId,
        entities: cluster.entities,
        pairDetails: cluster.pairDetails,
        entityTotal: cluster.entityTotal!,
        pairTotal: cluster.pairTotal!,
        page,
        pageSize,
        nextPage: cluster.nextPage ?? null,
      };
    } catch (err) {
      const error = logErrorFields(err);
      this.logger.warn(
        `[${event}] [fail] userId=${user.id} entityType=${entityType} durationMs=${Date.now() - startedAt} errorClass=${error.errorClass} error="${error.error}" - duplicate cluster page failed`,
      );
      throw err;
    }
  }

  private async loadDuplicatePages(
    entityType: EntityType,
    user: RequestUser,
    libraryId: number | undefined,
    similarity: number,
    page: number,
    pageSize: number,
    clusterRoot?: string,
    detailsPage = 1,
    detailsPageSize = 10,
  ): Promise<DuplicateScanResponse> {
    const strategy = this.getStrategy(entityType);
    const allLibraryIds = await this.libraryService.findAccessibleLibraryIds(user);
    if (libraryId && !allLibraryIds.includes(libraryId)) throw new BadRequestException('Library not accessible');
    const scope: EntityBookScope = {
      libraryIds: libraryId ? [libraryId] : allLibraryIds,
      contentFilters: user.isSuperuser ? undefined : user.contentFilters,
    };
    const graph = new DuplicateGraph();
    const status = strategy.isInline || scope.libraryIds.length === 0 ? null : await this.duplicateCompute.getStatus(entityType);
    const read = async (replay: (consumer: (pairs: RawCandidatePair[]) => void) => Promise<void>): Promise<DuplicateScanResponse> => {
      const ranked = graph.ranked();
      const clampedPage = ranked.length > 0 ? Math.max(1, Math.min(page, Math.ceil(ranked.length / pageSize))) : 1;
      const selected = clusterRoot
        ? ranked.filter((cluster) => cluster.root === clusterRoot)
        : ranked.slice((clampedPage - 1) * pageSize, clampedPage * pageSize);
      const selectedRoots = new Set(selected.map((cluster) => cluster.root));
      const pairSlices = new Map<string, RawCandidatePair[]>();
      const positions = new Map<string, number>();
      const offset = (detailsPage - 1) * detailsPageSize;
      if (selected.length > 0)
        await replay((pairs) => {
          for (const pair of pairs) {
            const root = graph.root(String(pair.idA));
            if (!selectedRoots.has(root)) continue;
            const position = positions.get(root) ?? 0;
            positions.set(root, position + 1);
            if (position >= offset && position < offset + detailsPageSize) {
              const slice = pairSlices.get(root) ?? [];
              slice.push(pair);
              pairSlices.set(root, slice);
            }
          }
        });
      const clusters = await this.enrichClusterSlice(entityType, selected, pairSlices, scope, similarity, libraryId, detailsPage, detailsPageSize);
      const result = { entityType, clusters, totalEntities: graph.entityCount, total: ranked.length, page: clampedPage, pageSize };
      if (Buffer.byteLength(JSON.stringify(result)) > 1024 * 1024)
        throw new PayloadTooLargeException('Duplicate page exceeds response limit. Request a smaller page size.');
      return result;
    };
    if (status?.isComputing) return read(async () => {});
    const result = await this.duplicateCompute.withCandidateBatches(entityType, similarity, scope, (pairs) => graph.add(pairs), read);
    if (
      !strategy.isInline &&
      scope.libraryIds.length > 0 &&
      (!status || (!status.isComputing && (!status.computedAt || (status.threshold !== null && status.threshold > similarity))))
    )
      this.duplicateCompute.triggerCompute(entityType, strategy, similarity);
    return result!;
  }

  async getDuplicateScanStatus(entityType: EntityType, user?: RequestUser): Promise<DuplicateScanStatus> {
    const strategy = this.getStrategy(entityType);

    if (strategy.isInline) {
      return { entityType, state: 'done', computedAt: null, totalPairs: null, threshold: null, progressPct: null };
    }

    const row = await this.duplicateCompute.getStatus(entityType);

    if (!row) {
      return { entityType, state: 'idle', computedAt: null, totalPairs: null, threshold: null, progressPct: null };
    }

    let state: DuplicateScanStatus['state'] = 'done';
    if (row.isComputing) state = 'computing';
    else if (row.errorMessage && !row.computedAt) state = 'error';
    else if (!row.computedAt) state = 'idle';

    const scopedPairCount = user
      ? await this.duplicateCompute.countScopedCandidates(entityType, {
          libraryIds: await this.libraryService.findAccessibleLibraryIds(user),
          contentFilters: user.isSuperuser ? undefined : user.contentFilters,
        })
      : row.totalPairs;
    const progressPct =
      row.isComputing && row.totalCount && row.processedCount !== null ? Math.round((row.processedCount / row.totalCount) * 100) : null;

    return {
      entityType,
      state,
      computedAt: row.computedAt ? row.computedAt.toISOString() : null,
      totalPairs: scopedPairCount ?? null,
      threshold: row.threshold ?? null,
      progressPct,
    };
  }

  async refreshDuplicates(entityType: EntityType, minSimilarity?: number, user?: RequestUser): Promise<DuplicateScanStatus> {
    const strategy = this.getStrategy(entityType);
    const threshold = minSimilarity ?? DEFAULT_MIN_SIMILARITY;

    if (!strategy.isInline) {
      this.duplicateCompute.triggerCompute(entityType, strategy, threshold);
    }

    return this.getDuplicateScanStatus(entityType, user);
  }

  async browse(
    entityType: EntityType,
    user: RequestUser,
    params: { search?: string; page?: number; pageSize?: number; sortBy?: string; sortOrder?: string; bookCount?: string },
  ): Promise<BrowseEntitiesResponse> {
    const strategy = this.getStrategy(entityType);
    const libraryIds = await this.libraryService.findAccessibleLibraryIds(user);

    if (libraryIds.length === 0) return { items: [], total: 0, page: params.page ?? 1, pageSize: params.pageSize ?? 25 };
    const result = await strategy.browse({
      libraryIds,
      search: params.search,
      page: params.page ?? 1,
      pageSize: params.pageSize ?? 25,
      sortBy: (params.sortBy as 'name' | 'bookCount') || 'name',
      sortOrder: (params.sortOrder as 'asc' | 'desc') || 'asc',
      bookCount: strategy.isInline ? 'any' : (params.bookCount as 'any' | 'empty') || 'any',
      contentFilters: user.isSuperuser ? undefined : user.contentFilters,
    });

    return { items: result.items, total: result.total, page: params.page ?? 1, pageSize: params.pageSize ?? 25 };
  }

  async merge(
    entityType: EntityType,
    user: RequestUser,
    targetId: number | string,
    sourceIds: (number | string)[],
    writeFiles: boolean,
  ): Promise<MergeResult> {
    const event = 'entity_manager.merge';
    const startedAt = Date.now();
    this.logger.log(
      `[${event}] [start] userId=${user.id} entityType=${entityType} targetId="${sanitizeLogValue(String(targetId))}" sourceCount=${sourceIds.length} - merge started`,
    );

    try {
      const strategy = this.getStrategy(entityType);
      this.assertIdentity(strategy, targetId);
      if (!Array.isArray(sourceIds) || sourceIds.length === 0 || sourceIds.length > 100 || sourceIds.includes(targetId)) {
        throw new BadRequestException('Merge requires 1 to 100 sources distinct from the target');
      }
      sourceIds.forEach((id) => this.assertIdentity(strategy, id));
      const libraryIds = await this.libraryService.findAccessibleLibraryIds(user);
      const result = await strategy.merge({
        targetId,
        sourceIds,
        userId: user.id,
        libraryIds,
        contentFilters: user.isSuperuser ? undefined : user.contentFilters,
        onBooksChanged: (bookIds, executor) => this.metadataScoreService.calculateAndSaveMany(bookIds, executor),
        spoolBookIds: writeFiles,
      });

      await this.finishMutation(result, user, writeFiles);

      const nonInlineSourceIds: number[] = [];
      for (const sourceId of sourceIds) {
        if (strategy.isInline) {
          await this.repo.deleteInlineDismissedPairsForValue(entityType, sourceId as string);
        } else {
          await this.repo.deleteDismissedPairsForEntity(entityType, sourceId as number);
          nonInlineSourceIds.push(sourceId as number);
        }
      }

      if (nonInlineSourceIds.length > 0) {
        await this.duplicateCompute.invalidateCandidatesForEntities(entityType, nonInlineSourceIds);
      }

      this.logger.log(
        `[${event}] [end] userId=${user.id} entityType=${entityType} durationMs=${Date.now() - startedAt} affectedBooks=${result.affectedBookCount ?? result.affectedBookIds.length} - merge completed`,
      );

      return {
        targetId,
        mergedIds: sourceIds,
        affectedBookCount: result.affectedBookCount ?? result.affectedBookIds.length,
        imagePromoted: result.imagePromoted,
        fieldsResolved: result.fieldsResolved,
      };
    } catch (err) {
      const error = logErrorFields(err);
      this.logger.warn(
        `[${event}] [fail] userId=${user.id} entityType=${entityType} durationMs=${Date.now() - startedAt} errorClass=${error.errorClass} error="${error.error}" - merge failed`,
      );
      throw err;
    }
  }

  async rename(entityType: EntityType, user: RequestUser, entityId: number | string, newName: string, writeFiles: boolean): Promise<RenameResult> {
    const event = 'entity_manager.rename';
    const startedAt = Date.now();
    this.logger.log(
      `[${event}] [start] userId=${user.id} entityType=${entityType} entityId="${sanitizeLogValue(String(entityId))}" - rename started`,
    );

    try {
      const strategy = this.getStrategy(entityType);
      const libraryIds = await this.libraryService.findAccessibleLibraryIds(user);
      this.assertIdentity(strategy, entityId);
      if (!newName?.trim()) throw new BadRequestException('Name cannot be empty');
      const result = await strategy.rename({
        entityId,
        newName,
        userId: user.id,
        libraryIds,
        contentFilters: user.isSuperuser ? undefined : user.contentFilters,
        onBooksChanged: (bookIds, executor) => this.metadataScoreService.calculateAndSaveMany(bookIds, executor),
        spoolBookIds: writeFiles,
      });

      await this.finishMutation(result, user, writeFiles);

      this.logger.log(
        `[${event}] [end] userId=${user.id} entityType=${entityType} durationMs=${Date.now() - startedAt} implicitMerge=${result.wasImplicitMerge} - rename completed`,
      );

      return {
        entityId,
        oldName: result.oldName,
        newName: newName.trim(),
        affectedBookCount: result.affectedBookCount ?? result.affectedBookIds.length,
        wasImplicitMerge: result.wasImplicitMerge,
        mergedEntityId: result.mergedEntityId,
      };
    } catch (err) {
      const error = logErrorFields(err);
      this.logger.warn(
        `[${event}] [fail] userId=${user.id} entityType=${entityType} durationMs=${Date.now() - startedAt} errorClass=${error.errorClass} error="${error.error}" - rename failed`,
      );
      throw err;
    }
  }

  async deleteEntity(
    entityType: EntityType,
    user: RequestUser,
    entityId: number | string,
    mode: 'soft' | 'hard' | 'inline',
    writeFiles: boolean,
  ): Promise<DeleteResult> {
    const event = 'entity_manager.delete';
    const startedAt = Date.now();
    this.logger.log(
      `[${event}] [start] userId=${user.id} entityType=${entityType} entityId="${sanitizeLogValue(String(entityId))}" mode=${mode} - delete started`,
    );

    try {
      const strategy = this.getStrategy(entityType);
      const libraryIds = await this.libraryService.findAccessibleLibraryIds(user);
      this.assertIdentity(strategy, entityId);
      const effectiveMode = !strategy.isInline && mode === 'soft' && (await strategy.getBookCount(entityId)) === 0 ? 'hard' : mode;
      const result = await strategy.deleteEntity({
        entityId,
        mode: effectiveMode,
        libraryIds,
        contentFilters: user.isSuperuser ? undefined : user.contentFilters,
        onBooksChanged: (bookIds, executor) => this.metadataScoreService.calculateAndSaveMany(bookIds, executor),
        spoolBookIds: writeFiles,
      });

      await this.finishMutation(result, user, writeFiles);

      if (strategy.isInline) {
        await this.repo.deleteInlineDismissedPairsForValue(entityType, entityId as string);
      } else if (effectiveMode === 'hard') {
        await this.repo.deleteDismissedPairsForEntity(entityType, entityId as number);
        await this.duplicateCompute.invalidateCandidatesForEntities(entityType, [entityId as number]);
      }

      this.logger.log(
        `[${event}] [end] userId=${user.id} entityType=${entityType} durationMs=${Date.now() - startedAt} affectedBooks=${result.affectedBookCount ?? result.affectedBookIds.length} - delete completed`,
      );

      return { entityId, name: result.name, affectedBookCount: result.affectedBookCount ?? result.affectedBookIds.length, mode: effectiveMode };
    } catch (err) {
      const error = logErrorFields(err);
      this.logger.warn(
        `[${event}] [fail] userId=${user.id} entityType=${entityType} durationMs=${Date.now() - startedAt} errorClass=${error.errorClass} error="${error.error}" - delete failed`,
      );
      throw err;
    }
  }

  async bulkDelete(
    entityType: EntityType,
    user: RequestUser,
    entityIds: (number | string)[],
    mode: 'soft' | 'hard' | 'inline',
    writeFiles: boolean,
  ): Promise<BulkDeleteResult> {
    if (!Array.isArray(entityIds) || entityIds.length === 0 || entityIds.length > 100) {
      throw new BadRequestException('Select 1 to 100 entities');
    }
    const results: DeleteResult[] = [];
    const errors: { entityId: number | string; error: string }[] = [];

    for (const entityId of entityIds) {
      try {
        const result = await this.deleteEntity(entityType, user, entityId, mode, writeFiles);
        results.push(result);
      } catch (err) {
        errors.push({ entityId, error: err instanceof Error ? err.message : String(err) });
      }
    }

    return { results, errors };
  }

  async split(entityType: EntityType, user: RequestUser, entityId: number, newNames: string[], writeFiles: boolean): Promise<SplitResult> {
    const event = 'entity_manager.split';
    const startedAt = Date.now();
    this.logger.log(
      `[${event}] [start] userId=${user.id} entityType=${entityType} entityId="${sanitizeLogValue(String(entityId))}" newCount=${newNames.length} - split started`,
    );

    try {
      const strategy = this.getStrategy(entityType);

      if (strategy.isInline) {
        throw new BadRequestException('Split is not supported for inline entity types');
      }
      if (newNames.length < 2) {
        throw new BadRequestException('Split requires at least 2 new names');
      }

      const libraryIds = await this.libraryService.findAccessibleLibraryIds(user);
      this.assertIdentity(strategy, entityId);
      if (newNames.length > 100 || newNames.some((name) => !name.trim())) throw new BadRequestException('Split names cannot be empty');
      const result = await strategy.split({
        entityId,
        newNames,
        libraryIds,
        contentFilters: user.isSuperuser ? undefined : user.contentFilters,
        onBooksChanged: (bookIds, executor) => this.metadataScoreService.calculateAndSaveMany(bookIds, executor),
        spoolBookIds: writeFiles,
      });

      await this.finishMutation(result, user, writeFiles);

      await this.repo.deleteDismissedPairsForEntity(entityType, entityId);

      this.logger.log(
        `[${event}] [end] userId=${user.id} entityType=${entityType} durationMs=${Date.now() - startedAt} newEntities=${result.newEntities.length} - split completed`,
      );

      return {
        originalId: entityId,
        originalName: result.originalName,
        newEntities: result.newEntities,
        affectedBookCount: result.affectedBookCount ?? result.affectedBookIds.length,
      };
    } catch (err) {
      const error = logErrorFields(err);
      this.logger.warn(
        `[${event}] [fail] userId=${user.id} entityType=${entityType} durationMs=${Date.now() - startedAt} errorClass=${error.errorClass} error="${error.error}" - split failed`,
      );
      throw err;
    }
  }

  async dismissPair(entityType: EntityType, user: RequestUser, idA: number | string, idB: number | string, reason?: string): Promise<void> {
    const event = 'entity_manager.dismiss_pair';
    const startedAt = Date.now();
    const fields = `userId=${user.id} idA="${sanitizeLogValue(String(idA))}" idB="${sanitizeLogValue(String(idB))}" entityType=${entityType}`;
    this.logger.log(`[${event}] [start] ${fields} - duplicate pair dismissal started`);
    try {
      const strategy = this.getStrategy(entityType);
      await this.assertPairScope(strategy, user, idA, idB);
      if (strategy.isInline) {
        await this.repo.insertInlineDismissedPair(entityType, idA as string, idB as string, reason, user.id);
      } else {
        await this.repo.insertDismissedPair(entityType, idA as number, idB as number, reason, user.id);
      }
      this.logger.log(`[${event}] [end] ${fields} durationMs=${Date.now() - startedAt} - duplicate pair dismissal completed`);
    } catch (err) {
      const error = logErrorFields(err);
      this.logger.warn(
        `[${event}] [fail] ${fields} durationMs=${Date.now() - startedAt} errorClass=${error.errorClass} error="${error.error}" - duplicate pair dismissal failed`,
      );
      throw err;
    }
  }

  async undismissPair(entityType: EntityType, user: RequestUser, idA: number | string, idB: number | string): Promise<void> {
    const event = 'entity_manager.undismiss_pair';
    const startedAt = Date.now();
    const fields = `userId=${user.id} idA="${sanitizeLogValue(String(idA))}" idB="${sanitizeLogValue(String(idB))}" entityType=${entityType}`;
    this.logger.log(`[${event}] [start] ${fields} - duplicate pair restoration started`);
    try {
      const strategy = this.getStrategy(entityType);
      await this.assertPairScope(strategy, user, idA, idB);
      if (strategy.isInline) {
        await this.repo.deleteInlineDismissedPair(entityType, idA as string, idB as string);
      } else {
        await this.repo.deleteDismissedPair(entityType, idA as number, idB as number);
      }
      this.logger.log(`[${event}] [end] ${fields} durationMs=${Date.now() - startedAt} - duplicate pair restoration completed`);
    } catch (err) {
      const error = logErrorFields(err);
      this.logger.warn(
        `[${event}] [fail] ${fields} durationMs=${Date.now() - startedAt} errorClass=${error.errorClass} error="${error.error}" - duplicate pair restoration failed`,
      );
      throw err;
    }
  }

  async getDismissedPairs(entityType: EntityType, user: RequestUser): Promise<DismissedPairInfo[]> {
    return (await this.getDismissedPairsPage(entityType, user, 1, 100)).items;
  }

  async getDismissedPairsPage(entityType: EntityType, user: RequestUser, page = 1, pageSize = 20): Promise<EntityDismissedPairsPage> {
    this.getStrategy(entityType);
    const libraryIds = await this.libraryService.findAccessibleLibraryIds(user);
    const result = await this.repo.findDismissedPairsPage(
      entityType,
      { libraryIds, contentFilters: user.isSuperuser ? undefined : user.contentFilters },
      page,
      pageSize,
    );
    const response = { ...result, page, pageSize };
    if (Buffer.byteLength(JSON.stringify(response)) > 1024 * 1024)
      throw new PayloadTooLargeException('Dismissed pairs page exceeds response limit. Request a smaller page size.');
    return response;
  }

  async getEntityInfo(entityType: EntityType, user: RequestUser, entityId: number | string): Promise<EntityInfo> {
    const strategy = this.getStrategy(entityType);
    this.assertIdentity(strategy, entityId);
    const entity = await strategy.findEntityById(entityId);
    if (!entity) throw new NotFoundException(`${entityType} not found`);

    const libraryIds = await this.libraryService.findAccessibleLibraryIds(user);
    const bookScope: EntityBookScope = {
      libraryIds,
      contentFilters: user.isSuperuser ? undefined : user.contentFilters,
    };
    const [globalBookCount, bookCount, bookTitles] = await Promise.all([
      strategy.getBookCount(entityId),
      strategy.getBookCount(entityId, bookScope),
      strategy.getBookTitles(entityId, BOOK_TITLES_LIMIT, bookScope),
    ]);
    if (globalBookCount > 0 && bookCount === 0) throw new NotFoundException(`${entityType} not found`);

    return { id: entity.id, name: entity.name, bookCount, bookTitles };
  }

  private async assertPairScope(strategy: EntityStrategy, user: RequestUser, idA: number | string, idB: number | string): Promise<void> {
    this.assertIdentity(strategy, idA);
    this.assertIdentity(strategy, idB);
    if (idA === idB) throw new BadRequestException('Select two distinct entities');
    const libraryIds = await this.libraryService.findAccessibleLibraryIds(user);
    await strategy.assertMutationScope([idA, idB], { libraryIds, contentFilters: user.isSuperuser ? undefined : user.contentFilters });
    await this.getEntityInfo(strategy.entityType, user, idA);
    await this.getEntityInfo(strategy.entityType, user, idB);
  }

  private assertIdentity(strategy: EntityStrategy, id: number | string): void {
    if (strategy.isInline ? typeof id !== 'string' || !id.trim() : !Number.isInteger(id) || Number(id) <= 0) {
      throw new BadRequestException('A valid entity identity is required');
    }
  }

  private async enrichClusterSlice(
    entityType: EntityType,
    rankedSlice: Array<{ root: string; memberIds: Set<string>; avgSimilarity: number; pairCount: number }>,
    pairSlices: Map<string, RawCandidatePair[]>,
    scope: EntityBookScope,
    similarity: number,
    libraryId: number | undefined,
    page: number,
    pageSize: number,
  ): Promise<DuplicateCluster[]> {
    const inline = this.getStrategy(entityType).isInline;
    const memberSlices = new Map(
      rankedSlice.map((cluster) => [
        cluster.root,
        [...cluster.memberIds].sort((a, b) => a.localeCompare(b)).slice((page - 1) * pageSize, page * pageSize),
      ]),
    );
    const ids = new Set([...memberSlices.values()].flat());
    for (const pairs of pairSlices.values())
      for (const pair of pairs) {
        ids.add(String(pair.idA));
        ids.add(String(pair.idB));
      }
    const rows = await this.repo.findClusterEntities(
      entityType,
      [...ids].map((id) => (inline ? id : Number(id))),
      scope,
    );
    const entityMap = new Map(rows.map((entity) => [String(entity.id), entity]));
    return rankedSlice.flatMap((cluster) => {
      const entities = memberSlices
        .get(cluster.root)!
        .map((id) => entityMap.get(id))
        .filter((entity): entity is NonNullable<typeof entity> => !!entity);
      const pairs = pairSlices.get(cluster.root) ?? [];
      if (entities.length === 0 && pairs.every((pair) => !entityMap.has(String(pair.idA)) && !entityMap.has(String(pair.idB)))) return [];
      const suggestedTarget = entities.reduce<(typeof entities)[number] | undefined>(
        (best, entity) => (!best || entity.bookCount > best.bookCount ? entity : best),
        undefined,
      );
      return {
        clusterId: Buffer.from(JSON.stringify({ root: cluster.root, minSimilarity: similarity, libraryId })).toString('base64url'),
        entities,
        entityTotal: cluster.memberIds.size,
        pairTotal: cluster.pairCount,
        detailsPageSize: pageSize,
        nextPage: page * pageSize < Math.max(cluster.memberIds.size, cluster.pairCount) ? page + 1 : null,
        averageSimilarity: Math.round(cluster.avgSimilarity * 100) / 100,
        suggestedTargetId: suggestedTarget?.id ?? (inline ? cluster.root : Number(cluster.root)),
        pairDetails: pairs.map((pair) => ({
          idA: pair.idA,
          idB: pair.idB,
          nameA: entityMap.get(String(pair.idA))?.name ?? pair.nameA,
          nameB: entityMap.get(String(pair.idB))?.name ?? pair.nameB,
          similarity: Math.round(pair.simScore * 100) / 100,
          reasons: this.computeReasons(
            pair.simScore,
            entityMap.get(String(pair.idA))?.name ?? pair.nameA,
            entityMap.get(String(pair.idB))?.name ?? pair.nameB,
          ),
        })),
      };
    });
  }

  private computeReasons(simScore: number, nameA: string, nameB: string): string[] {
    const reasons: string[] = [];
    if (simScore >= 0.85) reasons.push('Very high name similarity');
    else if (simScore >= 0.7) reasons.push('High name similarity');
    else reasons.push('Moderate name similarity');

    const a = nameA.toLowerCase();
    const b = nameB.toLowerCase();
    if (a.length >= 4 && b.length >= 4 && (a.includes(b) || b.includes(a))) {
      reasons.push('Name containment');
    }

    const tokensA = a
      .replace(/[^a-z0-9\s]/g, '')
      .split(/\s+/)
      .filter(Boolean)
      .sort();
    const tokensB = b
      .replace(/[^a-z0-9\s]/g, '')
      .split(/\s+/)
      .filter(Boolean)
      .sort();
    if (tokensA.length > 0 && tokensA.join(' ') === tokensB.join(' ')) {
      reasons.push('Same normalized tokens');
    }

    return reasons;
  }

  private scheduleWrites(bookIds: number[], userId: number): void {
    const uniqueIds = [...new Set(bookIds)];
    for (const bookId of uniqueIds) {
      this.fileWriteService.scheduleWrite(bookId, 'auto', userId);
    }
  }

  private async finishMutation(
    result: import('./strategies/entity-strategy.interface').StrategyAffectedBooks,
    user: RequestUser,
    writeFiles: boolean,
  ): Promise<void> {
    try {
      if (result.affectedBookCount === undefined) await this.metadataScoreService.calculateAndSaveMany(result.affectedBookIds);
      if (!writeFiles) return;
      if (!result.affectedBookBatches) {
        this.scheduleWrites(result.affectedBookIds, user.id);
        return;
      }
      const startedAt = Date.now();
      let processed = 0;
      this.logger.log(
        `[entity_manager.write_files] [start] userId=${user.id} bookCount=${result.affectedBookCount ?? 0} - entity file updates started`,
      );
      for await (const ids of result.affectedBookBatches()) {
        const libraryIds = await this.libraryService.findAccessibleLibraryIds(user);
        const scopedIds = await this.repo.filterBookIdsByScope(ids, { libraryIds });
        for (let index = 0; index < scopedIds.length; index += 5) {
          await Promise.all(scopedIds.slice(index, index + 5).map((bookId) => this.fileWriteService.writeToFile(bookId, 'auto', user.id)));
        }
        processed += ids.length;
        this.logger.log(
          `[entity_manager.write_files] [end] userId=${user.id} durationMs=${Date.now() - startedAt} processed=${processed} bookCount=${result.affectedBookCount ?? 0} - entity file update progress`,
        );
      }
    } finally {
      await result.disposeAffectedBooks?.();
    }
  }
}
