// lib/report.mjs — session-independent morning-report generator.
// Compiles a Markdown report from disk; never calls Date.now() or new Date() without args.
// Always use the injected nowEpoch for all time math.
import {
  readFileSync, existsSync, readdirSync,
} from "node:fs";
import { join } from "node:path";

// ── helpers ──────────────────────────────────────────────────────────────────

function fmtEpoch(epoch) {
  if (epoch == null) return "—";
  const value = Number(epoch);
  if (!Number.isFinite(value)) return "—";
  const date = new Date(value * 1000);
  return Number.isNaN(date.getTime()) ? "—" : date.toISOString();
}

// Report inputs include model-generated findings and filesystem names. Replace
// terminal control characters instead of failing the emergency report.
function safeDisplay(value) {
  return String(value ?? "").replace(/\p{Cc}/gu, "�");
}
function safeCode(value) {
  return safeDisplay(value).replace(/`/g, "ˋ");
}
function safeTable(value) {
  return safeDisplay(value).replace(/\\/g, "\\\\").replace(/\|/g, "\\|");
}

function corruptStateNotice({ corruptPath, currentP, logsDir, commitPrefix, recoveryHint, archivePath }) {
  const source = archivePath
    ? `以下详情仅来自历史归档 \`${safeCode(archivePath)}\`，不代表本夜实际进展。`
    : "归档里也没有可用记录。";
  return [
    "> 🚨 **状态文件损坏，本夜实际进展未知。**",
    `> \`${safeCode(corruptPath || currentP)}\` 存在但无法解析；${source}`,
    "> 夜班很可能是跑过的——任务可能已实现甚至已 checkpoint，**不要据此认为什么都没发生**。",
    "",
    "请自行核对：",
    `- \`${safeCode(logsDir)}/\` 下的运行日志`,
    `- 队列里各仓库的 \`git log\`（本工具的 checkpoint 提交信息以 \`${safeCode(commitPrefix)}\` 开头）`,
    `- 损坏的状态文件本身（未删除，保留在 \`${safeCode(corruptPath || currentP)}\`）`,
    "",
    "恢复前先确认没有仍在运行的编排器，并核对各任务仓库的工作树与 checkpoint。然后把损坏文件移动到同目录下不匹配 `run-*.json` 的 `corrupt-current-run-<时间戳>.json.bak` 隔离名；保留证据，不要删除。",
    "",
    `恢复：${safeDisplay(recoveryHint)}`,
  ];
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

/** Find the newest run-*.json archive in state/.
 *  Returns { state, corrupt, path }; an unreadable archive is distinct from no archive. */
function newestArchive(stateDir) {
  if (!existsSync(stateDir)) return { state: null, corrupt: false };
  const files = readdirSync(stateDir)
    .filter((f) => /^run-.*\.json$/.test(f))
    .sort();            // run-YYYY-MM-DDTHHMMSS[~NNN].json sorts newest-last (and after legacy date-only names)
  if (!files.length) return { state: null, corrupt: false };
  const newest = join(stateDir, files[files.length - 1]);
  try {
    return { state: JSON.parse(readFileSync(newest, "utf-8")), corrupt: false, path: newest };
  } catch { return { state: null, corrupt: true, path: newest }; }
}

// ── public API ────────────────────────────────────────────────────────────────

/**
 * buildReport({ home, nowEpoch }) → markdown string
 *
 * @param {string} home      – root dir (e.g. ~/sleep-well or a tmp fixture)
 * @param {number} nowEpoch  – current time as Unix epoch seconds (injected; never call Date.now() here)
 */
export function heartbeatStaleSeconds(raw = process.env.SLEEP_WELL_AI_TIMEOUT) {
  const text = raw == null || raw === "" ? "1800" : String(raw);
  if (!/^\d+$/.test(text)) return 2700;
  const seconds = Number(text);
  if (!Number.isSafeInteger(seconds) || seconds < 1 || seconds > 86_400) return 2700;
  return Math.max(2700, seconds + 900);
}

export function buildReport({ home, nowEpoch, recoveryHint = "重开 /loop sleep-well", stopPath, commitPrefix = "sleep-well:", backupDir, staleSecs = heartbeatStaleSeconds() }) {
  const stateDir  = join(home, "state");
  const logsDir   = join(home, "logs");
  const currentP  = join(stateDir, "current-run.json");
  const heartbeatP = join(stateDir, "heartbeat");
  const stopP     = stopPath || join(home, "STOP");  // Codex 侧 home 是 root/codex，STOP 在 root
  const findingsP = join(home, "findings.jsonl");
  const backupP   = join(backupDir || join(home, "backups"), "backup-manifest.jsonl");

  // ── 1. Load run state ─────────────────────────────────────────────────────
  // A corrupt state file means progress is unknown, not that the run never started.
  let runState = null;
  let stateCorrupt = false;
  let corruptPath = null;
  let stateSourcePath = null;
  if (existsSync(currentP)) {
    try { runState = JSON.parse(readFileSync(currentP, "utf-8")); stateSourcePath = currentP; }
    catch { stateCorrupt = true; corruptPath = currentP; }
  }
  if (!runState) {
    const arch = newestArchive(stateDir);
    runState = arch.state;
    if (arch.state) stateSourcePath = arch.path;
    if (arch.corrupt) { stateCorrupt = true; corruptPath = corruptPath || arch.path; }
  }

  if (!runState) {
    if (stateCorrupt) {
      return [
        "# sleep-well 晨报",
        "",
        ...corruptStateNotice({ corruptPath, currentP, logsDir, commitPrefix, recoveryHint, archivePath: null }),
      ].join("\n");
    }
    return [
      "# sleep-well 晨报",
      "",
      "> ⚠️ 找不到运行记录（current-run.json 及归档均不存在）。",
      "> 夜班可能未启动，或 `~/sleep-well/state/` 目录尚不存在。",
      "",
      `恢复：${recoveryHint}`,
    ].join("\n");
  }

  const tasks    = Array.isArray(runState.tasks) ? runState.tasks : [];
  // findings.jsonl intentionally retains history for Tier-1 discovery. Morning
  // reports must show only this run and count each stable finding key once.
  const findingsByKey = new Map();
  for (const finding of readJsonl(findingsP)) {
    if (finding.runId !== runState.startedAt) continue;
    const key = `${finding.taskId ?? ""}\0${finding.key || JSON.stringify([
      finding.repo, finding.file, finding.line, finding.issue, finding.severity, finding.taskId,
    ])}`;
    findingsByKey.set(key, finding);
  }
  const findings = [...findingsByKey.values()];
  // backup-manifest.jsonl also retains history. Show only backups newly created
  // for the run represented by this report.
  const backups  = readJsonl(backupP).filter((b) => b.runId === runState.startedAt);

  // ── 2. Heartbeat / status banner ──────────────────────────────────────────
  const STALE_SECS = Number.isSafeInteger(staleSecs) && staleSecs > 0
    ? staleSecs
    : heartbeatStaleSeconds();
  const hasStop = existsSync(stopP);

  let heartbeatEpoch = null;
  if (existsSync(heartbeatP)) {
    try {
      const heartbeatMs = new Date(readFileSync(heartbeatP, "utf-8").trim()).getTime();
      heartbeatEpoch = Number.isFinite(heartbeatMs) ? Math.floor(heartbeatMs / 1000) : null;
    } catch { /* bad timestamp — leave null */ }
  }

  // A finalized run takes precedence over a recently written heartbeat.
  let statusBanner;
  const term = runState && runState.terminatedAt ? runState : null;
  if (stateCorrupt) {
    statusBanner = `🚨 **状态文件损坏** — 下方表格来自历史归档 \`${safeCode(stateSourcePath)}\`，不代表本夜进展。`;
  } else if (term) {
    statusBanner = `✅ **已收工** — ${safeDisplay(term.terminatedReason || "原因未记录")}。`;
  } else if (hasStop) {
    statusBanner = "✅ **正常停止** — STOP 文件已存在，夜班已结束。";
  } else if (heartbeatEpoch == null) {
    // No heartbeat written — treat as interrupted / not started
    statusBanner = `⚠️ **疑似中断** — 未发现心跳文件，夜班可能从未启动或很早崩溃。${recoveryHint} 以恢复。`;
  } else {
    const age = nowEpoch - heartbeatEpoch;
    if (age > STALE_SECS) {
      const ageMin = Math.round(age / 60);
      statusBanner = `⚠️ **疑似中断 (heartbeat stale ${ageMin} min)** — 心跳已停止 ${ageMin} 分钟。${recoveryHint} 以恢复。`;
    } else {
      statusBanner = "🟢 **运行中** — 心跳新鲜，夜班正常进行。";
    }
  }

  // ── 3. Build sections ─────────────────────────────────────────────────────
  const lines = [];

  lines.push("# sleep-well 晨报");
  lines.push("");
  if (stateCorrupt) {
    lines.push(...corruptStateNotice({
      corruptPath, currentP, logsDir, commitPrefix, recoveryHint, archivePath: stateSourcePath,
    }));
    lines.push("");
  }
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
      lines.push(`| ${safeTable(t.id)} | ${safeTable(t.title)} | ${safeTable(t.status)} | ${rotations} | ${autoCount} | ${nhCount} |`);
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
      lines.push(`### ${safeDisplay(t.id)} — ${safeDisplay(t.title ?? "(无标题)")}`);
      const nhFindings = findings.filter((f) => f.taskId === t.id && f.severity === "needs-human");
      if (nhFindings.length === 0) {
        lines.push("_（无 needs-human findings）_");
      } else {
        for (const f of nhFindings) {
          lines.push(`- \`${safeCode(f.file)}:${safeCode(f.line)}\` — ${safeDisplay(f.issue)}`);
        }
      }
      lines.push("");
    }
  }

  // ── 本夜备份的文件 ────────────────────────────────────────────────────────
  lines.push("## 本夜备份的文件");
  lines.push("");
  if (backups.length === 0) {
    lines.push("_（无备份记录）_");
  } else {
    for (const b of backups) {
      lines.push(`- **${safeDisplay(b.original)}** → \`${safeCode(b.backupPath)}\``);
      lines.push(`  - 运行日期: ${safeDisplay(b.runDate ?? "—")}，原因: ${safeDisplay(b.reason ?? "—")}`);
      lines.push("  - 确认无误后，请逐字核对目标并用文件管理器或人工命令删除；本报告不生成可复制的删除命令。");
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
    for (const t of doneTasks)    lines.push(`- ✅ **${safeDisplay(t.id)}** ${safeDisplay(t.title)}`);
    for (const t of skippedTasks) lines.push(`- ⏭️ **${safeDisplay(t.id)}** ${safeDisplay(t.title)} _(skipped)_`);
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
    for (const f of logFiles) lines.push(`- \`${safeCode(join(logsDir, f))}\``);
  }
  lines.push("");

  lines.push("---");
  lines.push(`恢复：${safeDisplay(recoveryHint)}`);

  return lines.join("\n");
}
