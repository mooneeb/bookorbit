import { createHash } from 'node:crypto';
import {
  createReaderStateIsolationE2EContext,
  closeReaderStateIsolationE2EContext,
  authHeader,
  type ReaderStateIsolationE2EContext,
} from './e2e/reader-state-isolation/reader-state-isolation-harness';
import { prepareNativeQA } from './e2e/native-reader/native-reader-qa';
import type { NativeEpubSession } from '@bookorbit/types';
import { spawn } from 'node:child_process';
import { mkdir, open, readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';

describe('Native verified offline EPUB HTTP workflow', { timeout: 180_000 }, () => {
  let ctx: ReaderStateIsolationE2EContext;
  let qa: Awaited<ReturnType<typeof prepareNativeQA>>;
  beforeAll(async () => {
    ctx = await createReaderStateIsolationE2EContext();
    qa = await prepareNativeQA(ctx, true);
    if (process.env.NATIVE_QA === '1') await ctx.app.listen(55458, '127.0.0.1');
  }, 180_000);
  afterAll(async () => {
    if (ctx) await closeReaderStateIsolationE2EContext(ctx);
  });

  it('Choose and reopen a verified book', async () => {
    const file = qa.files['QA Prose'];
    const response = await ctx.app.inject({
      method: 'POST',
      url: `/api/v1/epub-sessions/books/${file.bookId}/files/${file.bookFileId}`,
      headers: authHeader(qa.owner.accessToken),
    });
    expect(response.statusCode, response.body).toBe(201);
    const manifest = response.json<NativeEpubSession>();
    expect(manifest.accountId).toBe(qa.owner.userId);
    expect(manifest.sourceFileId).toMatch(/^[a-f0-9-]{36}$/);
    expect(manifest.sourceRevision).toBe(manifest.sourceSha256);
    const original = await ctx.app.inject({
      method: 'GET',
      url: `/api/v1/epub-sessions/${manifest.id}/original`,
      headers: authHeader(qa.owner.accessToken),
    });
    expect(createHash('sha256').update(original.rawPayload).digest('hex')).toBe(manifest.sourceSha256);
    for (const [index, member] of manifest.members.entries()) {
      const resource = await ctx.app.inject({
        method: 'GET',
        url: `/api/v1/epub-sessions/${manifest.id}/members/${index}`,
        headers: authHeader(qa.owner.accessToken),
      });
      expect(resource.rawPayload.length).toBe(member.bytes);
      expect(createHash('sha256').update(resource.rawPayload).digest('hex')).toBe(member.sha256);
    }
    const stolen = await ctx.app.inject({
      method: 'GET',
      url: `/api/v1/epub-sessions/${manifest.id}/original`,
      headers: authHeader(qa.other.accessToken),
    });
    expect(stolen.statusCode).toBe(403);
    const denied = await ctx.app.inject({
      method: 'POST',
      url: `/api/v1/epub-sessions/books/${file.bookId}/files/${file.bookFileId}`,
      headers: authHeader(qa.denied.accessToken),
    });
    expect(denied.statusCode).toBe(403);
    const extra = await ctx.app.inject({
      method: 'POST',
      url: `/api/v1/epub-sessions/books/${file.bookId}/files/${file.bookFileId}`,
      headers: authHeader(qa.owner.accessToken),
      payload: { unexpected: true },
    });
    expect(extra.statusCode).toBe(400);
  });

  it('Browse a large isolated catalog', async () => {
    const headers = authHeader(qa.owner.accessToken);
    const catalog = async (page: number, q = '') => {
      const result = await ctx.app.inject({
        method: 'POST',
        url: '/api/v1/books/query',
        headers,
        payload: { q, sort: [{ field: 'title', dir: 'asc' }], pagination: { page, size: 50 } },
      });
      expect(result.statusCode).toBe(201);
      expect(result.json().items.length).toBeLessThanOrEqual(100);
      expect(result.json().items.some((book: { title: string }) => book.title === 'B Secret')).toBe(false);
      return result.json().items as { id: number; title: string }[];
    };
    const first = await catalog(0),
      second = await catalog(1),
      third = await catalog(2);
    expect(first).toHaveLength(50);
    expect(new Set([...first, ...second, ...third].map((book) => book.id)).size).toBe(150);
    expect((await catalog(0, 'QA Prose')).map((book) => book.title)).toEqual(['QA Prose']);
    expect(await catalog(0, 'B Secret')).toEqual([]);
    const cold: number[] = [],
      warm: number[] = [];
    for (let run = 0; run < 30; run++) {
      let started = performance.now();
      await catalog(0);
      cold.push(performance.now() - started);
      started = performance.now();
      await catalog(1);
      warm.push(performance.now() - started);
    }
    const percentile = (values: number[], fraction: number) => [...values].sort((a, b) => a - b)[Math.ceil(values.length * fraction) - 1];
    console.log(
      JSON.stringify({
        event: 'native.catalog_measurements',
        runs: 30,
        firstPage: { p50: percentile(cold, 0.5), p95: percentile(cold, 0.95) },
        nextPage: { p50: percentile(warm, 0.5), p95: percentile(warm, 0.95) },
        failures: 0,
        transport: 'authenticated Fastify inject; no client cache; PostgreSQL buffers retained',
      }),
    );
    expect(percentile(cold, 0.95)).toBeLessThanOrEqual(2000);
    expect(percentile(warm, 0.95)).toBeLessThanOrEqual(1000);
  });

  it('Refuse an incomplete or hostile package', async () => {
    for (const title of [
      'QA Broken',
      'QA Traversal',
      'QA Broken Srcset',
      'QA Broken Style',
      'QA Broken Import',
      'QA Embedded',
      'QA Media',
      'QA Vertical',
      'QA Mixed',
      'QA Nodes',
    ]) {
      const file = qa.files[title];
      const response = await ctx.app.inject({
        method: 'POST',
        url: `/api/v1/epub-sessions/books/${file.bookId}/files/${file.bookFileId}`,
        headers: authHeader(qa.owner.accessToken),
      });
      expect(response.statusCode, response.body).toBe(400);
    }
    const file = qa.files['QA Hostile'];
    const response = await ctx.app.inject({
      method: 'POST',
      url: `/api/v1/epub-sessions/books/${file.bookId}/files/${file.bookFileId}`,
      headers: authHeader(qa.owner.accessToken),
    });
    expect(response.statusCode, response.body).toBe(201);
    const manifest = response.json<NativeEpubSession>();
    const index = manifest.members.findIndex((member) => member.path === 'one.xhtml');
    const resource = await ctx.app.inject({
      method: 'GET',
      url: `/api/v1/epub-sessions/${manifest.id}/members/${index}`,
      headers: authHeader(qa.owner.accessToken),
    });
    expect(resource.body).toContain('<script>');
    expect(createHash('sha256').update(resource.rawPayload).digest('hex')).toBe(manifest.members[index].sha256);
  });

  it.skipIf(process.env.NATIVE_QA !== '1')(
    'runs the three scenarios through the native adapters and contained WebKit host',
    async () => {
      const root = fileURLToPath(new URL('../../', import.meta.url));
      await mkdir(resolve(root, 'native/build'), { recursive: true });
      const logPath = resolve(root, 'native/build/qa-native.log');
      const log = await open(logPath, 'w');
      try {
        const code = await new Promise<number | null>((accept, reject) => {
          const child = spawn(
            'xcodebuild',
            [
              '-project',
              'native/BookOrbit.xcodeproj',
              '-scheme',
              'BookOrbit',
              '-destination',
              `platform=iOS Simulator,id=${process.env.QA_SIMULATOR_ID ?? 'EB2080CE-A9ED-4B71-BEDE-830512F4CA70'}`,
              '-parallel-testing-enabled',
              'NO',
              '-derivedDataPath',
              'native/build',
              'CODE_SIGNING_ALLOWED=YES',
              'CODE_SIGN_IDENTITY=-',
              'test',
            ],
            { cwd: root, stdio: ['ignore', log.fd, log.fd] },
          );
          child.on('error', reject);
          child.on('exit', accept);
        });
        expect(code, (await readFile(logPath, 'utf8')).slice(-12000)).toBe(0);
      } finally {
        await log.close();
      }
    },
    20 * 60 * 1000,
  );
});
