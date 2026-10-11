import { createRequire } from "node:module";
import { mkdirSync, renameSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { isMainThread } from "node:worker_threads";

const output = process.env.IPAD_KOBO_QUERY_OBSERVER;
if (output && isMainThread) {
  const database = new URL(process.env.DATABASE_URL ?? "");
  if (!["localhost", "127.0.0.1"].includes(database.hostname) || !/^bookorbit_ipad_[0-9]+_e2e$/.test(database.pathname.slice(1))) {
    throw new Error("Kobo query observation requires the isolated iPad database");
  }
  const require = createRequire(new URL("../../server/package.json", import.meta.url));
  const { Client } = require("pg");
  const original = Client.prototype.query;
  const evidence = { startedAt: new Date().toISOString(), categories: {}, peakRssBytes: process.memoryUsage().rss };
  const target = resolve(output);
  const temporary = `${target}.${process.pid}.tmp`;
  mkdirSync(dirname(target), { recursive: true });
  const flush = () => {
    evidence.peakRssBytes = Math.max(evidence.peakRssBytes, process.memoryUsage().rss);
    writeFileSync(temporary, `${JSON.stringify(evidence, null, 2)}\n`);
    renameSync(temporary, target);
  };
  const classify = (statement) => {
    if (!/^\s*select\b/i.test(statement)) return;
    if (/from "books"/i.test(statement) && /string_agg\(/i.test(statement)) return "catalog";
    if (/from "books"/i.test(statement) && /"kobo_book_entitlements"\."entitlement_id"/i.test(statement)) return "tags";
    if (/from "kobo_device_snapshot_books"/i.test(statement) && /\blimit\b/i.test(statement)) return "pending";
    if (/from "kobo_reading_states"/i.test(statement)) return "readingStates";
    if (/from "kobo_book_entitlements"/i.test(statement)) return "identities";
    if (/from "kobo_sync_settings"/i.test(statement)) return "settings";
    if (/from "reading_progress"/i.test(statement)) return "progress";
    if (/from "book_files"/i.test(statement)) return "files";
    if (/from "books"/i.test(statement)) return "bookAccess";
  };
  Client.prototype.query = function (...args) {
    const statement = typeof args[0] === "string" ? args[0] : (args[0]?.text ?? "");
    const category = classify(statement);
    if (!category) return original.apply(this, args);
    const started = performance.now();
    const observe = (result) => {
      const rows = result?.rows?.length ?? 0;
      const entry = (evidence.categories[category] ??= { queries: 0, returnedRows: 0, maxRows: 0, totalDurationMs: 0 });
      entry.queries++;
      entry.returnedRows += rows;
      entry.maxRows = Math.max(entry.maxRows, rows);
      entry.totalDurationMs += performance.now() - started;
      return result;
    };
    const last = args.length - 1;
    if (typeof args[last] === "function") {
      const callback = args[last];
      args[last] = (error, result) => {
        if (!error) observe(result);
        callback(error, result);
      };
      return original.apply(this, args);
    }
    const result = original.apply(this, args);
    return result?.then ? result.then(observe) : result;
  };
  flush();
  setInterval(flush, 250).unref();
  process.once("exit", flush);
}
