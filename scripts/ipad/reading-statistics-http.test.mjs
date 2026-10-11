import assert from "node:assert/strict";
import { test } from "node:test";

const base = process.env.IPAD_E04_API_URL ?? "http://127.0.0.1:16502/api/v1";
const endpoint = new URL(base);
if (!["localhost", "127.0.0.1"].includes(endpoint.hostname) || endpoint.pathname !== "/api/v1") {
  throw new Error("Reading statistics tests require an isolated localhost BookOrbit fixture");
}

async function request(path, { token, method = "GET", body } = {}) {
  return fetch(`${base}/${path}`, {
    method,
    headers: {
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...(body ? { "Content-Type": "application/json" } : {}),
    },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
}

async function login(username) {
  const response = await request("auth/login", {
    method: "POST",
    body: { username, password: "IpadFixture123", clientKind: "native", deviceLabel: "Reading statistics acceptance" },
  });
  assert.equal(response.status, 200);
  return response.json();
}

async function json(path, token) {
  const response = await request(path, { token });
  assert.equal(response.status, 200, path);
  const bytes = await response.text();
  assert.ok(Buffer.byteLength(bytes) < 512 * 1024, `${path} response stays bounded`);
  return JSON.parse(bytes);
}

async function logout(session) {
  assert.equal((await request("auth/logout", { method: "POST", body: { refreshToken: session.refreshToken } })).status, 200);
}

test("IPAD-E04-A01-statistics: real saved sessions feed duration, native attribution, completion and earned achievements", async () => {
  const session = await login("ipad-e04-statistics");
  try {
    const activity = await json("user-statistics/activity-overview", session.accessToken);
    assert.equal(activity.timezone, "UTC");
    assert.deepEqual(activity.snapshot.lastSevenDays, { totalSeconds: 900, readingSeconds: 600, listeningSeconds: 300 });
    assert.equal(activity.rhythm.sessionsCount, 2);
    assert.equal(activity.snapshot.completedBooksYtd, 1);
    assert.equal(activity.goal.completedBooks, 1);
    assert.deepEqual(activity.sources.slices, [{ bucket: "ios", totalSeconds: 900 }]);
    assert.equal(activity.sources.totals.totalSeconds, 900);
    assert.equal(
      activity.dailyActivity.days.reduce((sum, day) => sum + day.totalSeconds, 0),
      900,
    );
    assert.equal(activity.dailyActivity.days.length, 84);
    assert.ok(activity.calendar.days.length >= 365 && activity.calendar.days.length <= 366);
    assert.equal(activity.goal.points.length, 12);
    assert.equal(activity.rhythm.hours.length, 24);
    assert.equal(activity.rhythm.weekdays.length, 7);
    const catalogue = await json("achievements", session.accessToken);
    const firstCompletion = catalogue.categories.flatMap((category) => category.achievements).find((item) => item.key === "books_finished_1");
    assert.ok(firstCompletion);
    assert.equal(firstCompletion.earned, true);
    assert.ok(firstCompletion.awardedAt);
    const repeated = await json("user-statistics/activity-overview", session.accessToken);
    assert.deepEqual(repeated.snapshot.lastSevenDays, activity.snapshot.lastSevenDays);
    assert.equal(repeated.rhythm.sessionsCount, 2);
    assert.equal((await request("user-statistics/activity-overview?unexpected=true", { token: session.accessToken })).status, 400);
  } finally {
    await logout(session);
  }
});

test("IPAD-E04-A01-goal: preference changes refresh cached goal and achievement availability immediately without changing activity", async () => {
  const session = await login("ipad-e04-statistics");
  const original = (await json("auth/me", session.accessToken)).settings;
  const originalConfig = original.dashboardConfig ?? {};
  const originalAchievements = original.achievementPreferences ?? { enabled: true };
  async function save(dashboardConfig, achievementPreferences) {
    const result = await request("users/me/settings", {
      token: session.accessToken,
      method: "PATCH",
      body: { settings: { dashboardConfig, achievementPreferences } },
    });
    assert.equal(result.status, 200);
  }
  try {
    const before = await json("user-statistics/activity-overview", session.accessToken);
    const goalBooks = before.goal.goalBooks === 24 ? 36 : 24;
    await save({ ...originalConfig, readingGoal: goalBooks }, { ...originalAchievements, enabled: false });
    const updated = await json("user-statistics/activity-overview", session.accessToken);
    assert.equal(updated.goal.goalBooks, goalBooks);
    assert.equal(updated.achievementsEnabled, false);
    assert.deepEqual(updated.snapshot.lastSevenDays, before.snapshot.lastSevenDays);
    assert.equal(updated.goal.completedBooks, 1);
    assert.equal(updated.goal.points.at(-1).targetCumulative, goalBooks);
    const account = await json("auth/me", session.accessToken);
    assert.equal(account.settings.dashboardConfig.readingGoal, goalBooks);
    await save(originalConfig, originalAchievements);
    const restored = await json("user-statistics/activity-overview", session.accessToken);
    assert.equal(restored.goal.goalBooks, originalConfig.readingGoal ?? null);
    assert.equal(restored.achievementsEnabled, originalAchievements.enabled !== false);
  } finally {
    await save(originalConfig, originalAchievements);
    await logout(session);
  }
});

test("IPAD-E04-A01-statistics-isolation: unauthenticated and unrelated readers cannot observe the worked example", async () => {
  const restricted = await login("ipad-restricted");
  try {
    for (const route of ["user-statistics/activity-overview", "achievements"]) {
      assert.equal((await request(route)).status, 401);
    }
    const activity = await json("user-statistics/activity-overview", restricted.accessToken);
    assert.equal(activity.snapshot.lastSevenDays.totalSeconds, 0);
    assert.equal(activity.snapshot.completedBooksYtd, 0);
    assert.equal(activity.rhythm.sessionsCount, 0);
    assert.deepEqual(activity.sources.slices, []);
    const achievements = await json("achievements", restricted.accessToken);
    assert.equal(achievements.totalEarned, 0);
    assert.ok(achievements.categories.flatMap((category) => category.achievements).every((item) => !item.contextBookTitle));
  } finally {
    await logout(restricted);
  }
});
