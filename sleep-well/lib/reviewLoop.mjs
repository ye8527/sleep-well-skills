// lib/reviewLoop.mjs
// history: finding COUNTS per review round SINCE THE LAST ROTATION (the orchestrator resets it to [] on rotate).
// rotations: how many fresh-session rotations already used for this task.
export function decideNext(history, rotations, cfg) {
  const rounds = history.length;
  if (rounds === 0) return { action: "continue", reason: "first-round" };
  if (history[rounds - 1] === 0) return { action: "done", reason: "no-findings" };

  if (rounds >= cfg.review_stall_rounds) {
    const w = history.slice(-cfg.review_stall_rounds);
    const strictlyDecreasing = w.every((v, i) => i === 0 || v < w[i - 1]);
    if (!strictlyDecreasing) return { action: "stop", reason: "stall" };
  }

  if (rounds >= cfg.review_rounds_rotate_at) {
    if (rotations < cfg.review_rotations_max) return { action: "rotate", reason: "context-too-long" };
    return { action: "stop", reason: "rotation-cap" };
  }
  return { action: "continue", reason: "progress" };
}
