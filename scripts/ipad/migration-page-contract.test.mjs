import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";
import test from "node:test";

const root = fileURLToPath(new URL("../../", import.meta.url));
const run = promisify(execFile);

test("migration pages decode integral counts and nullable end cursors", async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "bookorbit-migration-page-"));
  try {
    const generated = await readFile(path.join(root, "ipad/Sources/Contracts/GeneratedContracts.swift"), "utf8");
    const names = new Set(["MigrationPlanPageApi", "JSONValue"]);
    const declarations = generated
      .split(/\n(?=(?:struct|enum|indirect enum|typealias) )/)
      .filter((declaration) => names.has(declaration.match(/^(?:struct|enum|indirect enum|typealias) (\w+)/)?.[1]));
    assert.equal(declarations.length, names.size);
    const contracts = path.join(directory, "Contracts.swift");
    const source = path.join(directory, "main.swift");
    const executable = path.join(directory, "migration-page");
    await writeFile(contracts, `import Foundation\n\n${declarations.join("\n")}`);
    await writeFile(
      source,
      `import Foundation

let decoder = JSONDecoder()
let first = try decoder.decode(MigrationPlanPageApi.self, from: Data(#"{"artifactId":7,"kind":"matched","offset":0,"limit":40,"total":41,"nextOffset":40,"items":[{"sourceBookId":"one","targetBookId":12}]}"#.utf8))
let offset: Int = first.offset
let limit: Int = first.limit
let total: Int = first.total
let nextOffset: Int? = first.nextOffset
precondition(offset == 0 && limit == 40 && total == 41 && nextOffset == 40)
precondition("\\(offset + 1)-\\(offset + first.items.count) of \\(total)" == "1-1 of 41")
let last = try decoder.decode(MigrationPlanPageApi.self, from: Data(#"{"artifactId":7,"kind":"matched","offset":40,"limit":40,"total":41,"nextOffset":null,"items":[{"sourceBookId":"last"}]}"#.utf8))
precondition(last.nextOffset == nil)
precondition("\\(last.offset + 1)-\\(last.offset + last.items.count) of \\(last.total)" == "41-41 of 41")
let absent = try decoder.decode(MigrationPlanPageApi.self, from: Data(#"{"artifactId":7,"kind":"matched","offset":40,"limit":40,"total":41,"items":[]}"#.utf8))
precondition(absent.nextOffset == nil)
let roundTrip = try decoder.decode(MigrationPlanPageApi.self, from: JSONEncoder().encode(last))
precondition(roundTrip == last)
print("migration page contracts passed")
`,
    );
    await run("swiftc", ["-swift-version", "6", contracts, source, "-o", executable], { cwd: root, maxBuffer: 4 * 1024 * 1024 });
    const result = await run(executable);
    assert.match(result.stdout, /migration page contracts passed/);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
