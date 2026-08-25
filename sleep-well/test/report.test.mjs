import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { buildReport } from "../lib/report.mjs";

function fixture() {
  const home = mkdtempSync(join(tmpdir(), "sw-report-"));
  mkdirSync(join(home, "state"), { recursive: true });
  mkdirSync(join(home, "backups"), { recursive: true });
  mkdirSync(join(home, "logs"), { recursive: true });
  writeFileSync(join(home, "state", "current-run.json"), JSON.stringify({
    startedAt: 1000, cutoffEpoch: 99999, teamDelegationsTonight: 1,
    tasks: [
      { id: "t1", title: "Add CSV", status: "done", findingsHistory: [2, 0], reviewRotations: 0 },
      { id: "t2", title: "Fix nav", status: "needs_human", findingsHistory: [3, 3], reviewRotations: 1 },
    ],
  }));
  writeFileSync(join(home, "findings.jsonl"),
    JSON.stringify({ taskId: "t1", file: "a.js", line: 1, issue: "x", severity: "auto" }) + "\n" +
    JSON.stringify({ taskId: "t2", file: "b.js", line: 9, issue: "tricky", severity: "needs-human" }) + "\n");
  writeFileSync(join(home, "backups", "backup-manifest.jsonl"),
    JSON.stringify({ original: "/p/研究计划书.docx", backupPath: "/p/backups/研究计划书.docx.ab12.bak", runDate: "2026-06-17", reason: "Tier3" }) + "\n");
  return home;
}

test("buildReport summarizes tasks, needs-human, backups", () => {
  const home = fixture();
  writeFileSync(join(home, "state", "heartbeat"), new Date(2000 * 1000).toISOString());
  const md = buildReport({ home, nowEpoch: 2000 + 600 });
  assert.match(md, /t1/); assert.match(md, /done/);
  assert.match(md, /需要你处理|needs.human/i); assert.match(md, /t2/); assert.match(md, /tricky/);
  assert.match(md, /研究计划书\.docx/); assert.match(md, /\.bak/);
  rmSync(home, { recursive: true, force: true });
});

test("buildReport flags a likely interruption when heartbeat is stale + no STOP", () => {
  const home = fixture();
  writeFileSync(join(home, "state", "heartbeat"), new Date(1000 * 1000).toISOString());
  const md = buildReport({ home, nowEpoch: 1000 + 3600 });
  assert.match(md, /疑似中断|interrupt|stale|中断/i);
  rmSync(home, { recursive: true, force: true });
});

test("buildReport handles missing state gracefully", () => {
  const home = mkdtempSync(join(tmpdir(), "sw-report-empty-"));
  const md = buildReport({ home, nowEpoch: 5000 });
  assert.match(md, /找不到|no run|未启动|未找到/i);
  rmSync(home, { recursive: true, force: true });
});
