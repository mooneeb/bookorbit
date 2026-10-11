import { readFileSync } from 'node:fs';
import { parseEnv } from 'node:util';
import { drizzle } from 'drizzle-orm/node-postgres';
import { Client } from 'pg';

import * as schema from '../../db/schema';
import { BulkRenameRepository } from './bulk-rename.repository';

function selectedBooksRepository(presentIds: number[] = []) {
  const calls: Array<{ text: string; params: number[] }> = [];
  const query = vi.fn().mockImplementation((config: { text: string }, params: number[]) => {
    calls.push({ text: config.text, params });
    const rows = config.text.includes('from "books"')
      ? presentIds
          .filter((id) => params.slice(2, -1).includes(id))
          .sort((a, b) => a - b)
          .map((id) => [id, ...new Array(21).fill(null)])
      : [];
    return Promise.resolve({ rows });
  });
  const db = drizzle({ client: { query } as never, schema });
  return { repository: new BulkRenameRepository(db), calls };
}

describe('bulk rename reviewed ID reads', () => {
  it.skipIf(!process.env.BULK_RENAME_TEST_ENV)('binds selected-read parameters as PostgreSQL integers', async () => {
    const env = parseEnv(readFileSync(process.env.BULK_RENAME_TEST_ENV!, 'utf8'));
    const client = new Client({ connectionString: env.DATABASE_URL });
    const { repository, calls } = selectedBooksRepository();
    await repository.findBooksForLibraryIds(42, [17]);
    await client.connect();
    try {
      for (const parameter of calls[0].params) {
        const result = await client.query('SELECT 1::integer <= $1 AS valid_bound', [parameter]);
        expect(typeof result.rows[0].valid_bound).toBe('boolean');
      }
    } finally {
      await client.end();
    }
  });

  it('reads 251 reviewed IDs in two targeted pages with no oversized integer bound', async () => {
    const ids = Array.from({ length: 251 }, (_, index) => index + 1);
    const { repository, calls } = selectedBooksRepository(ids);
    const first = await repository.findBooksForLibraryIds(42, ids);
    const second = await repository.findBooksForLibraryIds(42, ids.slice(250));
    expect([...first, ...second].map((book) => book.bookId)).toEqual(ids);
    const pages = calls.filter((call) => call.text.includes('from "books"'));
    expect(pages).toHaveLength(2);
    expect(pages[0].params).toEqual([42, 0, ...ids.slice(0, 250), 250]);
    expect(pages[1].params).toEqual([42, 0, 251, 250]);
    for (const page of pages) {
      expect(page.text).toContain('"books"."library_id" =');
      expect(page.text).toContain('"books"."id" in');
      expect(page.text).toContain('order by "books"."id" asc');
      expect(page.text).not.toContain('<=');
    }
  });

  it('skips empty reads and retains only existing sparse reviewed IDs', async () => {
    const { repository, calls } = selectedBooksRepository([7, 11, 90]);
    await expect(repository.findBooksForLibraryIds(42, [])).resolves.toEqual([]);
    expect(calls).toHaveLength(0);
    await expect(repository.findBooksForLibraryIds(42, [99])).resolves.toEqual([]);
    expect(calls).toHaveLength(1);
    const books = await repository.findBooksForLibraryIds(42, [90, 7, 99]);
    expect(books.map((book) => book.bookId)).toEqual([7, 90]);
    expect(calls[1].params).toEqual([42, 0, 90, 7, 99, 250]);
    expect(calls.every((call) => call.text.startsWith('select '))).toBe(true);
    for (const related of calls.slice(2)) expect(related.params).toEqual([7, 90]);
  });
});
