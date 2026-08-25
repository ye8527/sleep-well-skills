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

export function nextPending(state) {
  return state.tasks.find((t) => t.status === "pending") || null;
}

const IN_FLIGHT = ["implementing", "reviewing", "fixing"];
// Resume selector: a non-terminal in-flight task (with uncommitted work) takes priority over starting a new pending one.
// Tasks flagged reviewDeferred (Codex 5h-exhausted) are skipped so Claude-only pending work can proceed.
export function nextTask(state) {
  return state.tasks.find((t) => IN_FLIGHT.includes(t.status) && !t.reviewDeferred)
    || state.tasks.find((t) => t.status === "pending")
    || null;
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
