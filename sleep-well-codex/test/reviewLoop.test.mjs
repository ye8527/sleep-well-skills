// test/reviewLoop.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { decideNext } from "../lib/reviewLoop.mjs";

const cfg = { review_rounds_rotate_at: 10, review_rotations_max: 2, review_stall_rounds: 2 };

test("zero findings -> done", () => {
  assert.equal(decideNext([5, 2, 0], 0, cfg).action, "done");
});

test("strictly shrinking -> continue", () => {
  assert.equal(decideNext([5, 3], 0, cfg).action, "continue");
});

test("stall (not strictly decreasing over window) -> stop", () => {
  const d = decideNext([3, 3], 0, cfg);
  assert.equal(d.action, "stop");
  assert.equal(d.reason, "stall");
});

test(">= rotate_at rounds with rotations left -> rotate", () => {
  const hist = [10, 9, 8, 7, 6, 5, 4, 3, 2, 1]; // 10 rounds, strictly decreasing so stall does not fire
  assert.equal(decideNext(hist, 0, cfg).action, "rotate");
});

test("rotation cap reached -> stop", () => {
  const hist = [10, 9, 8, 7, 6, 5, 4, 3, 2, 1];
  const d = decideNext(hist, 2, cfg);
  assert.equal(d.action, "stop");
  assert.equal(d.reason, "rotation-cap");
});
