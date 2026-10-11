import { Injectable, Logger, ServiceUnavailableException } from '@nestjs/common';

import { sanitizeLogValue } from '../../../common/utils/log-sanitize.utils';
import { KoboDownloadRepository } from '../kobo-download.repository';

@Injectable()
export class KoboSourcePublicationService {
  private readonly logger = new Logger(KoboSourcePublicationService.name);

  constructor(private readonly repository: KoboDownloadRepository) {}

  async invalidatePublishedSource(bookId: number, bookFileId: number): Promise<void> {
    const startedAt = Date.now();
    this.logger.log(`[kobo.source_publication] [start] bookId=${bookId} bookFileId=${bookFileId} - refreshing device delivery state`);
    try {
      const devices = await this.repository.invalidatePublishedSource(bookId, bookFileId);
      this.logger.log(
        `[kobo.source_publication] [end] bookId=${bookId} bookFileId=${bookFileId} durationMs=${Date.now() - startedAt} devices=${devices} - device delivery state refreshed`,
      );
    } catch (error) {
      this.logger.error(
        `[kobo.source_publication] [fail] bookId=${bookId} bookFileId=${bookFileId} durationMs=${Date.now() - startedAt} errorClass=${error instanceof Error ? error.name : 'UnknownError'} error="${sanitizeLogValue(error instanceof Error ? error.message : String(error))}" - device delivery state refresh failed`,
      );
      throw new ServiceUnavailableException('Kobo delivery refresh failed; retry source PDF publication');
    }
  }
}
