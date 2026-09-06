import { test } from "node:test";
import assert from "node:assert/strict";
import { chmodSync, mkdtempSync, mkdirSync, readFileSync, statSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { buildReport, heartbeatStaleSeconds } from "../lib/report.mjs";

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
    JSON.stringify({ runId: 1000, key: "x", taskId: "t1", file: "a.js", line: 1, issue: "x", severity: "auto" }) + "\n" +
    JSON.stringify({ runId: 1000, key: "tricky", taskId: "t2", file: "b.js", line: 9, issue: "tricky", severity: "needs-human" }) + "\n");
  writeFileSync(join(home, "backups", "backup-manifest.jsonl"),
    JSON.stringify({ runId: 999, original: "/p/旧备份.docx", backupPath: "/p/backups/old.bak", runDate: "2026-06-16", reason: "old" }) + "\n" +
    JSON.stringify({ runId: 1000, original: "/p/研究计划书.docx", backupPath: "/p/backups/研究计划书.docx.ab12.bak", runDate: "2026-06-17", reason: "Tier3" }) + "\n");
  return home;
}

test("buildReport summarizes tasks, needs-human, backups", () => {
  const home = fixture();
  writeFileSync(join(home, "state", "heartbeat"), new Date(2000 * 1000).toISOString());
  const md = buildReport({ home, nowEpoch: 2000 + 600 });
  assert.match(md, /t1/); assert.match(md, /done/);
  assert.match(md, /需要你处理|needs.human/i); assert.match(md, /t2/); assert.match(md, /tricky/);
  assert.match(md, /研究计划书\.docx/); assert.match(md, /\.bak/);
  assert.doesNotMatch(md, /旧备份|old\.bak/);
  rmSync(home, { recursive: true, force: true });
});

test("buildReport reads a configured backup directory", () => {
  const home = fixture();
  const backupDir = join(home, "custom-backups");
  mkdirSync(backupDir, { recursive: true });
  writeFileSync(join(backupDir, "backup-manifest.jsonl"),
    JSON.stringify({ runId: 1000, original: "/p/custom-location.docx", backupPath: "/custom/location.bak", runDate: "2026-06-17", reason: "configured" }) + "\n");
  const md = buildReport({ home, nowEpoch: 2000, backupDir });
  assert.match(md, /custom-location\.docx/);
  assert.match(md, /\/custom\/location\.bak/);
  assert.doesNotMatch(md, /研究计划书\.docx/);
  rmSync(home, { recursive: true, force: true });
});

test("buildReport gives persisted terminal state precedence over a fresh heartbeat", () => {
  const home = fixture();
  const statePath = join(home, "state", "current-run.json");
  const state = JSON.parse(readFileSync(statePath, "utf8"));
  state.terminatedAt = 2100;
  state.terminatedReason = "到达 cutoff";
  writeFileSync(statePath, JSON.stringify(state));
  writeFileSync(join(home, "state", "heartbeat"), new Date(2099 * 1000).toISOString());
  const md = buildReport({ home, nowEpoch: 2100 });
  assert.match(md, /已收工.*到达 cutoff/);
  assert.doesNotMatch(md, /🟢.*运行中/);
  rmSync(home, { recursive: true, force: true });
});

test("buildReport uses the injected recovery hint", () => {
  const home = fixture();
  const md = buildReport({ home, nowEpoch: 2000, recoveryHint: "launchd will resume automatically" });
  assert.match(md, /恢复：launchd will resume automatically/);
  assert.doesNotMatch(md, /重开 \/loop sleep-well/);
  rmSync(home, { recursive: true, force: true });
});

test("buildReport filters prior runs and deduplicates repeated review rounds", () => {
  const home = fixture();
  writeFileSync(join(home, "findings.jsonl"),
    JSON.stringify({ runId: 999, key: "old", taskId: "t2", file: "old.js", line: 1, issue: "old issue", severity: "needs-human" }) + "\n" +
    JSON.stringify({ runId: 1000, key: "same", taskId: "t2", file: "b.js", line: 9, issue: "current issue", severity: "needs-human" }) + "\n" +
    JSON.stringify({ runId: 1000, key: "same", taskId: "t2", file: "b.js", line: 9, issue: "current issue", severity: "needs-human" }) + "\n");
  const md = buildReport({ home, nowEpoch: 2000 });
  assert.doesNotMatch(md, /old issue/);
  assert.equal((md.match(/current issue/g) || []).length, 1);
  assert.match(md, /\| t2 \| Fix nav \| needs_human \| 2 \| 0 \| 1 \|/);
  rmSync(home, { recursive: true, force: true });
});

test("buildReport flags a likely interruption when heartbeat is stale + no STOP", () => {
  const home = fixture();
  writeFileSync(join(home, "state", "heartbeat"), new Date(1000 * 1000).toISOString());
  const md = buildReport({ home, nowEpoch: 1000 + 3600 });
  assert.match(md, /疑似中断|interrupt|stale|中断/i);
  rmSync(home, { recursive: true, force: true });
});

test("heartbeat staleness stays beyond the configured AI timeout", () => {
  assert.equal(heartbeatStaleSeconds(""), 2700);
  assert.equal(heartbeatStaleSeconds("1800"), 2700);
  assert.equal(heartbeatStaleSeconds("4000"), 4900);
  assert.equal(heartbeatStaleSeconds("invalid"), 2700);
});

test("buildReport tolerates finite epochs outside the Date range", () => {
  const home = fixture();
  const statePath = join(home, "state", "current-run.json");
  const state = JSON.parse(readFileSync(statePath, "utf8"));
  state.startedAt = 1e14;
  state.cutoffEpoch = 1e14;
  writeFileSync(statePath, JSON.stringify(state));
  const md = buildReport({ home, nowEpoch: 5000 });
  assert.match(md, /\| 开始时间 \| — \|/);
  assert.match(md, /\| 截止时间 \| — \|/);
  rmSync(home, { recursive: true, force: true });
});

test("buildReport treats an invalid heartbeat as an interruption", () => {
  const home = fixture();
  writeFileSync(join(home, "state", "heartbeat"), "not-a-date");
  const md = buildReport({ home, nowEpoch: 5000 });
  assert.match(md, /疑似中断|interrupt|中断/i);
  assert.doesNotMatch(md, /🟢.*运行中/);
  rmSync(home, { recursive: true, force: true });
});

test("buildReport handles missing state gracefully", () => {
  const home = mkdtempSync(join(tmpdir(), "sw-report-empty-"));
  const md = buildReport({ home, nowEpoch: 5000 });
  assert.match(md, /找不到|no run|未启动|未找到/i);
  rmSync(home, { recursive: true, force: true });
});

test("buildReport selects the later same-second collision archive", () => {
  const home = mkdtempSync(join(tmpdir(), "sw-report-collision-"));
  mkdirSync(join(home, "state"), { recursive: true });
  const state = (id) => JSON.stringify({
    startedAt: 1000, cutoffEpoch: 2000, terminatedAt: 1500,
    terminatedReason: "test", tasks: [{ id, title: id, status: "done" }],
  });
  writeFileSync(join(home, "state", "run-1970-01-01T001640.json"), state("older-run"));
  writeFileSync(join(home, "state", "run-1970-01-01T001640~001.json"), state("newer-run"));
  const md = buildReport({ home, nowEpoch: 2000 });
  assert.match(md, /newer-run/);
  assert.doesNotMatch(md, /older-run/);
  rmSync(home, { recursive: true, force: true });
});

test("buildReport 区分「状态损坏」与「从未启动」，且不编造原因", () => {
  const home = mkdtempSync(join(tmpdir(), "sw-report-corrupt-"));
  mkdirSync(join(home, "state"), { recursive: true });
  writeFileSync(join(home, "state", "current-run.json"), '{"tasks":[{"id":"t1","stat');
  const md = buildReport({ home, nowEpoch: 5000 });
  assert.match(md, /损坏/, "必须明说状态文件损坏");
  assert.match(md, /corrupt-current-run-<时间戳>\.json\.bak/, "必须给出不会伪装成正常归档的隔离名");
  assert.match(md, /未知/, "必须承认本夜进展未知");
  assert.doesNotMatch(md, /夜班可能未启动/, "不得声称夜班可能未启动——那是未经核实的原因");
  assert.match(md, /git log/, "应指引用户去核对 git log");
  assert.match(md, /sleep-well:/, "Claude 变体默认提示自己的 checkpoint 前缀");
  assert.doesNotMatch(md, /sleep-well-codex:/, "共享默认不得误指向 Codex 变体");
  const codexMd = buildReport({ home, nowEpoch: 5000, commitPrefix: "sleep-well-codex:" });
  assert.match(codexMd, /sleep-well-codex:/, "Codex 变体可显式传入自己的 checkpoint 前缀");
  rmSync(home, { recursive: true, force: true });
});

test("corrupt current state remains a loud warning when a valid archive exists", () => {
  const home = mkdtempSync(join(tmpdir(), "sw-report-corrupt-with-archive-"));
  mkdirSync(join(home, "state"), { recursive: true });
  writeFileSync(join(home, "state", "current-run.json"), '{"tasks":[');
  writeFileSync(join(home, "state", "run-2026-08-25T070000.json"), JSON.stringify({
    startedAt: 1000, cutoffEpoch: 2000, terminatedAt: 1500,
    terminatedReason: "previous night", tasks: [{ id: "archived-task", status: "done" }],
  }));
  const md = buildReport({ home, nowEpoch: 5000 });
  assert.match(md, /🚨 \*\*状态文件损坏/);
  assert.match(md, /历史归档/);
  assert.match(md, /run-2026-08-25T070000\.json/);
  assert.match(md, /archived-task/, "历史信息可以保留，但必须标清来源");
  assert.doesNotMatch(md, /✅ \*\*已收工/, "旧归档不得把损坏状态伪装成正常收工");
  assert.match(md, /corrupt-current-run-<时间戳>\.json\.bak/);
  rmSync(home, { recursive: true, force: true });
});

test("report display replaces controls from findings and backup paths", () => {
  const home = mkdtempSync(join(tmpdir(), "sw-report-controls-"));
  mkdirSync(join(home, "state"), { recursive: true });
  mkdirSync(join(home, "backups"), { recursive: true });
  writeFileSync(join(home, "state", "current-run.json"), JSON.stringify({
    startedAt: 1000, cutoffEpoch: 9999,
    tasks: [{ id: "t1", title: "review", status: "needs_human" }],
  }));
  writeFileSync(join(home, "findings.jsonl"), JSON.stringify({
    runId: 1000, taskId: "t1", key: "k", severity: "needs-human",
    file: "src/evil\u001b.js", line: "1\u009b", issue: "danger\u001b[2Jhidden",
  }) + "\n");
  writeFileSync(join(home, "backups", "backup-manifest.jsonl"), JSON.stringify({
    runId: 1000, original: "bad\u001bname", backupPath: "/tmp/bad\u009b.bak", reason: "why\u0007",
  }) + "\n");
  const md = buildReport({ home, nowEpoch: 2000 });
  assert.doesNotMatch(md, /[\u0000-\u0009\u000b-\u001f\u007f-\u009f]/u);
  assert.match(md, /�/, "控制字符应替换而不是让整份应急报告失败");
  assert.doesNotMatch(md, /确认无误后可删:.*rm/, "不可信路径不得拼成可复制删除命令");
  rmSync(home, { recursive: true, force: true });
});

test("buildReport 在最新归档损坏时也说实话", () => {
  const home = mkdtempSync(join(tmpdir(), "sw-report-archcorrupt-"));
  mkdirSync(join(home, "state"), { recursive: true });
  writeFileSync(join(home, "state", "run-2026-08-10.json"), '{"tasks":[{"id":"t1"');
  const md = buildReport({ home, nowEpoch: 5000 });
  assert.match(md, /损坏/, "归档损坏也要明说");
  assert.doesNotMatch(md, /夜班可能未启动/, "不得声称夜班可能未启动");
  rmSync(home, { recursive: true, force: true });
});

test("report entrypoint rejects an account-home runtime root before chmod", () => {
  const accountHome = mkdtempSync(join(tmpdir(), "sw-report-unsafe-root-"));
  chmodSync(accountHome, 0o755);
  const reportBin = fileURLToPath(new URL("../bin/report.mjs", import.meta.url));
  assert.throws(() => execFileSync(process.execPath, [reportBin], {
    env: {
      ...process.env,
      HOME: accountHome,
      SLEEP_WELL_HOME: accountHome,
      SLEEP_WELL_ROOT: accountHome,
    },
    stdio: "pipe",
  }));
  assert.equal(statSync(accountHome).mode & 0o777, 0o755);
  rmSync(accountHome, { recursive: true, force: true });
});
