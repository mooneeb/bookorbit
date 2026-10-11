import { Test } from '@nestjs/testing';
import { getTableColumns } from 'drizzle-orm';
import { drizzle } from 'drizzle-orm/node-postgres';
import { DB } from '../../db/db.module';
import * as schema from '../../db/schema';
import { AuthSessionRepository } from './auth-session.repository';

const now = new Date('2026-09-12T12:00:00Z');
const expiresAt = new Date(now.getTime() + 60_000);
const session = { id: 7, userId: 2, tokenVersion: 3, authenticationMethod: 'password', clientKind: 'native', revokedAt: null, expiresAt };
const token = {
  id: 10,
  sessionId: 7,
  userId: 2,
  tokenHash: 'old',
  authenticationMethod: 'password',
  revokedAt: null,
  rotatedAt: null,
  replacedByTokenHash: null,
  expiresAt,
};
const params = { sessionId: 7, userId: 2, tokenVersion: 3, tokenHashes: ['old', 'next', 'latest'], expiresAt, now, graceMs: 30_000 };

async function fixture(options: { session?: object | null; user?: object | null; tokens?: object[] } = {}) {
  const results = [
    options.user === null ? [] : [options.user ?? { active: true, tokenVersion: 3 }],
    options.session === null ? [] : [options.session ?? session],
    options.tokens ?? [token],
  ];
  const writes: { table: unknown; value: unknown }[] = [];
  const tx = {
    select: vi.fn(() => {
      const result = results.shift();
      const query = {
        from: vi.fn().mockReturnThis(),
        where: vi.fn().mockReturnThis(),
        for: vi.fn().mockResolvedValue(result),
        then: (resolve: (value: unknown) => unknown) => Promise.resolve(result).then(resolve),
      };
      return query;
    }),
    update: vi.fn((table: unknown) => ({
      set: (value: unknown) => {
        writes.push({ table, value });
        return { where: vi.fn().mockResolvedValue({ rowCount: 1 }) };
      },
    })),
    insert: vi.fn((table: unknown) => ({
      values: (value: object) => {
        writes.push({ table, value });
        return { returning: vi.fn().mockResolvedValue([{ id: 11, ...value }]) };
      },
    })),
  };
  const db = { transaction: vi.fn((callback: (transaction: typeof tx) => unknown) => Promise.resolve(callback(tx))) };
  const module = await Test.createTestingModule({ providers: [AuthSessionRepository, { provide: DB, useValue: db }] }).compile();
  return { repository: module.get(AuthSessionRepository), tx, writes };
}

describe('AuthSessionRepository refresh transactions', () => {
  it('rotates once, keeps the session identity, and updates only the related OIDC lifetime', async () => {
    const { repository, writes } = await fixture();
    const result = await repository.exchange(params);
    expect(result).toMatchObject({ session: { id: 7 }, refresh: { tokenHash: 'next', sessionId: 7 }, tokenIndex: 1 });
    expect(writes).toContainEqual({ table: schema.refreshTokens, value: { revokedAt: now, rotatedAt: now, replacedByTokenHash: 'next' } });
    expect(writes).toContainEqual({ table: schema.authSessions, value: { expiresAt } });
    expect(writes).toContainEqual({ table: schema.users, value: expect.objectContaining({ lastAuthenticatedAt: now }) });
  });

  it('recovers an already committed replacement without another write', async () => {
    const { repository, writes } = await fixture({
      tokens: [
        { ...token, revokedAt: now, rotatedAt: now, replacedByTokenHash: 'next' },
        { ...token, id: 11, tokenHash: 'next' },
      ],
    });
    expect(await repository.exchange(params)).toMatchObject({ tokenIndex: 1, refresh: { tokenHash: 'next' } });
    expect(writes).toEqual([]);
  });

  it('recovers a bounded chain after another caller has already rotated the replacement', async () => {
    const { repository, writes } = await fixture({
      tokens: [
        { ...token, revokedAt: now, rotatedAt: now, replacedByTokenHash: 'next' },
        { ...token, id: 11, tokenHash: 'next', revokedAt: now, rotatedAt: now, replacedByTokenHash: 'latest' },
        { ...token, id: 12, tokenHash: 'latest' },
      ],
    });
    expect(await repository.exchange(params)).toMatchObject({ tokenIndex: 2 });
    expect(writes).toEqual([]);
  });

  it.each([
    ['expired grace', { revokedAt: now, rotatedAt: new Date(now.getTime() - 30_001), replacedByTokenHash: 'next' }],
    ['explicit revocation', { revokedAt: now }],
    ['future rotation', { revokedAt: now, rotatedAt: new Date(now.getTime() + 1), replacedByTokenHash: 'next' }],
    ['broken successor', { revokedAt: now, rotatedAt: now, replacedByTokenHash: 'different' }],
  ])('revokes only the affected family after %s', async (_name, changes) => {
    const { repository, writes, tx } = await fixture({
      tokens: [
        { ...token, ...changes },
        { ...token, tokenHash: 'next' },
      ],
    });
    expect(await repository.exchange(params)).toBeNull();
    expect(writes).toContainEqual({ table: schema.authSessions, value: { revokedAt: now } });
    expect(tx.update).not.toHaveBeenCalledWith(schema.users);
  });

  it.each([
    { session: null },
    { session: { ...session, revokedAt: now } },
    { session: { ...session, expiresAt: now } },
    { session: { ...session, tokenVersion: 2 } },
    { user: null },
    { user: { active: false, tokenVersion: 3 } },
    { user: { active: true, tokenVersion: 4 } },
    { tokens: [] },
    { tokens: [{ ...token, expiresAt: now }] },
  ])('refuses an invalid session/account/token without minting or mutating credentials: %j', async (options) => {
    const { repository, writes } = await fixture(options);
    expect(await repository.exchange(params)).toBeNull();
    expect(writes).toEqual([]);
  });

  it('cannot recover through a successor explicitly revoked after rotation', async () => {
    const { repository, writes } = await fixture({
      tokens: [
        { ...token, revokedAt: now, rotatedAt: now, replacedByTokenHash: 'next' },
        { ...token, tokenHash: 'next', revokedAt: now },
      ],
    });
    expect(await repository.exchange(params)).toBeNull();
    expect(writes.some((write) => write.table === schema.users)).toBe(false);
  });
});

const storedSession: typeof schema.authSessions.$inferSelect = {
  ...session,
  deviceLabel: 'Moon tablet',
  createdAt: now,
};
const storedRefresh: typeof schema.refreshTokens.$inferSelect = { ...token, createdAt: now };

function databaseRow<T extends object>(row: T, columns: Record<keyof T, unknown>) {
  return Object.keys(columns).map((key) => {
    const value = row[key as keyof T];
    return value instanceof Date ? value.toISOString() : value;
  });
}

async function sqlFixture(responses: unknown[][][] = []) {
  const calls: { text: string; values: unknown[] }[] = [];
  const query = vi.fn((statement: string | { text: string }, values: unknown[] = []) => {
    const text = typeof statement === 'string' ? statement : statement.text;
    calls.push({ text, values });
    if (['begin', 'commit', 'rollback'].includes(text)) return Promise.resolve({ rows: [], rowCount: 0 });
    const rows = responses.shift() ?? [];
    return Promise.resolve({ rows, rowCount: rows.length });
  });
  const db = drizzle({ client: { query } as never, schema });
  const module = await Test.createTestingModule({ providers: [AuthSessionRepository, { provide: DB, useValue: db }] }).compile();
  const statements = () => calls;
  return { repository: module.get(AuthSessionRepository), query, statements };
}

describe('AuthSessionRepository SQL boundaries', () => {
  beforeEach(() => vi.useFakeTimers({ toFake: ['Date'] }).setSystemTime(now));
  afterEach(() => vi.useRealTimers());

  it('atomically creates a named native session and refresh credential for the locked account', async () => {
    const { repository, statements } = await sqlFixture([[[true, 3]], [databaseRow(storedSession, getTableColumns(schema.authSessions))]]);
    const input: typeof schema.authSessions.$inferInsert = {
      userId: 2,
      tokenVersion: 3,
      authenticationMethod: 'password',
      clientKind: 'native',
      deviceLabel: 'Moon tablet',
      expiresAt,
    };
    expect(await repository.create(input, 'credential-hash')).toEqual(storedSession);
    const calls = statements();
    expect(calls.map(({ text }) => (text === 'begin' || text === 'commit' ? text : text.split(' ')[0]))).toEqual([
      'begin',
      'select',
      'insert',
      'insert',
      'update',
      'commit',
    ]);
    expect(calls[1].text).toContain('where "users"."id" = $1 for update');
    expect(calls[1].values).toEqual([2]);
    expect(calls[2].text).toContain('insert into "auth_sessions"');
    expect(calls[2].values).toEqual([2, 3, 'password', 'native', 'Moon tablet', expiresAt.toISOString()]);
    expect(calls[3].text).toContain('insert into "refresh_tokens"');
    expect(calls[3].values).toEqual([2, 7, 'credential-hash', 'password', expiresAt.toISOString()]);
    expect(calls[4].text).toContain('where "users"."id" = $3');
    expect(calls[4].values).toEqual([now.toISOString(), now.toISOString(), 2]);
  });

  it('links provider metadata to the created session and its account and expiry', async () => {
    const oidcSession = { ...storedSession, authenticationMethod: 'oidc' };
    const { repository, statements } = await sqlFixture([[[true, 3]], [databaseRow(oidcSession, getTableColumns(schema.authSessions))]]);
    expect(
      await repository.create(oidcSession, 'oidc-hash', {
        providerId: 9,
        oidcSubject: 'subject-2',
        oidcIssuer: 'https://identity.example',
        oidcSessionId: 'provider-session',
        idTokenHint: 'id-token-hint',
        idpRefreshToken: 'provider-refresh',
      }),
    ).toEqual(oidcSession);
    const insert = statements().find(({ text }) => text.startsWith('insert into "oidc_sessions"'))!;
    expect(insert.text).toContain('"user_id", "session_id", "provider_id", "oidc_subject", "oidc_issuer", "oidc_session_id"');
    expect(insert.values).toEqual([
      2,
      7,
      9,
      'subject-2',
      'https://identity.example',
      'provider-session',
      'id-token-hint',
      'provider-refresh',
      expiresAt.toISOString(),
    ]);
    expect(statements().at(-1)?.text).toBe('commit');
  });

  it.each([{ rows: [] }, { rows: [[false, 3]] }, { rows: [[true, 4]] }])(
    'does not issue credentials for a missing, inactive, or changed account: %j',
    async ({ rows }) => {
      const { repository, statements } = await sqlFixture([rows]);
      expect(await repository.create(storedSession, 'unused-hash')).toBeNull();
      expect(statements().map(({ text }) => text.split(' ')[0])).toEqual(['begin', 'select', 'commit']);
      expect(statements()[1].values).toEqual([2]);
    },
  );

  it('rolls back session creation if writing its refresh credential fails', async () => {
    const { repository, query, statements } = await sqlFixture([[[true, 3]], [databaseRow(storedSession, getTableColumns(schema.authSessions))]]);
    const transport = query.getMockImplementation()!;
    query.mockImplementation(async (statement, values) => {
      const text = typeof statement === 'string' ? statement : statement.text;
      if (text.startsWith('insert into "refresh_tokens"')) throw new Error('refresh insert failed');
      return transport(statement, values);
    });
    await expect(repository.create(storedSession, 'hash')).rejects.toThrow();
    expect(statements().at(-1)?.text).toBe('rollback');
    expect(statements().some(({ text }) => text.startsWith('update "users"'))).toBe(false);
  });

  it('looks up individual sessions and hashed refresh credentials with bounded queries', async () => {
    const { repository, statements } = await sqlFixture([
      [databaseRow(storedSession, getTableColumns(schema.authSessions))],
      [databaseRow(storedRefresh, getTableColumns(schema.refreshTokens))],
      [],
      [],
    ]);
    expect(await repository.findSession(7)).toEqual(storedSession);
    expect(await repository.findRefresh('old')).toEqual(storedRefresh);
    expect(await repository.findSession(404)).toBeUndefined();
    expect(await repository.findRefresh('missing')).toBeUndefined();
    const calls = statements();
    expect(calls[0].text).toContain('"authSessions"."id" = $1 limit $2');
    expect(calls[0].values).toEqual([7, 1]);
    expect(calls[1].text).toContain('"refreshTokens"."token_hash" = $1 limit $2');
    expect(calls[1].values).toEqual(['old', 1]);
    expect(calls[2].values).toEqual([404, 1]);
    expect(calls[3].values).toEqual(['missing', 1]);
  });

  it.each([{ rows: [[7]] }, { rows: [] }])(
    'requires ownership, version, method, non-revocation, and strict expiry for activity: %j',
    async ({ rows }) => {
      const { repository, statements } = await sqlFixture([rows]);
      expect(await repository.isActive(7, 2, 3, 'password')).toBe(rows.length > 0);
      const [call] = statements();
      expect(call.text).toContain('"auth_sessions"."id" = $1');
      expect(call.text).toContain('"auth_sessions"."user_id" = $2');
      expect(call.text).toContain('"auth_sessions"."token_version" = $3');
      expect(call.text).toContain('"auth_sessions"."authentication_method" = $4');
      expect(call.text).toContain('"auth_sessions"."revoked_at" is null');
      expect(call.text).toContain('"auth_sessions"."expires_at" > $5');
      expect(call.values).toEqual([7, 2, 3, 'password', now.toISOString(), 1]);
    },
  );

  it('revokes the owner session and only its active refresh and provider credentials in one transaction', async () => {
    const { repository, statements } = await sqlFixture([[[7]]]);
    await repository.revoke(7, 2);
    const calls = statements();
    expect(calls[0].text).toBe('begin');
    expect(calls[1].text).toContain('where ("auth_sessions"."id" = $2 and "auth_sessions"."user_id" = $3)');
    expect(calls[1].values).toEqual([now.toISOString(), 7, 2]);
    expect(calls[2].text).toContain('where ("refresh_tokens"."session_id" = $2 and "refresh_tokens"."revoked_at" is null)');
    expect(calls[2].values).toEqual([now.toISOString(), 7]);
    expect(calls[3].text).toContain('where "oidc_sessions"."session_id" = $2');
    expect(calls[3].values).toEqual([true, 7]);
    expect(calls[4].text).toBe('commit');
  });

  it('does not mutate another account credentials when the owner session update returns no row', async () => {
    const { repository, statements } = await sqlFixture([[]]);
    await repository.revoke(7, 99);
    expect(statements().map(({ text }) => text.split(' ')[0])).toEqual(['begin', 'update', 'commit']);
    expect(statements()[1].text).toContain('"auth_sessions"."user_id" = $3');
    expect(statements()[1].values).toEqual([now.toISOString(), 7, 99]);
  });

  it.each([{ rows: [[7, 'native', 'Moon tablet', 'password', now.toISOString(), expiresAt.toISOString()]] }, { rows: [] }])(
    'lists at most 100 current owner sessions using safe display fields: %j',
    async ({ rows }) => {
      const { repository, statements } = await sqlFixture([rows]);
      expect(await repository.list(2)).toEqual(
        rows.length
          ? [
              {
                id: 7,
                clientKind: 'native',
                deviceLabel: 'Moon tablet',
                authenticationMethod: 'password',
                createdAt: now,
                expiresAt,
              },
            ]
          : [],
      );
      const [call] = statements();
      expect(call.text).toContain('inner join "users" on "users"."id" = "auth_sessions"."user_id"');
      expect(call.text).toContain('"auth_sessions"."user_id" = $1');
      expect(call.text).toContain('"auth_sessions"."revoked_at" is null');
      expect(call.text).toContain('"auth_sessions"."expires_at" > $2');
      expect(call.text).toContain('"auth_sessions"."token_version" = "users"."token_version"');
      expect(call.text).toContain('order by "auth_sessions"."id" desc limit $3');
      expect(call.text).not.toContain('token_hash');
      expect(call.values).toEqual([2, now.toISOString(), 100]);
    },
  );
});
