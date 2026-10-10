import { createHash, randomUUID } from 'node:crypto';
import { afterAll, beforeAll, expect, test, vi } from 'vitest';
import type { BookmarkResponse } from '@bookorbit/types';

import { createEpubFixture } from '../e2e/reader-state-isolation/reader-state-isolation-fixture-builder';
import type { LocatedBookFile, ReaderStateIsolationE2EContext } from '../e2e/reader-state-isolation/reader-state-isolation-harness';

let harness: typeof import('../e2e/reader-state-isolation/reader-state-isolation-harness');
let ctx: ReaderStateIsolationE2EContext;
let epub: LocatedBookFile;
let fileHash: string;
const username = `bookmark-retirement-${randomUUID().slice(0, 8)}`;
const password = 'BookmarkRetirement123';
const protocolHeaders = { 'x-auth-user': username, 'x-auth-key': password };

async function pull(deviceId = 'retirement-device-a') {
  const response = await ctx.app.inject({
    method: 'POST',
    url: '/api/v1/koreader/plugin/bookmarks/exchange',
    headers: protocolHeaders,
    payload: {
      deviceId,
      deviceModel: 'HTTP protocol fixture',
      pluginVersion: '0.5.0',
      books: [{ hash: fileHash, keys: [], keysComplete: false, changes: [] }],
    },
  });
  expect(response.statusCode).toBe(201);
  return response.json() as { results: { toApply: { add: { serverId: number; pos: string }[]; delete: { serverId: number }[] } }[] };
}

async function create(payload: { clientId?: string; cfi: string; title: string }): Promise<BookmarkResponse> {
  const response = await ctx.app.inject({
    method: 'POST',
    url: `/api/v1/books/${epub.bookId}/bookmarks`,
    headers: harness.authHeader(ctx.adminToken),
    payload,
  });
  expect(response.statusCode, response.body).toBe(201);
  return response.json() as BookmarkResponse;
}

async function remove(bookmarkId: number) {
  const response = await ctx.app.inject({
    method: 'DELETE',
    url: `/api/v1/books/${epub.bookId}/bookmarks/${bookmarkId}`,
    headers: harness.authHeader(ctx.adminToken),
  });
  expect(response.statusCode).toBe(204);
}

async function acknowledge(deviceId: string, applied: { serverId: number; pos: string }[], deleted: number[]) {
  const response = await ctx.app.inject({
    method: 'POST',
    url: '/api/v1/koreader/plugin/bookmarks/exchange-ack',
    headers: protocolHeaders,
    payload: {
      deviceId,
      deviceModel: 'HTTP protocol fixture',
      pluginVersion: '0.5.0',
      books: [
        {
          hash: fileHash,
          applied: applied.map((entry) => ({ serverId: entry.serverId, pos: entry.pos, status: 'applied', datetime: '2026-01-01 12:00:00' })),
          deleted: deleted.map((serverId) => ({ serverId, status: 'applied' })),
        },
      ],
    },
  });
  expect(response.statusCode, response.body).toBe(201);
}

beforeAll(async () => {
  if (!process.env.DATABASE_URL || !URL.canParse(process.env.DATABASE_URL))
    throw new Error('Retirement HTTP tests require DATABASE_URL from scripts/ipad/run-bookmark-retirement.mjs');
  const database = new URL(process.env.DATABASE_URL);
  if (!['localhost', '127.0.0.1'].includes(database.hostname) || !/^bookorbit_bookmark_retirement_\d+_e2e$/.test(database.pathname.slice(1)))
    throw new Error('Retirement HTTP tests require their own migrated localhost bookmark-retirement database');
  if (!process.env.JWT_SECRET) throw new Error('Retirement HTTP tests require JWT_SECRET from scripts/ipad/run-bookmark-retirement.mjs');
  harness = await import('../e2e/reader-state-isolation/reader-state-isolation-harness');
  ctx = await harness.createReaderStateIsolationE2EContext();
  const library = await harness.createLibraryWithFolder(ctx, { name: `Retirement fixture ${randomUUID()}` });
  const epubPath = await createEpubFixture(library.folderPath, 'retirement.epub', {
    title: 'Bookmark retirement fixture',
    uid: `urn:uuid:${randomUUID()}`,
  });
  await harness.triggerAndWaitForLibraryScan(ctx, library.libraryId);
  epub = await harness.locateBookByAbsolutePath(ctx, epubPath);
  const artifact = await ctx.app.inject({
    method: 'GET',
    url: `/api/v1/books/files/${epub.bookFileId}/serve`,
    headers: harness.authHeader(ctx.adminToken),
  });
  expect(artifact.statusCode).toBe(200);
  const hash = createHash('md5');
  for (const offset of [0, 1024, 4096, 16384, 65536, 262144, 1048576, 4194304, 16777216, 67108864, 268435456, 1073741824]) {
    if (offset >= artifact.rawPayload.length) break;
    hash.update(artifact.rawPayload.subarray(offset, offset + 1024));
  }
  fileHash = hash.digest('hex');
  const credentials = await ctx.app.inject({
    method: 'POST',
    url: '/api/v1/koreader/credentials',
    headers: harness.authHeader(ctx.adminToken),
    payload: { username, password },
  });
  expect([200, 201]).toContain(credentials.statusCode);
});

afterAll(async () => {
  vi.useRealTimers();
  if (ctx) await harness.closeReaderStateIsolationE2EContext(ctx);
});

test('IPAD-E02-A05-bookmark-retirement: five hundred acknowledged tombstones release the device working set without losing retry identities', async () => {
  const now = Date.now();
  let first: { clientId: string; cfi: string; title: string } | undefined;
  let firstId = 0;
  vi.useFakeTimers({ toFake: ['Date'] });
  vi.setSystemTime(now - 91 * 24 * 60 * 60 * 1000);
  try {
    for (let index = 0; index < 500; index++) {
      const payload = { clientId: randomUUID(), cfi: `epubcfi(/6/2!/4/2/1[retired-${index}]:0)`, title: `Old offline bookmark ${index}` };
      const bookmark = await create(payload);
      await remove(bookmark.id);
      if (index === 0) {
        first = payload;
        firstId = bookmark.id;
      }
    }
  } finally {
    vi.useRealTimers();
  }
  const active = await create({ clientId: randomUUID(), cfi: 'epubcfi(/6/2!/4/2/1:3)', title: 'Live bookmark after tombstones' });
  let result = await pull();
  for (let batch = 0; batch < 10; batch++) result = await pull();
  expect(result.results[0].toApply.add.map((item) => item.serverId)).toContain(active.id);
  const stale = await ctx.app.inject({
    method: 'POST',
    url: `/api/v1/books/${epub.bookId}/bookmarks`,
    headers: harness.authHeader(ctx.adminToken),
    payload: first!,
  });
  expect(stale.statusCode).toBe(409);
  await remove(firstId);
  const fresh = await create({ ...first!, clientId: randomUUID() });
  expect(fresh.id).not.toBe(firstId);
});

test('IPAD-E02-A05-bookmark-retirement: every device acknowledges before retirement and ordinary tombstones are still purged', async () => {
  const payload = { clientId: randomUUID(), cfi: 'epubcfi(/6/2!/4/2/1:4)', title: 'Two device deletion' };
  const bookmark = await create(payload);
  const deviceA = 'retirement-device-a';
  const deviceB = 'retirement-device-b';
  for (const device of [deviceA, deviceB]) {
    const result = await pull(device);
    const entry = result.results[0].toApply.add.find((item) => item.serverId === bookmark.id);
    expect(entry).toBeDefined();
    await acknowledge(device, [entry!], []);
  }
  vi.useFakeTimers({ toFake: ['Date'] });
  vi.setSystemTime(Date.now() - 91 * 24 * 60 * 60 * 1000);
  try {
    await remove(bookmark.id);
  } finally {
    vi.useRealTimers();
  }
  expect((await pull(deviceA)).results[0].toApply.delete.map((item) => item.serverId)).toContain(bookmark.id);
  await acknowledge(deviceA, [], [bookmark.id]);
  await pull(deviceA);
  expect((await pull(deviceB)).results[0].toApply.delete.map((item) => item.serverId)).toContain(bookmark.id);
  await acknowledge(deviceB, [], [bookmark.id]);
  await pull(deviceB);
  expect((await pull(deviceB)).results[0].toApply.delete.map((item) => item.serverId)).not.toContain(bookmark.id);
  const stale = await ctx.app.inject({
    method: 'POST',
    url: `/api/v1/books/${epub.bookId}/bookmarks`,
    headers: harness.authHeader(ctx.adminToken),
    payload,
  });
  expect(stale.statusCode).toBe(409);

  const replacement = await create({ ...payload, clientId: randomUUID() });
  const replacementEntry = (await pull(deviceB)).results[0].toApply.add.find((item) => item.serverId === replacement.id);
  expect(replacementEntry).toBeDefined();
  const upload = await ctx.app.inject({
    method: 'POST',
    url: '/api/v1/koreader/plugin/bookmarks/exchange',
    headers: protocolHeaders,
    payload: {
      deviceId: deviceB,
      deviceModel: 'HTTP protocol fixture',
      pluginVersion: '0.5.0',
      books: [{ hash: fileHash, keys: [], keysComplete: false, changes: [{ datetime: '2026-01-02 12:00:00', pos: replacementEntry!.pos }] }],
    },
  });
  expect(upload.statusCode, upload.body).toBe(201);
  const afterUpload = await ctx.app.inject({
    method: 'POST',
    url: `/api/v1/books/${epub.bookId}/bookmarks`,
    headers: harness.authHeader(ctx.adminToken),
    payload,
  });
  expect(afterUpload.statusCode).toBe(409);

  const ordinaryPayload = { cfi: 'epubcfi(/6/2!/4/2/1:5)', title: 'Ordinary web deletion' };
  const ordinary = await create(ordinaryPayload);
  vi.useFakeTimers({ toFake: ['Date'] });
  vi.setSystemTime(Date.now() - 91 * 24 * 60 * 60 * 1000);
  try {
    await remove(ordinary.id);
  } finally {
    vi.useRealTimers();
  }
  await pull();
  const recreated = await create({ ...ordinaryPayload, clientId: ordinary.clientId });
  expect(recreated.id).not.toBe(ordinary.id);
});
