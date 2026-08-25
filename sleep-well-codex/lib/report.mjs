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

/** Find the newest run-*.json archive in state/.
 *  返回 { state, corrupt }: corrupt=true 表示**找到了归档但读不了**——
 *  这与「没有归档」必须分开（Codex R11 提醒: R10 只修了 current-run.json 那一处）。
 *  原实现 `catch { return null }` 把两者折叠，于是最新归档损坏时早报仍会落到
 *  「夜班可能未启动」那个编造原因的分支。 */
function newestArchive(stateDir) {
  if (!existsSync(stateDir)) return { state: null, corrupt: false };
  const files = readdirSync(stateDir)
    .filter((f) => /^run-.*\.json$/.test(f))
    .sort();            // lexicographic; run-<date>.json sorts newest-last
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
export function buildReport({ home, nowEpoch, recoveryHint = "重开 /loop sleep-well", stopPath }) {
  const stateDir  = join(home, "state");
  const logsDir   = join(home, "logs");
  const currentP  = join(stateDir, "current-run.json");
  const heartbeatP = join(stateDir, "heartbeat");
  const stopP     = stopPath || join(home, "STOP");  // Codex 侧 home 是 root/codex，STOP 在 root
  const findingsP = join(home, "findings.jsonl");
  const backupP   = join(home, "backups", "backup-manifest.jsonl");

  // ── 1. Load run state ─────────────────────────────────────────────────────
  // ⚠️ 「文件损坏」与「从未启动」必须分开（R10 自查）。原来两者都落到下面那个
  //    「找不到运行记录…夜班可能未启动」分支——而那句话是**编造的原因**:
  //    夜班可能跑了一整夜、任务已实现并 checkpoint，只是 current-run.json 被写坏了。
  //    早报是两侧 AI 全挂那一夜唯一的产物，而崩溃恰恰是它最可能被写坏的时候——
  //    最需要它说实话的场景，就是它最容易说假话的场景。
  let runState = null;
  let stateCorrupt = false;
  let corruptPath = null;      // 到底是哪个文件坏了——不能报一个不存在的路径（Codex R12 #8）
  if (existsSync(currentP)) {
    try { runState = JSON.parse(readFileSync(currentP, "utf-8")); }
    catch { stateCorrupt = true; corruptPath = currentP; }
  }
  if (!runState) {
    const arch = newestArchive(stateDir);
    runState = arch.state;
    if (arch.corrupt) { stateCorrupt = true; corruptPath = corruptPath || arch.path; }   // 归档损坏同样是「读不了」
  }

  if (!runState) {
    if (stateCorrupt) {
      // 说事实，不猜原因: 文件在、但读不了，所以本夜实际进展**未知**。
      return [
        "# sleep-well 晨报",
        "",
        "> 🚨 **状态文件损坏，本夜实际进展未知。**",
        `> \`${corruptPath || currentP}\` 存在但无法解析，归档里也没有可用记录。`,
        "> 夜班很可能是跑过的——任务可能已实现甚至已 checkpoint，**不要据此认为什么都没发生**。",
        "",
        "请自行核对：",
        `- \`${logsDir}/\` 下的运行日志`,
        "- 队列里各仓库的 `git log`（本工具的 checkpoint 提交信息以 `sleep-well-codex:` 开头）",
        `- 损坏的状态文件本身（未删除，保留在 \`${corruptPath || currentP}\`）`,
        "",
        `恢复：${recoveryHint}`,
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

  // 已收工的运行不应报「运行中」（Codex R2 #11）: finalize 会在出早报之前把
  // terminatedAt/terminatedReason 写进 state，此处优先采信它，否则心跳刚刷新过、
  // 早报会说「运行中」而实际编排器下一步就归档退出了。
  let statusBanner;
  const term = runState && runState.terminatedAt ? runState : null;
  if (term) {
    statusBanner = `✅ **已收工** — ${term.terminatedReason || "原因未记录"}。`;
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
