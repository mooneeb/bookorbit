import { BadRequestException, Injectable, Logger } from '@nestjs/common';

import { sanitizeLogValue } from '../../../common/utils/log-sanitize.utils';
import { mapWithConcurrency } from '../../../common/utils/batch.utils';
import { KoboSpanConverterService } from '../../position-converter/kobo-span-converter.service';
import { KoboKepubContextService, type KepubContextResult } from './kobo-kepub-context.service';
import type { KoboSettings } from './kobo-settings.service';

const EVENT = 'kobo.progress_bridge';

export interface CanonicalProgressPoint {
  cfi: string;
  xpointer: string;
}

export interface KoboBookmarkPoint {
  source: string;
  value: string;
  contentSourceProgressPercent: number | null;
}

/**
 * Converts reading positions between Kobo KoboSpan bookmarks and canonical
 * cfi/xpointer points through the kepub span codec. Returns null instead of
 * failing so progress sync always degrades to percent.
 */
@Injectable()
export class KoboProgressBridgeService {
  private readonly logger = new Logger(KoboProgressBridgeService.name);

  constructor(
    private readonly kepubContextService: KoboKepubContextService,
    private readonly koboSpanConverter: KoboSpanConverterService,
  ) {}

  async koboBookmarkToCanonical(userId: number, bookId: number, source: string, spanValue: string): Promise<CanonicalProgressPoint | null> {
    try {
      const kepub = await this.kepubContextService.resolveForBook(userId, bookId);
      if (!kepub.ok) return this.logDegraded('bookmark_to_canonical', userId, bookId, kepub.reason);

      const outcome = await this.koboSpanConverter.koboBookmarkToPositions({
        bookFileId: kepub.file.id,
        ctx: kepub.ctx,
        chapterFilename: source,
        spanId: spanValue,
      });
      if (outcome.status === 'failed' || !outcome.cfi || !outcome.xpointer) {
        return this.logDegraded('bookmark_to_canonical', userId, bookId, outcome.reason ?? 'incomplete_outcome');
      }
      return { cfi: outcome.cfi, xpointer: outcome.xpointer };
    } catch (error) {
      this.logWarn('bookmark_to_canonical', userId, bookId, error);
      return null;
    }
  }

  async cfiToKoboBookmark(userId: number, bookId: number, cfi: string): Promise<KoboBookmarkPoint | null> {
    try {
      const kepub = await this.kepubContextService.resolveForBook(userId, bookId);
      if (!kepub.ok) return this.logDegraded('cfi_to_bookmark', userId, bookId, kepub.reason);

      return await this.convertCfi(userId, bookId, cfi, kepub);
    } catch (error) {
      this.logWarn('cfi_to_bookmark', userId, bookId, error);
      return null;
    }
  }

  async cfiToKoboBookmarks(
    userId: number,
    positions: { bookId: number; cfi: string }[],
    settings: KoboSettings,
  ): Promise<Map<number, KoboBookmarkPoint>> {
    if (positions.length > 100) throw new BadRequestException('Kobo position batches require at most 100 books');
    if (positions.length === 0) return new Map();
    const files = await this.kepubContextService.resolveReaderFiles(positions.map((position) => position.bookId)).catch((error: unknown) => {
      this.logWarn('cfi_to_bookmark_batch', userId, positions[0].bookId, error);
      return null;
    });
    if (!files) return new Map();
    const converted = await mapWithConcurrency(positions, 2, async ({ bookId, cfi }) => {
      try {
        const file = files.get(bookId);
        if (!file) return [bookId, this.logDegraded('cfi_to_bookmark', userId, bookId, 'no_reader_file')] as const;
        const kepub = await this.kepubContextService.resolveForReaderFile(file, settings);
        if (!kepub.ok) return [bookId, this.logDegraded('cfi_to_bookmark', userId, bookId, kepub.reason)] as const;
        return [bookId, await this.convertCfi(userId, bookId, cfi, kepub)] as const;
      } catch (error) {
        this.logWarn('cfi_to_bookmark', userId, bookId, error);
        return [bookId, null] as const;
      }
    });
    const bookmarks = new Map<number, KoboBookmarkPoint>();
    for (const [bookId, point] of converted) if (point) bookmarks.set(bookId, point);
    return bookmarks;
  }

  private async convertCfi(
    userId: number,
    bookId: number,
    cfi: string,
    kepub: Extract<KepubContextResult, { ok: true }>,
  ): Promise<KoboBookmarkPoint | null> {
    const outcome = await this.koboSpanConverter.cfiPointToKoboBookmark({ bookFileId: kepub.file.id, ctx: kepub.ctx, cfi });
    if (outcome.status === 'failed' || !outcome.spanId || !outcome.chapterFilename) {
      return this.logDegraded('cfi_to_bookmark', userId, bookId, outcome.reason ?? 'incomplete_outcome');
    }
    return {
      source: outcome.chapterFilename,
      value: outcome.spanId,
      contentSourceProgressPercent: outcome.contentSourceProgressPercent ?? null,
    };
  }

  /**
   * A conversion that gives up is not an error, but it does mean the device receives a
   * percent without a position, so it has to be visible: the resulting bookmark looks
   * healthy on the device while resuming at the wrong place.
   */
  private logDegraded(operation: string, userId: number, bookId: number, reason: string): null {
    this.logger.warn(
      `[${EVENT}] [fail] op=${operation} userId=${userId} bookId=${bookId} reason=${sanitizeLogValue(reason)} - kobo position unavailable, progress degrades to percent`,
    );
    return null;
  }

  private logWarn(operation: string, userId: number, bookId: number, error: unknown): void {
    const errorClass = error instanceof Error ? error.constructor.name : 'UnknownError';
    this.logger.warn(
      `[${EVENT}] [fail] op=${operation} userId=${userId} bookId=${bookId} errorClass=${errorClass} error="${sanitizeLogValue(
        error instanceof Error ? error.message : 'unknown error',
      )}" - kobo progress conversion failed`,
    );
  }
}
