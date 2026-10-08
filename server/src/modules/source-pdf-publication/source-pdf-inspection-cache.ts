import { ServiceUnavailableException } from '@nestjs/common';
import type { NativePdfPageSource } from '@bookorbit/types';
import type { BigIntStats } from 'fs';

export type SourcePdfPageFacts = Pick<NativePdfPageSource, 'page' | 'pageFingerprint' | 'width' | 'height'>;
export interface SourcePdfInspectionFacts {
  sourceRevision: string;
  protectedDocument: boolean;
  pageCount: number;
  pages: ReadonlyMap<number, SourcePdfPageFacts>;
}

interface CachedInspection extends SourcePdfInspectionFacts {
  identity: string;
  pages: Map<number, SourcePdfPageFacts>;
}

const MAX_FILES = 64;
const MAX_PAGES = 4096;
const MAX_PAGES_PER_FILE = 256;
const MAX_ACTIVE_LOADS = 2;
const MAX_WAITING_LOADS = 64;

export function sourcePdfFileIdentity(state: BigIntStats): string {
  return `${state.dev}:${state.ino}:${state.size}:${state.mtimeNs}:${state.ctimeNs}`;
}

export class SourcePdfInspectionCache {
  private readonly entries = new Map<string, CachedInspection>();
  private activeLoads = 0;
  private readonly waitingLoads: Array<() => void> = [];

  get(path: string, identity: string): SourcePdfInspectionFacts | undefined {
    const entry = this.entries.get(path);
    if (!entry) return undefined;
    if (entry.identity !== identity) {
      this.entries.delete(path);
      return undefined;
    }
    this.entries.delete(path);
    this.entries.set(path, entry);
    return entry;
  }

  put(path: string, identity: string, facts: SourcePdfInspectionFacts): void {
    const previous = this.entries.get(path);
    const pages = new Map(previous?.identity === identity ? previous.pages : []);
    for (const [page, fact] of facts.pages) {
      pages.delete(page);
      pages.set(page, fact);
    }
    while (pages.size > MAX_PAGES_PER_FILE) pages.delete(pages.keys().next().value!);
    this.entries.delete(path);
    this.entries.set(path, { ...facts, identity, pages });
    let pageCount = [...this.entries.values()].reduce((total, entry) => total + entry.pages.size, 0);
    while (this.entries.size > MAX_FILES || pageCount > MAX_PAGES) {
      const oldest = this.entries.keys().next().value!;
      pageCount -= this.entries.get(oldest)!.pages.size;
      this.entries.delete(oldest);
    }
  }

  async load<T>(loadFacts: () => Promise<T>): Promise<T> {
    if (this.activeLoads >= MAX_ACTIVE_LOADS) {
      if (this.waitingLoads.length >= MAX_WAITING_LOADS) throw new ServiceUnavailableException('PDF inspection queue is full; retry shortly');
      await new Promise<void>((resolve) => this.waitingLoads.push(resolve));
    } else this.activeLoads++;
    try {
      return await loadFacts();
    } finally {
      const next = this.waitingLoads.shift();
      if (next) next();
      else this.activeLoads--;
    }
  }
}
