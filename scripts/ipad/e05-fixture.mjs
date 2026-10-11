import { writeFile } from "node:fs/promises";
import { json, login, setBaseURL } from "./e05-http-support.mjs";

export async function configureE05Fixture(artifacts, baseURL) {
  if (baseURL) setBaseURL(baseURL);
  const owner = await login();
  const users = await json("users?page=0&pageSize=10&search=ipad-editor", owner.accessToken);
  const administrator = users.users.find((user) => user.username === "ipad-editor");
  if (!administrator) throw new Error("E05 requires the isolated editor fixture");
  await json(`users/${administrator.id}/permissions`, owner.accessToken, "PUT", { permissionNames: ["manage_app_settings"] }, 204);
  const fixture = { settingsAdministrator: "ipad-editor", settingsAdministratorId: administrator.id, profileName: "E05 Native Profile" };
  await writeFile(`${artifacts}/e05-fixture.json`, `${JSON.stringify(fixture, null, 2)}\n`);
  await json("auth/logout", undefined, "POST", { refreshToken: owner.refreshToken });
  return fixture;
}
