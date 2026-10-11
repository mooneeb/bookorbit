import assert from "node:assert/strict";
import { mkdir, rename, writeFile } from "node:fs/promises";
import { dirname } from "node:path";

export async function writeFixtureCheckpoint(path, checkpoint) {
  await mkdir(dirname(path), { recursive: true });
  const temporary = `${path}.${process.pid}.tmp`;
  await writeFile(temporary, JSON.stringify(checkpoint, null, 2), { mode: 0o600 });
  await rename(temporary, path);
}

export async function waitForInitialScan(libraryId, request, { timeoutMs = 300_000, onProgress = () => {}, pollMs = 1_000 } = {}) {
  assert.ok(Number.isFinite(timeoutMs) && timeoutMs > 0);
  assert.ok(Number.isFinite(pollMs) && pollMs > 0);
  const startedAt = Date.now();
  const deadline = startedAt + timeoutMs;
  let lastReportedAt = 0;
  let lastProgress;
  do {
    const { progress } = await request(`scanner/libraries/${libraryId}/scan-status`);
    lastProgress = progress;
    const terminal = progress?.status === "completed" || progress?.status === "failed";
    if (terminal || Date.now() - lastReportedAt >= 5_000) {
      await onProgress({ libraryId, elapsedMs: Date.now() - startedAt, timeoutMs, progress });
      lastReportedAt = Date.now();
    }
    if (progress?.status === "failed") assert.fail(`Fixture scan failed: ${progress.errorMessage ?? progress.error}`);
    if (progress?.status === "completed" || !progress) {
      const history = await request(`scanner/libraries/${libraryId}/scan-history?limit=1`);
      const latest = history[0];
      if (latest?.status === "failed") assert.fail(`Fixture scan failed: ${latest.errorMessage}`);
      if (latest?.status === "completed") {
        if (progress) assert.equal(latest.id, progress.jobId);
        await onProgress({ libraryId, elapsedMs: Date.now() - startedAt, timeoutMs, progress, history: latest });
        return latest;
      }
    }
    const remainingMs = deadline - Date.now();
    if (remainingMs > 0) await new Promise((resolve) => setTimeout(resolve, Math.min(pollMs, remainingMs)));
  } while (Date.now() < deadline);
  await onProgress({ libraryId, elapsedMs: Date.now() - startedAt, timeoutMs, progress: lastProgress, incomplete: true });
  assert.fail(
    `Initial library ${libraryId} scan is incomplete after ${timeoutMs}ms; retain its resources and resume from public scan status/history`,
  );
}

export async function cleanupFixture(steps) {
  const errors = [];
  for (const step of steps) {
    try {
      await step();
    } catch (error) {
      errors.push(error);
    }
  }
  if (errors.length) throw new AggregateError(errors, "Migration fixture cleanup failed");
}

export function migrationBooksQuery(page = 0) {
  return {
    sort: [{ field: "title", dir: "asc" }],
    pagination: { page, size: 100 },
  };
}
