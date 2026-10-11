export type ScanJobStatus = "running" | "completed" | "failed";
export type ScanTriggeredBy = "manual" | "watcher" | "schedule";

/** The last recorded scan_jobs row for a library, or null when it has never been scanned. */
export interface LibraryLastScan {
  status: ScanJobStatus;
  triggeredBy: ScanTriggeredBy;
  startedAt: string;
  completedAt: string | null;
  addedCount: number;
  updatedCount: number;
  missingCount: number;
  errorMessage: string | null;
}

/** One row of a library's scan_jobs history, newest first. */
export interface LibraryScanHistoryEntry extends LibraryLastScan {
  id: number;
}

export interface ScanProgressEvent {
  jobId: number;
  libraryId: number;
  status: ScanJobStatus;
  processed: number;
  total: number;
  added: number;
  updated: number;
  missing: number;
  errorMessage?: string;
}

export interface CoverRefreshProgressEvent {
  libraryId: number;
  processed: number;
  total: number;
  status: "running" | "completed";
}

export interface CoverRefreshedEvent {
  bookIds: number[];
  libraryId?: number;
}

export interface BookMissingEvent {
  libraryId: number;
  bookIds: number[];
}

export interface BookRestoredEvent {
  libraryId: number;
  bookIds: number[];
}

export interface BookMovedEvent {
  libraryId: number;
  bookIds: number[];
}

export interface BookTransferredEvent {
  fromLibraryId: number;
  toLibraryId: number;
  bookIds: number[];
}

export interface BookProgressChangedEvent {
  bookId: number;
  progress: number;
  source: "koreader" | "kobo" | "web_reader";
}

export interface ScanBooksAddedEvent {
  libraryId: number;
  books: import("./book").BookCard[];
}

/** Audited library projection used when configuring server-side scans. */
export interface LibraryScanConfiguration {
  id: number;
  name: string;
  type: import("./library").LibraryType;
  folders: import("./library").LibraryFolder[];
  watch: boolean;
  autoScanCronExpression: string | null;
  allowedFormats: string[];
  excludePatterns: string[];
  organizationMode: import("./library").OrganizationMode;
}

export interface ScanStartResult {
  jobId: number;
}

export interface ScanStatusResponse {
  progress: ScanProgressEvent | null;
}

/** Reusing the same baseline reconciles an accepted scan instead of repeating it. */
export interface ScanStartRequest {
  expectedLastJobId?: number;
}

export interface ScanConfigurationRequest {
  folders: string[];
  watch: boolean;
  autoScanCronExpression: string | null;
  allowedFormats: string[];
  excludePatterns: string[];
  organizationMode: import("./library").OrganizationMode;
}

export interface ScanPreviewRequest {
  libraryId: number;
  paths: string[];
}
