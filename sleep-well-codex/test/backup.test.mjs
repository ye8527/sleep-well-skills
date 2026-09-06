// test/backup.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync, readFileSync, existsSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { backupFile, readManifest } from "../lib/backup.mjs";

test("backupFile copies the original and records a manifest line", () => {
  const root = mkdtempSync(join(tmpdir(), "sw-bk-"));
  const orig = join(root, "研究计划书.docx");
  writeFileSync(orig, "ORIGINAL");
  const backupRoot = join(root, "backups");

  const entry = backupFile(orig, { backupRoot, runDate: "2026-06-16", runId: 1000, reason: "Tier3 edit" });

  assert.ok(existsSync(entry.backupPath));
  assert.equal(readFileSync(entry.backupPath, "utf-8"), "ORIGINAL");
  assert.equal(entry.original, orig);
  assert.equal(entry.reason, "Tier3 edit");
  assert.equal(entry.runId, 1000);

  const manifest = readManifest(backupRoot);
  assert.equal(manifest.length, 1);
  assert.equal(manifest[0].original, orig);
  assert.equal(manifest[0].runId, 1000);
  rmSync(root, { recursive: true, force: true });
});

test("same-basename docs get distinct backups; same doc twice is idempotent", () => {
  const root = mkdtempSync(join(tmpdir(), "sw-bk2-"));
  const a = join(root, "a", "notes.md"); const b = join(root, "b", "notes.md");
  mkdirSync(join(root, "a")); mkdirSync(join(root, "b"));
  writeFileSync(a, "AAA"); writeFileSync(b, "BBB");
  const backupRoot = join(root, "backups");
  const ea = backupFile(a, { backupRoot, runDate: "2026-06-16", runId: 1000, reason: "x" });
  const eb = backupFile(b, { backupRoot, runDate: "2026-06-16", runId: 1000, reason: "x" });
  assert.notEqual(ea.backupPath, eb.backupPath);
  assert.equal(readFileSync(ea.backupPath, "utf-8"), "AAA");
  assert.equal(readFileSync(eb.backupPath, "utf-8"), "BBB");
  writeFileSync(a, "AAA-edited");
  const ea2 = backupFile(a, { backupRoot, runDate: "2026-06-16", runId: 1001, reason: "x" });
  assert.equal(ea2.skipped, true); // first backup preserved the TRUE original
  assert.equal(ea2.runId, 1001);
  assert.equal(readFileSync(ea.backupPath, "utf-8"), "AAA");
  rmSync(root, { recursive: true, force: true });
});

test("backupFile rejects a manifest entry without a run id", () => {
  const root = mkdtempSync(join(tmpdir(), "sw-bk3-"));
  const orig = join(root, "notes.md");
  writeFileSync(orig, "ORIGINAL");
  assert.throws(
    () => backupFile(orig, { backupRoot: join(root, "backups"), runDate: "2026-06-16", reason: "x" }),
    /runId/,
  );
  rmSync(root, { recursive: true, force: true });
});
