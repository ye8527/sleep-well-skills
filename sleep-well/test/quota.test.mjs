import { test } from "node:test";
import assert from "node:assert/strict";
import { claudeDecision, codexDecision } from "../lib/quota.mjs";

const T = { sleepAt: 92, alertAt: 80 };

test("claudeDecision proceeds when utilization low", () => {
  const d = claudeDecision({ fiveHourUtil: 40, fiveHourResetIso: "x", sevenDayUtil: 10, sevenDayResetIso: "y" }, T);
  assert.equal(d.action, "proceed");
});
test("claudeDecision wraps-and-sleeps on the binding (highest) window", () => {
  const d = claudeDecision({ fiveHourUtil: 95, fiveHourResetIso: "5h", sevenDayUtil: 30, sevenDayResetIso: "7d" }, T);
  assert.equal(d.action, "wrap-and-sleep");
  assert.equal(d.window, "five_hour");
  assert.equal(d.sleepUntilIso, "5h");
});
test("claudeDecision alerts in the alert zone", () => {
  assert.equal(claudeDecision({ fiveHourUtil: 85, sevenDayUtil: 0 }, T).action, "alert");
});
test("codexDecision uses codex when 5h available", () => {
  assert.equal(codexDecision({ fiveHourExhausted: false, weeklyExhausted: false }, 0).action, "use-codex");
});
test("codexDecision degrades when weekly exhausted", () => {
  assert.equal(codexDecision({ fiveHourExhausted: true, weeklyExhausted: true }, 0).action, "degrade");
});
test("codexDecision defers when 5h out but reset is near", () => {
  const now = 1000, reset = 1000 + 3 * 3600;
  const d = codexDecision({ fiveHourExhausted: true, weeklyExhausted: false, nextUsefulResetEpoch: reset }, now, 10);
  assert.equal(d.action, "defer");
  assert.equal(d.sleepUntilEpoch, reset);
});
test("codexDecision degrades when 5h reset is >degradeAfterHours away", () => {
  const now = 1000, reset = 1000 + 12 * 3600;
  assert.equal(codexDecision({ fiveHourExhausted: true, weeklyExhausted: false, nextUsefulResetEpoch: reset }, now, 10).action, "degrade");
});
