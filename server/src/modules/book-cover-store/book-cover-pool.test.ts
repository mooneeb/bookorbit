import { ConfigService } from '@nestjs/config';
import { drizzle } from 'drizzle-orm/node-postgres';
import { mkdtemp, readFile, rm } from 'fs/promises';
import { readFileSync } from 'node:fs';
import { parseEnv } from 'node:util';
import { tmpdir } from 'os';
import { join } from 'path';
import { Pool } from 'pg';
import sharp from 'sharp';
import * as schema from '../../db/schema';
import { BookCoverEventsService } from './book-cover-events.service';
import { BookCoverStoreRepository } from './book-cover-store.repository';
import { BookCoverStore } from './book-cover-store.service';

function deferred() {
  let resolve!: () => void;
  const promise = new Promise<void>((done) => {
    resolve = done;
  });
  return { promise, resolve };
}
async function image(red: number) {
  return sharp({ create: { width: 20, height: 30, channels: 3, background: { r: red, g: 30, b: 40 } } })
    .png()
    .toBuffer();
}
// Session-local tables isolate these checks from real library data.
async function fixture() {
  const env = parseEnv(readFileSync(process.env.BOOK_COVER_LOCK_TEST_ENV!, 'utf8'));
  const pool = new Pool({ connectionString: env.DATABASE_URL, max: 2, connectionTimeoutMillis: 1000 });
  const clients = await Promise.all([pool.connect(), pool.connect()]);
  try {
    await Promise.all(
      clients.map((client) =>
        client.query(`
      create temp table libraries (id integer primary key, cover_aspect_ratio text);
      create temp table books (id integer primary key, library_id integer, primary_file_id integer, updated_at timestamptz default now());
      create temp table book_files (id integer primary key, book_id integer, format text, role text, media_overlay_available boolean);
      create temp table book_metadata (like public.book_metadata including defaults including constraints including indexes);
      create temp table book_covers (book_id integer, medium text, source text, origin text check (origin <> 'provider'), width integer, height integer, updated_at timestamptz, dormant_since timestamptz, primary key (book_id, medium));
      insert into libraries values (1, '2/3');
      insert into books (id, library_id, primary_file_id) values (1, 1, 11), (2, 1, 12);
      insert into book_files values (11, 1, 'epub', 'content', false), (12, 2, 'epub', 'content', false);
      insert into book_covers values (1, 'ebook', 'extracted', 'embedded', 20, 30, now(), null), (2, 'ebook', 'extracted', 'embedded', 20, 30, now(), null);
    `),
      ),
    );
  } finally {
    clients.forEach((client) => client.release());
  }
  const root = await mkdtemp(join(tmpdir(), 'cover-pool-'));
  const repository = new BookCoverStoreRepository(drizzle(pool, { schema }));
  const store = new BookCoverStore({ getOrThrow: () => root } as unknown as ConfigService, repository, {
    emitChanged: vi.fn(),
  } as unknown as BookCoverEventsService);
  return {
    pool,
    repository,
    store,
    close: async () => {
      await pool.end();
      await rm(root, { recursive: true, force: true });
    },
  };
}

describe.skipIf(!process.env.BOOK_COVER_LOCK_TEST_ENV)('cover writes on a bounded PostgreSQL pool', () => {
  it('finishes two different book writes while both pool connections hold locks', async () => {
    const f = await fixture();
    const bothEntered = deferred();
    let entered = 0;
    const original = f.repository.withBookWriteLock.bind(f.repository);
    vi.spyOn(f.repository, 'withBookWriteLock').mockImplementation((bookId, operation) =>
      original(bookId, async (locked) => {
        if (++entered === 2) bothEntered.resolve();
        await bothEntered.promise;
        expect(locked).not.toBe(f.repository);
        return operation(locked);
      }),
    );
    try {
      const bytes = await image(80);
      expect(await Promise.all([f.store.saveCustom(1, 'ebook', bytes), f.store.saveExtracted(2, 'ebook', bytes, { origin: 'embedded' })])).toEqual([
        true,
        true,
      ]);
      expect(f.pool.waitingCount).toBe(0);
      expect(f.pool.idleCount).toBe(2);
    } finally {
      await f.close();
    }
  });
  it('serializes two writes to one book and serves the newer bytes', async () => {
    const f = await fixture();
    const firstEntered = deferred();
    const releaseFirst = deferred();
    let entered = 0;
    const original = f.repository.withBookWriteLock.bind(f.repository);
    vi.spyOn(f.repository, 'withBookWriteLock').mockImplementation((bookId, operation) =>
      original(bookId, async (locked) => {
        entered++;
        if (entered === 1) {
          firstEntered.resolve();
          await releaseFirst.promise;
        }
        return operation(locked);
      }),
    );
    try {
      const older = await image(40);
      const newer = await image(180);
      const first = f.store.saveCustom(1, 'ebook', older);
      await firstEntered.promise;
      const second = f.store.saveCustom(1, 'ebook', newer);
      await new Promise((resolve) => setTimeout(resolve, 40));
      expect(entered).toBe(1);
      releaseFirst.resolve();
      expect(await Promise.all([first, second])).toEqual([true, true]);
      const path = await f.store.resolve(1, { medium: 'ebook', variant: 'cover', strict: true });
      expect(await readFile(path!)).toEqual(newer);
    } finally {
      releaseFirst.resolve();
      await f.close();
    }
  });
  it('releases a failed mutation so queued writes and reads finish', async () => {
    const f = await fixture();
    try {
      const bytes = await image(100);
      const results = await Promise.allSettled([
        f.store.saveCustom(1, 'ebook', bytes, { origin: 'provider' }),
        f.store.saveCustom(1, 'ebook', bytes),
        f.store.saveCustom(2, 'ebook', bytes),
      ]);
      expect(results.map((result) => result.status)).toEqual(['rejected', 'fulfilled', 'fulfilled']);
      expect(await f.store.saveCustom(1, 'ebook', bytes)).toBe(true);
      expect(await f.store.getBookVersion(1)).toBeTypeOf('string');
      expect(await f.store.resolve(1, { medium: 'ebook', variant: 'cover' })).not.toBeNull();
      expect(f.pool.waitingCount).toBe(0);
      expect(f.pool.idleCount).toBe(2);
    } finally {
      await f.close();
    }
  });
});
