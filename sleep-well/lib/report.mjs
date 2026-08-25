// lib/report.mjs — session-independent morning-report generator.
// Compiles a Markdown report from disk; never calls Date.now() or new Date() without args.
// Always use the injected nowEpoch for all time math.
import {
  readFileSync, existsSync, readdirSync,
} from "node:fs";
import { join } from "node:path";

// ── helpers ──────────────────────────────────────────────────────────────────

function fmtEpoch(epoch) {
  if (epoch == null || isNaN(epoch)) return "—";
  return new Date(epoch * 1000).toISOString();
}

/** Parse one JSONL file; skip blank/malformed lines silently. */
function readJsonl(path) {
  if (!existsSync(path)) return [];
  const lines = [];
  for (const raw of readFileSync(path, "utf-8").split("\n")) {
    const s = raw.trim();
    if (!s) continue;
    try { lines.push(JSON.parse(s)); } catch { /* malformed — skip */ }
  }
  return lines;
}

/** Find the newest run-*.json archive in state/ */
function newestArchive(stateDir) {
  if (!existsSync(stateDir)) return null;
  const files = readdirSync(stateDir)
    .filter((f) => /^run-.*\.json$/.test(f))
    .sort();            // lexicographic; run-<date>.json sorts newest-last
  if (!files.length) return null;
  try {
    return JSON.parse(readFileSync(join(stateDir, files[files.length - 1]), "utf-8"));
  } catch { return null; }
}

// ── public API ────────────────────────────────────────────────────────────────

/**
 * buildReport({ home, nowEpoch }) → markdown string
 *
 * @param {string} home      – root dir (e.g. ~/sleep-well or a tmp fixture)
 * @param {number} nowEpoch  – current time as Unix epoch seconds (injected; never call Date.now() here)
 */
export function buildReport({ home, nowEpoch }) {
  const stateDir  = join(home, "state");
  const logsDir   = join(home, "logs");
  const currentP  = join(stateDir, "current-run.json");
  const heartbeatP = join(stateDir, "heartbeat");
  const stopP     = join(home, "STOP");
  const findingsP = join(home, "findings.jsonl");
  const backupP   = join(home, "backups", "backup-manifest.jsonl");

  // ── 1. Load run state ─────────────────────────────────────────────────────
  let runState = null;
  if (existsSync(currentP)) {
    try { runState = JSON.parse(readFileSync(currentP, "utf-8")); } catch { /* malformed */ }
  }
  if (!runState) {
    runState = newestArchive(stateDir);
  }

  if (!runState) {
    return [
      "# sleep-well 晨报",
      "",
      "> ⚠️ 找不到运行记录（current-run.json 及归档均不存在）。",
      "> 夜班可能未启动，或 `~/sleep-well/state/` 目录尚不存在。",
      "",
      "恢复：重开 /loop sleep-well",
    ].join("\n");
  }

  const tasks    = Array.isArray(runState.tasks) ? runState.tasks : [];
  const findings = readJsonl(findingsP);
  const backups  = readJsonl(backupP);

  // ── 2. Heartbeat / status banner ──────────────────────────────────────────
  const STALE_SECS = 20 * 60;   // 20 minutes
  const hasStop = existsSync(stopP);

  let heartbeatEpoch = null;
  if (existsSync(heartbeatP)) {
    try {
      heartbeatEpoch = Math.floor(new Date(readFileSync(heartbeatP, "utf-8").trim()).getTime() / 1000);
    } catch { /* bad timestamp — leave null */ }
  }

  let statusBanner;
  if (hasStop) {
    statusBanner = "✅ **正常停止** — STOP 文件已存在，夜班已结束。";
  } else if (heartbeatEpoch == null) {
    // No heartbeat written — treat as interrupted / not started
    statusBanner = "⚠️ **疑似中断** — 未发现心跳文件，夜班可能从未启动或很早崩溃。重开 /loop sleep-well 以恢复。";
  } else {
    const age = nowEpoch - heartbeatEpoch;
    if (age > STALE_SECS) {
      const ageMin = Math.round(age / 60);
      statusBanner = `⚠️ **疑似中断 (heartbeat stale ${ageMin} min)** — 心跳已停止 ${ageMin} 分钟。重开 /loop sleep-well 以恢复。`;
    } else {
      statusBanner = "🟢 **运行中** — 心跳新鲜，夜班正常进行。";
    }
  }

  // ── 3. Build sections ─────────────────────────────────────────────────────
  const lines = [];

  lines.push("# sleep-well 晨报");
  lines.push("");
  lines.push(`## 状态`);
  lines.push("");
  lines.push(statusBanner);
  lines.push("");
  lines.push(`| 字段 | 值 |`);
  lines.push(`|---|---|`);
  lines.push(`| 开始时间 | ${fmtEpoch(runState.startedAt)} |`);
  lines.push(`| 最后心跳 | ${heartbeatEpoch != null ? fmtEpoch(heartbeatEpoch) : "—"} |`);
  lines.push(`| 团队委派次数 | ${runState.teamDelegationsTonight ?? 0} |`);
  lines.push(`| 截止时间 | ${fmtEpoch(runState.cutoffEpoch)} |`);
  lines.push("");

  // ── 任务一览 ──────────────────────────────────────────────────────────────
  lines.push("## 任务一览");
  lines.push("");
  if (tasks.length === 0) {
    lines.push("_（无任务）_");
  } else {
    lines.push("| id | 标题 | 状态 | 审查轮 | auto findings | needs-human findings |");
    lines.push("|---|---|---|---|---|---|");
    for (const t of tasks) {
      const tFindings = findings.filter((f) => f.taskId === t.id);
      const autoCount = tFindings.filter((f) => f.severity === "auto").length;
      const nhCount   = tFindings.filter((f) => f.severity === "needs-human").length;
      const rotations = Array.isArray(t.findingsHistory) ? t.findingsHistory.length : (t.reviewRotations ?? 0);
      lines.push(`| ${t.id} | ${t.title ?? ""} | ${t.status} | ${rotations} | ${autoCount} | ${nhCount} |`);
    }
  }
  lines.push("");

  // ── 需要你处理 ────────────────────────────────────────────────────────────
  const nhTasks = tasks.filter((t) => t.status === "needs_human");
  lines.push("## 需要你处理");
  lines.push("");
  if (nhTasks.length === 0) {
    lines.push("_（无需人工处理的任务）_");
  } else {
    for (const t of nhTasks) {
      lines.push(`### ${t.id} — ${t.title ?? "(无标题)"}`);
      const nhFindings = findings.filter((f) => f.taskId === t.id && f.severity === "needs-human");
      if (nhFindings.length === 0) {
        lines.push("_（无 needs-human findings）_");
      } else {
        for (const f of nhFindings) {
          lines.push(`- \`${f.file}:${f.line}\` — ${f.issue}`);
        }
      }
      lines.push("");
    }
  }

  // ── 已备份的文件 ──────────────────────────────────────────────────────────
  lines.push("## 已备份的文件");
  lines.push("");
  if (backups.length === 0) {
    lines.push("_（无备份记录）_");
  } else {
    for (const b of backups) {
      lines.push(`- **${b.original}** → \`${b.backupPath}\``);
      lines.push(`  - 运行日期: ${b.runDate ?? "—"}，原因: ${b.reason ?? "—"}`);
      lines.push(`  - 确认无误后可删: \`rm "${b.backupPath}"\``);
    }
  }
  lines.push("");

  // ── 完成/跳过 ─────────────────────────────────────────────────────────────
  const doneTasks    = tasks.filter((t) => t.status === "done");
  const skippedTasks = tasks.filter((t) => t.status === "skipped");
  lines.push("## 完成/跳过");
  lines.push("");
  if (doneTasks.length === 0 && skippedTasks.length === 0) {
    lines.push("_（无完成或跳过任务）_");
  } else {
    for (const t of doneTasks)    lines.push(`- ✅ **${t.id}** ${t.title ?? ""}`);
    for (const t of skippedTasks) lines.push(`- ⏭️ **${t.id}** ${t.title ?? ""} _(skipped)_`);
  }
  lines.push("");

  // ── 详细日志 ──────────────────────────────────────────────────────────────
  lines.push("## 详细日志");
  lines.push("");
  const logFiles = existsSync(logsDir)
    ? readdirSync(logsDir).filter((f) => f.endsWith(".md")).sort()
    : [];
  if (logFiles.length === 0) {
    lines.push("_（无日志文件）_");
  } else {
    for (const f of logFiles) lines.push(`- \`${join(logsDir, f)}\``);
  }
  lines.push("");

  lines.push("---");
  lines.push("恢复：重开 /loop sleep-well");

  return lines.join("\n");
}
