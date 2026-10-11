import { expect, test } from "@playwright/test";

async function signIn(page, username) {
  await page.goto("/login");
  await page.locator("#username").fill(username);
  await page.locator("#password").fill("IpadFixture123");
  await page.getByRole("button", { name: "Sign in", exact: true }).click();
  await expect(page).not.toHaveURL(/\/login/);
}

test("IPAD-E05-A01-web-profile-cross-client: actual web profile displays the native account name", async ({ page }, info) => {
  await signIn(page, "ipad-owner");
  const response = await page.request.get("/api/v1/auth/me");
  expect(response.status()).toBe(200);
  const account = await response.json();
  if (process.env.IPAD_E05_EXPECT_NATIVE === "1") expect(account.name).toBe("E05 Native Profile");
  await page.goto("/settings/account/profile");
  await expect(page.locator("#account-full-name")).toHaveValue(account.name);
  await page.screenshot({ path: info.outputPath("IPAD-E05-A01-web-profile.png") });
  await page.reload();
  await expect(page.locator("#account-full-name")).toHaveValue(account.name);
});

test("IPAD-E05-A04-web-permission-settings: settings permission exposes the maintenance form and rejects user administration", async ({
  page,
}, info) => {
  await signIn(page, "ipad-editor");
  await page.goto("/settings/library/maintenance");
  await expect(page.getByRole("spinbutton")).toBeVisible();
  await expect(page.getByRole("button", { name: "Run backfill", exact: true })).toHaveCount(0);
  expect((await page.request.get("/api/v1/users?page=0&pageSize=5")).status()).toBe(403);
  await page.screenshot({ path: info.outputPath("IPAD-E05-A04-web-settings-admin.png") });
});

test("IPAD-E05-A03-web-authentication-policy: the real users form reflects the native persisted registration policy", async ({ page }, info) => {
  await signIn(page, "ipad-owner");
  const response = await page.request.get("/api/v1/app-settings");
  expect(response.status()).toBe(200);
  const settings = await response.json();
  const registration = settings.find((setting) => setting.key === "allow_registration");
  expect(registration).toBeTruthy();
  await page.goto("/settings/admin/users");
  await expect(page.getByRole("switch", { name: "Allow self-registration", exact: true })).toHaveAttribute("aria-checked", registration.value);
  await page.screenshot({ path: info.outputPath("IPAD-E05-A03-web-registration-policy.png") });
});

test("IPAD-E05-A04-web-reader-denied: a reader receives enforced configuration denial", async ({ page }, info) => {
  await signIn(page, "ipad-reader");
  expect((await page.request.patch("/api/v1/app-settings/max_upload_size_mb", { data: { value: "252" } })).status()).toBe(403);
  await page.goto("/settings/account/profile");
  await expect(page.locator("#account-username")).toHaveValue("ipad-reader");
  await page.screenshot({ path: info.outputPath("IPAD-E05-A04-web-reader-profile.png") });
});
