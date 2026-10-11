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

test("generated native contracts remain deterministic", async () => {
  await run(process.execPath, ["scripts/ipad/generate-contracts.mjs", "--check"], { cwd: root });
});

test("acquisition contracts preserve wire discriminators, nullable clears, and dynamic values", async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "bookorbit-contracts-"));
  const source = path.join(directory, "main.swift");
  const contracts = path.join(directory, "Contracts.swift");
  const executable = path.join(directory, "contracts");
  try {
    const generated = await readFile(path.join(root, "ipad/Sources/Contracts/GeneratedContracts.swift"), "utf8");
    const names = new Set([
      "UploadTarget",
      "UploadTargetLibrary",
      "UploadTargetExistingBook",
      "UploadTargetBookDock",
      "CreateUploadSessionRequest",
      "BookDockFinalizeJobRequest",
      "BookDockFinalizeOverride",
      "BookDockFinalizeJob",
      "BookDockFinalizeFileResult",
      "BulkStringEdit",
      "BulkNumberEdit",
      "ScanConfigurationRequest",
      "JSONValue",
      "StringOrNumber",
      "MissingResourcePage",
      "MissingBookEntry",
      "MissingBooksPage",
    ]);
    const selected = generated
      .split(/\n(?=(?:struct|enum|indirect enum|typealias) )/)
      .filter((declaration) => names.has(declaration.match(/^(?:struct|enum|indirect enum|typealias) (\w+)/)?.[1]));
    assert.equal(selected.length, names.size);
    await writeFile(contracts, `import Foundation\n\n${selected.join("\n")}`);
    await writeFile(
      source,
      `
import Foundation

func object<T: Encodable>(_ value: T) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
}

let target = UploadTarget.library(.init(kind: "library", libraryId: 42, folderId: nil))
let payload = CreateUploadSessionRequest(filename: "book.epub", sizeBytes: 1024, idempotencyKey: "test", target: target)
let encoded = try object(payload)
let destination = encoded["target"] as! [String: Any]
precondition(destination["kind"] as? String == "library")
precondition(destination["libraryId"] as? Int == 42)
precondition(destination["folderId"] == nil)
precondition(encoded["sha256"] == nil)
let dock = try JSONDecoder().decode(UploadTarget.self, from: Data(#"{"kind":"book_dock"}"#.utf8))
precondition(dock == .book_dock(.init(kind: "book_dock")))

let jobRequest = BookDockFinalizeJobRequest(idempotencyKey: "e02836c7-a75b-4c8c-befa-e3d120086b99", fileIds: [7])
let encodedJobRequest = try object(jobRequest)
precondition(encodedJobRequest["idempotencyKey"] as? String == jobRequest.idempotencyKey)
precondition(encodedJobRequest["fileIds"] as? [Int] == [7])
precondition(encodedJobRequest["selectAll"] == nil && encodedJobRequest["overrides"] == nil)
let missingIdempotencyKey = try? JSONDecoder().decode(BookDockFinalizeJobRequest.self, from: Data(#"{"fileIds":[7]}"#.utf8))
precondition(missingIdempotencyKey == nil)
let job = try JSONDecoder().decode(BookDockFinalizeJob.self, from: Data(#"{"id":3,"state":"completed","total":1,"processed":1,"succeeded":1,"failed":0,"error":null,"createdAt":"2026-10-10T00:00:00Z","updatedAt":"2026-10-10T00:00:00Z","results":[],"resultsTruncated":false}"#.utf8))
precondition(job.id == 3 && job.processed == 1 && job.state == "completed")
let encodedJob = try object(job)
precondition(encodedJob["error"] is NSNull)

let clearedString = try object(BulkStringEdit(value: nil))
let clearedNumber = try object(BulkNumberEdit(value: nil))
precondition(clearedString["value"] is NSNull)
precondition(clearedNumber["value"] is NSNull)
let configuration = ScanConfigurationRequest(folders: ["/books"], watch: false, autoScanCronExpression: nil, allowedFormats: ["epub"], excludePatterns: [], organizationMode: "book_per_file")
let encodedConfiguration = try object(configuration)
precondition(encodedConfiguration["autoScanCronExpression"] is NSNull)

let dynamic = try JSONDecoder().decode([String: JSONValue].self, from: Data(#"{"enabled":true,"limit":12,"nested":{"values":[null,"ok"]}}"#.utf8))
precondition(dynamic["enabled"] == .boolean(true))
precondition(dynamic["limit"] == .number(12))
precondition(dynamic["nested"] == .object(["values": .array([.null, .string("ok")])]))
let roundTrip = try JSONDecoder().decode([String: JSONValue].self, from: JSONEncoder().encode(dynamic))
precondition(roundTrip == dynamic)
let numericIdentifier = try JSONDecoder().decode(StringOrNumber.self, from: Data("42".utf8))
let stringIdentifier = try JSONDecoder().decode(StringOrNumber.self, from: Data(#""publisher""#.utf8))
precondition(numericIdentifier == .number(42))
precondition(stringIdentifier == .string("publisher"))
let page = try JSONDecoder().decode(MissingBooksPage.self, from: Data(#"{"items":[],"total":0,"page":1,"pageSize":25}"#.utf8))
precondition(page.pageSize == 25 && page.items.isEmpty)
print("wire contracts passed")
`,
    );
    await run("swiftc", ["-swift-version", "6", contracts, source, "-o", executable], { cwd: root, maxBuffer: 4 * 1024 * 1024 });
    const result = await run(executable);
    assert.match(result.stdout, /wire contracts passed/);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
