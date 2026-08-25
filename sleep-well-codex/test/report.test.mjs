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

// R10 自查: 「状态文件损坏」与「从未启动」必须分开说。
// 原实现把 JSON.parse 失败 catch 掉后落到「找不到运行记录…夜班可能未启动」分支，
// 那是**编造的原因**——夜班可能跑了一整夜、任务已 checkpoint，只是状态文件被写坏了。
// 早报是两侧 AI 全挂那夜唯一的产物，而崩溃恰恰是它最容易被写坏的时候。
test("buildReport 区分「状态损坏」与「从未启动」，且不编造原因", () => {
  const home = mkdtempSync(join(tmpdir(), "sw-report-corrupt-"));
  mkdirSync(join(home, "state"), { recursive: true });
  writeFileSync(join(home, "state", "current-run.json"), '{"tasks":[{"id":"t1","stat');
  const md = buildReport({ home, nowEpoch: 5000 });
  assert.match(md, /损坏/, "必须明说状态文件损坏");
  assert.match(md, /未知/, "必须承认本夜进展未知");
  assert.doesNotMatch(md, /夜班可能未启动/, "不得声称夜班可能未启动——那是未经核实的原因");
  assert.match(md, /git log/, "应指引用户去核对 git log");
  rmSync(home, { recursive: true, force: true });
});

// Codex R11 提醒: R10 只修了 current-run.json 那一处，最新归档损坏时仍会落到
// 「夜班可能未启动」这个编造原因的分支。归档损坏与「没有归档」也必须分开。
test("buildReport 在最新归档损坏时也说实话", () => {
  const home = mkdtempSync(join(tmpdir(), "sw-report-archcorrupt-"));
  mkdirSync(join(home, "state"), { recursive: true });
  writeFileSync(join(home, "state", "run-2026-08-10.json"), '{"tasks":[{"id":"t1"');
  const md = buildReport({ home, nowEpoch: 5000 });
  assert.match(md, /损坏/, "归档损坏也要明说");
  assert.doesNotMatch(md, /夜班可能未启动/, "不得声称夜班可能未启动");
  rmSync(home, { recursive: true, force: true });
});
