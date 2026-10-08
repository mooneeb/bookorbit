import { BadRequestException, Injectable, Logger, ServiceUnavailableException } from '@nestjs/common';
import { createHash } from 'node:crypto';
import type { EpubBookInfo, EpubTocItem } from '@bookorbit/types';
import type { RequestUser } from '../../common/types/request-user';
import { sanitizeLogValue } from '../../common/utils/log-sanitize.utils';
import { PositionConverterService } from '../position-converter/position-converter.service';
import { EpubService } from '../reader/epub/epub.service';
import { bookmarkCfiKey, compareBookmarkCfiKeys } from './epub-bookmark-location';

export interface EpubBookmarkContext {
  spineStep: number;
  startKey: string[];
  endKey: string[] | null;
  chapterTitle: string | null;
  percentage: number | null;
}

interface CachedContexts {
  info: EpubBookInfo;
  pending: boolean;
  result: Promise<string>;
}

interface TocEntry {
  label: string | null;
  fragment: string | null;
  previousLabel: string | null;
}

@Injectable()
export class EpubBookmarkContextService {
  private readonly logger = new Logger(EpubBookmarkContextService.name);
  private readonly cache = new Map<number, CachedContexts>();
  private metadataInFlight = 0;

  constructor(
    private readonly epubService: EpubService,
    private readonly positions: PositionConverterService,
  ) {}

  async get(bookId: number, fileId: number, user: RequestUser): Promise<string> {
    if (this.metadataInFlight >= 2) throw new ServiceUnavailableException('Bookmark chapter context is busy. Retry.');
    this.metadataInFlight += 1;
    let info: EpubBookInfo;
    try {
      info = await this.epubService.getBookInfo(bookId, fileId, user);
    } finally {
      this.metadataInFlight -= 1;
    }
    const existing = this.cache.get(fileId);
    if (existing?.info === info) return existing.result;
    if (existing?.pending) throw new ServiceUnavailableException('Bookmark chapter context changed. Retry.');
    this.cache.delete(fileId);
    if (this.cache.size >= 4) {
      const available = [...this.cache].find(([, entry]) => !entry.pending);
      if (!available) throw new ServiceUnavailableException('Bookmark chapter context is busy. Retry.');
      this.cache.delete(available[0]);
    }
    if ([...this.cache.values()].filter((entry) => entry.pending).length >= 2) {
      throw new ServiceUnavailableException('Bookmark chapter context is busy. Retry.');
    }
    const entry: CachedContexts = { info, pending: true, result: this.build(bookId, fileId, info) };
    this.cache.set(fileId, entry);
    try {
      return await entry.result;
    } catch (error) {
      if (this.cache.get(fileId) === entry) this.cache.delete(fileId);
      throw error;
    } finally {
      entry.pending = false;
    }
  }

  revision(contexts: string, fileRevision: string): string {
    return createHash('sha256').update(fileRevision).update(contexts).digest('hex');
  }

  private async build(bookId: number, fileId: number, info: EpubBookInfo): Promise<string> {
    const startedAt = Date.now();
    this.logger.log(`[bookmark.chapter_context] [start] bookId=${bookId} fileId=${fileId} - bookmark chapter context started`);
    try {
      const contexts = await this.resolve(info, fileId);
      const serialized = JSON.stringify(contexts);
      if (Buffer.byteLength(serialized) > 4 * 1024 * 1024) throw new BadRequestException('The bookmark chapter context exceeds the supported size');
      this.logger.log(
        `[bookmark.chapter_context] [end] bookId=${bookId} fileId=${fileId} durationMs=${Date.now() - startedAt} ranges=${contexts.length} - bookmark chapter context completed`,
      );
      return serialized;
    } catch (error) {
      this.logger.warn(
        `[bookmark.chapter_context] [fail] bookId=${bookId} fileId=${fileId} durationMs=${Date.now() - startedAt} errorClass=${error instanceof Error ? error.name : 'Unknown'} error="${sanitizeLogValue(error instanceof Error ? error.message : 'unknown error')}" - bookmark chapter context failed`,
      );
      throw error;
    }
  }

  private async resolve(info: EpubBookInfo, fileId: number): Promise<EpubBookmarkContext[]> {
    if (info.spine.length > 4096 || info.manifest.length > 32768) {
      throw new BadRequestException('The publication exceeds the bookmark chapter context limit');
    }
    if ((info.toc?.children?.length ?? 0) > 4096) throw new BadRequestException('The contents exceed the bookmark chapter context limit');
    const sections = new Set(info.spine.map((section) => section.href));
    const grouped = new Map<string, TocEntry[]>();
    const pending: EpubTocItem[] = info.toc ? (info.toc.href ? [info.toc] : [...(info.toc.children ?? [])].reverse()) : [];
    let scanned = 0;
    let previousLabel: string | null = null;
    while (pending.length) {
      if (++scanned > 4096) throw new BadRequestException('The contents exceed the bookmark chapter context limit');
      const item = pending.pop()!;
      if (item.label.length > 2000) throw new BadRequestException('A contents label exceeds the bookmark chapter context limit');
      const label = item.label.trim() || null;
      const [href, rawFragment] = item.href?.split('#') ?? [];
      if (href != null && sections.has(href)) {
        let fragment = rawFragment ?? null;
        try {
          if (fragment) fragment = decodeURIComponent(fragment);
        } catch {
          /* Keep an unencoded fragment as the reader does. */
        }
        const entries = grouped.get(href) ?? [];
        entries.push({ label, fragment, previousLabel });
        grouped.set(href, entries);
      }
      previousLabel = label;
      if (pending.length + (item.children?.length ?? 0) > 4096)
        throw new BadRequestException('The contents exceed the bookmark chapter context limit');
      for (let index = (item.children?.length ?? 0) - 1; index >= 0; index -= 1) pending.push(item.children![index]);
    }
    const sizesByHref = new Map(info.manifest.map((item) => [item.href, item.size]));
    const sizes = info.spine.map((section) => (section.linear ? Math.max(0, sizesByHref.get(section.href) ?? 0) : 0));
    const total = sizes.reduce((sum, size) => sum + size, 0);
    const percentages: Array<number | null> = [];
    let before = 0;
    for (const size of sizes) {
      percentages.push(total > 0 ? Math.min(100, Math.round((before / total + Number.EPSILON) * 100)) : null);
      before += size;
    }
    const results: EpubBookmarkContext[][] = Array.from({ length: info.spine.length }, () => []);
    const budget = { bytes: 0 };
    let nextIndex = 0;
    let stopped = false;
    const worker = async () => {
      try {
        while (!stopped && nextIndex < info.spine.length) {
          const sectionIndex = nextIndex++;
          results[sectionIndex] = await this.resolveSection(
            fileId,
            sectionIndex,
            grouped.get(info.spine[sectionIndex].href) ?? [],
            percentages[sectionIndex],
            budget,
          );
        }
      } catch (error) {
        stopped = true;
        throw error;
      }
    };
    const workers = await Promise.allSettled([worker(), worker()]);
    const failure = workers.find((worker) => worker.status === 'rejected');
    if (failure?.status === 'rejected') throw failure.reason;
    const contexts = results.flat();
    let carriedLabel: string | null = null;
    for (let sectionIndex = 0; sectionIndex < results.length; sectionIndex += 1) {
      const section = results[sectionIndex];
      if (!grouped.has(info.spine[sectionIndex].href)) section[0].chapterTitle = carriedLabel;
      carriedLabel = section.at(-1)!.chapterTitle;
    }
    contexts.forEach((context, index) => {
      context.endKey = contexts[index + 1]?.startKey ?? null;
    });
    return contexts;
  }

  private reserveContext(context: EpubBookmarkContext, budget: { bytes: number }): void {
    if (context.startKey.length > 512) throw new BadRequestException('A contents anchor exceeds the bookmark context limit');
    budget.bytes += Buffer.byteLength(JSON.stringify(context.startKey)) * 2 + Buffer.byteLength(JSON.stringify(context.chapterTitle)) + 256;
    if (budget.bytes > 4 * 1024 * 1024) throw new BadRequestException('The bookmark chapter context exceeds the supported size');
  }

  private async resolveSection(
    fileId: number,
    sectionIndex: number,
    entries: TocEntry[],
    percentage: number | null,
    budget: { bytes: number },
  ): Promise<EpubBookmarkContext[]> {
    const sectionStart = bookmarkCfiKey(`epubcfi(/6/${(sectionIndex + 1) * 2}!/0)`)!;
    const initial: EpubBookmarkContext = {
      spineStep: (sectionIndex + 1) * 2,
      startKey: sectionStart,
      endKey: null,
      chapterTitle: entries[0]?.previousLabel ?? null,
      percentage,
    };
    if (!entries.length) {
      this.reserveContext(initial, budget);
      return [initial];
    }
    if (entries.length === 1 && !entries[0].fragment) {
      const context = { ...initial, chapterTitle: entries[0].label };
      this.reserveContext(context, budget);
      return [context];
    }
    const anchors: Array<string[] | null> = [];
    for (let offset = 0; offset < entries.length; offset += 512) {
      const chunk = entries.slice(offset, offset + 512);
      const cfis = await this.positions.tocFragmentCfis(
        fileId,
        sectionIndex,
        chunk.map((entry) => entry.fragment ?? ''),
      );
      anchors.push(
        ...cfis.map((cfi) => {
          const key = cfi ? bookmarkCfiKey(cfi) : null;
          if (cfi && !key) throw new BadRequestException('A contents anchor exceeds the bookmark context limit');
          if (key && key.length > 512) throw new BadRequestException('A contents anchor exceeds the bookmark context limit');
          return key;
        }),
      );
    }
    const boundaries = anchors.filter((key): key is string[] => key != null).sort(compareBookmarkCfiKeys);
    const keys = [sectionStart, ...boundaries.filter((key) => compareBookmarkCfiKeys(key, sectionStart) > 0)];
    const contexts: EpubBookmarkContext[] = [];
    for (const key of keys) {
      if (contexts.length && compareBookmarkCfiKeys(contexts.at(-1)!.startKey, key) === 0) continue;
      const following = anchors.findIndex((anchor) => anchor && compareBookmarkCfiKeys(anchor, key) > 0);
      const label = following < 0 ? entries.at(-1)!.label : following === 0 ? entries[0].previousLabel : entries[following - 1].label;
      const context = { ...initial, startKey: key, chapterTitle: label };
      this.reserveContext(context, budget);
      contexts.push(context);
    }
    return contexts;
  }
}
