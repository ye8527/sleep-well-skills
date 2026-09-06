// test/config.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { DEFAULTS, mergeConfig, expandHome, loadConfig, parseMorningHour } from "../lib/config.mjs";

test("DEFAULTS carry the spec §10 values", () => {
  assert.equal(DEFAULTS.review_rounds_rotate_at, 10);
  assert.equal(DEFAULTS.review_rotations_max, 2);
  assert.equal(DEFAULTS.review_stall_rounds, 2);
  assert.equal(DEFAULTS.morning_hour, "07:00");
  assert.deepEqual(DEFAULTS.discovery_tiers_auto, [1, 2, 3]);
});

test("mergeConfig overlays user values onto defaults", () => {
  const merged = mergeConfig({ review_rounds_rotate_at: 8, push_enabled: false });
  assert.equal(merged.review_rounds_rotate_at, 8);
  assert.equal(merged.push_enabled, false);
  assert.equal(merged.review_rotations_max, 2); // untouched default
});

test("morning_hour accepts strict HH:MM and rejects values that disable cutoff", () => {
  assert.deepEqual(parseMorningHour("07:00"), { hour: 7, minute: 0 });
  assert.deepEqual(parseMorningHour("23:59"), { hour: 23, minute: 59 });
  for (const value of ["7:00", "7am", "07.00", "24:00", "07:60", "", null]) {
    assert.throws(() => mergeConfig({ morning_hour: value }), /morning_hour.*HH:MM/);
  }
});

test("expandHome resolves a leading ~", () => {
  assert.equal(expandHome("~/sleep-well"), `${process.env.HOME}/sleep-well`);
  assert.equal(expandHome("/abs/path"), "/abs/path");
});

test("loadConfig expands ~ in path-valued config", () => {
  const cfg = loadConfig("/nonexistent/config.json"); // missing -> defaults
  assert.equal(cfg.backup_dir, process.env.HOME + "/sleep-well/backups");
  assert.equal(cfg.discovery_repo, process.env.HOME + "/Projects/example-repo");
});
