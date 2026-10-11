import { Inject, Injectable, Logger } from '@nestjs/common';
import type { ConfigType } from '@nestjs/config';

import { sanitizeLogValue } from '../../common/utils/log-sanitize.utils';
import { appConfig } from '../../config/config';
import {
  bookOrbitReadwiseHighlightUrl,
  openLibraryCoverUrl,
  READWISE_BATCH_SIZE,
  READWISE_CATEGORY,
  READWISE_MAX,
  READWISE_SOURCE_TYPE,
} from './readwise.constants';
import { ReadwiseClientService, ReadwiseUnauthorizedError, type ReadwiseHighlight } from './readwise-client.service';
import { ReadwiseRepository, type NewHighlightRow } from './readwise.repository';

const SYNC_EVENT = 'readwise.sync';

function truncate(value: string, max: number): string {
  return value.length > max ? value.slice(0, max) : value;
}

@Injectable()
export class ReadwiseSyncService {
  private readonly logger = new Logger(ReadwiseSyncService.name);

  constructor(
    private readonly repo: ReadwiseRepository,
    private readonly client: ReadwiseClientService,
    @Inject(appConfig.KEY) private readonly appConfiguration: ConfigType<typeof appConfig>,
  ) {}

  async flush(userId: number): Promise<boolean> {
    const startedAtMs = Date.now();
    const configured = await this.repo.findSettings(userId);
    if (!configured?.apiToken || !configured.enabled || !(await this.repo.userHasReadwiseSyncPermission(userId))) return false;
    const settings = await this.repo.claimSync(userId);
    if (!settings?.apiToken) return false;
    let watermark = settings.lastSyncedAnnotationId;
    let syncedHighlights = 0;
    let batches = 0;
    let receivedBookIds: number[] = settings.syncReceivedBookIds?.slice(-100) ?? [];
    this.logger.log(
      `[${SYNC_EVENT}] [start] userId=${userId} afterAnnotationId=${watermark} batchSize=${READWISE_BATCH_SIZE} - Readwise sync started`,
    );
    try {
      while (batches < 5) {
        const current = await this.repo.findSettings(userId);
        if (!current?.enabled || current.apiToken !== settings.apiToken || !(await this.repo.userHasReadwiseSyncPermission(userId))) break;
        const rows = await this.repo.findNewHighlights(userId, watermark, READWISE_BATCH_SIZE);
        if (rows.length === 0) break;
        const ids = await this.client.createHighlights(
          userId,
          settings.apiToken,
          rows.map((r) => this.toHighlight(userId, r)),
        );
        watermark = rows[rows.length - 1]!.annotationId;
        syncedHighlights += rows.length;
        batches += 1;
        receivedBookIds = [...new Set([...receivedBookIds, ...ids])].slice(-100);
        await this.repo.upsertSettings(userId, {
          lastSyncedAnnotationId: watermark,
          lastSyncedAt: new Date(),
          syncExportedHighlights: syncedHighlights,
          syncReceivedBookIds: receivedBookIds,
          syncLeaseUntil: new Date(Date.now() + 5 * 60_000),
        });
        if (rows.length < READWISE_BATCH_SIZE) break;
      }
      const remaining = batches === 5 && (await this.repo.countPendingHighlights(userId, watermark)) > 0;
      await this.repo.upsertSettings(userId, {
        syncState: remaining ? 'queued' : 'succeeded',
        syncFinishedAt: new Date(),
        syncLeaseUntil: null,
        syncError: null,
      });
      this.logger.log(
        `[${SYNC_EVENT}] [end] userId=${userId} durationMs=${Date.now() - startedAtMs} batches=${batches} syncedHighlights=${syncedHighlights} watermark=${watermark} remaining=${remaining} - Readwise sync completed`,
      );
      return remaining;
    } catch (err) {
      const unauthorized = err instanceof ReadwiseUnauthorizedError;
      await this.repo.upsertSettings(userId, {
        syncState: 'failed',
        syncFinishedAt: new Date(),
        syncLeaseUntil: null,
        syncError: unauthorized
          ? 'Readwise rejected the token. Reconnect with a valid token.'
          : 'Readwise delivery could not be confirmed. Retry to resume safely.',
        ...(unauthorized ? { disabledReason: 'invalid_token', enabled: false } : {}),
      });
      this.logger.warn(
        `[${SYNC_EVENT}] [fail] userId=${userId} durationMs=${Date.now() - startedAtMs} errorClass=${err instanceof Error ? err.constructor.name : 'UnknownError'} error="${sanitizeLogValue(err instanceof Error ? err.message : String(err))}" - Readwise sync failed`,
      );
      if (unauthorized) return false;
      throw err;
    }
  }

  private toHighlight(userId: number, r: NewHighlightRow): ReadwiseHighlight {
    const isbn = r.isbn13 || r.isbn10;
    return {
      text: truncate(r.text, READWISE_MAX.TEXT),
      ...(r.title ? { title: truncate(r.title, READWISE_MAX.TITLE) } : {}),
      ...(r.author ? { author: truncate(r.author, READWISE_MAX.AUTHOR) } : {}),
      ...(r.note ? { note: truncate(r.note, READWISE_MAX.NOTE) } : {}),
      ...(isbn ? { image_url: openLibraryCoverUrl(isbn) } : {}),
      highlighted_at: r.createdAt.toISOString(),
      highlight_url: truncate(bookOrbitReadwiseHighlightUrl(this.appConfiguration.appUrl, r.bookId, r.annotationId), READWISE_MAX.HIGHLIGHT_URL),
      source_type: READWISE_SOURCE_TYPE,
      category: READWISE_CATEGORY,
    };
  }
}
