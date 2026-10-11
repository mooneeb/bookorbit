export type MigrationRunState = "draft" | "preflight_failed" | "dry_run_ready" | "running" | "failed" | "completed";

export type UnresolvedReasonCode =
  | "no_isbn_match"
  | "no_asin_match"
  | "no_file_hash_match"
  | "no_file_path_match"
  | "no_title_author_match"
  | "insufficient_source_data"
  | "ambiguous_isbn_match"
  | "ambiguous_asin_match"
  | "ambiguous_file_hash_match"
  | "ambiguous_file_path_match"
  | "ambiguous_title_author_match"
  | "duplicate_target_match";

export interface MigrationSourceCapabilities {
  ok?: boolean;
  sourceType: string;
  sourceVersion: string | null;
  missingTables: string[];
  warnings: string[];
  counts: Record<string, number>;
}

export interface MigrationSourceApi {
  id: number;
  type: string;
  name: string;
  connectionConfig: Record<string, unknown>;
  capabilities: MigrationSourceCapabilities | null;
  lastValidatedAt: string | null;
  createdAt: string;
  updatedAt: string;
}

export interface MigrationProfileApi {
  id: number;
  sourceId: number;
  name: string;
  userMappings: Array<{ sourceUserId: string; targetUserId: number | null }>;
  pathMappings: Array<{ sourcePrefix: string; targetPrefix: string }>;
  scope: Record<string, unknown>;
  createdAt: string;
  updatedAt: string;
}

export interface MigrationPlanSummary {
  generatedAt?: string;
  status?: string;
  matchedBooks?: number;
  unresolvedBooks?: number;
  duplicateBookMatches?: number;
  unresolvedByReason?: Record<string, number>;
  mappedUsers?: number;
  perUserPreview?: Array<{ sourceUserId: string; targetUserId: number; username: string; counts: Record<string, number> }>;
  artifactSizeBytes?: { plan: number; sourceData: number; total: number };
}

export interface MigrationPlanArtifactApi {
  id: number;
  sourceId: number;
  profileId: number;
  plan: Record<string, unknown>;
  summary: MigrationPlanSummary;
  createdAt: string;
  updatedAt: string;
}

export interface MigrationRunApi {
  id: number;
  sourceId: number;
  profileId: number;
  planArtifactId: number | null;
  state: MigrationRunState;
  currentStage: string | null;
  targetKey: string;
  errorMessage: string | null;
  startedAt: string | null;
  endedAt: string | null;
  createdAt: string;
  updatedAt: string;
}

export interface MigrationRunMetricApi {
  stage: string;
  entityType: string;
  processed: number;
  imported: number;
  skipped: number;
  unresolved: number;
  failed: number;
  updatedAt: string;
}

export interface MigrationProgressEvent {
  runId: number;
  state: MigrationRunState;
  currentStage: string | null;
  totals: {
    processed: number;
    imported: number;
    skipped: number;
    unresolved: number;
    failed: number;
  };
  metrics: MigrationRunMetricApi[];
}

export interface MigrationUserMapping {
  sourceUserId: string;
  targetUserId: number | null;
}

export interface MigrationPathMapping {
  sourcePrefix: string;
  targetPrefix: string;
}

export interface CreateMigrationSourcePayload {
  type: string;
  name: string;
  connectionConfig: Record<string, unknown>;
}

export interface CreateMigrationProfilePayload {
  sourceId: number;
  name: string;
  userMappings: MigrationUserMapping[];
  pathMappings: MigrationPathMapping[];
}

export interface CreateMigrationDryRunPayload {
  profileId: number;
}
export interface StartMigrationRunPayload {
  planArtifactId: number;
}
export interface ResolveMigrationDuplicatesPayload {
  resolutions: Array<{ targetBookId: number; selectedSourceBookId: string }>;
}

export interface MigrationWorkflowStateApi {
  active: {
    source: MigrationSourceApi;
    profile: MigrationProfileApi | null;
    plan: MigrationPlanArtifactApi | null;
    run: MigrationRunApi | null;
  } | null;
  hasActiveRun: boolean;
}

export interface MigrationTargetUser {
  id: number;
  username: string;
  name: string;
  email: string | null;
}
export interface MigrationMappingSuggestions {
  sourceId: number;
  generatedAt: string;
  suggestions: Array<{
    sourceUserId: string;
    username: string;
    suggestedTargetUserId: number | null;
  }>;
}

export interface MigrationRunProgressApi {
  run: MigrationRunApi;
  totals: { processed: number; imported: number; skipped: number; unresolved: number; failed: number };
  metrics: MigrationRunMetricApi[];
}

export interface MigrationPageCursor {
  total: number;
  limit: number;
  nextOffset: number | null;
}

export interface MigrationReportMatchedBook {
  sourceBookId: string;
  sourceTitle: string | null;
  sourceAuthor: string | null;
  targetBookId: number;
  targetTitle: string | null;
  strategy: string;
}

export interface MigrationReportUnresolvedBook {
  sourceBookId: string;
  title: string | null;
  author: string | null;
  reason: string;
}

export interface MigrationReportDuplicateMatch {
  targetBookId: number;
  targetTitle: string | null;
  sourceBookIds: string[];
  sourceTitles: Array<string | null>;
  strategies: string[];
  reason: string;
  candidatePagination?: MigrationPageCursor;
}

export interface MigrationReportUserPreview {
  sourceUserId: string;
  targetUserId: number;
  username: string;
  counts: { statuses: number; fileProgress: number; readingSessions: number; bookmarks: number; annotations: number; shelves: number };
}

export interface MigrationRunReportApi extends MigrationRunProgressApi {
  plan: Record<string, unknown> | null;
  summary: MigrationPlanSummary | null;
  details: {
    matchedBooks: MigrationReportMatchedBook[];
    unresolvedBooks: MigrationReportUnresolvedBook[];
    duplicateBookMatches: MigrationReportDuplicateMatch[];
    userPreview: MigrationReportUserPreview[];
  };
  detailsPagination: {
    matchedBooks: MigrationPageCursor;
    unresolvedBooks: MigrationPageCursor;
    duplicateBookMatches: MigrationPageCursor;
    userPreview: MigrationPageCursor;
  };
}

export interface MigrationReportPageApi {
  runId: number;
  kind: string;
  offset: number;
  limit: number;
  total: number;
  nextOffset: number | null;
  items: Array<Record<string, unknown>>;
}

export interface MigrationDuplicateCandidatePageApi {
  artifactId: number;
  targetBookId: number;
  offset: number;
  limit: number;
  total: number;
  nextOffset: number | null;
  items: Array<{ sourceBookId: string; title: string | null; author: string | null; filePath: string | null; strategy: string }>;
}

export interface MigrationPlanPageApi {
  artifactId: number;
  kind: string;
  offset: number;
  limit: number;
  total: number;
  nextOffset: number | null;
  items: Array<Record<string, unknown>>;
}
