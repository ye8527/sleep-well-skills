// test/state.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { newRunState, saveState, loadState, advance, selectNextTask, STATUSES, pastCutoff, hasDeferredReviews } from "../lib/state.mjs";

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


test("newRunState seeds cutoffEpoch null; pastCutoff compares", () => {
  assert.equal(newRunState([]).cutoffEpoch, null);
  assert.equal(pastCutoff(100, 200), false);
  assert.equal(pastCutoff(200, 200), true);
  assert.equal(pastCutoff(300, null), false);
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

// ⚠️ 这些测试原来测的是 `nextTask`/`nextPending`——**零生产调用**（R16 自查）。
//    真正在跑的是 cli.mjs 里那套带同仓库串行的选择器，而它当时一条单测都没有。
//    现在选择器搬进 state.mjs，测试测的就是跑的那一份。
test("selectNextTask: 在途任务优先于新的 pending", () => {
  const s = newRunState([{ id: "a", status: "pending", repo: "/r1" }, { id: "b", status: "reviewing", repo: "/r2" }]);
  assert.equal(selectNextTask(s).task.id, "b");
});

test("selectNextTask: 跳过挂起审查，让其它 pending 继续", () => {
  const s = newRunState([
    { id: "a", status: "reviewing", repo: "/r1", reviewDeferred: true },
    { id: "b", status: "pending", repo: "/r2" },
  ]);
  assert.equal(selectNextTask(s).task.id, "b");
});

test("selectNextTask: 同仓库串行——在途任务会挡住同仓库的 pending", () => {
  const s = newRunState([
    { id: "a", status: "implementing", repo: "/same" },
    { id: "b", status: "pending", repo: "/same" },
  ]);
  // a 在途 → 先返回 a
  assert.equal(selectNextTask(s).task.id, "a");
  // a 转终态后，b 才能被取到
  s.tasks[0].status = "done";
  assert.equal(selectNextTask(s).task.id, "b");
});

test("selectNextTask: needs_human 且有残留时继续阻塞同仓库；残留清理后放行", () => {
  const s = newRunState([
    { id: "a", status: "needs_human", repo: "/same", dirtyResidue: true },
    { id: "b", status: "pending", repo: "/same" },
  ]);
  const r1 = selectNextTask(s, () => true);    // 工作区仍脏
  assert.equal(r1.task, null);
  assert.equal(r1.blockedBySameRepo, true);
  const r2 = selectNextTask(s, () => false);   // 人工清理后
  assert.equal(r2.task.id, "b");
});

test("selectNextTask: 只剩挂起审查时返回 deferred", () => {
  const s = newRunState([{ id: "a", status: "reviewing", repo: "/r1", reviewDeferred: true }]);
  const r = selectNextTask(s);
  assert.equal(r.task, null);
  assert.equal(r.deferred, true);
});
