// lib/quota.mjs — pure quota decisions. No I/O, no Date.now() (now is injected).

// q: { fiveHourUtil, fiveHourResetIso, sevenDayUtil, sevenDayResetIso }
export function claudeDecision(q, thresholds = { sleepAt: 92, alertAt: 80 }) {
  const windows = [
    { name: "five_hour", util: q.fiveHourUtil ?? 0, resetIso: q.fiveHourResetIso },
    { name: "seven_day", util: q.sevenDayUtil ?? 0, resetIso: q.sevenDayResetIso },
  ];
  const binding = windows.reduce((a, b) => (b.util > a.util ? b : a));
  if (binding.util >= thresholds.sleepAt)
    return { action: "wrap-and-sleep", window: binding.name, sleepUntilIso: binding.resetIso, reason: `${binding.name} ${binding.util}%` };
  if (binding.util >= thresholds.alertAt)
    return { action: "alert", window: binding.name, reason: `${binding.name} ${binding.util}%` };
  return { action: "proceed", reason: `max util ${binding.util}%` };
}

// q: { fiveHourExhausted, weeklyExhausted, nextUsefulResetEpoch }; nowEpoch in seconds.
export function codexDecision(q, nowEpoch, degradeAfterHours = 10) {
  if (q.weeklyExhausted) return { action: "degrade", reason: "codex weekly exhausted" };
  if (!q.fiveHourExhausted) return { action: "use-codex", reason: "codex available" };
  const hoursToReset = q.nextUsefulResetEpoch ? (q.nextUsefulResetEpoch - nowEpoch) / 3600 : Infinity;
  if (hoursToReset > degradeAfterHours)
    return { action: "degrade", reason: `codex reset ${hoursToReset.toFixed(1)}h away > ${degradeAfterHours}h` };
  return { action: "defer", sleepUntilEpoch: q.nextUsefulResetEpoch, reason: "defer reviews until codex 5h reset" };
}
