// lib/backoff.mjs — escalating backoff for riding out transient API overload / 5xx.
// Pure: 0-indexed failure count in → {delaySeconds, giveUp} out. ScheduleWakeup is
// clamped to <=3600s, so values >3600 must be spanned via planRelay by the caller.
const DEFAULT_SCHEDULE = [120, 300, 900, 1800, 3600, 3600]; // 2m,5m,15m,30m,1h,1h  (~172 min total)

export function nextBackoff(attempt, schedule = DEFAULT_SCHEDULE) {
  if (attempt >= schedule.length) return { delaySeconds: 0, giveUp: true };
  return { delaySeconds: schedule[attempt], giveUp: false };
}
