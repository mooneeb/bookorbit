import assert from "node:assert/strict";
import { test } from "node:test";

const base = "http://localhost:16482/api/v1";
async function request(path, { token, body, method = body ? "POST" : "GET" } = {}) {
  return fetch(`${base}/${path}`, {
    method,
    headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(body ? { "Content-Type": "application/json" } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
}
async function login(username) {
  const response = await request("auth/login", {
    body: { username, password: "IpadFixture123", clientKind: "native", deviceLabel: "Organization HTTP fixture" },
  });
  assert.equal(response.status, 200);
  return response.json();
}
async function record(path, token) {
  const response = await request(path, { token });
  assert.equal(response.status, 200, path);
  const bytes = await response.text();
  assert.ok(bytes.length < 150_000, `${path}: bounded response`);
  return JSON.parse(bytes);
}
async function logout(session) {
  assert.equal((await request("auth/logout", { body: { refreshToken: session.refreshToken } })).status, 200);
}

test("IPAD-E01-A01/A05-organization: authorized directories page, search, sort and filter without exposing another library", async () => {
  const reader = await login("ipad-reader");
  const restricted = await login("ipad-restricted");
  try {
    const libraries = await record("libraries", reader.accessToken);
    const library = libraries.find((item) => item.name === "Large library");
    assert.ok(library);
    for (const [route, prefix] of [
      ["authors", "Orbit author"],
      ["series", "Orbit series"],
    ]) {
      const first = await record(`${route}?q=${encodeURIComponent(prefix)}&size=40&page=0&sort=name&order=asc`, reader.accessToken);
      assert.equal(first.total, 55);
      assert.equal(first.size, 40);
      assert.equal(first.page, 0);
      assert.deepEqual(
        first.items.map((item) => item.name),
        Array.from({ length: 40 }, (_, index) => `${prefix} ${String(index).padStart(3, "0")}`),
      );
      const second = await record(`${route}?q=${encodeURIComponent(prefix)}&size=40&page=1&sort=name&order=asc`, reader.accessToken);
      assert.equal(second.total, 55);
      assert.equal(second.page, 1);
      assert.deepEqual(
        second.items.map((item) => item.name),
        Array.from({ length: 15 }, (_, index) => `${prefix} ${String(index + 40).padStart(3, "0")}`),
      );
      const descending = await record(
        `${route}?q=${encodeURIComponent(prefix)}&size=40&page=0&sort=name&order=desc&libraryId=${library.id}`,
        reader.accessToken,
      );
      assert.deepEqual(
        descending.items.map((item) => item.name),
        Array.from({ length: 40 }, (_, index) => `${prefix} ${String(54 - index).padStart(3, "0")}`),
      );
      const hidden = await record(`${route}?size=40&page=0`, restricted.accessToken);
      assert.equal(hidden.total, 0);
      assert.deepEqual(hidden.items, []);
      assert.equal((await request(`${route}?size=40&page=0`)).status, 401);
      for (const query of ["size=101", "size=1.5", "page=-1", "sort=invalid", "order=invalid", "unexpected=true"]) {
        assert.equal((await request(`${route}?${query}`, { token: reader.accessToken })).status, 400, `${route}?${query}`);
      }
    }
    for (const query of ["hasSortName=true", "minBookCount=2", "hasSortName=true&minBookCount=2&hasPhoto=false"]) {
      const result = await record(`authors?q=Orbit%20author&${query}&size=40`, reader.accessToken);
      assert.equal(result.total, 1);
      assert.equal(result.items[0].name, "Orbit author 000");
      assert.equal(result.items[0].bookCount, 45);
    }
    assert.equal((await record("authors?q=Orbit%20author&addedWithinDays=30&size=40", reader.accessToken)).total, 0);
    assert.equal((await record("authors?q=Orbit%20author&hasPhoto=true&size=40", reader.accessToken)).total, 0);
    const gaps = await record("series?q=Orbit%20series&completionStatus=has_gaps&author=Orbit%20author%20000&size=40", reader.accessToken);
    assert.equal(gaps.total, 1);
    assert.equal(gaps.items[0].name, "Orbit series 000");
    assert.equal(gaps.items[0].bookCount, 45);
    assert.equal(gaps.items[0].gapCount, 2);
    assert.deepEqual(gaps.items[0].gaps, [2, 47]);
    assert.equal((await record("series?q=Orbit%20series&completionStatus=complete&size=40", reader.accessToken)).total, 0);
  } finally {
    await logout(reader);
    await logout(restricted);
  }
});

test("IPAD-E01-A01/A05-organization: profiles and forty-book pages lead only to authorized files", async () => {
  const reader = await login("ipad-reader");
  const restricted = await login("ipad-restricted");
  try {
    const author = (await record("authors?q=Orbit%20author%20000&size=40", reader.accessToken)).items[0];
    const series = (await record("series?q=Orbit%20series%20000&size=40", reader.accessToken)).items[0];
    const profile = await record(`authors/${author.id}`, reader.accessToken);
    assert.equal(profile.description, "An author profile for the native organization journey.");
    assert.equal(profile.birthYear, 1975);
    assert.deepEqual(profile.genres, ["Science fiction"]);
    assert.deepEqual(profile.influences, ["Orbit predecessor"]);
    const authorFirst = await record(`authors/${author.id}/books?page=0&size=40&sort=title&order=asc&collapseSeries=false`, reader.accessToken);
    assert.equal(authorFirst.total, 45);
    assert.equal(authorFirst.bookTotal, 45);
    assert.equal(authorFirst.items.length, 40);
    assert.equal(authorFirst.items[0].title, "Library book 00200");
    const authorSecond = await record(`authors/${author.id}/books?page=1&size=40&sort=title&order=asc&collapseSeries=false`, reader.accessToken);
    assert.deepEqual(
      authorSecond.items.map((book) => book.id),
      [241, 242, 243, 244, 1],
    );
    const seriesFirst = await record(`series/${series.id}/books?page=0&size=40&sort=seriesIndex&order=asc`, reader.accessToken);
    assert.equal(seriesFirst.total, 45);
    assert.equal(seriesFirst.items.length, 40);
    assert.equal(seriesFirst.items[0].id, 1);
    assert.equal(seriesFirst.seriesInfo.expectedBookCount, 47);
    assert.deepEqual(seriesFirst.seriesInfo.possibleGaps, [2, 47]);
    const seriesSecond = await record(`series/${series.id}/books?page=1&size=40&sort=seriesIndex&order=asc`, reader.accessToken);
    assert.deepEqual(
      seriesSecond.items.map((book) => book.id),
      [240, 241, 242, 243, 244],
    );
    const detail = await record("books/1", reader.accessToken);
    assert.equal(detail.title, "Orbit fixture");
    assert.equal(detail.files[0].format, "pdf");
    const delivered = await request(`books/files/${detail.files[0].id}/serve`, { token: reader.accessToken });
    assert.equal(delivered.status, 200);
    assert.match(delivered.headers.get("content-type"), /^application\/pdf/);
    assert.equal((await delivered.arrayBuffer()).byteLength, detail.files[0].sizeBytes);
    const hiddenAuthorBooks = await record(`authors/${author.id}/books?size=40`, restricted.accessToken);
    assert.equal(hiddenAuthorBooks.total, 0);
    assert.deepEqual(hiddenAuthorBooks.items, []);
    for (const path of [`authors/${author.id}`, `series/${series.id}/books?size=40`]) {
      const denied = await request(path, { token: restricted.accessToken });
      assert.equal(denied.status, 404, path);
    }
  } finally {
    await logout(reader);
    await logout(restricted);
  }
});
