import config from "./playwright.config.mjs";

export default { ...config, testMatch: "e03-entities-cross-client.test.mjs" };
