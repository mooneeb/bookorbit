import { readFileSync } from 'node:fs';
import { parseEnv } from 'node:util';
import { Client } from 'pg';

import { BOOK_COVER_WRITE_LOCK_NAMESPACE } from './book-cover-store.repository';

const DOCK_FINALIZE_LOCK_NAMESPACE = 4105;

async function withTransactions(operation: (first: Client, second: Client) => Promise<void>): Promise<void> {
  const env = parseEnv(readFileSync(process.env.BOOK_COVER_LOCK_TEST_ENV!, 'utf8'));
  const first = new Client({ connectionString: env.DATABASE_URL });
  const second = new Client({ connectionString: env.DATABASE_URL });
  try {
    await first.connect();
    await second.connect();
    await first.query('BEGIN');
    await second.query('BEGIN');
    await operation(first, second);
  } finally {
    await Promise.allSettled([first.query('ROLLBACK'), second.query('ROLLBACK')]);
    await Promise.allSettled([first.end(), second.end()]);
  }
}

async function tryLock(client: Client, namespace: number, id: number): Promise<boolean> {
  const result = await client.query<{ acquired: boolean }>('SELECT pg_try_advisory_xact_lock($1::integer, $2::integer) AS acquired', [namespace, id]);
  return result.rows[0].acquired;
}

describe.skipIf(!process.env.BOOK_COVER_LOCK_TEST_ENV)('cover advisory locks in PostgreSQL', () => {
  it('allows a Dock job and cover write with the same ID to lock simultaneously', async () => {
    await withTransactions(async (dock, cover) => {
      expect(await tryLock(dock, DOCK_FINALIZE_LOCK_NAMESPACE, 2_100_000_001)).toBe(true);
      expect(await tryLock(cover, BOOK_COVER_WRITE_LOCK_NAMESPACE, 2_100_000_001)).toBe(true);
    });
  });

  it('serializes cover writes for the same book until the transaction releases its lock', async () => {
    await withTransactions(async (first, second) => {
      expect(await tryLock(first, BOOK_COVER_WRITE_LOCK_NAMESPACE, 2_100_000_001)).toBe(true);
      expect(await tryLock(second, BOOK_COVER_WRITE_LOCK_NAMESPACE, 2_100_000_001)).toBe(false);
      await first.query('COMMIT');
      expect(await tryLock(second, BOOK_COVER_WRITE_LOCK_NAMESPACE, 2_100_000_001)).toBe(true);
    });
  });

  it('keeps recovery locks independent when job and book IDs differ or cross', async () => {
    await withTransactions(async (dock, cover) => {
      expect(await tryLock(dock, DOCK_FINALIZE_LOCK_NAMESPACE, 2_100_000_001)).toBe(true);
      expect(await tryLock(cover, BOOK_COVER_WRITE_LOCK_NAMESPACE, 2_100_000_002)).toBe(true);
      expect(await tryLock(dock, DOCK_FINALIZE_LOCK_NAMESPACE, 2_100_000_002)).toBe(true);
      expect(await tryLock(cover, BOOK_COVER_WRITE_LOCK_NAMESPACE, 2_100_000_001)).toBe(true);
    });
  });
});
