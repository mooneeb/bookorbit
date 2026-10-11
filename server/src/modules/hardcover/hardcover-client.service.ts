import { BadGatewayException, GatewayTimeoutException, Inject, Injectable, Logger, Optional } from '@nestjs/common';
import type { ConfigType } from '@nestjs/config';

import { sanitizeLogValue } from '../../common/utils/log-sanitize.utils';
import { appConfig } from '../../config/config';
import { HARDCOVER_GRAPHQL_URL, HARDCOVER_MAX_RETRIES } from './hardcover.constants';
import { HardcoverQueueService } from './hardcover-queue.service';

export interface HardcoverGraphQLResponse<T> {
  data?: T;
  errors?: { message: string }[];
}

@Injectable()
export class HardcoverClientService {
  private readonly logger = new Logger(HardcoverClientService.name);

  constructor(
    private readonly queue: HardcoverQueueService,
    @Optional() @Inject(appConfig.KEY) private readonly config?: ConfigType<typeof appConfig>,
  ) {}

  async query<T>(userId: number, token: string, query: string, variables?: Record<string, unknown>): Promise<T> {
    const startedAt = Date.now();
    this.logger.log(`[hardcover.client] [start] userId=${userId} - provider request started`);
    try {
      const data = await this.executeWithRetry<T>(userId, token, query, variables, 0);
      this.logger.log(`[hardcover.client] [end] userId=${userId} durationMs=${Date.now() - startedAt} confirmed=true - provider request completed`);
      return data;
    } catch (error: unknown) {
      this.logger.warn(
        `[hardcover.client] [fail] userId=${userId} durationMs=${Date.now() - startedAt} errorClass=${error instanceof Error ? error.constructor.name : 'Error'} error="${sanitizeLogValue(error instanceof Error ? error.message : String(error))}" - provider request failed`,
      );
      throw error;
    }
  }

  private async executeWithRetry<T>(
    userId: number,
    token: string,
    query: string,
    variables: Record<string, unknown> | undefined,
    attempt: number,
  ): Promise<T> {
    await this.queue.throttle(userId);

    let response: Response;
    try {
      response = await fetch(this.config?.hardcoverGraphqlUrl ?? HARDCOVER_GRAPHQL_URL, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${token}`,
          'User-Agent': 'BookOrbit Hardcover Sync (https://bookorbit.app)',
        },
        body: JSON.stringify({ query, variables }),
        signal: AbortSignal.timeout(this.config?.hardcoverRequestTimeoutMs ?? 15_000),
      });
    } catch (err) {
      const errorClass = err instanceof Error ? err.constructor.name : 'UnknownError';
      const error = sanitizeLogValue(err instanceof Error ? err.message : String(err));
      this.logger.error(`[hardcover.client] [fail] userId=${userId} attempt=${attempt} errorClass=${errorClass} error="${error}" - fetch failed`);
      if (err instanceof Error && ['TimeoutError', 'AbortError'].includes(err.name)) {
        throw new GatewayTimeoutException('Hardcover request timed out. Retry after checking the connection.');
      }
      throw new BadGatewayException('Hardcover could not be reached. Retry after checking the connection.');
    }

    if (response.status === 429) {
      if (attempt >= HARDCOVER_MAX_RETRIES) {
        this.logger.error(
          `[hardcover.client] [fail] userId=${userId} attempt=${attempt} errorClass=RateLimitError error="rate limit exceeded after retries" - giving up`,
        );
        throw new BadGatewayException('Hardcover rate limit exceeded');
      }
      const backoffMs = Math.pow(2, attempt + 1) * 1000;
      this.logger.warn(`[hardcover.client] userId=${userId} attempt=${attempt} backoffMs=${backoffMs} - rate limited, backing off`);
      await new Promise((resolve) => setTimeout(resolve, backoffMs));
      return this.executeWithRetry<T>(userId, token, query, variables, attempt + 1);
    }

    if (!response.ok) {
      const errorClass = `HttpError${response.status}`;
      this.logger.error(
        `[hardcover.client] [fail] userId=${userId} status=${response.status} errorClass=${errorClass} error="unexpected HTTP status" - request failed`,
      );
      throw new BadGatewayException(`Hardcover API error: ${response.status}`);
    }

    const json = (await response.json()) as HardcoverGraphQLResponse<T>;

    if (json.errors?.length) {
      const error = sanitizeLogValue(json.errors[0].message);
      this.logger.error(`[hardcover.client] [fail] userId=${userId} errorClass=GraphQLError error="${error}" - GraphQL error`);
      throw new BadGatewayException('Hardcover rejected the request. Check your credentials and retry.');
    }

    if (!json.data) throw new BadGatewayException('Hardcover returned no data');
    return json.data;
  }
}
