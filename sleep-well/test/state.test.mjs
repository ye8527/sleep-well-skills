// test/state.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { newRunState, saveState, loadState, advance, nextPending, nextTask, STATUSES, pastCutoff, hasDeferredReviews } from "../lib/state.mjs";

function tmp() { return mkdtempSync(join(tmpdir(), "sw-state-")); }

test("save then load round-trips state", () => {
  const dir = tmp();
  const path = join(dir, "run.json");
  const s = newRunState([{ id: "t1", status: "pending" }, { id: "t2", status: "pending" }]);
  saveState(path, s);
  const back = loadState(path);
  assert.equal(back.tasks.length, 2);
  assert.equal(back.tasks[0].id, "t1");
  rmSync(dir, { recursive: true, force: true });
});

test("nextPending returns first pending task, null when none", () => {
  const s = newRunState([{ id: "t1", status: "done" }, { id: "t2", status: "pending" }]);
  assert.equal(nextPending(s).id, "t2");
  s.tasks[1].status = "done";
  assert.equal(nextPending(s), null);
});

test("advance only allows legal transitions", () => {
  const s = newRunState([{ id: "t1", status: "pending" }]);
  advance(s, "t1", "implementing");
  assert.equal(s.tasks[0].status, "implementing");
  assert.throws(() => advance(s, "t1", "done"), /illegal transition/);
});

test("STATUSES is the closed set", () => {
  assert.deepEqual(
    [...STATUSES].sort(),
    ["done", "fixing", "implementing", "needs_human", "pending", "reviewing", "skipped"]
  );
});

test("newRunState seeds teamDelegationsTonight", () => {
  assert.equal(newRunState([]).teamDelegationsTonight, 0);
});

test("nextTask resumes an in-flight task before a pending one", () => {
  const s = newRunState([{ id: "a", status: "pending" }, { id: "b", status: "reviewing" }]);
  assert.equal(nextTask(s).id, "b");
  s.tasks[1].status = "done";
  assert.equal(nextTask(s).id, "a");
});

test("newRunState seeds cutoffEpoch null; pastCutoff compares", () => {
  assert.equal(newRunState([]).cutoffEpoch, null);
  assert.equal(pastCutoff(100, 200), false);
  assert.equal(pastCutoff(200, 200), true);
  assert.equal(pastCutoff(300, null), false);
});

test("nextTask skips a deferred review in favor of pending work", () => {
  const s = newRunState([{ id: "a", status: "reviewing", reviewDeferred: true }, { id: "b", status: "pending" }]);
  assert.equal(nextTask(s).id, "b");
  s.tasks[1].status = "done";
  assert.equal(nextTask(s), null); // only a deferred review left -> orchestrator sleeps until codex resets
});

test("hasDeferredReviews detects deferred reviews", () => {
  assert.equal(hasDeferredReviews(newRunState([{ id: "a", status: "reviewing", reviewDeferred: true }])), true);
  assert.equal(hasDeferredReviews(newRunState([{ id: "a", status: "pending" }])), false);
});

test("saveState writes atomically (no leftover .tmp)", () => {
  const dir = mkdtempSync(join(tmpdir(), "sw-atomic-"));
  const p = join(dir, "run.json");
  saveState(p, newRunState([{ id: "a", status: "pending" }]));
  assert.equal(existsSync(p + ".tmp"), false);
  assert.equal(loadState(p).tasks[0].id, "a");
  rmSync(dir, { recursive: true, force: true });
});
