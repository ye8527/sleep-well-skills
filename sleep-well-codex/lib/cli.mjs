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

import {
  readFileSync, writeFileSync, existsSync, mkdirSync, unlinkSync, lstatSync, readlinkSync,
  openSync, readSync, closeSync, readdirSync, rmSync,
} from "node:fs";
import { createHash } from "node:crypto";
import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
import { dirname } from "node:path";
import { parseQueue } from "./queue.mjs";
import { newRunState, saveState, loadState, selectNextTask, hasDeferredReviews, advance, pastCutoff } from "./state.mjs";
import { decideNext, parseFindingCount } from "./reviewLoop.mjs";
import { loadConfig, parseMorningHour } from "./config.mjs";
import { backupFile } from "./backup.mjs";
import { isProtectedPath } from "./guardrails.mjs";
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
    return execFileSync(
      "git",
      ["-C", repo, "status", "--porcelain", "--", ".", ":(exclude).review"],
      { encoding: "utf8" },
    ).trim() !== "";
  } catch { return true; }   // 查不出来就保守认为仍脏
}

function splitNul(buf) {
  const parts = [];
  let start = 0;
  for (let i = 0; i < buf.length; i++) {
    if (buf[i] !== 0) continue;
    if (i > start) parts.push(buf.subarray(start, i));
    start = i + 1;
  }
  return parts;
}

function modeListSnapshot(listFile) {
  const paths = splitNul(readFileSync(listFile));
  const h = createHash("sha256");
  h.update(`count\0${paths.length}\0`);
  for (const p of [...paths].sort(Buffer.compare)) {
    const st = lstatSync(p);
    if (!st.isFile()) throw new Error("权限快照条目不是普通文件");
    h.update("path\0"); h.update(p); h.update("\0");
    h.update(`mode\0${st.mode}\0`);
  }
  return { count: paths.length, digest: h.digest("hex") };
}

const SNAPSHOT_MAX_ENTRIES = 500_000;
const SNAPSHOT_MAX_BYTES = 64 * 1024 * 1024 * 1024;
const SNAPSHOT_CHUNK_BYTES = 1024 * 1024;

function snapshotGit(repo, args) {
  const { execFileSync } = require("node:child_process");
  return execFileSync("git", ["-C", repo, ...args], {
    encoding: null,
    maxBuffer: 256 * 1024 * 1024,
    stdio: ["ignore", "pipe", "pipe"],
  });
}

function mergeNulPathLists(...lists) {
  const unique = new Map();
  for (const raw of lists) {
    for (const p of splitNul(raw)) unique.set(p.toString("base64"), p);
  }
  const paths = [...unique.values()].sort(Buffer.compare);
  return Buffer.concat(paths.flatMap((p) => [p, Buffer.from([0])]));
}

function hashListedSnapshot(repo, index, pathsRaw, label) {
  const paths = splitNul(pathsRaw);
  if (paths.length > SNAPSHOT_MAX_ENTRIES) {
    throw new Error(`${label} 条目数 ${paths.length} 超过上限 ${SNAPSHOT_MAX_ENTRIES}`);
  }
  const h = createHash("sha256");
  h.update("index\0"); h.update(index);
  h.update("paths\0"); h.update(pathsRaw);
  const root = Buffer.from(repo.endsWith("/") ? repo : `${repo}/`);
  const chunk = Buffer.allocUnsafe(SNAPSHOT_CHUNK_BYTES);
  let totalBytes = 0;
  for (const rel of paths) {
    const abs = Buffer.concat([root, rel]);
    h.update("path\0"); h.update(rel); h.update("\0");
    let st;
    try { st = lstatSync(abs); }
    catch (err) {
      if (err?.code === "ENOENT") { h.update("missing\0"); continue; }
      throw err;
    }
    h.update(`mode\0${st.mode}\0`);
    if (st.isFile()) {
      totalBytes += st.size;
      if (totalBytes > SNAPSHOT_MAX_BYTES) {
        throw new Error(`${label} 文件总大小超过上限 ${SNAPSHOT_MAX_BYTES} 字节`);
      }
      h.update(`file\0${st.size}\0`);
      const fd = openSync(abs, "r");
      try {
        for (;;) {
          const n = readSync(fd, chunk, 0, chunk.length, null);
          if (n === 0) break;
          h.update(chunk.subarray(0, n));
        }
      } finally {
        closeSync(fd);
      }
    } else if (st.isSymbolicLink()) {
      h.update("symlink\0"); h.update(readlinkSync(abs, { encoding: "buffer" }));
    } else if (st.isDirectory()) {
      // A gitlink/submodule's index identity is already in the --stage bytes.
      h.update("directory\0");
    } else {
      h.update("special\0");
    }
    h.update("\0");
  }
  return h.digest("hex");
}

// Hash the exact Git-visible working content and index without invoking clean
// filters or mutating the real index. Streaming plus explicit count/byte bounds
// avoids one Buffer per whole file; the shell caller additionally supplies a
// timeout and heartbeat through run_with_timeout.
function repoContentSnapshot(repo) {
  // The adapter may write files under .review, but it may never mutate the Git
  // index. Include the complete index so staging a review artifact is detected
  // before a later plain `git commit` could submit it. Working-tree content
  // under .review remains intentionally excluded below.
  const index = snapshotGit(repo, ["ls-files", "--stage", "-z", "--", "."]);
  const pathsRaw = snapshotGit(repo, [
    "ls-files", "--cached", "--others", "--exclude-standard", "-z",
    "--", ".", ":(exclude).review",
  ]);
  return hashListedSnapshot(repo, index, pathsRaw, "仓库内容快照");
}

// `.review/` is writable by the external review adapter but is reserved from
// the Codex implement/fix process. Include both ignored and ordinary untracked
// entries so a repository-level .gitignore cannot hide an implementation-side write.
function reviewContentSnapshot(repo) {
  const index = snapshotGit(repo, ["ls-files", "--stage", "-z", "--", ".review"]);
  const ordinary = snapshotGit(repo, [
    "ls-files", "--cached", "--others", "--exclude-standard", "-z", "--", ".review",
  ]);
  const ignored = snapshotGit(repo, [
    "ls-files", "--others", "--ignored", "--exclude-standard", "-z", "--", ".review",
  ]);
  return hashListedSnapshot(repo, index, mergeNulPathLists(ordinary, ignored), ".review 保留区快照");
}

// Hash selected Git metadata paths without invoking Git. This command is used
// immediately after an AI/reviewer process returns, before a malicious change
// to .git/config or hooks could be activated by the next Git command. Do not
// follow symlinks: changing a link or its target text changes the digest, while
// repository-external targets remain outside the documented repository check.
const META_MAX_ENTRIES = 100_000;
const META_MAX_BYTES = 1024 * 1024 * 1024;
function pathContentSnapshot(inputRoots) {
  const roots = [...new Set(inputRoots.filter(Boolean))].sort();
  if (roots.length === 0) throw new Error("Git 元数据快照没有目标路径");
  const h = createHash("sha256");
  const chunk = Buffer.allocUnsafe(SNAPSHOT_CHUNK_BYTES);
  let entries = 0;
  let totalBytes = 0;

  const joinPath = (parent, child) => Buffer.concat([
    parent,
    parent.length > 0 && parent[parent.length - 1] === 47 ? Buffer.alloc(0) : Buffer.from("/"),
    child,
  ]);
  const visit = (abs, rel) => {
    entries++;
    if (entries > META_MAX_ENTRIES) {
      throw new Error(`Git 元数据条目数超过上限 ${META_MAX_ENTRIES}`);
    }
    h.update("path\0"); h.update(rel); h.update("\0");
    let st;
    try { st = lstatSync(abs); }
    catch (err) {
      if (err?.code === "ENOENT") { h.update("missing\0"); return; }
      throw err;
    }
    h.update(`mode\0${st.mode}\0`);
    if (st.isFile()) {
      totalBytes += st.size;
      if (totalBytes > META_MAX_BYTES) {
        throw new Error(`Git 元数据文件总大小超过上限 ${META_MAX_BYTES} 字节`);
      }
      h.update(`file\0${st.size}\0`);
      const fd = openSync(abs, "r");
      try {
        for (;;) {
          const n = readSync(fd, chunk, 0, chunk.length, null);
          if (n === 0) break;
          h.update(chunk.subarray(0, n));
        }
      } finally {
        closeSync(fd);
      }
    } else if (st.isSymbolicLink()) {
      h.update("symlink\0"); h.update(readlinkSync(abs, { encoding: "buffer" }));
    } else if (st.isDirectory()) {
      const names = readdirSync(abs, { encoding: "buffer" }).sort(Buffer.compare);
      h.update(`directory\0${names.length}\0`);
      for (const name of names) visit(joinPath(abs, name), joinPath(rel, name));
    } else {
      h.update("special\0");
    }
    h.update("\0");
  };

  for (const root of roots) {
    const abs = Buffer.from(root);
    h.update("root\0"); h.update(abs); h.update("\0");
    visit(abs, Buffer.from("."));
  }
  return h.digest("hex");
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
      const selected = selectNextTask(st, repoStillDirty);
      if (selected.task) {
        for (const key of ["id", "repo", "status"]) {
          if (typeof selected.task[key] !== "string" || selected.task[key].length === 0) {
            die(`选中的任务缺少有效 ${key}，状态可能损坏`);
          }
        }
      }
      // taskId is always present (empty only when task is null), so shell-side
      // extraction failure cannot be confused with a genuinely idle run.
      out({ ...selected, taskId: selected.task?.id ?? "" });
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
    case "graceful-hop-exit": {
      // Planned launchd hand-offs deliberately preserve in-flight state for
      // the next trigger. Bind the marker to this run and persist it atomically
      // only after all AI-side effects have passed their post-call guards.
      const [reason = "planned-hop-exit"] = rest;
      const st = readState();
      if (!Number.isSafeInteger(st.startedAt)) die("活动 run 缺少有效 startedAt");
      st.gracefulHopExit = {
        runId: st.startedAt,
        at: Math.floor(Date.now() / 1000),
        reason: String(reason).slice(0, 200),
      };
      saveState(STATE_FILE, st);
      out({ marked: true, runId: st.startedAt });
      break;
    }
    case "quarantine-inflight": {
      // A prior orchestrator process may have died after an AI wrote files but
      // before the post-call guard ran. Without a persisted guard baseline it
      // is unsafe to resume those in-flight tasks and absorb current contents
      // as a fresh baseline. A run-bound marker proves the prior process
      // reached a guarded, planned hand-off; consume it exactly once. Missing
      // or malformed proof fails closed by quarantining in-flight work.
      const st = readState();
      const force = rest[0] === "force";
      const marker = st.gracefulHopExit;
      const graceful = !force && marker != null
        && Number.isSafeInteger(st.startedAt)
        && marker.runId === st.startedAt
        && Number.isSafeInteger(marker.at);
      if (Object.hasOwn(st, "gracefulHopExit")) delete st.gracefulHopExit;
      if (graceful) {
        saveState(STATE_FILE, st);
        out({ count: 0, taskIds: [], graceful: true });
        break;
      }
      const inFlight = new Set(["implementing", "reviewing", "fixing"]);
      const affected = st.tasks.filter((t) => inFlight.has(t.status));
      for (const t of affected) {
        advance(st, t.id, "needs_human");
        t.dirtyResidue = true;
        t.reviewDeferred = false;
      }
      if (marker != null || affected.length > 0) saveState(STATE_FILE, st);
      out({ count: affected.length, taskIds: affected.map((t) => t.id), graceful: false, forced: force });
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
      const count = parseFindingCount(n);
      t.findingsHistory = Array.isArray(t.findingsHistory) ? t.findingsHistory : [];
      t.findingsHistory.push(count);
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
      const st = readState();
      if (!Number.isSafeInteger(st.startedAt)) die("活动 run 缺少有效 startedAt，拒绝记录 findings");
      for (const it of items) {
        appendFinding(`${CODEX_HOME}/findings.jsonl`, {
          repo, file: it.file, line: it.location, issue: it.title,
          severity: it.kind, taskId, runId: st.startedAt,
        });
      }
      out({
        declared,
        recorded: items.length,
        autoFixable: items.filter((i) => i.kind === "auto").length,
        needsHuman: items.filter((i) => i.kind === "needs-human").length,
      });
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
    case "terminal-clear": {
      // 下一夜的启动路径（Codex R2 #12）: 不清除的话第一夜之后永远不再开工。
      // 由用户重新 `launchctl load` 时经 SKILL.md 的启动流程显式调用。
      // An unarchived run still carries the previous night's cutoff. Clearing
      // TERMINATED beside it would make the first re-armed tick immediately
      // finalize that stale run and unload again, silently skipping the night.
      if (existsSync(STATE_FILE)) {
        die("检测到未归档的 current-run.json；请先核对仓库并运行 archive，或把该文件改名隔离保留证据，再执行 terminal-clear");
      }
      if (existsSync(`${CODEX_HOME}/TERMINATED`)) unlinkSync(`${CODEX_HOME}/TERMINATED`);
      // Notification dedupe belongs to one operational run. Archive failures
      // deliberately retain these markers across launchd retries, but an
      // explicit next-night re-arm must not let them suppress the new report.
      let notificationMarkersCleared = 0;
      if (existsSync(STATE_DIR)) {
        for (const name of readdirSync(STATE_DIR)) {
          if (!/^\.push-once-[A-Za-z0-9_-]+$/.test(name)) continue;
          rmSync(`${STATE_DIR}/${name}`, { recursive: true, force: true });
          notificationMarkersCleared++;
        }
      }
      if (existsSync(CODEX_HOME)) {
        for (const name of readdirSync(CODEX_HOME)) {
          if (!/^\.push-once-fallback-[A-Za-z0-9_-]+$/.test(name)) continue;
          rmSync(`${CODEX_HOME}/${name}`, { recursive: true, force: true });
          notificationMarkersCleared++;
        }
      }
      out({ cleared: true, notificationMarkersCleared });
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
        const st = readState();
        if (!Number.isSafeInteger(st.startedAt)) die("活动 run 缺少有效 startedAt，拒绝记录备份");
        const e = backupFile(orig, {
          backupRoot: root, runDate, runId: st.startedAt, reason: reason || "guard-snapshot",
        });
        out({ ok: true, ...e });
      } catch (err) {
        die(`backup-file 失败: ${String(err && err.message || err)}`);
      }
      break;
    }

    case "repo-content-snapshot": {
      const [repo] = rest;
      if (!repo) die("repo-content-snapshot 缺少 repo");
      out({ digest: repoContentSnapshot(repo) });
      break;
    }
    case "review-content-snapshot": {
      const [repo] = rest;
      if (!repo) die("review-content-snapshot 缺少 repo");
      out({ digest: reviewContentSnapshot(repo) });
      break;
    }
    case "path-content-snapshot": {
      if (rest.filter(Boolean).length === 0) die("path-content-snapshot 缺少路径");
      out({ digest: pathContentSnapshot(rest) });
      break;
    }

    case "protected-in-null": {
      // protected-in-null <NUL-list> <output-file>
      //
      // Preserve the original POSIX filename bytes in the output. Decoding a
      // path list as UTF-8 and round-tripping it through JSON replaces invalid
      // bytes with U+FFFD, so the shell can no longer open the selected file.
      // Classification still sees UTF-8 text (valid CJK stays intact, and a
      // byte-invalid prefix before `.env` still matches the credential suffix).
      const [lf, dest] = rest;
      if (!lf || !dest) die("protected-in-null 参数不足");
      if (!existsSync(lf)) die("protected-in-null 输入清单不存在");
      try {
        const selected = splitNul(readFileSync(lf))
          .filter((p) => isProtectedPath(p.toString("utf8")));
        writeFileSync(dest, Buffer.concat(selected.flatMap((p) => [p, Buffer.from([0])])));
        out({ count: selected.length });
      } catch (err) {
        die(`protected-in-null 失败: ${String(err && err.message || err)}`);
      }
      break;
    }
    case "mode-list-snapshot": {
      const [lf] = rest;
      if (!lf || !existsSync(lf)) die("mode-list-snapshot 输入清单不存在");
      try { out(modeListSnapshot(lf)); }
      catch (err) { die(`mode-list-snapshot 失败: ${String(err && err.message || err)}`); }
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
      const started = Number.isSafeInteger(st.startedAt) ? st.startedAt : Math.floor(Date.now() / 1000);
      const d = new Date(started * 1000);
      const stamp = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}T${String(d.getHours()).padStart(2, "0")}${String(d.getMinutes()).padStart(2, "0")}${String(d.getSeconds()).padStart(2, "0")}`;
      let dest = `${STATE_DIR}/run-${stamp}.json`;
      let collision = 0;
      while (existsSync(dest)) {
        collision++;
        // `~` sorts after the base name's `.`, so report.mjs's lexical
        // newest-last selection picks the later collision rather than the base.
        dest = `${STATE_DIR}/run-${stamp}~${String(collision).padStart(3, "0")}.json`;
      }
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
  const { hour: h, minute: m } = parseMorningHour(hhmm);
  const now = new Date();
  const t = new Date(now);
  t.setHours(h, m, 0, 0);
  if (t <= now) t.setDate(t.getDate() + 1);
  return Math.floor(t.getTime() / 1000);
}
