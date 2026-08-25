// lib/state.mjs
import { readFileSync, writeFileSync, mkdirSync, renameSync } from "node:fs";
import { dirname } from "node:path";

export const STATUSES = new Set([
  "pending", "implementing", "reviewing", "fixing", "done", "needs_human", "skipped",
]);

const LEGAL = {
  pending: ["implementing", "skipped"],
  implementing: ["reviewing", "needs_human", "skipped"],
  reviewing: ["fixing", "done", "needs_human", "skipped"],
  fixing: ["reviewing", "needs_human", "skipped"],
  done: [],
  needs_human: [],
  skipped: [],
};

export function newRunState(tasks) {
  return { startedAt: null, cutoffEpoch: null, tasks: tasks.map((t) => ({ ...t })), openWorktrees: [], teamDelegationsTonight: 0 };
}

export function pastCutoff(nowEpoch, cutoffEpoch) {
  return cutoffEpoch != null && nowEpoch >= cutoffEpoch;
}

export function saveState(path, state) {
  mkdirSync(dirname(path), { recursive: true });
  const tmp = `${path}.tmp`;
  writeFileSync(tmp, JSON.stringify(state, null, 2));
  renameSync(tmp, path);
}

export function loadState(path) {
  return JSON.parse(readFileSync(path, "utf-8"));
}

const IN_FLIGHT = ["implementing", "reviewing", "fixing"];

// ⚠️ 这里原来有 `nextPending` 与 `nextTask` 两个导出，**生产代码一次都没调用过**
//    （`cli.mjs` 的 next-task 自己实现了一套带同仓库串行的选择器），
//    却各有 2 和 4 条单测——**测的东西和用的东西是两个实现，而用的那个没有任何单测**
//    （R16 自查）。「58 项单测通过」于是让人以为任务选择被覆盖了。
//    处置: 删掉死代码，把**生产选择器**搬到这里，让测试测的就是跑的那一份。
//
// selectNextTask(state, repoIsDirty) → { task, deferred, blockedBySameRepo }
//   repoIsDirty(repo) 由调用方注入（cli.mjs 传真实的 git status 探测，测试传桩）。
export function selectNextTask(state, repoIsDirty = () => true) {
  // 同仓库严格串行（用户 2026-08-10 裁定；Codex R1 #8）: 某仓库若有任务在途或挂起，
  // 它的未提交 diff 还在工作区——此时取同仓库的下一个任务，两份改动会混进同一次审查与
  // `git add -A`，甚至以 t2 的名义提交 t1 的工作。
  // needs_human 且留了残留的仓库也要继续阻塞（Codex R2 #9），但 dirtyResidue 只是
  // 「当时留了残留」的记录，人工清理后不应永久阻塞——每次判定复核实际状态（Codex R5 #10）。
  const busyRepos = new Set(
    state.tasks.filter((t) =>
      IN_FLIGHT.includes(t.status) ||
      t.reviewDeferred ||
      (t.status === "needs_human" && t.dirtyResidue === true && repoIsDirty(t.repo)),
    ).map((t) => t.repo),
  );
  const inFlight = state.tasks.find((t) => IN_FLIGHT.includes(t.status) && !t.reviewDeferred);
  if (inFlight) return { task: inFlight };
  const pending = state.tasks.find((t) => t.status === "pending" && !busyRepos.has(t.repo));
  if (pending) return { task: pending };
  return {
    task: null,
    deferred: hasDeferredReviews(state),
    blockedBySameRepo: state.tasks.some((t) => t.status === "pending" && busyRepos.has(t.repo)),
  };
}

export function hasDeferredReviews(state) {
  return state.tasks.some((t) => t.reviewDeferred);
}

export function advance(state, id, to) {
  if (!STATUSES.has(to)) throw new Error(`unknown status ${to}`);
  const t = state.tasks.find((x) => x.id === id);
  if (!t) throw new Error(`no task ${id}`);
  if (!LEGAL[t.status].includes(to)) {
    throw new Error(`illegal transition ${t.status} -> ${to} for ${id}`);
  }
  t.status = to;
  return t;
}
