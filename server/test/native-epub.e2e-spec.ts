import { randomUUID, createHash } from 'node:crypto';
import { writeFile } from 'node:fs/promises';
import * as schema from '../src/db/schema';
import {
  authHeader,
  closeReaderStateIsolationE2EContext,
  createLibraryWithFolder,
  createReaderStateIsolationE2EContext,
  createUserAndLogin,
  grantLibraryAccess,
  locateBookByAbsolutePath,
  triggerAndWaitForLibraryScan,
  type ReaderStateIsolationE2EContext,
} from './e2e/reader-state-isolation/reader-state-isolation-harness';
import { createEpubFixture } from './e2e/reader-state-isolation/reader-state-isolation-fixture-builder';

describe('Native connected EPUB adapter', { timeout: 120_000 }, () => {
  let ctx: ReaderStateIsolationE2EContext;
  beforeAll(async () => {
    ctx = await createReaderStateIsolationE2EContext();
  }, 60_000);
  afterAll(async () => {
    if (ctx) await closeReaderStateIsolationE2EContext(ctx);
  });

  it('connects, pages/searches, opens immutable source text and isolates another owner and denied account', async () => {
    const library = await createLibraryWithFolder(ctx, { name: `native-${randomUUID()}` });
    const path = await createEpubFixture(library.folderPath, 'book.epub', { title: 'Native readable EPUB' });
    await triggerAndWaitForLibraryScan(ctx, library.libraryId);
    const file = await locateBookByAbsolutePath(ctx, path);
    await ctx.db
      .insert(schema.bookMetadata)
      .values({ bookId: file.bookId, title: 'Native readable EPUB' })
      .onConflictDoUpdate({ target: schema.bookMetadata.bookId, set: { title: 'Native readable EPUB' } });
    const owner = await createUserAndLogin(ctx);
    const second = await createUserAndLogin(ctx);
    const denied = await createUserAndLogin(ctx);
    await grantLibraryAccess(ctx, owner.userId, library.libraryId, 'owner');
    await grantLibraryAccess(ctx, second.userId, library.libraryId, 'owner');
    const identity = await ctx.app.inject({ method: 'GET', url: '/api/v1/server-identity' });
    expect(identity.json().product).toBe('bookorbit');
    const login = await ctx.app.inject({
      method: 'POST',
      url: '/api/v1/auth/login',
      payload: {
        username: owner.username,
        password: owner.password,
        clientKind: 'native',
        deviceLabel: 'Native adapter fixture',
      },
    });
    expect(login.statusCode).toBe(200);
    const session = login.json();
    expect(session.refreshToken).toEqual(expect.any(String));
    const headers = authHeader(session.accessToken);
    const me = await ctx.app.inject({ method: 'GET', url: '/api/v1/auth/me', headers });
    expect(me.json().id).toBe(owner.userId);
    const catalog = await ctx.app.inject({
      method: 'POST',
      url: '/api/v1/books/query',
      headers,
      payload: { q: 'Native', pagination: { page: 0, size: 50 }, sort: [{ field: 'title', dir: 'asc' }] },
    });
    expect(catalog.statusCode).toBe(201);
    expect(catalog.json().items.map((book: { id: number }) => book.id)).toContain(file.bookId);
    const detail = await ctx.app.inject({ method: 'GET', url: `/api/v1/books/${file.bookId}`, headers });
    expect(detail.json().files.map((item: { id: number }) => item.id)).toContain(file.bookFileId);
    const openUrl = `/api/v1/epub-sessions/books/${file.bookId}/files/${file.bookFileId}`;
    const opened = await ctx.app.inject({ method: 'POST', url: openUrl, headers });
    expect(opened.statusCode).toBe(201);
    const manifest = opened.json();
    const originalUrl = `/api/v1/epub-sessions/${manifest.id}/original`;
    const original = await ctx.app.inject({ method: 'GET', url: originalUrl, headers });
    expect(original.statusCode).toBe(200);
    expect(createHash('sha256').update(original.rawPayload).digest('hex')).toBe(manifest.sourceSha256);
    expect((await ctx.app.inject({ method: 'GET', url: originalUrl, headers: authHeader(second.accessToken) })).statusCode).toBe(403);
    const chapterIndex = manifest.members.findIndex((item: { path: string }) => item.path.endsWith('chapter.xhtml'));
    expect(chapterIndex).toBeGreaterThanOrEqual(0);
    const url = `/api/v1/epub-sessions/${manifest.id}/members/${chapterIndex}`;
    const chapter = await ctx.app.inject({ method: 'GET', url, headers });
    expect(chapter.statusCode).toBe(200);
    expect(chapter.body).toContain('Native readable EPUB');
    expect(createHash('sha256').update(chapter.rawPayload).digest('hex')).toBe(manifest.members[chapterIndex].sha256);
    expect((await ctx.app.inject({ method: 'GET', url, headers: authHeader(second.accessToken) })).statusCode).toBe(403);
    expect((await ctx.app.inject({ method: 'POST', url: openUrl, headers: authHeader(denied.accessToken) })).statusCode).toBe(403);
    const deniedCatalog = await ctx.app.inject({
      method: 'POST',
      url: '/api/v1/books/query',
      headers: authHeader(denied.accessToken),
      payload: { pagination: { page: 0, size: 50 } },
    });
    expect(deniedCatalog.json().items.map((book: { id: number }) => book.id)).not.toContain(file.bookId);
    const secondOpen = await ctx.app.inject({ method: 'POST', url: openUrl, headers: authHeader(second.accessToken) });
    expect(secondOpen.statusCode).toBe(201);
    await writeFile(path, 'replacement cannot change an open snapshot');
    expect((await ctx.app.inject({ method: 'GET', url, headers })).body).toBe(chapter.body);
    expect((await ctx.app.inject({ method: 'DELETE', url: `/api/v1/epub-sessions/${manifest.id}`, headers })).statusCode).toBe(200);
    expect((await ctx.app.inject({ method: 'GET', url, headers })).statusCode).toBe(404);
  });
});
