import { test, expect } from "@playwright/test";

async function signIn(page, username) {
  await page.goto("/login");
  await page.locator("#username").fill(username);
  await page.locator("#password").fill("IpadFixture123");
  await page.getByRole("button", { name: "Sign in", exact: true }).click();
  await expect(page).not.toHaveURL(/\/login/);
}

test("IPAD-E03-REQUEST-ADMIN-03: web shows and validates the source and client created in the real native journey", async ({ page }, info) => {
  await signIn(page, "ipad-settings-admin");
  const sourcesResponse = await page.request.get("/api/v1/admin/request-indexers");
  expect(sourcesResponse.status()).toBe(200);
  const source = (await sourcesResponse.json()).indexers.find((item) => item.name.startsWith("Native source "));
  expect(source, "Run RequestAdministrationJourneyTests native configuration before this cross-client test").toBeTruthy();
  expect(source.color).toBe("teal");
  expect(source.networkProfile).toEqual({ resolvers: ["1.1.1.1", "8.8.8.8"] });
  await page.goto("/settings/admin/requests?tab=sources");
  await expect(page.getByText(source.name, { exact: true }).first()).toBeVisible();
  await page.screenshot({ path: info.outputPath("IPAD-E03-REQUEST-ADMIN-native-source-in-web.png") });
  const clientsResponse = await page.request.get("/api/v1/admin/download-clients");
  expect(clientsResponse.status()).toBe(200);
  const client = (await clientsResponse.json()).clients.find((item) => item.name.startsWith("Native client "));
  expect(client).toBeTruthy();
  expect(client.color).toBe("orange");
  expect(client.hasPassword).toBe(true);
  expect(client.password).toBeUndefined();
  await page.goto("/settings/admin/requests?tab=clients");
  await expect(page.getByText(client.name, { exact: true }).first()).toBeVisible();
  await page.screenshot({ path: info.outputPath("IPAD-E03-REQUEST-ADMIN-native-client-in-web.png") });
  expect((await page.request.get("/api/v1/admin/request-indexers/plugins/updates")).status()).toBe(403);
});

test("IPAD-E03-REQUEST-ADMIN-04: request moderator is denied the configuration API and web settings", async ({ page }, info) => {
  await signIn(page, "ipad-request-moderator");
  expect((await page.request.get("/api/v1/admin/request-indexers")).status()).toBe(403);
  expect((await page.request.get("/api/v1/admin/download-clients")).status()).toBe(403);
  await page.goto("/settings/admin/requests");
  await expect(page.getByRole("button", { name: "Add source", exact: true })).toHaveCount(0);
  await page.screenshot({ path: info.outputPath("IPAD-E03-REQUEST-ADMIN-web-moderator-denied.png") });
});
