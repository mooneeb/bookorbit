export interface AppSettingResponse {
  id: number;
  key: string;
  value: string;
  updatedAt: string;
}

export interface UpdateAppSettingRequest {
  value: string;
}

export interface BookEmbeddingRebuildResult {
  queued: number;
}

export interface AchievementBackfillResult {
  usersProcessed: number;
  awardsGranted: number;
}

export interface MaintenanceOperationStatus {
  runId: string | null;
  status: "idle" | "running" | "completed" | "failed" | "disabled";
  processed: number;
  failed: number;
  awardsGranted: number;
  startedAt: string | null;
  completedAt: string | null;
}
