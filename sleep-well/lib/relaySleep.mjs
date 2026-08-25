// lib/relaySleep.mjs — split a sleep gap into <=maxHop chunks for relayed ScheduleWakeup.
export function planRelay(nowEpoch, untilEpoch, maxHopSeconds = 3600) {
  let remaining = untilEpoch - nowEpoch;
  if (remaining <= 0) return [];
  const hops = [];
  while (remaining > 0) {
    const hop = Math.min(remaining, maxHopSeconds);
    hops.push(hop);
    remaining -= hop;
  }
  return hops;
}
