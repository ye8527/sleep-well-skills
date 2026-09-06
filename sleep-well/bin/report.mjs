#!/usr/bin/env node
// Regenerate ~/sleep-well/morning-report.md from disk. Works with NO Claude session.
import { buildReport } from "../lib/report.mjs";
import { loadConfig } from "../lib/config.mjs";
import { chmodSync, writeFileSync, mkdirSync, realpathSync } from "node:fs";
import { isAbsolute, join } from "node:path";
process.umask(0o077);
const configuredHome = process.env.SLEEP_WELL_HOME || join(process.env.HOME, "sleep-well");
if (!isAbsolute(configuredHome)) throw new Error("SLEEP_WELL_HOME must be an absolute path");
mkdirSync(configuredHome, { recursive: true, mode: 0o700 });
const home = realpathSync(configuredHome);
const accountHome = realpathSync(process.env.HOME);
if (home === "/" || home === accountHome) throw new Error("SLEEP_WELL_HOME must not be / or the account HOME");
chmodSync(home, 0o700);
// A malformed config must not suppress the emergency morning report. Fall
// back to the historical colocated directory, but honor a valid custom
// backup_dir so the report and backup writer read the same manifest.
let backupDir = join(home, "backups");
try {
  const configuredBackupDir = loadConfig(join(home, "config.json")).backup_dir;
  if (typeof configuredBackupDir !== "string" || configuredBackupDir.length === 0) {
    throw new TypeError("backup_dir must be a non-empty string");
  }
  backupDir = configuredBackupDir;
}
catch (err) { process.stderr.write(`config unavailable for report; using default backup path: ${err.message}\n`); }
const md = buildReport({ home, nowEpoch: Math.floor(Date.now() / 1000), backupDir });
const out = join(home, "morning-report.md");
writeFileSync(out, md, { mode: 0o600 });
chmodSync(out, 0o600);
console.log(out);
