// test/findings.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { appendFinding, readFindings, findingKey } from "../lib/findings.mjs";

test("findingKey is stable for the same file+line+text", () => {
  const a = findingKey({ repo: "r", file: "a.js", line: 10, issue: "x" });
  const b = findingKey({ repo: "r", file: "a.js", line: 10, issue: "x" });
  assert.equal(a, b);
  assert.notEqual(a, findingKey({ repo: "r", file: "a.js", line: 11, issue: "x" }));
});

test("append then read round-trips findings", () => {
  const dir = mkdtempSync(join(tmpdir(), "sw-find-"));
  const path = join(dir, "findings.jsonl");
  appendFinding(path, { repo: "r", file: "a.js", line: 1, issue: "bug", severity: "auto", taskId: "t1" });
  appendFinding(path, { repo: "r", file: "b.js", line: 2, issue: "nit", severity: "needs-human", taskId: "t1" });
  const all = readFindings(path);
  assert.equal(all.length, 2);
  assert.equal(all[0].severity, "auto");
  assert.ok(all[0].key);
  rmSync(dir, { recursive: true, force: true });
});
