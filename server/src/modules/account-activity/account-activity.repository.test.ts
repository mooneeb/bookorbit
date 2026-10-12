import { Test } from '@nestjs/testing';
import { drizzle } from 'drizzle-orm/node-postgres';

import { DB } from '../../db';
import * as schema from '../../db/schema';
import { AccountActivityRepository, type AccountActivityListQuery } from './account-activity.repository';

const recentCutoff = new Date('2026-09-12T00:00:00.000Z');
const listQuery: AccountActivityListQuery = {
  page: 3,
  pageSize: 25,
  sortBy: 'lastAuthenticatedAt',
  sortDir: 'desc',
  recentCutoff,
};

async function fixture(...results: unknown[][][]) {
  const query = vi.fn<(config: { text: string }, params: unknown[]) => Promise<{ rows: unknown[][] }>>();
  for (const rows of results) query.mockResolvedValueOnce({ rows });
  query.mockResolvedValue({ rows: [] });
  const db = drizzle({ client: { query } as never, schema });
  const module = await Test.createTestingModule({ providers: [AccountActivityRepository, { provide: DB, useValue: db }] }).compile();
  return { repository: module.get(AccountActivityRepository), query };
}

describe('AccountActivityRepository', () => {
  it('returns bounded account pages with mapped timestamps and a numeric total', async () => {
    const createdAt = '2026-01-01T00:00:00.000Z';
    const lastAuthenticatedAt = '2026-10-01T12:00:00.000Z';
    const { repository, query } = await fixture(
      [[41, 'reader', 'Reader', true, false, 'local', createdAt, null, lastAuthenticatedAt, 'private']],
      [['275']],
    );

    await expect(repository.list(listQuery)).resolves.toEqual({
      items: [
        {
          id: 41,
          username: 'reader',
          name: 'Reader',
          active: true,
          isSuperuser: false,
          provisioningMethod: 'local',
          createdAt: new Date(createdAt),
          lastLoginAt: null,
          lastAuthenticatedAt: new Date(lastAuthenticatedAt),
          readingInsightsSharingLevel: 'private',
        },
      ],
      total: 275,
    });
    const [[page, params], [count]] = query.mock.calls;
    expect(params).toEqual([25, 50]);
    expect(page.text).toContain('limit $1 offset $2');
    expect(page.text).toContain('order by "users"."last_authenticated_at" desc nulls last, "users"."username" asc');
    expect(count.text).toBe('select count(*) from "users"');
    for (const sensitiveColumn of ['email', 'password_hash', 'oidc_subject', 'kobo_token']) {
      expect(page.text).not.toContain(`"${sensitiveColumn}"`);
    }
    expect(query).toHaveBeenCalledTimes(2);
  });

  it('returns an empty page and omits blank search predicates', async () => {
    const { repository, query } = await fixture([], [[0]]);

    await expect(repository.list({ ...listQuery, page: 1, search: '   ' })).resolves.toEqual({ items: [], total: 0 });
    expect(query.mock.calls[0][0].text).not.toContain('where');
    expect(query.mock.calls[0][1]).toEqual([25]);
    expect(query.mock.calls[1][1]).toEqual([]);
  });

  it('escapes search wildcards and applies provisioning filters to both page and count', async () => {
    const { repository, query } = await fixture([], [[0]]);

    await repository.list({ ...listQuery, search: '  A%B_C\\D  ', provisioningMethod: 'oidc' });

    const pattern = '%A\\%B\\_C\\\\D%';
    for (const [statement, params] of query.mock.calls) {
      expect(statement.text).toContain('("users"."name" ilike $1 or "users"."username" ilike $2)');
      expect(statement.text).toContain('"users"."provisioning_method" = $3');
      expect(params.slice(0, 3)).toEqual([pattern, pattern, 'oidc']);
      expect(statement.text).not.toContain('A%B_C');
    }
    expect(query.mock.calls[0][1]).toEqual([pattern, pattern, 'oidc', 25, 50]);
    expect(query.mock.calls[1][1]).toEqual([pattern, pattern, 'oidc']);
  });

  it.each([
    { state: 'disabled' as const, predicate: '"users"."active" = $1', params: [false] },
    { state: 'never' as const, predicate: '("users"."active" = $1 and "users"."last_authenticated_at" is null)', params: [true] },
    {
      state: 'recent' as const,
      predicate: '("users"."active" = $1 and "users"."last_authenticated_at" >= $2)',
      params: [true, recentCutoff.toISOString()],
    },
    {
      state: 'dormant' as const,
      predicate: '("users"."active" = $1 and "users"."last_authenticated_at" < $2)',
      params: [true, recentCutoff.toISOString()],
    },
  ])('uses the $state activity boundary consistently for page and total', async ({ state, predicate, params }) => {
    const { repository, query } = await fixture([], [[0]]);

    await repository.list({ ...listQuery, state });

    for (const [statement, values] of query.mock.calls) {
      expect(statement.text).toContain(`where ${predicate}`);
      expect(values.slice(0, params.length)).toEqual(params);
    }
    expect(query.mock.calls[1][1]).toEqual(params);
    expect(query.mock.calls[0][1]).toEqual([...params, 25, 50]);
  });

  it.each([
    ['name', 'name'],
    ['createdAt', 'created_at'],
    ['lastLoginAt', 'last_login_at'],
    ['lastAuthenticatedAt', 'last_authenticated_at'],
  ] as const)('sorts by %s with nulls last and a stable username tie breaker', async (sortBy, column) => {
    const { repository, query } = await fixture([], [[0]]);

    await repository.list({ ...listQuery, sortBy, sortDir: 'asc' });

    expect(query.mock.calls[0][0].text).toContain(`order by "users"."${column}" asc nulls last, "users"."username" asc`);
    expect(query.mock.calls[1][0].text).not.toContain('order by');
  });

  it('summarizes mutually exclusive activity states in one aggregate query', async () => {
    const { repository, query } = await fixture([[4, 3, 2, 1]]);

    await expect(repository.summary(recentCutoff)).resolves.toEqual({ recent: 4, dormant: 3, never: 2, disabled: 1 });

    expect(query).toHaveBeenCalledTimes(1);
    const [statement, params] = query.mock.calls[0];
    expect(params).toEqual([recentCutoff, recentCutoff]);
    expect(statement.text).toContain('count(*) filter (where "active" = true and "last_authenticated_at" >= $1)::int');
    expect(statement.text).toContain('count(*) filter (where "active" = true and "last_authenticated_at" < $2)::int');
    expect(statement.text).toContain('count(*) filter (where "active" = true and "last_authenticated_at" is null)::int');
    expect(statement.text).toContain('count(*) filter (where "active" = false)::int');
  });

  it('returns zero summary counts when no aggregate row is returned', async () => {
    const { repository } = await fixture([]);

    await expect(repository.summary(recentCutoff)).resolves.toEqual({ recent: 0, dormant: 0, never: 0, disabled: 0 });
  });

  it('limits account detail lookup to the requested ID and excludes credentials', async () => {
    const createdAt = '2026-01-01T00:00:00.000Z';
    const { repository, query } = await fixture([
      [41, 'reader', 'Reader', 'reader@example.com', true, false, 'local', createdAt, null, null, 'private'],
    ]);

    await expect(repository.findById(41)).resolves.toEqual({
      id: 41,
      username: 'reader',
      name: 'Reader',
      email: 'reader@example.com',
      active: true,
      isSuperuser: false,
      provisioningMethod: 'local',
      createdAt: new Date(createdAt),
      lastLoginAt: null,
      lastAuthenticatedAt: null,
      readingInsightsSharingLevel: 'private',
    });
    const [statement, params] = query.mock.calls[0];
    expect(statement.text).toContain('where "users"."id" = $1 limit $2');
    expect(params).toEqual([41, 1]);
    expect(statement.text).toContain('"email"');
    expect(statement.text).not.toContain('"password_hash"');
    expect(statement.text).not.toContain('"oidc_subject"');
  });

  it('returns undefined for a missing account', async () => {
    const { repository } = await fixture([]);

    await expect(repository.findById(404)).resolves.toBeUndefined();
  });
});
