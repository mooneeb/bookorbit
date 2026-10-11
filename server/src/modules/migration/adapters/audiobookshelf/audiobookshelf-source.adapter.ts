import { Injectable } from '@nestjs/common';

import type { SourceAdapter, SourceExportData, SourceSnapshot, SourceValidationResult } from '../source-adapter.types';
import { AudiobookshelfApiConnector } from './audiobookshelf-api.connector';
import { AudiobookshelfBackupConnector } from './audiobookshelf-backup.connector';
import type { AudiobookshelfConnectionConfig } from './audiobookshelf-connection-config';
import { AudiobookshelfNormalizer } from './audiobookshelf-normalizer';
import type { AudiobookshelfNormalizationResult } from './audiobookshelf-source.types';

@Injectable()
export class AudiobookshelfSourceAdapter implements SourceAdapter<AudiobookshelfConnectionConfig> {
  readonly type = 'audiobookshelf';

  constructor(
    private readonly apiConnector: AudiobookshelfApiConnector,
    private readonly backupConnector: AudiobookshelfBackupConnector,
    private readonly normalizer: AudiobookshelfNormalizer,
  ) {}

  async validate(config: AudiobookshelfConnectionConfig): Promise<SourceValidationResult> {
    if (config.mode === 'backup') {
      const normalized = await this.fetchBackupSummary(config);
      return {
        ok: true,
        sourceType: this.type,
        sourceVersion: normalized.sourceVersion,
        missingTables: [],
        warnings: normalized.warnings,
        counts: normalized.counts,
      };
    }

    // A live library can hold tens of thousands of expanded items and every user's
    // full session history. Validation only needs reachability, credentials and counts.
    const summary = await this.apiConnector.fetchSnapshotSummary(config);
    return {
      ok: true,
      sourceType: this.type,
      sourceVersion: summary.sourceVersion,
      missingTables: [],
      warnings: [],
      counts: summary.counts,
    };
  }

  async snapshot(config: AudiobookshelfConnectionConfig): Promise<SourceSnapshot> {
    if (config.mode === 'backup') {
      const normalized = await this.fetchBackupSummary(config);
      return {
        generatedAt: new Date().toISOString(),
        sourceType: this.type,
        sourceVersion: normalized.sourceVersion,
        counts: normalized.counts,
      };
    }
    const summary = await this.apiConnector.fetchSnapshotSummary(config);
    return {
      generatedAt: new Date().toISOString(),
      sourceType: this.type,
      sourceVersion: summary.sourceVersion,
      counts: summary.counts,
    };
  }

  async exportData(config: AudiobookshelfConnectionConfig): Promise<SourceExportData> {
    return (await this.fetchNormalized(config)).data;
  }

  async *exportDataBatches(config: AudiobookshelfConnectionConfig): AsyncGenerator<SourceExportData> {
    const batches =
      config.mode === 'backup' ? this.backupConnector.fetchSourceRecordBatches(config) : this.apiConnector.fetchSourceRecordBatches(config);
    for await (const records of batches) {
      const data = this.normalizer.normalize(records).data;
      data.bookOverlays = records.bookOverlays ?? true;
      yield data;
    }
  }

  async fetchPathPrefixes(config: AudiobookshelfConnectionConfig): Promise<string[]> {
    if (config.mode === 'backup') {
      const prefixes = new Set<string>();
      for await (const records of this.backupConnector.fetchSourceRecordBatches(config)) {
        if (records.bookOverlays === true) break;
        for (const prefix of this.normalizer.normalize(records).pathPrefixes) prefixes.add(prefix);
      }
      return [...prefixes].sort((left, right) => left.localeCompare(right));
    }
    const folders = await this.apiConnector.fetchLibraryFolders(config);
    const prefixes = new Set<string>();
    for (const folder of folders) {
      const value = folder.path.trim();
      const normalized = value !== '/' && !/^[A-Za-z]:[\\/]$/.test(value) ? value.replace(/[\\/]+$/, '') : value;
      if (normalized) prefixes.add(normalized);
    }
    return [...prefixes].sort((left, right) => left.localeCompare(right));
  }

  private async fetchBackupSummary(config: Extract<AudiobookshelfConnectionConfig, { mode: 'backup' }>) {
    const counts: Record<string, number> = {
      users: 0,
      books: 0,
      files: 0,
      userBookStatuses: 0,
      userFileProgress: 0,
      readingSessions: 0,
      bookmarks: 0,
    };
    const warnings = new Set<string>();
    let sourceVersion: string | null = null;
    for await (const records of this.backupConnector.fetchSourceRecordBatches(config)) {
      const normalized = this.normalizer.normalize(records);
      sourceVersion = normalized.sourceVersion;
      const data = normalized.data;
      if (!records.libraryItems.length) counts.users += data.users.length;
      if (records.bookOverlays !== false) {
        counts.books += data.books.length;
        counts.files += data.books.reduce((total, book) => total + (book.files?.length ?? 0), 0);
      }
      counts.userBookStatuses += data.userBookStatuses.length;
      counts.userFileProgress += data.userFileProgress.length;
      counts.readingSessions += data.readingSessions.length;
      counts.bookmarks += data.bookmarks.length;
      for (const warning of normalized.warnings) if (warnings.size < 100) warnings.add(warning);
    }
    return { sourceVersion, warnings: [...warnings], counts };
  }

  private async fetchNormalized(config: AudiobookshelfConnectionConfig): Promise<AudiobookshelfNormalizationResult> {
    const records =
      config.mode === 'api' ? await this.apiConnector.fetchSourceRecords(config) : await this.backupConnector.fetchSourceRecords(config);
    return this.normalizer.normalize(records);
  }
}
