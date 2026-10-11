export type ReadwiseSyncDisabledReason = "permission_denied" | "missing_token" | "user_disabled" | "invalid_token";

export interface ReadwiseSettings {
  tokenConfigured: boolean;
  enabled: boolean;
  effectiveEnabled: boolean;
  disabledReason: ReadwiseSyncDisabledReason | null;
  lastSyncedAt: string | null;
}

export interface UpsertReadwiseSettingsPayload {
  apiToken?: string;
  enabled?: boolean;
  includeExistingHighlights?: boolean;
}

export interface ReadwiseTokenValidationResult {
  valid: boolean;
  message?: string;
}

export type ReadwiseSyncState = "idle" | "queued" | "running" | "succeeded" | "failed" | "interrupted";

export interface ReadwiseSyncStatus {
  state: ReadwiseSyncState;
  exportedHighlights: number;
  pendingHighlights: number;
  startedAt: string | null;
  finishedAt: string | null;
  error: string | null;
  receivedBookIds: number[];
}
