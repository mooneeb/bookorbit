import { ConflictException } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { getTableColumns } from 'drizzle-orm';
import { drizzle } from 'drizzle-orm/node-postgres';

import { AuthenticationPolicyService } from '../../common/services/authentication-policy.service';
import { DB } from '../../db/db.module';
import * as schema from '../../db/schema';
import { OidcIdentityRepository } from './oidc-identity.repository';

const linkedAt = new Date('2026-01-02T03:04:05Z');
const identity: typeof schema.oidcIdentities.$inferSelect = {
  id: 4,
  userId: 7,
  providerId: 2,
  oidcSubject: 'Subject/ABC',
  oidcIssuer: 'https://id.example/realm/',
  linkedAt,
};
const identityRow = [identity.id, identity.userId, identity.providerId, identity.oidcSubject, identity.oidcIssuer, linkedAt.toISOString()];

describe('OidcIdentityRepository', () => {
  let repository: OidcIdentityRepository;
  let responses: unknown[][][];
  const query = vi.fn<(config: { text: string } | string, params?: unknown[]) => Promise<{ rows: unknown[][] }>>();
  const policy = {
    lockAdministratorAvailability: vi.fn(),
    isPasswordLoginEnabled: vi.fn(),
    hasEnabledOidcIdentityForUser: vi.fn(),
    assertUsableOidcSuperuser: vi.fn(),
  };

  beforeEach(async () => {
    responses = [];
    query.mockReset().mockImplementation((config) => {
      const text = typeof config === 'string' ? config : config.text;
      return Promise.resolve({ rows: ['begin', 'commit', 'rollback'].includes(text) ? [] : (responses.shift() ?? []) });
    });
    policy.lockAdministratorAvailability.mockReset().mockResolvedValue(undefined);
    policy.isPasswordLoginEnabled.mockReset().mockReturnValue(true);
    policy.hasEnabledOidcIdentityForUser.mockReset().mockResolvedValue(true);
    policy.assertUsableOidcSuperuser.mockReset().mockResolvedValue(undefined);
    const db = drizzle({ client: { query } as never, schema });
    const module = await Test.createTestingModule({
      providers: [OidcIdentityRepository, { provide: DB, useValue: db }, { provide: AuthenticationPolicyService, useValue: policy }],
    }).compile();
    repository = module.get(OidcIdentityRepository);
  });

  function captured(index = 0) {
    const [config, params] = query.mock.calls[index];
    return { text: typeof config === 'string' ? config : config.text, params };
  }

  function unlinkResponses(provisioningMethod = 'local') {
    const userValues: Record<string, unknown> = { id: 7, provisioningMethod };
    responses.push([identityRow], [Object.keys(getTableColumns(schema.users)).map((key) => userValues[key] ?? null)]);
  }

  it('finds an identity by its provider and exact opaque subject in a bounded query', async () => {
    responses.push([identityRow]);

    await expect(repository.findByProviderAndSubject(2, 'Subject/ABC')).resolves.toEqual(identity);

    expect(query).toHaveBeenCalledOnce();
    expect(captured().text).toContain('"oidcIdentities"."provider_id" = $1');
    expect(captured().text).toContain('"oidcIdentities"."oidc_subject" = $2');
    expect(captured().text).toContain('limit $3');
    expect(captured().params).toEqual([2, 'Subject/ABC', 1]);
  });

  it('finds an identity by the exact issuer and subject without rewriting either value', async () => {
    responses.push([identityRow]);

    await expect(repository.findByIssuerAndSubject(identity.oidcIssuer, identity.oidcSubject)).resolves.toEqual(identity);

    expect(captured().text).toContain('"oidcIdentities"."oidc_issuer" = $1');
    expect(captured().text).toContain('"oidcIdentities"."oidc_subject" = $2');
    expect(captured().text).toContain('limit $3');
    expect(captured().params).toEqual([identity.oidcIssuer, identity.oidcSubject, 1]);
  });

  it('returns undefined when provider, issuer, or user lookups have no matching identity', async () => {
    await expect(repository.findByProviderAndSubject(2, 'missing')).resolves.toBeUndefined();
    await expect(repository.findByIssuerAndSubject(identity.oidcIssuer, 'missing')).resolves.toBeUndefined();
    await expect(repository.findByUserAndProvider(99, 2)).resolves.toBeUndefined();

    expect(query).toHaveBeenCalledTimes(3);
    expect(captured(2).params).toEqual([99, 2, 1]);
  });

  it('looks up a provider only within the requested user account', async () => {
    responses.push([identityRow]);

    await expect(repository.findByUserAndProvider(7, 2)).resolves.toEqual(identity);

    expect(captured().text).toContain('"oidcIdentities"."user_id" = $1');
    expect(captured().text).toContain('"oidcIdentities"."provider_id" = $2');
    expect(captured().text).toContain('limit $3');
    expect(captured().params).toEqual([7, 2, 1]);
  });

  it('lists linked providers in one user-scoped query with only display and identity fields', async () => {
    responses.push([[4, 2, 'work', 'Work SSO', '/work.svg', identity.oidcSubject, identity.oidcIssuer, linkedAt.toISOString()]]);

    await expect(repository.findByUser(7)).resolves.toEqual([
      {
        id: 4,
        providerId: 2,
        providerSlug: 'work',
        providerName: 'Work SSO',
        providerIconUrl: '/work.svg',
        oidcSubject: identity.oidcSubject,
        oidcIssuer: identity.oidcIssuer,
        linkedAt,
      },
    ]);

    expect(query).toHaveBeenCalledOnce();
    expect(captured().text).toContain('inner join "oidc_providers" on "oidc_identities"."provider_id" = "oidc_providers"."id"');
    expect(captured().text).toContain('where "oidc_identities"."user_id" = $1');
    expect(captured().text).not.toContain('client_secret');
    expect(captured().text).not.toContain('client_id');
    expect(captured().params).toEqual([7]);
  });

  it('returns an empty provider list for an account with no identities', async () => {
    await expect(repository.findByUser(99)).resolves.toEqual([]);
    expect(captured().params).toEqual([99]);
  });

  it('creates an identity with the owning user and returns database-generated fields', async () => {
    responses.push([identityRow]);

    await expect(
      repository.create({ userId: 7, providerId: 2, oidcSubject: identity.oidcSubject, oidcIssuer: identity.oidcIssuer }),
    ).resolves.toEqual(identity);

    expect(query).toHaveBeenCalledOnce();
    expect(captured().text).toContain('insert into "oidc_identities"');
    expect(captured().text).toContain('values (default, $1, $2, $3, $4, default)');
    expect(captured().text).toContain('returning "id", "user_id", "provider_id", "oidc_subject", "oidc_issuer", "linked_at"');
    expect(captured().params).toEqual([7, 2, identity.oidcSubject, identity.oidcIssuer]);
  });

  it('unlinks only the requested user and provider while preserving local password access', async () => {
    unlinkResponses();

    await expect(repository.remove(7, 2)).resolves.toEqual(identity);

    expect(captured(0).text).toBe('begin');
    expect(captured(1).text).toContain(
      'delete from "oidc_identities" where ("oidc_identities"."user_id" = $1 and "oidc_identities"."provider_id" = $2)',
    );
    expect(captured(1).params).toEqual([7, 2]);
    expect(captured(2).text).toContain('"users"."id" = $1');
    expect(captured(2).params).toEqual([7, 1]);
    expect(captured(3).text).toBe('commit');
    expect(policy.lockAdministratorAvailability).toHaveBeenCalledOnce();
    expect(policy.hasEnabledOidcIdentityForUser).not.toHaveBeenCalled();
    expect(policy.assertUsableOidcSuperuser).toHaveBeenCalledOnce();
  });

  it('returns null when a provider belongs to another account and skips account policy checks', async () => {
    await expect(repository.remove(99, 2)).resolves.toBeNull();

    expect(query).toHaveBeenCalledTimes(3);
    expect(captured(1).text).toContain('"oidc_identities"."user_id" = $1 and "oidc_identities"."provider_id" = $2');
    expect(captured(1).params).toEqual([99, 2]);
    expect(captured(2).text).toBe('commit');
    expect(policy.isPasswordLoginEnabled).not.toHaveBeenCalled();
    expect(policy.assertUsableOidcSuperuser).not.toHaveBeenCalled();
  });

  it('rolls back unlinking the final enabled sign-in method in SSO-only mode', async () => {
    unlinkResponses();
    policy.isPasswordLoginEnabled.mockReturnValue(false);
    policy.hasEnabledOidcIdentityForUser.mockResolvedValue(false);

    await expect(repository.remove(7, 2)).rejects.toThrow(ConflictException);

    expect(captured(3).text).toBe('rollback');
    expect(policy.hasEnabledOidcIdentityForUser).toHaveBeenCalledWith(expect.anything(), 7);
    expect(policy.assertUsableOidcSuperuser).not.toHaveBeenCalled();
  });

  it('commits unlinking when another enabled identity remains and rechecks administrator availability', async () => {
    unlinkResponses();
    policy.isPasswordLoginEnabled.mockReturnValue(false);

    await expect(repository.remove(7, 2)).resolves.toEqual(identity);

    expect(captured(3).text).toBe('commit');
    expect(policy.hasEnabledOidcIdentityForUser).toHaveBeenCalledWith(expect.anything(), 7);
    expect(policy.assertUsableOidcSuperuser).toHaveBeenCalledOnce();
  });

  it('protects an OIDC-provisioned account from losing its final identity even when passwords are enabled', async () => {
    unlinkResponses('oidc');
    policy.hasEnabledOidcIdentityForUser.mockResolvedValue(false);

    await expect(repository.remove(7, 2)).rejects.toThrow('Cannot unlink the last enabled sign-in provider for this account');

    expect(captured(3).text).toBe('rollback');
  });

  it('deletes every identity only for the requested user', async () => {
    await expect(repository.removeAllForUser(7)).resolves.toBeUndefined();

    expect(query).toHaveBeenCalledOnce();
    expect(captured().text).toBe('delete from "oidc_identities" where "oidc_identities"."user_id" = $1');
    expect(captured().params).toEqual([7]);
  });

  it('counts the requested account identities using only their ids and returns zero for an empty account', async () => {
    responses.push([[4], [5]], []);

    await expect(repository.countByUser(7)).resolves.toBe(2);
    await expect(repository.countByUser(99)).resolves.toBe(0);

    expect(captured().text).toBe('select "id" from "oidc_identities" where "oidc_identities"."user_id" = $1');
    expect(captured().params).toEqual([7]);
    expect(captured(1).params).toEqual([99]);
  });
});
