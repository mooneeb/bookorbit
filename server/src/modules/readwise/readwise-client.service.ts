import { BadGatewayException, Inject, Injectable, Logger, Optional, ServiceUnavailableException, UnauthorizedException } from '@nestjs/common';
import type { ConfigType } from '@nestjs/config';

import { sanitizeLogValue } from '../../common/utils/log-sanitize.utils';
import { appConfig } from '../../config/config';
import { READWISE_AUTH_URL, READWISE_HIGHLIGHTS_URL, READWISE_MAX_RETRIES, READWISE_REQUEST_TIMEOUT_MS } from './readwise.constants';
import { ReadwiseQueueService } from './readwise-queue.service';

export interface ReadwiseHighlight {
  text: string;
  title?: string;
  author?: string;
  note?: string;
  image_url?: string;
  highlighted_at?: string;
  highlight_url?: string;
  source_type: string;
  category: string;
}

@Injectable()
export class ReadwiseClientService {
  private readonly logger = new Logger(ReadwiseClientService.name);

  constructor(
    private readonly queue: ReadwiseQueueService,
    @Optional() @Inject(appConfig.KEY) private readonly configuration?: ConfigType<typeof appConfig>,
  ) {}

  private endpoint(kind: 'auth' | 'highlights'): string {
    const base = this.configuration?.nodeEnv === 'test' ? this.configuration.readwiseBaseUrl : undefined;
    return base ? `${base.replace(/\/+$/, '')}/${kind}/` : kind === 'auth' ? READWISE_AUTH_URL : READWISE_HIGHLIGHTS_URL;
  }

  private timeout(): number {
    return this.configuration?.nodeEnv === 'test'
      ? (this.configuration.readwiseRequestTimeoutMs ?? READWISE_REQUEST_TIMEOUT_MS)
      : READWISE_REQUEST_TIMEOUT_MS;
  }

  async validateToken(userId: number, token: string): Promise<boolean> {
    const startedAtMs = Date.now();
    this.logger.log(`[readwise.client.validate_token] [start] userId=${userId} - token validation started`);
    try {
      const res = await fetch(this.endpoint('auth'), {
        headers: { Authorization: `Token ${token}` },
        signal: AbortSignal.timeout(this.timeout()),
        redirect: 'error',
      });
      const valid = res.status === 204;
      this.logger.log(
        `[readwise.client.validate_token] [end] userId=${userId} durationMs=${Date.now() - startedAtMs} valid=${valid} - token validation completed`,
      );
      return valid;
    } catch (err) {
      const errorClass = err instanceof Error ? err.constructor.name : 'UnknownError';
      this.logger.warn(
        `[readwise.client.validate_token] [fail] userId=${userId} durationMs=${Date.now() - startedAtMs} errorClass=${errorClass} error="${sanitizeLogValue(err instanceof Error ? err.message : String(err))}" - token validation failed`,
      );
      return false;
    }
  }

  async createHighlights(userId: number, token: string, highlights: ReadwiseHighlight[], attempt = 0): Promise<number[]> {
    if (highlights.length === 0) return [];
    await this.queue.throttle(userId);

    const startedAtMs = Date.now();
    this.logger.log(
      `[readwise.client.create_highlights] [start] userId=${userId} attempt=${attempt} highlights=${highlights.length} - Readwise delivery started`,
    );
    let res: Response;
    try {
      res = await fetch(this.endpoint('highlights'), {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Token ${token}`,
          'User-Agent': 'BookOrbit Readwise Sync',
        },
        body: JSON.stringify({ highlights }),
        signal: AbortSignal.timeout(this.timeout()),
        redirect: 'error',
      });
    } catch (err) {
      const errorClass = err instanceof Error ? err.constructor.name : 'UnknownError';
      this.logger.error(
        `[readwise.client.create_highlights] [fail] userId=${userId} attempt=${attempt} durationMs=${Date.now() - startedAtMs} errorClass=${errorClass} error="${sanitizeLogValue(err instanceof Error ? err.message : String(err))}" - Readwise highlights create request failed`,
      );
      throw err;
    }

    if (res.status === 429) {
      if (attempt >= READWISE_MAX_RETRIES) throw new ServiceUnavailableException('Readwise rate limit exceeded');
      const backoffMs = Math.pow(2, attempt + 1) * 1000;
      await new Promise((resolve) => setTimeout(resolve, backoffMs));
      return this.createHighlights(userId, token, highlights, attempt + 1);
    }
    if (res.status === 401) throw new ReadwiseUnauthorizedError();
    if (!res.ok) throw new BadGatewayException(`Readwise API error: ${res.status}`);
    const receipt: unknown = await res.json();
    if (!Array.isArray(receipt) || receipt.length === 0 || receipt.length > highlights.length) {
      throw new BadGatewayException('Readwise did not return a valid delivery receipt');
    }
    const ids: number[] = [];
    let confirmedHighlights = 0;
    for (const book of receipt) {
      if (
        !book ||
        typeof book !== 'object' ||
        !Number.isSafeInteger(book.id) ||
        book.id <= 0 ||
        !Number.isSafeInteger(book.num_highlights) ||
        book.num_highlights < 1 ||
        !Array.isArray(book.modified_highlights) ||
        book.modified_highlights.some((id: unknown) => !Number.isSafeInteger(id) || Number(id) <= 0)
      ) {
        throw new BadGatewayException('Readwise did not confirm the received highlights');
      }
      ids.push(book.id);
      confirmedHighlights += book.modified_highlights.length;
    }
    const distinctHighlights = new Set(highlights.map((h) => JSON.stringify([h.title ?? null, h.author ?? null, h.text]))).size;
    if (confirmedHighlights < distinctHighlights) throw new BadGatewayException('Readwise delivery receipt is incomplete');
    this.logger.log(
      `[readwise.client.create_highlights] [end] userId=${userId} durationMs=${Date.now() - startedAtMs} confirmedHighlights=${confirmedHighlights} receivedBooks=${ids.length} - Readwise delivery confirmed`,
    );
    return [...new Set(ids)];
  }
}

export class ReadwiseUnauthorizedError extends UnauthorizedException {
  constructor() {
    super('Readwise token unauthorized');
    this.name = 'ReadwiseUnauthorizedError';
  }
}
