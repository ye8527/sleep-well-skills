import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { triedKey, parseTodos, dedupe, pickCandidates, tierMode, loadTried, markTried } from "../lib/discovery.mjs";

test("triedKey is stable + path-sensitive", () => {
  const a = triedKey({ source: "s", repo: "r", path: "a.js", text: "TODO x" });
  assert.equal(a, triedKey({ source: "s", repo: "r", path: "a.js", text: "TODO x" }));
  assert.notEqual(a, triedKey({ source: "s", repo: "r", path: "b.js", text: "TODO x" }));
});
test("parseTodos parses `grep -rn` lines into candidates", () => {
  const out = "src/a.js:12: // TODO: handle null\nsrc/b.js:3:// FIXME broken";
  const c = parseTodos(out, "/repo");
  assert.equal(c.length, 2);
  assert.equal(c[0].path, "src/a.js");
  assert.equal(c[0].line, 12);
  assert.match(c[0].text, /TODO: handle null/);
  assert.equal(c[0].repo, "/repo");
  assert.equal(c[0].source, "tier2-todo");
});
test("dedupe removes already-tried candidates", () => {
  const items = [{ source: "s", path: "a.js", text: "x" }, { source: "s", path: "b.js", text: "y" }];
  const tried = new Set([triedKey(items[0])]);
  const fresh = dedupe(items, tried);
  assert.equal(fresh.length, 1);
  assert.equal(fresh[0].path, "b.js");
});
test("pickCandidates takes up to k in tier order, stopping early", () => {
  const tiers = [
    { tier: 1, items: [{ id: "f1" }] },
    { tier: 2, items: [{ id: "t1" }, { id: "t2" }, { id: "t3" }] },
  ];
  const picked = pickCandidates(tiers, 3);
  assert.deepEqual(picked.map((p) => p.id), ["f1", "t1", "t2"]);
});
test("tierMode classifies auto/propose/off from config", () => {
  const cfg = { discovery_tiers_auto: [1, 2, 3], discovery_tiers_propose: [4] };
  assert.equal(tierMode(1, cfg), "auto");
  assert.equal(tierMode(4, cfg), "propose");
  assert.equal(tierMode(9, cfg), "off");
});
test("tried.log round-trips via markTried/loadTried", () => {
  const dir = mkdtempSync(join(tmpdir(), "sw-tried-"));
  const p = join(dir, "tried.log");
  const c = { source: "s", path: "a.js", text: "x" };
  markTried(p, c);
  assert.ok(loadTried(p).has(triedKey(c)));
  rmSync(dir, { recursive: true, force: true });
});
