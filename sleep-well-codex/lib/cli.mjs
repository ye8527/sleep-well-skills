#!/usr/bin/env node
// lib/cli.mjs — 把 lib 模块的操作暴露成子命令，供 orchestrator.sh 调用。
//
// 为什么不用 sleep-well 那种内联 `node --input-type=module -e '...'`:
// 那种写法把 JS 塞进 shell 单引号里，路径含引号/中文/空格时极易炸，且 shell 与 JS 的
// 引号嵌套无法静态检查——sleep-well 的 SKILL.md 专门写了一节注意事项来提醒这件事。
// 走子命令后，参数经 argv 传递，shell 侧只需正常引用变量。
//
// 约定: 成功时把 JSON 写 stdout 并 exit 0；失败时把原因写 stderr 并 exit 1。
// 绝不在失败时打印看起来像成功的 JSON——编排器靠退出码分支。

import { readFileSync, writeFileSync, existsSync, mkdirSync, unlinkSync } from "node:fs";
import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
import { dirname } from "node:path";
import { parseQueue } from "./queue.mjs";
import { newRunState, saveState, loadState, selectNextTask, hasDeferredReviews, advance, pastCutoff } from "./state.mjs";
import { decideNext } from "./reviewLoop.mjs";
import { loadConfig } from "./config.mjs";
import { backupFile } from "./backup.mjs";
import { classifyCommand, isProtectedPath } from "./guardrails.mjs";
import { appendFinding } from "./findings.mjs";
import { parseReviewOutput, extractFindings, verifyFindingsIntegrity } from "./claudeReview.mjs";
import { classifyOutcome, decideHop, nextBackoffHops } from "./quota.mjs";

const HOME = process.env.HOME;
const ROOT = process.env.SLEEP_WELL_ROOT || `${HOME}/sleep-well`;
const CODEX_HOME = `${ROOT}/codex`;
const STATE_DIR = `${CODEX_HOME}/state`;
const STATE_FILE = `${STATE_DIR}/current-run.json`;
const QUEUE_FILE = process.env.SLEEP_WELL_QUEUE || `${ROOT}/queue.md`;

const die = (m) => { process.stderr.write(String(m) + "\n"); process.exit(1); };
const out = (o) => { process.stdout.write(JSON.stringify(o) + "\n"); };
// ⚠️ lib/state.mjs 的 loadState 直接 JSON.parse(readFileSync(...))——文件缺失时**抛
// ENOENT**，不返回 null；空文件则 JSON.parse("") 抛 SyntaxError。两种都要自己守，
// 否则编排器会把「没有活动 run」这种正常状态当成崩溃。
const stateExists = () => existsSync(STATE_FILE) && readFileSync(STATE_FILE, "utf8").trim() !== "";
const readState = () => {
  if (!stateExists()) die(`没有活动的 run: ${STATE_FILE}`);
  return loadState(STATE_FILE);
};

// 复核仓库当前是否仍有未提交改动（同步、只读）
function repoStillDirty(repo) {
  try {
    const { execFileSync } = require("node:child_process");
    return execFileSync("git", ["-C", repo, "status", "--porcelain"], { encoding: "utf8" }).trim() !== "";
  } catch { return true; }   // 查不出来就保守认为仍脏
}

const [, , cmd, ...rest] = process.argv;

try {
  switch (cmd) {
    // ── 生命周期 ──────────────────────────────────────────────────────
    case "init": {
      // 已有活动 run 则原样返回（跨跳续跑的关键: 固定文件名，不按日期命名）
      if (stateExists()) {
        const existing = loadState(STATE_FILE);
        out({ resumed: true, tasks: existing.tasks.length, cutoffEpoch: existing.cutoffEpoch });
        break;
      }
      if (!existsSync(QUEUE_FILE)) die(`队列文件不存在: ${QUEUE_FILE}`);
      const cfg = loadConfig(`${CODEX_HOME}/config.json`);
      const tasks = parseQueue(readFileSync(QUEUE_FILE, "utf8"));
      if (tasks.length === 0) die("队列为空");
      const st = newRunState(tasks);
      st.startedAt = Math.floor(Date.now() / 1000);
      st.cutoffEpoch = nextMorningEpoch(cfg.morning_hour);
      st.backoffAttempt = 0;
      mkdirSync(STATE_DIR, { recursive: true });
      saveState(STATE_FILE, st);
      out({ resumed: false, tasks: tasks.length, cutoffEpoch: st.cutoffEpoch });
      break;
    }
    case "cutoff-passed": {
      const st = readState();
      out({ passed: pastCutoff(Math.floor(Date.now() / 1000), st.cutoffEpoch), cutoffEpoch: st.cutoffEpoch });
      break;
    }
    case "next-task": {
      // 选择逻辑在 lib/state.mjs 的 selectNextTask——**测试测的就是这一份**
      // （R16 自查: 原来 state.nextTask 有 4 条单测却零生产调用，而这里这套零单测）。
      const st = readState();
      out(selectNextTask(st, repoStillDirty));
      break;
    }
    case "advance": {
      const [id, to] = rest;
      const st = readState();
      advance(st, id, to);
      saveState(STATE_FILE, st);
      out({ id, status: to });
      break;
    }
    case "get-field": {
      const [id, key] = rest;
      const st = readState();
      const t = st.tasks.find((x) => x.id === id);
      if (!t) die(`no task ${id}`);
      process.stdout.write(t[key] == null ? "" : String(t[key]) + "\n");
      break;
    }
    case "set-field-str": {
      // 值按字符串原样存，免去调用方手工拼 JSON（路径含引号/反斜杠时会炸）
      const [id, key, val] = rest;
      const st = readState();
      const t = st.tasks.find((x) => x.id === id);
      if (!t) die(`no task ${id}`);
      t[key] = val == null ? "" : String(val);
      saveState(STATE_FILE, st);
      out({ id, [key]: t[key] });
      break;
    }
    case "set-field": {
      // set-field <id> <key> <jsonValue>
      const [id, key, raw] = rest;
      const st = readState();
      const t = st.tasks.find((x) => x.id === id);
      if (!t) die(`no task ${id}`);
      t[key] = JSON.parse(raw);
      saveState(STATE_FILE, st);
      out({ id, [key]: t[key] });
      break;
    }
    case "push-findings-count": {
      // push-findings-count <id> <n> → 追加到 findingsHistory 并给出 decideNext 判定
      const [id, n] = rest;
      const st = readState();
      const t = st.tasks.find((x) => x.id === id);
      if (!t) die(`no task ${id}`);
      t.findingsHistory = Array.isArray(t.findingsHistory) ? t.findingsHistory : [];
      t.findingsHistory.push(Number(n));
      t.reviewRotations = t.reviewRotations || 0;
      const cfg = loadConfig(`${CODEX_HOME}/config.json`);
      const d = decideNext(t.findingsHistory, t.reviewRotations, cfg);
      if (d.action === "rotate") { t.reviewRotations += 1; t.findingsHistory = []; }
      saveState(STATE_FILE, st);
      out({ ...d, history: t.findingsHistory, rotations: t.reviewRotations });
      break;
    }

    // ── 审查产物解析 ──────────────────────────────────────────────────
    case "parse-review": {
      // parse-review <stdoutFile> <stderrFile> <code>
      const [so, se, code] = rest;
      const r = parseReviewOutput(
        existsSync(so) ? readFileSync(so, "utf8") : "",
        existsSync(se) ? readFileSync(se, "utf8") : "",
        Number(code || 0),
      );
      out(r);
      break;
    }
    case "record-findings": {
      // record-findings <findingsFile> <taskId> <repo> → 写 findings.jsonl + 完整性断言
      const [ff, taskId, repo] = rest;
      if (!existsSync(ff)) die(`findings 文件不存在: ${ff}`);
      const body = readFileSync(ff, "utf8");
      const m = body.match(/^-\s*findings 条数:\s*(\d+)/m);
      const declared = m ? Number(m[1]) : null;
      if (declared === null) die("findings 文件缺少条数声明");
      const integrity = verifyFindingsIntegrity(body, declared);
      if (!integrity.ok) die(integrity.reason);
      const items = extractFindings(body);
      if (items.length !== declared) {
        die(`抽取到 ${items.length} 条 findings，声明 ${declared} 条——不一致，拒绝记录`);
      }
      for (const it of items) {
        appendFinding(`${CODEX_HOME}/findings.jsonl`, {
          repo, file: it.file, line: it.location, issue: it.title,
          severity: it.kind, taskId,
        });
      }
      out({ declared, recorded: items.length, autoFixable: items.filter((i) => i.kind === "auto").length });
      break;
    }

    // ── 额度与退避 ────────────────────────────────────────────────────
    case "classify": {
      // classify <outputFile> <code> <side>
      const [of_, code, side] = rest;
      out(classifyOutcome(existsSync(of_) ? readFileSync(of_, "utf8") : "", Number(code || 0), side));
      break;
    }
    case "decide-hop": {
      const [ck, xk] = rest;
      out(decideHop(ck, xk));
      break;
    }
    case "backoff": {
      const st = readState();
      const r = nextBackoffHops(st.backoffAttempt || 0);
      out(r);
      break;
    }
    case "backoff-bump": {
      const st = readState();
      st.backoffAttempt = (st.backoffAttempt || 0) + 1;
      saveState(STATE_FILE, st);
      out({ attempt: st.backoffAttempt });
      break;
    }
    case "backoff-reset": {
      const st = readState();
      st.backoffAttempt = 0;
      saveState(STATE_FILE, st);
      out({ attempt: 0 });
      break;
    }


    // ── 持久可用性状态（Codex R1 #6）─────────────────────────────────
    // 每一跳都是新进程，可用性判定若只存在内存变量里，下一跳全部重置为 ok，
    // decideHop 永远看不到 auth/quota → 认证失效不会 halt、额度中继形同虚设。
    case "availability-get": {
      const st = readState();
      const a = st.availability || { claude: "ok", codex: "ok" };
      out(a);
      break;
    }
    case "availability-set": {
      const [side, kind] = rest;
      const st = readState();
      st.availability = st.availability || { claude: "ok", codex: "ok" };
      st.availability[side] = kind;
      saveState(STATE_FILE, st);
      out(st.availability);
      break;
    }
    case "availability-reset": {
      const st = readState();
      st.availability = { claude: "ok", codex: "ok" };
      // 两侧恢复即解除全部挂起的审查（Codex R1 #5: 原实现只设不清，任务被永久跳过）
      let cleared = 0;
      for (const t of st.tasks) if (t.reviewDeferred) { t.reviewDeferred = false; cleared++; }
      saveState(STATE_FILE, st);
      out({ availability: st.availability, clearedDeferred: cleared });
      break;
    }

    // ── 退避倒计时（Codex R1 #7）─────────────────────────────────────
    // 原实现只把 hops 打进日志，launchd 5 分钟后照样重试；且先 bump 再读，
    // 首次就用了第二档，半小时就宣称「约 3 小时退避耗尽」。改为持久化 nextRetryEpoch。
    case "retry-due": {
      const st = readState();
      const now = Math.floor(Date.now() / 1000);
      out({ due: !st.nextRetryEpoch || now >= st.nextRetryEpoch, nextRetryEpoch: st.nextRetryEpoch || 0 });
      break;
    }
    case "backoff-schedule": {
      const st = readState();
      const attempt = st.backoffAttempt || 0;      // 先按当前档排期，再 bump
      const r = nextBackoffHops(attempt);
      if (r.giveUp) { out({ giveUp: true, attempt }); break; }
      st.nextRetryEpoch = Math.floor(Date.now() / 1000) + r.hops * 300;
      st.backoffAttempt = attempt + 1;
      saveState(STATE_FILE, st);
      out({ giveUp: false, hops: r.hops, attempt: st.backoffAttempt, nextRetryEpoch: st.nextRetryEpoch });
      break;
    }
    case "backoff-clear": {
      const st = readState();
      st.backoffAttempt = 0;
      st.nextRetryEpoch = 0;
      saveState(STATE_FILE, st);
      out({ attempt: 0 });
      break;
    }

    // ── 终止标记（Codex R1 #2）───────────────────────────────────────
    // archive 删掉活动状态后，下一次 launchd 触发会重新 init、把整夜从头再跑一遍；
    // STOP 场景还会每 5 分钟重复推一次早报。故先落终止标记，编排器开头即检。
    case "terminal-set": {
      const [reason] = rest;
      mkdirSync(CODEX_HOME, { recursive: true });
      writeFileSync(`${CODEX_HOME}/TERMINATED`,
        JSON.stringify({ at: new Date().toISOString(), reason }) + "\n");
      out({ terminated: true, reason });
      break;
    }
    case "terminal-check": {
      out({ terminated: existsSync(`${CODEX_HOME}/TERMINATED`) });
      break;
    }
    case "terminal-clear": {
      // 下一夜的启动路径（Codex R2 #12）: 不清除的话第一夜之后永远不再开工。
      // 由用户重新 `launchctl load` 时经 SKILL.md 的启动流程显式调用。
      if (existsSync(`${CODEX_HOME}/TERMINATED`)) unlinkSync(`${CODEX_HOME}/TERMINATED`);
      out({ cleared: true });
      break;
    }
    case "mark-terminal-in-state": {
      // 让早报看到「已收工」而不是「运行中」（Codex R1 #18）
      const [reason] = rest;
      const st = readState();
      st.terminatedAt = Math.floor(Date.now() / 1000);
      st.terminatedReason = reason;
      saveState(STATE_FILE, st);
      out({ terminatedAt: st.terminatedAt });
      break;
    }
    // ── 护栏 ──────────────────────────────────────────────────────────
    case "check-command": {
      out(classifyCommand(rest.join(" ")));
      break;
    }
    case "check-path": {
      out({ protected: isProtectedPath(rest[0]) });
      break;
    }
    case "backup-file": {
      // backup-file <原文件> <backupRoot> <runDate> <reason>
      // 只对**未被 git 跟踪**的受保护文件调用——已跟踪的由 git checkpoint 兜底。
      // 这条通路在 R11 之前一直是断的: backup.mjs 被复制进来却零调用点，
      // 于是相对 sleep-well 静默丢了「被忽略的 .env 被改后还能还原」这项能力。
      const [orig, root, runDate, reason] = rest;
      if (!orig || !root || !runDate) die("backup-file 参数不足");
      // ⚠️ 失败必须**退出码非零**（Codex R12 #2）: 原来打 {ok:false} 却 exit 0，
      // shell 侧 `if node ... ; then n=$((n+1))` 会把它算成成功，于是「已备份 N 份」
      // 是假的——护栏报警时你以为有副本可还原，其实没有。
      // 本文件开头的约定就写着「绝不在失败时打印看起来像成功的 JSON」，我自己违反了。
      try {
        const e = backupFile(orig, { backupRoot: root, runDate, reason: reason || "guard-snapshot" });
        out({ ok: true, ...e });
      } catch (err) {
        die(`backup-file 失败: ${String(err && err.message || err)}`);
      }
      break;
    }

    case "protected-in": {
      // protected-in [--null] <fileListFile> → 列出其中命中 isProtectedPath 的路径
      //
      // --null: 输入以 NUL 分隔（Codex R9 #3）。git 允许文件名含换行，按行切分会把
      // `legal\nnotes.txt` 拆成 `legal` 与 `notes.txt`——权威判定看到的是不存在的 `legal`，
      // 真实文件从未进入摘要，改它护栏毫无反应。实测复现过。整条管线必须是 NUL 协议。
      const nul = rest[0] === "--null";
      const lf = nul ? rest[1] : rest[0];
      const raw = existsSync(lf) ? readFileSync(lf, "utf8") : "";
      const lines = raw.split(nul ? "\0" : "\n").filter(Boolean);
      out({ protected: lines.filter((p) => isProtectedPath(p)) });
      break;
    }

    // ── 收尾 ──────────────────────────────────────────────────────────
    case "summary": {
      const st = readState();
      const by = {};
      for (const t of st.tasks) by[t.status] = (by[t.status] || 0) + 1;
      out({ total: st.tasks.length, byStatus: by,
            needsHuman: st.tasks.filter((t) => t.status === "needs_human").map((t) => t.id) });
      break;
    }
    case "archive": {
      const st = readState();
      const d = new Date((st.startedAt || Math.floor(Date.now() / 1000)) * 1000);
      const stamp = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
      const dest = `${STATE_DIR}/run-${stamp}.json`;
      mkdirSync(dirname(dest), { recursive: true });
      writeFileSync(dest, JSON.stringify(st, null, 2));
      // 必须删除而非清空: loadState 对空文件会 JSON.parse("") 抛错，
      // 下一夜的 init 会误判成「状态损坏」而不是「没有活动 run」。
      unlinkSync(STATE_FILE);
      out({ archived: dest });
      break;
    }
    default:
      die(`未知子命令: ${cmd}`);
  }
} catch (e) {
  die(e && e.stack ? e.stack : String(e));
}

// 下一个 morning_hour 的 epoch（从墙钟算，23:00 启动 + morning 07:00 → 次日 07:00）
function nextMorningEpoch(hhmm) {
  const [h, m] = String(hhmm || "07:00").split(":").map(Number);
  const now = new Date();
  const t = new Date(now);
  t.setHours(h, m, 0, 0);
  if (t <= now) t.setDate(t.getDate() + 1);
  return Math.floor(t.getTime() / 1000);
}
