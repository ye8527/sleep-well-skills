// lib/reviewLoop.mjs
// history: finding COUNTS per review round SINCE THE LAST ROTATION (the orchestrator resets it to [] on rotate).
// rotations: how many fresh-session rotations already used for this task.
import { DEFAULTS } from "./config.mjs";

export function parseFindingCount(value) {
  const text = String(value ?? "");
  if (!/^\d+$/.test(text)) throw new TypeError("findings 条数必须是非负整数");
  const count = Number(text);
  if (!Number.isSafeInteger(count)) throw new TypeError("findings 条数超出安全整数范围");
  return count;
}

export function decideNext(history, rotations, cfg) {
  const stallRounds = cfg?.review_stall_rounds ?? DEFAULTS.review_stall_rounds;
  const rotateAt = cfg?.review_rounds_rotate_at ?? DEFAULTS.review_rounds_rotate_at;
  const rotationsMax = cfg?.review_rotations_max ?? DEFAULTS.review_rotations_max;
  const rounds = history.length;
  if (rounds === 0) return { action: "continue", reason: "first-round" };
  if (history[rounds - 1] === 0) return { action: "done", reason: "no-findings" };

  if (rounds >= stallRounds) {
    const w = history.slice(-stallRounds);
    const strictlyDecreasing = w.every((v, i) => i === 0 || v < w[i - 1]);
    if (!strictlyDecreasing) return { action: "stop", reason: "stall" };
  }

  if (rounds >= rotateAt) {
    if (rotations < rotationsMax) return { action: "rotate", reason: "context-too-long" };
    return { action: "stop", reason: "rotation-cap" };
  }
  return { action: "continue", reason: "progress" };
}
