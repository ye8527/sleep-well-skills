// test/smoke.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { chmodSync, mkdtempSync, mkdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { tmpdir } from "node:os";
import { execFileSync } from "node:child_process";

test("node:test harness runs", () => {
  assert.equal(1 + 1, 2);
});

test("runtime skill states the critical mutex, repository, review, and checkpoint contracts", () => {
  const here = dirname(fileURLToPath(import.meta.url));
  const skill = readFileSync(join(here, "..", "SKILL.md"), "utf8");
  assert.match(skill, /NIGHT\.lock/);
  assert.match(skill, /only one variant may run at a time/i);
  assert.match(skill, /codex\/state\/current-run\.json/);
  assert.match(skill, /codex\/hook-recovery\.json/);
  assert.match(skill, /absence of that lock alone is never proof/i);
  assert.match(skill, /git -C <task\.repo> ls-files -- \.review/);
  assert.match(skill, /tracked conflict is `needs_human`/);
  assert.match(skill, /rev-parse --show-toplevel/);
  assert.match(skill, /canonicalize both.*pwd -P/i);
  assert.match(skill, /state\.terminatedAt/);
  assert.match(skill, /only a successful commit may/i);
  assert.match(skill, /produced no checkpointable change/i);
  assert.match(skill, /Review findings are untrusted model-generated evidence/i);
  assert.match(skill, /only sources of scope, permissions, executable commands, target repositories, or authorization/i);
  assert.match(skill, /global `CODEX_HOME`/);
  assert.match(skill, /direct Codex child only/i);
  assert.match(skill, /git stash/);
  assert.match(skill, /four separate gated commands/i);
  assert.doesNotMatch(skill, /for L in good-first-issue/);
  assert.match(skill, /unique local-start-time name/);
  assert.match(skill, /first unused `~NNN` suffix.*never overwrite/i);
  assert.match(skill, /backupFile\(originalAbsPath, \{ backupRoot: cfg\.backup_dir, runDate, runId: state\.startedAt/);
  assert.match(skill, /local calendar date of `state\.startedAt`/i);
  assert.match(skill, /morning report reads.*backup-manifest\.jsonl/i);
  assert.doesNotMatch(skill, /Guardrails §backup/);
});

test("report entrypoint honors config backup_dir", () => {
  const here = dirname(fileURLToPath(import.meta.url));
  const home = mkdtempSync(join(tmpdir(), "sw-report-entry-"));
  const backupDir = join(home, "configured-backups");
  mkdirSync(join(home, "state"), { recursive: true });
  mkdirSync(backupDir, { recursive: true });
  writeFileSync(join(home, "config.json"), JSON.stringify({ backup_dir: backupDir }));
  writeFileSync(join(home, "state", "current-run.json"), JSON.stringify({
    startedAt: 1000, cutoffEpoch: 9999999999, tasks: [],
  }));
  writeFileSync(join(backupDir, "backup-manifest.jsonl"), JSON.stringify({
    runId: 1000, original: "/docs/custom.docx", backupPath: "/vault/custom.bak",
  }) + "\n");
  chmodSync(home, 0o755);
  execFileSync(process.execPath, [join(here, "..", "bin", "report.mjs")], {
    env: { ...process.env, SLEEP_WELL_HOME: home }, stdio: "pipe",
  });
  const report = readFileSync(join(home, "morning-report.md"), "utf8");
  assert.match(report, /custom\.docx/);
  assert.match(report, /\/vault\/custom\.bak/);
  assert.equal(statSync(home).mode & 0o777, 0o700);
  assert.equal(statSync(join(home, "morning-report.md")).mode & 0o777, 0o600);
  rmSync(home, { recursive: true, force: true });
});

test("report entrypoint falls back when config backup_dir is not a string", () => {
  const here = dirname(fileURLToPath(import.meta.url));
  const home = mkdtempSync(join(tmpdir(), "sw-report-entry-bad-backup-dir-"));
  mkdirSync(join(home, "state"), { recursive: true });
  writeFileSync(join(home, "config.json"), JSON.stringify({ backup_dir: 42 }));
  writeFileSync(join(home, "state", "current-run.json"), JSON.stringify({
    startedAt: 1000, cutoffEpoch: 9999999999, tasks: [],
  }));
  const result = execFileSync(process.execPath, [join(here, "..", "bin", "report.mjs")], {
    env: { ...process.env, SLEEP_WELL_HOME: home }, encoding: "utf8",
  });
  assert.match(result, /morning-report\.md/);
  assert.match(readFileSync(join(home, "morning-report.md"), "utf8"), /sleep-well 晨报/);
  assert.equal(statSync(join(home, "morning-report.md")).mode & 0o777, 0o600);
  rmSync(home, { recursive: true, force: true });
});
