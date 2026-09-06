import { test } from "node:test";
import assert from "node:assert/strict";
import { chmodSync, existsSync, mkdtempSync, mkdirSync, readFileSync, rmSync, statSync, symlinkSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const here = dirname(fileURLToPath(import.meta.url));
const watchdog = join(here, "..", "bin", "watchdog.sh");

test("watchdog appends fallback PATH locations before resolving node", () => {
  const root = mkdtempSync(join(tmpdir(), "sw-watchdog-"));
  const home = join(root, "home");
  const sw = join(root, "state-home");
  const skill = join(root, "skill");
  const marker = join(root, "node-called");
  const fakeNode = join(home, ".local", "bin", "node-fallback-test");
  mkdirSync(dirname(fakeNode), { recursive: true });
  mkdirSync(join(skill, "bin"), { recursive: true });
  writeFileSync(fakeNode, "#!/bin/sh\nprintf '%s' \"$*\" > \"$FAKE_NODE_MARKER\"\n");
  chmodSync(fakeNode, 0o755);
  writeFileSync(join(skill, "bin", "report.mjs"), "// fixture\n");

  const result = spawnSync("/bin/sh", [watchdog], {
    encoding: "utf8",
    env: {
      ...process.env,
      HOME: home,
      PATH: "/usr/bin:/bin",
      SLEEP_WELL_HOME: sw,
      SLEEP_WELL_SKILL: skill,
      SLEEP_WELL_NODE: "node-fallback-test",
      FAKE_NODE_MARKER: marker,
    },
  });
  assert.equal(result.status, 0, result.stderr);
  assert.match(readFileSync(marker, "utf8"), /report\.mjs/);
  rmSync(root, { recursive: true, force: true });
});

test("watchdog refreshes the report before rejecting an invalid resume timeout", () => {
  const root = mkdtempSync(join(tmpdir(), "sw-watchdog-invalid-timeout-"));
  const home = join(root, "home");
  const sw = join(root, "state-home");
  const skill = join(root, "skill");
  const bin = join(root, "bin");
  const nodeMarker = join(root, "node-called");
  const claudeMarker = join(root, "claude-called");
  mkdirSync(home, { recursive: true });
  mkdirSync(join(sw, "state"), { recursive: true });
  mkdirSync(join(skill, "bin"), { recursive: true });
  mkdirSync(bin, { recursive: true });
  writeFileSync(join(sw, "state", "current-run.json"), "{}\n");
  writeFileSync(join(skill, "bin", "report.mjs"), "// fixture\n");
  writeFileSync(join(bin, "node-ok"), "#!/bin/sh\nprintf '%s' \"$*\" > \"$NODE_MARKER\"\n");
  writeFileSync(join(bin, "claude-probe"), "#!/bin/sh\nprintf called > \"$CLAUDE_MARKER\"\n");
  for (const name of ["node-ok", "claude-probe"]) chmodSync(join(bin, name), 0o755);

  const result = spawnSync("/bin/sh", [watchdog], {
    encoding: "utf8",
    env: {
      ...process.env,
      HOME: home,
      PATH: `${bin}:/usr/bin:/bin`,
      SLEEP_WELL_HOME: sw,
      SLEEP_WELL_SKILL: skill,
      SLEEP_WELL_NODE: "node-ok",
      SLEEP_WELL_CLAUDE: "claude-probe",
      SLEEP_WELL_AI_TIMEOUT: "30m",
      NODE_MARKER: nodeMarker,
      CLAUDE_MARKER: claudeMarker,
    },
  });
  assert.equal(result.status, 1);
  assert.match(readFileSync(nodeMarker, "utf8"), /report\.mjs/);
  assert.equal(existsSync(claudeMarker), false);
  assert.match(readFileSync(join(sw, "logs", "watchdog.log"), "utf8"), /report refreshed, headless resume disabled/);
  rmSync(root, { recursive: true, force: true });
});

test("watchdog reports a diagnostic failure when node is unavailable", () => {
  const root = mkdtempSync(join(tmpdir(), "sw-watchdog-missing-"));
  const home = join(root, "home");
  const sw = join(root, "state-home");
  mkdirSync(home, { recursive: true });
  mkdirSync(join(sw, "logs"), { recursive: true });
  const logPath = join(sw, "logs", "watchdog.log");
  writeFileSync(logPath, "existing\n");
  chmodSync(logPath, 0o644);
  const result = spawnSync("/bin/sh", [watchdog], {
    encoding: "utf8",
    env: {
      ...process.env,
      HOME: home,
      PATH: "/usr/bin:/bin",
      SLEEP_WELL_HOME: sw,
      SLEEP_WELL_NODE: "definitely-missing-node",
    },
  });
  assert.equal(result.status, 1);
  assert.match(readFileSync(logPath, "utf8"), /node not found/);
  assert.equal(statSync(sw).mode & 0o777, 0o700);
  assert.equal(statSync(join(sw, "logs")).mode & 0o777, 0o700);
  assert.equal(statSync(logPath).mode & 0o777, 0o600);
  rmSync(root, { recursive: true, force: true });
});

test("watchdog rejects the account HOME before changing its mode", () => {
  const home = mkdtempSync(join(tmpdir(), "sw-watchdog-unsafe-home-"));
  chmodSync(home, 0o755);
  const result = spawnSync("/bin/sh", [watchdog], {
    encoding: "utf8",
    env: { ...process.env, HOME: home, SLEEP_WELL_HOME: home },
  });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /dedicated directory/);
  assert.equal(statSync(home).mode & 0o777, 0o755);
  rmSync(home, { recursive: true, force: true });
});

test("watchdog rejects relative, filesystem-root, and symlinked log paths", () => {
  const root = mkdtempSync(join(tmpdir(), "sw-watchdog-root-guards-"));
  const home = join(root, "home");
  mkdirSync(home, { recursive: true });

  const relative = spawnSync("/bin/sh", [watchdog], {
    encoding: "utf8",
    env: { ...process.env, HOME: home, SLEEP_WELL_HOME: "relative/path" },
  });
  assert.equal(relative.status, 1);
  assert.match(relative.stderr, /absolute path/);

  const filesystemRoot = spawnSync("/bin/sh", [watchdog], {
    encoding: "utf8",
    env: { ...process.env, HOME: home, SLEEP_WELL_HOME: "/" },
  });
  assert.equal(filesystemRoot.status, 1);
  assert.match(filesystemRoot.stderr, /dedicated directory/);

  const sw = join(root, "state-home");
  const outside = join(root, "outside-logs");
  mkdirSync(sw, { recursive: true });
  mkdirSync(outside, { recursive: true });
  symlinkSync(outside, join(sw, "logs"));
  const linkedDir = spawnSync("/bin/sh", [watchdog], {
    encoding: "utf8",
    env: { ...process.env, HOME: home, SLEEP_WELL_HOME: sw },
  });
  assert.equal(linkedDir.status, 1);
  assert.match(linkedDir.stderr, /symlink/);
  assert.equal(existsSync(join(outside, "watchdog.log")), false);

  rmSync(join(sw, "logs"));
  mkdirSync(join(sw, "logs"));
  const outsideLog = join(root, "outside.log");
  writeFileSync(outsideLog, "outside\n");
  symlinkSync(outsideLog, join(sw, "logs", "watchdog.log"));
  const linkedFile = spawnSync("/bin/sh", [watchdog], {
    encoding: "utf8",
    env: { ...process.env, HOME: home, SLEEP_WELL_HOME: sw },
  });
  assert.equal(linkedFile.status, 1);
  assert.match(linkedFile.stderr, /log file must not be a symlink/);
  assert.equal(readFileSync(outsideLog, "utf8"), "outside\n");

  rmSync(root, { recursive: true, force: true });
});

test("watchdog treats heartbeat stat failure as unavailable telemetry", () => {
  const root = mkdtempSync(join(tmpdir(), "sw-watchdog-stat-"));
  const home = join(root, "home");
  const sw = join(root, "state-home");
  const skill = join(root, "skill");
  const bin = join(root, "bin");
  const claudeMarker = join(root, "claude-called");
  mkdirSync(home, { recursive: true });
  mkdirSync(join(sw, "state"), { recursive: true });
  mkdirSync(join(skill, "bin"), { recursive: true });
  mkdirSync(bin, { recursive: true });
  writeFileSync(join(sw, "state", "current-run.json"), "{}\n");
  writeFileSync(join(sw, "state", "heartbeat"), "alive\n");
  writeFileSync(join(skill, "bin", "report.mjs"), "// fixture\n");
  writeFileSync(join(bin, "node-ok"), "#!/bin/sh\nexit 0\n");
  writeFileSync(join(bin, "stat"), "#!/bin/sh\nexit 7\n");
  writeFileSync(join(bin, "claude-probe"), "#!/bin/sh\nprintf called > \"$CLAUDE_MARKER\"\n");
  for (const name of ["node-ok", "stat", "claude-probe"]) chmodSync(join(bin, name), 0o755);

  const result = spawnSync("/bin/sh", [watchdog], {
    encoding: "utf8",
    env: {
      ...process.env,
      HOME: home,
      PATH: `${bin}:/usr/bin:/bin`,
      SLEEP_WELL_HOME: sw,
      SLEEP_WELL_SKILL: skill,
      SLEEP_WELL_NODE: "node-ok",
      SLEEP_WELL_CLAUDE: "claude-probe",
      CLAUDE_MARKER: claudeMarker,
    },
  });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(existsSync(claudeMarker), false);
  assert.match(readFileSync(join(sw, "logs", "watchdog.log"), "utf8"), /heartbeat mtime unavailable/);
  rmSync(root, { recursive: true, force: true });
});

test("watchdog does not resume during a legitimate default-timeout review", () => {
  const root = mkdtempSync(join(tmpdir(), "sw-watchdog-threshold-"));
  const home = join(root, "home");
  const sw = join(root, "state-home");
  const skill = join(root, "skill");
  const bin = join(root, "bin");
  const claudeMarker = join(root, "claude-called");
  mkdirSync(home, { recursive: true });
  mkdirSync(join(sw, "state"), { recursive: true });
  mkdirSync(join(skill, "bin"), { recursive: true });
  mkdirSync(bin, { recursive: true });
  writeFileSync(join(sw, "state", "current-run.json"), "{}\n");
  const heartbeat = join(sw, "state", "heartbeat");
  writeFileSync(heartbeat, "alive\n");
  const withinReviewWindow = new Date(Date.now() - 1500 * 1000);
  utimesSync(heartbeat, withinReviewWindow, withinReviewWindow);
  writeFileSync(join(skill, "bin", "report.mjs"), "// fixture\n");
  writeFileSync(join(bin, "node-ok"), "#!/bin/sh\nexit 0\n");
  writeFileSync(join(bin, "claude-probe"), "#!/bin/sh\nprintf called > \"$CLAUDE_MARKER\"\n");
  for (const name of ["node-ok", "claude-probe"]) chmodSync(join(bin, name), 0o755);

  const result = spawnSync("/bin/sh", [watchdog], {
    encoding: "utf8",
    env: {
      ...process.env,
      HOME: home,
      PATH: `${bin}:/usr/bin:/bin`,
      SLEEP_WELL_HOME: sw,
      SLEEP_WELL_SKILL: skill,
      SLEEP_WELL_NODE: "node-ok",
      SLEEP_WELL_CLAUDE: "claude-probe",
      SLEEP_WELL_AI_TIMEOUT: "1800",
      CLAUDE_MARKER: claudeMarker,
    },
  });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(existsSync(claudeMarker), false);
  rmSync(root, { recursive: true, force: true });
});

test("watchdog resumes only after the computed stale threshold", () => {
  function runScenario(ageSeconds, aiTimeout) {
    const root = mkdtempSync(join(tmpdir(), "sw-watchdog-resume-"));
    const home = join(root, "home");
    const sw = join(root, "state-home");
    const skill = join(root, "skill");
    const bin = join(root, "bin");
    const claudeMarker = join(root, "claude-called");
    mkdirSync(home, { recursive: true });
    mkdirSync(join(sw, "state"), { recursive: true });
    mkdirSync(join(skill, "bin"), { recursive: true });
    mkdirSync(bin, { recursive: true });
    writeFileSync(join(sw, "state", "current-run.json"), "{}\n");
    const heartbeat = join(sw, "state", "heartbeat");
    writeFileSync(heartbeat, "alive\n");
    const heartbeatTime = new Date(Date.now() - ageSeconds * 1000);
    utimesSync(heartbeat, heartbeatTime, heartbeatTime);
    writeFileSync(join(skill, "bin", "report.mjs"), "// fixture\n");
    writeFileSync(join(bin, "node-ok"), "#!/bin/sh\nexit 0\n");
    writeFileSync(join(bin, "claude-probe"), "#!/bin/sh\nprintf '%s' \"$*\" > \"$CLAUDE_MARKER\"\n");
    for (const name of ["node-ok", "claude-probe"]) chmodSync(join(bin, name), 0o755);
    const result = spawnSync("/bin/sh", [watchdog], {
      encoding: "utf8",
      env: {
        ...process.env,
        HOME: home,
        PATH: `${bin}:/usr/bin:/bin`,
        SLEEP_WELL_HOME: sw,
        SLEEP_WELL_SKILL: skill,
        SLEEP_WELL_NODE: "node-ok",
        SLEEP_WELL_CLAUDE: "claude-probe",
        SLEEP_WELL_AI_TIMEOUT: aiTimeout,
        CLAUDE_MARKER: claudeMarker,
      },
    });
    const called = existsSync(claudeMarker);
    const args = called ? readFileSync(claudeMarker, "utf8") : "";
    const logPath = join(sw, "logs", "watchdog.log");
    const log = existsSync(logPath) ? readFileSync(logPath, "utf8") : "";
    rmSync(root, { recursive: true, force: true });
    return { result, called, args, log };
  }

  const stale = runScenario(3600, "1800");
  assert.equal(stale.result.status, 0, stale.result.stderr);
  assert.equal(stale.called, true);
  assert.match(stale.args, /Resume the sleep-well night shift/);
  assert.match(stale.log, /heartbeat stale/);

  const extendedReview = runScenario(3600, "4000");
  assert.equal(extendedReview.result.status, 0, extendedReview.result.stderr);
  assert.equal(extendedReview.called, false);

  const leadingZero = runScenario(600, "0900");
  assert.equal(leadingZero.result.status, 0, leadingZero.result.stderr);
  assert.equal(leadingZero.called, false);
  assert.doesNotMatch(leadingZero.result.stderr, /value too great for base|integer expression expected/);
});
