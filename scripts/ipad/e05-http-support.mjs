import assert from "node:assert/strict";

export let base = process.env.IPAD_BASE_URL ?? "http://localhost:16482/api/v1";
export function setBaseURL(value) {
  base = value;
}
const sessions = new Map();

export async function request(path, token, method = "GET", body) {
  return fetch(`${base}/${path}`, {
    method,
    headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(body === undefined ? {} : { "Content-Type": "application/json" }) },
    body: body === undefined ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(20_000),
  });
}

export async function json(path, token, method = "GET", body, expected = 200) {
  const response = await request(path, token, method, body);
  assert.equal(response.status, expected, `${method} ${path}: ${await response.clone().text()}`);
  return expected === 204 ? undefined : response.json();
}

export async function login(username = "ipad-owner", { fresh = false, deviceLabel = "E05 HTTP acceptance" } = {}) {
  if (!fresh && sessions.has(username)) return sessions.get(username);
  const session = await json("auth/login", undefined, "POST", {
    username,
    password: process.env.IPAD_FIXTURE_PASSWORD ?? "IpadFixture123",
    clientKind: "native",
    deviceLabel,
  });
  assert.ok(session.accessToken && session.refreshToken);
  if (!fresh) sessions.set(username, session);
  return session;
}
