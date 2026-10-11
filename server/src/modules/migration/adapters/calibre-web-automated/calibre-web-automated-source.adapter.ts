import { Injectable } from '@nestjs/common';

import type { SourceAdapter, SourceExportData, SourceSnapshot, SourceValidationResult } from '../source-adapter.types';
import type { CalibreWebAutomatedConnectionConfig } from './calibre-web-automated-connection-config';
import { CalibreWebAutomatedNormalizer } from './calibre-web-automated-normalizer';
import type { CalibreWebAutomatedNormalizationResult } from './calibre-web-automated-source.types';
import { CalibreWebAutomatedSnapshotConnector } from './calibre-web-automated-snapshot.connector';

@Injectable()
export class CalibreWebAutomatedSourceAdapter implements SourceAdapter<CalibreWebAutomatedConnectionConfig> {
  readonly type = 'calibre_web_automated';

  constructor(
    private readonly connector: CalibreWebAutomatedSnapshotConnector,
    private readonly normalizer: CalibreWebAutomatedNormalizer,
  ) {}

  async validate(config: CalibreWebAutomatedConnectionConfig): Promise<SourceValidationResult> {
    const normalized = await this.fetchSummary(config);
    return {
      ok: true,
      sourceType: this.type,
      sourceVersion: normalized.sourceVersion,
      missingTables: [],
      warnings: normalized.warnings,
      counts: normalized.counts,
    };
  }

  async snapshot(config: CalibreWebAutomatedConnectionConfig): Promise<SourceSnapshot> {
    const normalized = await this.fetchSummary(config);
    return {
      generatedAt: new Date().toISOString(),
      sourceType: this.type,
      sourceVersion: normalized.sourceVersion,
      counts: normalized.counts,
    };
  }

  async exportData(config: CalibreWebAutomatedConnectionConfig): Promise<SourceExportData> {
    return (await this.fetchNormalized(config)).data;
  }

  async *exportDataBatches(config: CalibreWebAutomatedConnectionConfig): AsyncGenerator<SourceExportData> {
    for await (const records of this.connector.fetchSourceRecordBatches(config)) {
      const data = this.normalizer.normalize(records).data;
      const domains = ['userBookStatuses', 'userFileProgress', 'readingSessions', 'bookmarks', 'annotations', 'shelves', 'shelfBooks'] as const;
      const pages = Math.max(1, ...domains.map((domain) => Math.ceil(data[domain].length / 500)));
      for (let page = 0; page < pages; page += 1) {
        const rows = Object.fromEntries(domains.map((domain) => [domain, data[domain].slice(page * 500, (page + 1) * 500)]));
        const shelfBooks = rows.shelfBooks as SourceExportData['shelfBooks'];
        const shelves = rows.shelves as SourceExportData['shelves'];
        const shelfIds = new Set(shelfBooks.map((row) => row.sourceShelfId));
        const references = data.shelves.filter(
          (shelf) => shelfIds.has(shelf.sourceShelfId) && !shelves.some((row) => row.sourceShelfId === shelf.sourceShelfId),
        );
        yield { ...data, ...rows, shelves: [...shelves, ...references], bookOverlays: records.bookOverlays !== false && page === 0 };
      }
    }
  }

  async fetchPathPrefixes(config: CalibreWebAutomatedConnectionConfig): Promise<string[]> {
    for await (const records of this.connector.fetchSourceRecordBatches(config)) {
      return this.normalizer.normalize(records).pathPrefixes;
    }
    return [];
  }

  private async fetchSummary(config: CalibreWebAutomatedConnectionConfig) {
    const counts: Record<string, number> = { users: 0, books: 0, files: 0, userBookStatuses: 0, userFileProgress: 0, shelves: 0, shelfBooks: 0 };
    const warnings = new Set<string>();
    for await (const records of this.connector.fetchSourceRecordBatches(config)) {
      const normalized = this.normalizer.normalize(records);
      const data = normalized.data;
      if (records.bookOverlays == null || (!data.books.length && !data.shelves.length)) counts.users += data.users.length;
      if (records.bookOverlays !== false) {
        counts.books += data.books.length;
        counts.files += data.books.reduce((total, book) => total + (book.files?.length ?? 0), 0);
      }
      if (records.bookOverlays == null || !data.books.length) counts.shelves += data.shelves.length;
      counts.userBookStatuses += data.userBookStatuses.length;
      counts.userFileProgress += data.userFileProgress.length;
      counts.shelfBooks += data.shelfBooks.length;
      for (const warning of normalized.warnings) if (warnings.size < 100) warnings.add(warning);
    }
    return { sourceVersion: null, warnings: [...warnings], counts };
  }

  private async fetchNormalized(config: CalibreWebAutomatedConnectionConfig): Promise<CalibreWebAutomatedNormalizationResult> {
    return this.normalizer.normalize(await this.connector.fetchSourceRecords(config));
  }
}
