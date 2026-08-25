// lib/config.mjs
import { homedir } from "node:os";
import { readFileSync } from "node:fs";
import { join } from "node:path";

export const DEFAULTS = {
  morning_hour: "07:00",
  review_rounds_rotate_at: 10,
  review_rotations_max: 2,
  review_stall_rounds: 2,
  codex_degrade_after_hours: 10,
  codex_recheck_after_weekly_reset: false,
  team_route_min_files: 3,
  team_autoproceed_confidence: 0.85,
  team_max_delegations_per_night: 4,
  discovery_k_per_cycle: 3,
  discovery_repo: "~/Projects/example-repo",
  discovery_tiers_auto: [1, 2, 3],
  discovery_tiers_propose: [4],
  backup_dir: "~/sleep-well/backups",
  backup_nongit_docs: true,
  backup_cleanup: "on-confirm",
  push_enabled: true,
};

export function expandHome(p) {
  if (typeof p === "string" && p.startsWith("~")) return homedir() + p.slice(1);
  return p;
}

export function mergeConfig(userCfg = {}) {
  return { ...DEFAULTS, ...userCfg };
}

export function loadConfig(path = join(homedir(), "sleep-well", "config.json")) {
  let userCfg = {};
  try {
    userCfg = JSON.parse(readFileSync(path, "utf-8"));
  } catch (e) {
    if (e.code !== "ENOENT") throw e; // missing file => defaults; malformed => surface
  }
  const merged = mergeConfig(userCfg);
  for (const k of ["backup_dir", "discovery_repo"]) {
    if (typeof merged[k] === "string") merged[k] = expandHome(merged[k]);
  }
  return merged;
}
