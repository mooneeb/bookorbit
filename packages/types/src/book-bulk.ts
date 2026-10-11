import type { CustomMetadataBookValueInput } from "./custom-metadata";

export interface BulkArrayEdit {
  mode: "add" | "remove" | "replace";
  values: string[];
}
export interface BulkStringEdit {
  value: string | null;
}
export interface BulkNumberEdit {
  value: number | null;
}
export interface BulkMetadataEditFields {
  authors?: BulkArrayEdit;
  genres?: BulkArrayEdit;
  tags?: BulkArrayEdit;
  narrators?: BulkArrayEdit;
  seriesName?: BulkStringEdit;
  publisher?: BulkStringEdit;
  language?: BulkStringEdit;
  publishedYear?: BulkNumberEdit;
  customMetadata?: CustomMetadataBookValueInput[];
}
export interface BulkMetadataVersion {
  bookId: number;
  updatedAt: string;
}
export interface SelectedBulkMetadataRequest {
  bookIds: number[];
  fields: BulkMetadataEditFields;
  expectedVersions?: BulkMetadataVersion[];
}
export interface BulkEditFieldResult {
  updated: number;
  skippedLocked: number;
}
export interface BulkEditMetadataResult {
  updatedBooks: number;
  fields: Record<string, BulkEditFieldResult>;
}
export interface BulkMetadataPreviewBook {
  bookId: number;
  title: string | null;
  updatedAt: string;
  libraryId: number;
  lockedFields: string[];
  currentValues: BulkMetadataPreviewValue[];
}
export interface BulkMetadataPreviewValue {
  field: string;
  value: string | null;
}
export interface BulkMetadataPreview {
  books: BulkMetadataPreviewBook[];
  fields: Record<string, BulkEditFieldResult>;
}
export interface SelectedBookExportRequest {
  bookIds: number[];
  allFormats?: boolean;
  audioOnly?: boolean;
}
export interface SelectedMetadataExportOptions {
  includePersonalData?: boolean;
  includeFilePaths?: boolean;
  includeContextMeta?: boolean;
  columnsMode?: "canonical" | "visible";
  visibleColumns?: string[];
}
export interface SelectedMetadataExportRequest {
  bookIds: number[];
  format: "csv" | "json";
  options?: SelectedMetadataExportOptions;
}
export interface MetadataExportPreflight {
  schemaVersion: number;
  rowCount: number;
  estimatedBytes: number;
  sizeCategory: "small" | "medium" | "large";
  fileName: string;
  scope: "selected" | "all-matching";
  format: "csv" | "json";
}
export interface BookExportPreview {
  bookCount: number;
  fileCount: number;
  projectedBytes: number;
  archiveFilename: string;
}
