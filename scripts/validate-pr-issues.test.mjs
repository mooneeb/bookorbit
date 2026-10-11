import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";

const workflows = ["ci.yml", "release.yml"];
const repository = "bookorbit/bookorbit";

function stepScript(workflow, stepName) {
  const source = readFileSync(new URL(`../.github/workflows/${workflow}`, import.meta.url), "utf8");
  const start = source.indexOf(`      - name: ${stepName}\n`);
  assert.notEqual(start, -1, `${workflow}: ${stepName} must exist`);
  const step = source.slice(start).split(/\n      - name:|\n  [a-z]/)[0];
  const script = step.split("        run: |\n")[1];
  assert.ok(script, `${workflow}: ${stepName} must have a shell script`);
  return script.replace(/^          /gm, "").trimEnd();
}

const curlStub = `#!/usr/bin/env node
const fs = require("node:fs");
const args = process.argv.slice(2);
const url = args.at(-1);
fs.appendFileSync(process.env.API_CALLS, JSON.stringify({ url, args }) + "\\n");
const issue = JSON.parse(process.env.API_ISSUES)[url];
fs.writeFileSync(args[args.indexOf("-o") + 1], JSON.stringify(issue?.body ?? { message: "Not Found" }));
process.stdout.write(String(issue?.status ?? 404));
`;

function validate(workflow, body, issues = {}, branch = "BO-6-fix-ci-validation") {
  const cwd = mkdtempSync(path.join(tmpdir(), "bookorbit-issue-policy-"));
  const callsPath = path.join(cwd, "calls.jsonl");
  const marker = path.join(cwd, "injected");
  try {
    writeFileSync(path.join(cwd, "curl"), curlStub, { mode: 0o755 });
    const responses = Object.fromEntries(
      Object.entries({ [`${repository}#6`]: { status: 200, body: { state: "open" } }, ...issues }).map(([ref, response]) => {
        const [repo, number] = ref.split("#");
        return [`https://api.github.com/repos/${repo}/issues/${number}`, response];
      }),
    );
    const result = spawnSync("bash", ["-euo", "pipefail", "-c", stepScript(workflow, "Validate referenced issues exist")], {
      cwd,
      encoding: "utf8",
      env: {
        ...process.env,
        PATH: `${cwd}:${process.env.PATH}`,
        GH_REPO: repository,
        GH_TOKEN: "test-token",
        PR_BRANCH: branch,
        PR_BODY: typeof body === "function" ? body(marker) : body,
        API_CALLS: callsPath,
        API_ISSUES: JSON.stringify(responses),
      },
    });
    const calls = existsSync(callsPath) ? readFileSync(callsPath, "utf8").trim().split("\n").map(JSON.parse) : [];
    return { ...result, calls, injected: existsSync(marker) };
  } finally {
    rmSync(cwd, { recursive: true, force: true });
  }
}

for (const workflow of workflows) {
  for (const keyword of ["close", "closes", "closed", "fix", "fixes", "fixed", "resolve", "resolves", "resolved", "Ref", "Related to"]) {
    test(`${workflow} accepts ${keyword} references with case and colon variants`, () => {
      for (const reference of [`${keyword} #6`, `${keyword.toUpperCase()}: #6`]) {
        const result = validate(workflow, reference);
        assert.equal(result.status, 0, result.stderr || result.stdout);
        assert.equal(result.calls.length, 2);
        assert.match(result.stdout, /state=open/);
      }
    });
  }

  test(`${workflow} supports multiline partial work and deduplicates references`, () => {
    const result = validate(workflow, "Implement one part of the issue.\nRelated\tto : #6\nRef #6\nCLOSES: #6");
    assert.equal(result.status, 0, result.stderr || result.stdout);
    assert.equal(result.calls.length, 2);
  });

  test(`${workflow} rejects missing and malformed references`, () => {
    for (const body of [
      "",
      "Work on #6",
      "Ref 6",
      "Related #6",
      "Ref#6",
      "Related to #0",
      "Closes #06",
      "Ref owner#6",
      "prefixRef #6",
      "Related to owner/repo/#6",
    ]) {
      const result = validate(workflow, body);
      assert.equal(result.status, 1, body);
      assert.match(result.stdout, /PR description must include at least one issue reference/);
      assert.equal(result.calls.length, 1);
    }
  });

  test(`${workflow} validates foreign repositories and preserves owner/repo handling`, () => {
    const result = validate(workflow, "Related to Other-Owner/Other.Repo#42\nRef other-owner/other.repo#42", {
      "other-owner/other.repo#42": { status: 200, body: { state: "closed" } },
    });
    assert.equal(result.status, 0, result.stderr || result.stdout);
    assert.deepEqual(
      result.calls.map(({ url }) => url),
      [`https://api.github.com/repos/${repository}/issues/6`, "https://api.github.com/repos/other-owner/other.repo/issues/42"],
    );
    assert.match(result.stdout, /other-owner\/other.repo#42 exists \(state=closed\)/);
  });

  test(`${workflow} rejects missing or inaccessible local and foreign issues`, () => {
    for (const ref of ["#42", "other/repo#42"]) {
      for (const status of [401, 403, 404]) {
        const repo = ref.startsWith("#") ? repository : "other/repo";
        const result = validate(workflow, `Ref ${ref}`, { [`${repo}#42`]: { status, body: {} } });
        assert.equal(result.status, 1);
        assert.match(result.stdout, /does not exist or is not accessible/);
        assert.equal(result.calls.at(-1).url, `https://api.github.com/repos/${repo}/issues/42`);
      }
    }
  });

  test(`${workflow} rejects a PR number in place of an issue`, () => {
    const result = validate(workflow, "Related to other/repo#42", {
      "other/repo#42": { status: 200, body: { state: "open", pull_request: { url: "https://example.com" } } },
    });
    assert.equal(result.status, 1);
    assert.match(result.stdout, /pull request, not an issue/);
  });

  test(`${workflow} requires the branch issue to exist`, () => {
    const result = validate(workflow, "Ref #6", { [`${repository}#6`]: { status: 404, body: {} } });
    assert.equal(result.status, 1);
    assert.match(result.stdout, /Branch name references #6/);
    assert.equal(result.calls.length, 1);
  });

  test(`${workflow} rejects branch names without an issue number`, () => {
    const result = validate(workflow, "Ref #6", {}, "fix-ci-validation");
    assert.equal(result.status, 1);
    assert.match(result.stdout, /Unable to extract issue number/);
    assert.equal(result.calls.length, 0);
  });

  test(`${workflow} treats PR text as data rather than shell code`, () => {
    const result = validate(workflow, (marker) => `Related to #6\n$(touch ${marker})\n\`touch ${marker}\`\n'; touch ${marker}; #\n::error::injected`);
    assert.equal(result.status, 0, result.stderr || result.stdout);
    assert.equal(result.injected, false);
    assert.equal(result.calls.length, 2);
    for (const { args } of result.calls) {
      assert.ok(args.includes("Authorization: Bearer test-token"));
      assert.ok(!args.some((arg) => arg.includes("touch")));
    }
  });
}

test("CI retains strict branch naming", () => {
  for (const [branch, status] of [
    ["BO-6-fix-ci-validation", 0],
    ["BO-6-Bad-Name", 1],
    ["BO-6-trailing-", 1],
    ["BO-6", 1],
  ]) {
    const result = spawnSync("bash", ["-euo", "pipefail", "-c", stepScript("ci.yml", "Validate PR branch name")], {
      encoding: "utf8",
      env: { ...process.env, PR_BRANCH: branch },
    });
    assert.equal(result.status, status, branch);
  }
});
