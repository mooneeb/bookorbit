import { createServer } from 'node:http';
import { createHash, randomUUID } from 'node:crypto';
import { exportJWK, generateKeyPair, SignJWT } from 'jose';

export const FIXTURE_ISSUER = 'http://localhost:16483';
export const FIXTURE_CLIENT_ID = 'ipad-test-client';

export async function startOidcProvider() {
  const { publicKey, privateKey } = await generateKeyPair('RS256');
  const jwk = { ...(await exportJWK(publicKey)), kid: 'ipad-fixture', alg: 'RS256', use: 'sig' };
  const codes = new Map<string, { nonce: string; challenge: string; redirectUri: string }>();
  const server = createServer((request, response) => {
    void (async () => {
      const url = new URL(request.url ?? '/', FIXTURE_ISSUER);
      if (url.pathname === '/.well-known/openid-configuration') {
        response.setHeader('Content-Type', 'application/json');
        response.end(
          JSON.stringify({
            issuer: FIXTURE_ISSUER,
            authorization_endpoint: `${FIXTURE_ISSUER}/authorize`,
            token_endpoint: `${FIXTURE_ISSUER}/token`,
            jwks_uri: `${FIXTURE_ISSUER}/jwks`,
          }),
        );
      } else if (url.pathname === '/jwks') {
        response.setHeader('Content-Type', 'application/json');
        response.end(JSON.stringify({ keys: [jwk] }));
      } else if (url.pathname === '/authorize') {
        const code = randomUUID();
        const redirectUri = url.searchParams.get('redirect_uri') ?? '';
        if (!['bookorbit://oauth2-callback', 'bookorbit-private://oauth2-callback', 'http://localhost:16484/oauth2-callback'].includes(redirectUri)) {
          response.writeHead(400).end();
          return;
        }
        codes.set(code, { nonce: url.searchParams.get('nonce') ?? '', challenge: url.searchParams.get('code_challenge') ?? '', redirectUri });
        const callback = new URL(redirectUri);
        callback.searchParams.set('code', code);
        callback.searchParams.set('state', url.searchParams.get('state') ?? '');
        response.writeHead(302, { Location: callback.toString() }).end();
      } else if (url.pathname === '/token' && request.method === 'POST') {
        let body = '';
        for await (const chunk of request) {
          body += chunk.toString();
          if (body.length > 8192) {
            response.writeHead(413).end();
            return;
          }
        }
        const params = new URLSearchParams(body);
        const code = params.get('code') ?? '';
        const authorization = codes.get(code);
        codes.delete(code);
        const challenge = createHash('sha256')
          .update(params.get('code_verifier') ?? '')
          .digest('base64url');
        if (
          !authorization ||
          challenge !== authorization.challenge ||
          params.get('redirect_uri') !== authorization.redirectUri ||
          params.get('client_id') !== FIXTURE_CLIENT_ID
        ) {
          response.writeHead(400).end();
          return;
        }
        const idToken = await new SignJWT({ nonce: authorization.nonce, preferred_username: 'ipad-owner', name: 'iPad Owner' })
          .setProtectedHeader({ alg: 'RS256', kid: 'ipad-fixture' })
          .setIssuer(FIXTURE_ISSUER)
          .setAudience(FIXTURE_CLIENT_ID)
          .setSubject('ipad-owner-subject')
          .setIssuedAt()
          .setExpirationTime('5m')
          .sign(privateKey);
        response.setHeader('Content-Type', 'application/json');
        response.end(JSON.stringify({ access_token: 'external-fixture-access-token', id_token: idToken }));
      } else {
        response.writeHead(404).end();
      }
    })().catch(() => response.writeHead(500).end());
  });
  await new Promise<void>((resolve, reject) => {
    server.once('error', reject);
    server.listen(16483, '127.0.0.1', resolve);
  });
  return server;
}
