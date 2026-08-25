import { test } from "node:test";
import assert from "node:assert/strict";
import { routeTask, teamGate, canDelegate } from "../lib/route.mjs";

const cfg = { team_route_min_files: 3, team_autoproceed_confidence: 0.85, team_max_delegations_per_night: 4 };

test("routeTask: feature/refactor/migration/audit -> team", () => {
  for (const type of ["feature", "refactor", "migration", "audit"])
    assert.equal(routeTask({ type }, cfg), "team", type);
});
test("routeTask: small types -> inline", () => {
  for (const type of ["bugfix", "docs", "test", "lint", "small-todo"])
    assert.equal(routeTask({ type }, cfg), "inline", type);
});
test("routeTask: files >= min -> team; explicit team flag overrides", () => {
  assert.equal(routeTask({ type: "bugfix", files: 5 }, cfg), "team");
  assert.equal(routeTask({ type: "feature", team: false }, cfg), "inline");
  assert.equal(routeTask({ type: "docs", team: true }, cfg), "team");
});
test("teamGate: proceeds only when approved+eligible+confident+low-risk+reversible", () => {
  const ok = { status: "approved", autoProceedEligible: true, verdict: { confidence: 0.9 }, plan: { tasks: [{ riskTier: "normal", kind: "edit" }] } };
  assert.equal(teamGate(ok, cfg).proceed, true);
});
test("teamGate: blocks not-approved / low-confidence / high-risk / migrate", () => {
  assert.equal(teamGate({ status: "needsHuman" }, cfg).proceed, false);
  assert.equal(teamGate({ status: "approved", autoProceedEligible: false, verdict: { confidence: 0.9 }, plan: { tasks: [] } }, cfg).proceed, false);
  assert.equal(teamGate({ status: "approved", autoProceedEligible: true, verdict: { confidence: 0.5 }, plan: { tasks: [] } }, cfg).proceed, false);
  assert.equal(teamGate({ status: "approved", autoProceedEligible: true, verdict: { confidence: 0.9 }, plan: { tasks: [{ riskTier: "high" }] } }, cfg).proceed, false);
  assert.equal(teamGate({ status: "approved", autoProceedEligible: true, verdict: { confidence: 0.9 }, plan: { tasks: [{ kind: "migrate" }] } }, cfg).proceed, false);
});
test("teamGate blocks a plan with a non-reversible task", () => {
  const pr = { status: "approved", autoProceedEligible: true, verdict: { confidence: 0.9 }, plan: { tasks: [{ riskTier: "normal", reversible: false }] } };
  assert.equal(teamGate(pr, cfg).proceed, false);
});
test("teamGate fail-closes on a task with missing/unknown riskTier", () => {
  const pr = { status: "approved", autoProceedEligible: true, verdict: { confidence: 0.9 }, plan: { tasks: [{ kind: "edit" }] } };
  assert.equal(teamGate(pr, cfg).proceed, false);
});
test("teamGate blocks a migration-kind plan", () => {
  const pr = { status: "approved", autoProceedEligible: true, verdict: { confidence: 0.9 }, plan: { tasks: [{ riskTier: "normal", kind: "migration" }] } };
  assert.equal(teamGate(pr, cfg).proceed, false);
});
test("canDelegate respects the nightly cap", () => {
  assert.equal(canDelegate(3, cfg), true);
  assert.equal(canDelegate(4, cfg), false);
});

test("routeTask keeps untyped 'task' inline", () => {
  assert.equal(routeTask({ type: "task" }, cfg), "inline");
});
