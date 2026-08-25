import { test } from "node:test";
import assert from "node:assert/strict";
import { nextBackoff } from "../lib/backoff.mjs";

test("escalating backoff then give up", () => {
  assert.equal(nextBackoff(0).delaySeconds, 120);
  assert.equal(nextBackoff(0).giveUp, false);
  assert.equal(nextBackoff(3).delaySeconds, 1800);
  assert.equal(nextBackoff(5).delaySeconds, 3600);
  assert.equal(nextBackoff(6).giveUp, true);
});
test("custom schedule", () => {
  assert.deepEqual(nextBackoff(1, [10, 20, 30]), { delaySeconds: 20, giveUp: false });
  assert.equal(nextBackoff(3, [10, 20, 30]).giveUp, true);
});
