import { test } from "node:test";
import assert from "node:assert/strict";
import { planRelay } from "../lib/relaySleep.mjs";

test("returns empty when target is now/past", () => {
  assert.deepEqual(planRelay(1000, 1000, 3600), []);
  assert.deepEqual(planRelay(1000, 500, 3600), []);
});
test("single hop when within one max-hop window", () => {
  assert.deepEqual(planRelay(0, 1800, 3600), [1800]);
});
test("chains hops for a multi-hour gap, each <= maxHop, summing to total", () => {
  const hops = planRelay(0, 5 * 3600 + 600, 3600); // 5h10m
  assert.ok(hops.every((h) => h <= 3600));
  assert.equal(hops.reduce((a, b) => a + b, 0), 5 * 3600 + 600);
  assert.equal(hops.length, 6); // five 3600 + one 600
});
