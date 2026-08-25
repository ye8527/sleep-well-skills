// test/findings.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { appendFinding, findingKey } from "../lib/findings.mjs";

test("findingKey is stable for the same file+line+text", () => {
  const a = findingKey({ repo: "r", file: "a.js", line: 10, issue: "x" });
  const b = findingKey({ repo: "r", file: "a.js", line: 10, issue: "x" });
  assert.equal(a, b);
  assert.notEqual(a, findingKey({ repo: "r", file: "a.js", line: 11, issue: "x" }));
});

