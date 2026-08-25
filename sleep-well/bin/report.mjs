#!/usr/bin/env node
// Regenerate ~/sleep-well/morning-report.md from disk. Works with NO Claude session.
import { buildReport } from "../lib/report.mjs";
import { writeFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";
const home = process.env.SLEEP_WELL_HOME || join(process.env.HOME, "sleep-well");
mkdirSync(home, { recursive: true });
const md = buildReport({ home, nowEpoch: Math.floor(Date.now() / 1000) });
const out = join(home, "morning-report.md");
writeFileSync(out, md);
console.log(out);
