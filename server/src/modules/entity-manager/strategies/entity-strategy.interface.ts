import type { BrowseEntityBookCountFilter, BrowseEntitySortBy, BrowseEntitySortOrder, ContentFilterRules, EntityType } from '@bookorbit/types';
import type { NodePgDatabase } from 'drizzle-orm/node-postgres';
import type * as schema from '../../../db/schema';

export type EntityMutationExecutor = Pick<NodePgDatabase<typeof schema>, 'execute'>;
export interface EntityMutationBooks {
  onBooksChanged?: (bookIds: number[], executor: EntityMutationExecutor) => Promise<void>;
  spoolBookIds?: boolean;
}
export interface StrategyAffectedBooks {
  affectedBookIds: number[];
  affectedBookCount?: number;
  affectedBookBatches?: () => AsyncIterable<number[]>;
  disposeAffectedBooks?: () => Promise<void>;
}

export interface EntityBookScope {
  libraryIds: number[];
  contentFilters?: ContentFilterRules;
}

export interface RawCandidatePair {
  idA: number | string;
  idB: number | string;
  nameA: string;
  nameB: string;
  simScore: number;
  sortNameA?: string | null;
  sortNameB?: string | null;
  hasPhotoA?: boolean;
  hasPhotoB?: boolean;
}

export interface BrowseParams {
  libraryIds: number[];
  search?: string;
  page: number;
  pageSize: number;
  sortBy: BrowseEntitySortBy;
  sortOrder: BrowseEntitySortOrder;
  bookCount: BrowseEntityBookCountFilter;
  contentFilters?: import('@bookorbit/types').ContentFilterRules;
}

export interface BrowseResult {
  items: { id: number | string; name: string; bookCount: number; sortName?: string | null; hasPhoto?: boolean }[];
  total: number;
}

export interface MergeInput extends EntityMutationBooks {
  targetId: number | string;
  sourceIds: (number | string)[];
  userId: number;
  libraryIds?: number[];
  contentFilters?: ContentFilterRules;
}

export interface StrategyMergeResult extends StrategyAffectedBooks {
  imagePromoted?: boolean;
  fieldsResolved?: string[];
}

export interface RenameInput extends EntityMutationBooks {
  entityId: number | string;
  newName: string;
  userId: number;
  libraryIds: number[];
  contentFilters?: ContentFilterRules;
}

export interface StrategyRenameResult extends StrategyAffectedBooks {
  oldName: string;
  wasImplicitMerge: boolean;
  mergedEntityId?: number | string;
}

export interface DeleteInput extends EntityMutationBooks {
  entityId: number | string;
  mode: 'soft' | 'hard' | 'inline';
  libraryIds: number[];
  contentFilters?: ContentFilterRules;
}

export interface StrategyDeleteResult extends StrategyAffectedBooks {
  name: string;
}

export interface SplitInput extends EntityMutationBooks {
  entityId: number;
  newNames: string[];
  libraryIds?: number[];
  contentFilters?: ContentFilterRules;
}

export interface StrategySplitResult extends StrategyAffectedBooks {
  originalName: string;
  newEntities: { id: number; name: string }[];
}

export interface EntityStrategy {
  readonly entityType: EntityType;
  readonly isInline: boolean;

  findCandidatePairs(libraryIds: number[], minSimilarity: number, contentFilters?: ContentFilterRules): Promise<RawCandidatePair[]>;

  getAllEntityIds?(): Promise<number[]>;

  computeCandidatePairsForBatch?(outerIds: number[], minSimilarity: number): Promise<RawCandidatePair[]>;

  browse(params: BrowseParams): Promise<BrowseResult>;

  assertMutationScope(ids: (number | string)[], scope: EntityBookScope): Promise<void>;

  merge(input: MergeInput): Promise<StrategyMergeResult>;
  rename(input: RenameInput): Promise<StrategyRenameResult>;
  deleteEntity(input: DeleteInput): Promise<StrategyDeleteResult>;
  split(input: SplitInput): Promise<StrategySplitResult>;

  findAffectedBookIds(ids: (number | string)[]): Promise<number[]>;
  getBookCount(id: number | string, scope?: EntityBookScope): Promise<number>;
  getBookTitles(id: number | string, limit: number, scope?: EntityBookScope): Promise<string[]>;
  findEntityById(id: number | string): Promise<{ id: number | string; name: string } | null>;
}
