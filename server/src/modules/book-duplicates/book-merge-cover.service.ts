import { Injectable, Logger } from '@nestjs/common';

import { sanitizeLogValue } from '../../common/utils/log-sanitize.utils';
import { BookCoverStore, type BookCoverAdoptionIntent } from '../book-cover-store/book-cover-store.service';

export type BookMergeCoverIntent = BookCoverAdoptionIntent;

@Injectable()
export class BookMergeCoverService {
  private readonly logger = new Logger(BookMergeCoverService.name);

  constructor(private readonly covers: BookCoverStore) {}

  async capture(sourceBookId: number, targetBookId: number): Promise<BookMergeCoverIntent> {
    const startedAt = Date.now();
    this.logger.log(
      `[book.duplicate_merge_cover_snapshot] [start] sourceBookId=${sourceBookId} targetBookId=${targetBookId} - cover snapshot started`,
    );
    try {
      const intent = await this.covers.captureAdoption(sourceBookId, targetBookId);
      this.logger.log(
        `[book.duplicate_merge_cover_snapshot] [end] sourceBookId=${sourceBookId} targetBookId=${targetBookId} durationMs=${Date.now() - startedAt} artifactsPreserved=${intent.artifacts.length} - cover snapshot completed`,
      );
      return intent;
    } catch (error) {
      this.logger.warn(
        `[book.duplicate_merge_cover_snapshot] [fail] sourceBookId=${sourceBookId} targetBookId=${targetBookId} durationMs=${Date.now() - startedAt} errorClass=${error instanceof Error ? error.name : 'Unknown'} error="${sanitizeLogValue(error instanceof Error ? error.message : 'Cover snapshot failed')}" - cover snapshot failed`,
      );
      throw error;
    }
  }

  async finish(intent: BookMergeCoverIntent): Promise<void> {
    const startedAt = Date.now();
    this.logger.log(
      `[book.duplicate_merge_covers] [start] sourceBookId=${intent.sourceBookId} targetBookId=${intent.targetBookId} - cover preservation started`,
    );
    try {
      await this.covers.finishAdoption(intent);
      this.logger.log(
        `[book.duplicate_merge_covers] [end] sourceBookId=${intent.sourceBookId} targetBookId=${intent.targetBookId} durationMs=${Date.now() - startedAt} artifactsPreserved=${intent.artifacts.length} - cover preservation completed`,
      );
    } catch (error) {
      this.logger.warn(
        `[book.duplicate_merge_covers] [fail] sourceBookId=${intent.sourceBookId} targetBookId=${intent.targetBookId} durationMs=${Date.now() - startedAt} errorClass=${error instanceof Error ? error.name : 'Unknown'} error="${sanitizeLogValue(error instanceof Error ? error.message : 'Cover preservation failed')}" - cover preservation pending retry`,
      );
      throw error;
    }
  }
}
