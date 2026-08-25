// lib/route.mjs — pure routing + team-plan gate decisions.
const TEAM_TYPES = new Set(["feature", "refactor", "migration", "audit"]);
const BLOCKED_KINDS = new Set(["migrate", "migration", "security", "delete", "schema"]);
const ALLOWED_TIERS = new Set(["low", "normal"]);

export function routeTask(task, cfg = { team_route_min_files: 3 }) {
  if (task.team === true) return "team";
  if (task.team === false) return "inline";
  if (typeof task.files === "number" && task.files >= cfg.team_route_min_files) return "team";
  if (TEAM_TYPES.has(task.type)) return "team";
  return "inline";
}

export function teamGate(planResult, cfg = { team_autoproceed_confidence: 0.85 }) {
  if (!planResult || planResult.status !== "approved") return { proceed: false, reason: `status ${planResult?.status}` };
  if (!planResult.autoProceedEligible) return { proceed: false, reason: "not auto-proceed eligible" };
  const conf = planResult.verdict?.confidence ?? 0;
  if (conf < cfg.team_autoproceed_confidence) return { proceed: false, reason: `confidence ${conf} < ${cfg.team_autoproceed_confidence}` };
  const tasks = planResult.plan?.tasks ?? [];
  if (tasks.length === 0) return { proceed: false, reason: "empty plan" };
  // Fail-closed: every task must carry an explicitly allowed (low/normal) riskTier — missing/unknown/high all block.
  if (!tasks.every((t) => ALLOWED_TIERS.has(t.riskTier))) return { proceed: false, reason: "a task has missing/unknown/high riskTier" };
  if (tasks.some((t) => BLOCKED_KINDS.has(t.kind))) return { proceed: false, reason: "a task is migrate/security/delete" };
  if (tasks.some((t) => t.reversible === false)) return { proceed: false, reason: "a task is non-reversible" };
  // reversibility is INFERRED from kind (migrate/security/delete are blocked above) because the real team-plan.js emits no explicit "reversible" field — requiring reversible===true would block all team runs.
  return { proceed: true, reason: "approved, eligible, low-risk, reversible" };
}

export function canDelegate(delegationsUsed, cfg = { team_max_delegations_per_night: 4 }) {
  return delegationsUsed < cfg.team_max_delegations_per_night;
}
