import { BadRequestException, Inject, Injectable, Logger } from '@nestjs/common';
import type { ConfigType } from '@nestjs/config';
import * as cheerio from 'cheerio';

import { sanitizeLogValue } from '../../common/utils/log-sanitize.utils';
import { appConfig } from '../../config/config';
import { STORYGRAPH_MAX_RETRIES, STORYGRAPH_REMEMBER_COOKIE_NAME, STORYGRAPH_SESSION_COOKIE_NAME } from './storygraph.constants';
import { StorygraphQueueService } from './storygraph-queue.service';
import { StorygraphRepository } from './storygraph.repository';

export interface StorygraphCookies {
  sessionCookie: string;
  rememberToken: string;
}

export interface StorygraphResponse {
  status: number;
  html: string;
  redirectedToSignIn: boolean;
}

const USER_AGENT = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

@Injectable()
export class StorygraphClientService {
  private readonly logger = new Logger(StorygraphClientService.name);

  constructor(
    private readonly queue: StorygraphQueueService,
    private readonly repo: StorygraphRepository,
    @Inject(appConfig.KEY) private readonly config: ConfigType<typeof appConfig>,
  ) {}

  async get(userId: number, cookies: StorygraphCookies, path: string): Promise<StorygraphResponse> {
    return this.executeWithRetry(userId, cookies, path, 'GET', undefined, 0);
  }

  async post(userId: number, cookies: StorygraphCookies, path: string, form: Record<string, string>, csrfToken: string): Promise<StorygraphResponse> {
    return this.executeWithRetry(userId, cookies, path, 'POST', { form, csrfToken }, 0);
  }

  extractCsrfToken(html: string): string | null {
    const $ = cheerio.load(html);
    const metaToken = $('meta[name="csrf-token"]').attr('content');
    if (metaToken) return metaToken;
    const inputToken = $('input[name="authenticity_token"]').attr('value');
    return inputToken ?? null;
  }

  private buildCookieHeader(cookies: StorygraphCookies): string {
    return `${STORYGRAPH_REMEMBER_COOKIE_NAME}=${cookies.rememberToken}; ${STORYGRAPH_SESSION_COOKIE_NAME}=${cookies.sessionCookie}`;
  }

  private async executeWithRetry(
    userId: number,
    cookies: StorygraphCookies,
    path: string,
    method: 'GET' | 'POST',
    post: { form: Record<string, string>; csrfToken: string } | undefined,
    attempt: number,
  ): Promise<StorygraphResponse> {
    const startedAt = Date.now();
    await this.queue.throttle(userId);

    const url = new URL(path.startsWith('http') ? path : `${this.config.storygraphBaseUrl.replace(/\/$/, '')}${path}`);
    if (url.origin !== new URL(this.config.storygraphBaseUrl).origin) {
      throw new BadRequestException('StoryGraph request origin is invalid');
    }
    const headers: Record<string, string> = {
      'User-Agent': USER_AGENT,
      Cookie: this.buildCookieHeader(cookies),
      Accept: 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
    };

    let body: string | undefined;
    if (method === 'POST' && post) {
      headers['Content-Type'] = 'application/x-www-form-urlencoded';
      headers['X-CSRF-Token'] = post.csrfToken;
      headers['X-Requested-With'] = 'XMLHttpRequest';
      body = new URLSearchParams({ ...post.form, authenticity_token: post.csrfToken }).toString();
    }

    let response: Response;
    try {
      response = await fetch(url.href, {
        method,
        headers,
        body,
        redirect: 'manual',
        signal: AbortSignal.timeout(this.config.storygraphRequestTimeoutMs),
      });
    } catch (err) {
      const errorClass = err instanceof Error ? err.constructor.name : 'UnknownError';
      const error = sanitizeLogValue(err instanceof Error ? err.message : String(err));
      this.logger.error(
        `[storygraph.client_request] [fail] userId=${userId} attempt=${attempt} durationMs=${Date.now() - startedAt} errorClass=${errorClass} error="${error}" - fetch failed`,
      );
      throw err;
    }

    if (method === 'GET' && (response.status === 429 || response.status >= 500) && attempt < STORYGRAPH_MAX_RETRIES) {
      const backoffMs = Math.pow(2, attempt + 1) * 1000;
      this.logger.warn(
        `[storygraph.client_request] [end] userId=${userId} attempt=${attempt} durationMs=${Date.now() - startedAt} status=${response.status} retryable=true backoffMs=${backoffMs} - retrying`,
      );
      await new Promise((resolve) => setTimeout(resolve, backoffMs));
      return this.executeWithRetry(userId, cookies, path, method, post, attempt + 1);
    }

    await this.persistRotatedSessionCookie(userId, cookies, response);

    const location = response.headers.get?.('location');
    const destination = location ? new URL(location, url) : null;
    if (destination && destination.origin !== url.origin) throw new BadRequestException('storygraph_redirect_not_allowed');
    const html = await this.readBoundedHtml(response);
    const target = destination?.pathname ?? response.url;
    const redirectedToSignIn = target.includes('/users/sign_in') || target.includes('/users/sign-in');

    return { status: response.status, html, redirectedToSignIn };
  }

  private async readBoundedHtml(response: Response): Promise<string> {
    const limit = 2 * 1024 * 1024;
    if (!response.body) {
      const html = await response.text();
      if (Buffer.byteLength(html) > limit) throw new BadRequestException('storygraph_response_too_large');
      return html;
    }
    const reader = response.body.getReader();
    const decoder = new TextDecoder();
    let html = '';
    let bytes = 0;
    try {
      while (true) {
        const chunk = await reader.read();
        if (chunk.done) break;
        bytes += chunk.value.byteLength;
        if (bytes > limit) throw new BadRequestException('storygraph_response_too_large');
        html += decoder.decode(chunk.value, { stream: true });
      }
      return html + decoder.decode();
    } finally {
      await reader.cancel();
      reader.releaseLock();
    }
  }

  private async persistRotatedSessionCookie(userId: number, cookies: StorygraphCookies, response: Response): Promise<void> {
    const setCookieHeaders = response.headers.getSetCookie?.() ?? [];
    for (const cookie of setCookieHeaders) {
      const match = new RegExp(`${STORYGRAPH_SESSION_COOKIE_NAME}=([^;]+)`).exec(cookie);
      if (match?.[1]) {
        cookies.sessionCookie = match[1];
        const startedAt = Date.now();
        await this.repo.updateSessionCookie(userId, match[1]).catch((err) => {
          const errorClass = err instanceof Error ? err.constructor.name : 'Error';
          const error = sanitizeLogValue(err instanceof Error ? err.message : String(err));
          this.logger.warn(
            `[storygraph.session_cookie] [fail] userId=${userId} durationMs=${Date.now() - startedAt} errorClass=${errorClass} error="${error}" - failed to persist rotated session cookie`,
          );
        });
        return;
      }
    }
  }
}
