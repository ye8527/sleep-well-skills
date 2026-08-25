---
name: sleep-well
description: Overnight night-shift orchestrator. Launch via `/loop sleep-well`. Works ~/sleep-well/queue.md task-by-task — implement, codex exec review, fix, re-review until zero findings (capped) — with code-enforced guardrails, full disk-state resume, and one-way phone push. Triggers on sleep-well, night shift, 夜班, overnight tasks.
---

# sleep-well — overnight night-shift orchestrator

## Launch & environment
- Run ONLY as `/loop sleep-well` in the Claude desktop client (no terminal, no bash wrapper).
- Pre-reqs (Phase 0): `codex` resolves on `PATH`; macOS is configured not to sleep on power (screen lock is fine); claude-quotas is available.
- All deterministic and safety logic lives in `~/.claude/skills/sleep-well/lib/*.mjs`. CALL those modules via Bash (a small `node --input-type=module -e '…'` runner) — never re-implement their judgement in prose.

## Startup self-check (run on EVERY loop entry)
1. Ensure `~/sleep-well/{state,logs,backups}` exist.
2. Load the ACTIVE run from `~/sleep-well/state/current-run.json` via `loadState` (a FIXED filename, so a post-midnight wakeup resumes the SAME run — never a date-stamped new file). If absent, build a NEW run: `parseQueue(~/sleep-well/queue.md)` + `newRunState`; set `state.startedAt` = now (epoch seconds) and `state.cutoffEpoch` = the epoch of the NEXT `morning_hour` at/after now (compute this from the wall clock — e.g. a 23:00 start with morning_hour 07:00 → tomorrow 07:00); `saveState` to `current-run.json`.
3. **Cutoff check:** if `~/sleep-well/STOP` exists OR `pastCutoff(now, state.cutoffEpoch)` → generate `~/sleep-well/morning-report.md` via `node ~/.claude/skills/sleep-well/bin/report.mjs` (it compiles the report from disk — the same generator the watchdog uses, so the report exists even with no live session); archive `current-run.json` → `state/run-<start-date>.json`, and STOP the loop (do NOT re-arm ScheduleWakeup).
4. `git worktree prune` in each repo referenced by `state.openWorktrees` — this is SAFE (it only removes admin metadata for worktrees whose directory is already gone; it does NOT delete branches). NEVER delete a branch listed in `openWorktrees`; those hold checkpoints. Only drop an `openWorktrees` entry once its work has been reviewed/finalized.

## Per-task loop
Take `nextTask(state)` (resumes an in-flight task before starting a new pending one). If null → check `hasDeferredReviews(state)` first: if true → `planRelay` + `ScheduleWakeup` to the Codex `nextUsefulResetEpoch`; on wake, clear `reviewDeferred` on those tasks and resume their reviews. Only when there are NO deferred reviews does null mean idle → run Idle discovery (see below), else write the morning-report and `ScheduleWakeup` until `state.cutoffEpoch`. Otherwise, for the task:

1. **Implement (resume-aware).** If `task.status === "pending"` → `advance(...,"implementing")`; `saveState`. If resuming a task already in `reviewing` → skip straight to step 2 (its uncommitted diff is on disk). If resuming `implementing` or `fixing` → keep that status (do NOT advance) and continue the work. Then implement/continue the task INLINE (route via `routeTask` — see "Team-mode delegation" below) inside `task.repo`.
   - Before running ANY shell command, pass it through `classifyCommand`. If `allowed` is false: STOP this task → `advance(...,"needs_human")`, log why, move to the next task.
   - Before editing a NON-git-tracked file: if `isProtectedPath(path)` → skip + needs_human; otherwise `backupFile(...)` FIRST. Git-tracked files are covered by the checkpoint commit below.
2. If the task is not already `reviewing`, `advance(...,"reviewing")`; `saveState`. **Do NOT commit yet** — the review must see the UNCOMMITTED diff. (A checkpoint commit here would leave nothing for `--uncommitted` to review — verified in the Phase-1 dry-run.) Run `runReview({ repo: task.repo, scope: "uncommitted" })` from `lib/codexReview.mjs`.
   - **codex review output is PROSE** — the review is in the returned `agentText` (there is no reliable structured `findings[]`). YOU read `agentText`, extract each distinct issue, and for each call `appendFinding(process.env.HOME + "/sleep-well/findings.jsonl", { repo, file, line, issue, severity, taskId: id })` with severity `auto` (clearly self-fixable) or `needs-human` (judgement/ambiguous). The round's finding COUNT = how many issues you extracted (0 when the prose says there are none).
3. Push that count onto `task.findingsHistory`; call `decideNext(task.findingsHistory, task.reviewRotations, cfg)`:
   - `done` → **NOW checkpoint** the clean result: `git add -A && git commit -m "sleep-well: <id> done"` (NEVER push, NEVER merge); `advance(...,"done")`; PushNotification "✓ <title> done"; next task.
   - `continue` → `advance(...,"fixing")`; fix only the `auto` findings, leaving the diff **UNCOMMITTED**; go back to step 2 (which advances fixing→reviewing and re-reviews).
   - `rotate` → summarize the review so far into `logs/<id>.md`; `task.reviewRotations++`; **reset `task.findingsHistory = []` (start a fresh segment so rounds count from this rotation)**; re-run `runReview` as a FRESH review on the same uncommitted diff (no carried-over context); go back to step 2.
   - `stop` → **commit the WIP so it is not lost**: `git add -A && git commit -m "sleep-well: <id> WIP needs-human"`; `advance(...,"needs_human")`; record the remaining findings; PushNotification if a decision is needed; next task.
4. `saveState` after EVERY transition — a wakeup starts a fresh session with no memory, so disk state is the only continuity. Uncommitted changes also survive a crash; on resume, re-review the uncommitted diff. NEVER run `git reset --hard` / `git checkout -- .` / `git clean` mid-task — they would discard the un-checkpointed work.

## Team-mode delegation (Phase 3)
In the per-task loop's implement step, first call `routeTask(task, cfg)`:
- `"inline"` → implement inline as in Phase 1.
- `"team"` → delegate, but ONLY if `canDelegate(state.teamDelegationsTonight, cfg)` is true AND the latest `claudeDecision` is `proceed` (a team run burns ~15-30 Claude agents — never start one in a depleted window). Otherwise fall back to inline.

To delegate:
1. Detect isolation: `git rev-parse --is-inside-work-tree` in `task.repo` → `isolation:"worktree"` if a git repo, else `"filelock"`. **Capture `task.repo`'s current HEAD sha NOW (before Stage 1)** — `git -C <task.repo> rev-parse HEAD` — and store as `preDelegationSha`. This is the review base used in step 5.
2. **Stage 1 — plan:** resolve `process.env.HOME + "/.claude/workflows/team-plan.js"` and invoke the **Workflow tool** with that `scriptPath` and `args: { task: task.prompt, budget: "normal", mode: <task.type>, isolation, allSonnet: false }`.
3. **Gate in CODE, not vibes:** call `teamGate(planResult, cfg)`. If `proceed` is false → skip the task to `needs_human` with the returned reason. NEVER auto-run a plan that isn't approved + auto-proceed-eligible + confident + low-risk + reversible.
4. **Stage 2 — exec:** resolve `process.env.HOME + "/.claude/workflows/team-exec.js"` and invoke the **Workflow tool** with that `scriptPath` and `args: { plan: <approved plan object>, isolation, allSonnet: false }`. Then `state.teamDelegationsTonight++`; append the returned branches to `state.openWorktrees`; `saveState`.
5. **NEVER merge** — leave the branches as local checkpoints (do NOT call finishing-a-development-branch). **Review the team output per branch — NOT via `--uncommitted` on `task.repo`, which is empty in worktree mode.** For each returned branch, run `runReview({ repo: <that branch's worktree dir>, scope: "base", base: <the pre-delegation HEAD sha of task.repo> })` to review the branch's diff against the base, then feed findings through the normal fix loop. (In `filelock` mode the changes ARE in `task.repo`'s working tree, so `runReview({ repo: task.repo, scope: "uncommitted" })` there is correct.) If a branch's diff cannot be reviewed, mark the task `needs_human` — NEVER silently skip review. On `status:"partial"`, surface `stillFailing` task ids.

**Degrade upgrade:** the Phase-2 Codex→Claude `degrade` now means a fresh agent-team review in **audit mode** (`mode:"audit"`, implementer-independent adversarial review) rather than a single fresh-session review.

## Quota orchestration (Phase 2)
Three windows: Claude 5h + 7-day, Codex 5h + weekly. Check at every task boundary and before each review.

**Claude:** call the claude-quotas `check_quota` tool; read its util% + reset for 5h and 7-day; call `claudeDecision({fiveHourUtil, fiveHourResetIso, sevenDayUtil, sevenDayResetIso})`:
- `proceed` → continue. `alert` → finish the current minimal unit, then re-check. `wrap-and-sleep` → checkpoint + `saveState`, then `planRelay(now, resetEpoch)` and chain `ScheduleWakeup` hops until the reset; resume from disk on wake.

**Codex:** detect 5h/weekly exhaustion from the last `codex` rate-limit error (or `~/.codex/state_5.sqlite` snapshot, best-effort). Call `codexDecision({fiveHourExhausted, weeklyExhausted, nextUsefulResetEpoch}, nowEpoch, cfg.codex_degrade_after_hours)`:
- `use-codex` → normal `runReview`. `defer` → set `task.reviewDeferred = true` + `saveState` so `nextTask` moves on to Claude-only pending work; when Codex's 5h resets, clear `reviewDeferred` on deferred tasks and resume their review. Do Claude-only queue work (implement next tasks) and batch the pending reviews; `planRelay` to the codex reset, resume and review then. `degrade` → review with **Claude in a FRESH session** (Phase 2 interim — a separate sub-agent reads the diff and lists issues, kept independent from the implementer; **Phase 3 upgrades this to agent-team adversarial review**). When `codex_recheck_after_weekly_reset` is true, re-review degrade-period changes with Codex once weekly resets.

**Interleave rule:** only one direction is exploitable — when Codex is out but Claude has budget, pull Claude-only work forward and defer reviews. When Claude is out, the whole session sleeps (Codex can't self-drive). Respect a per-night budget ceiling.

## Idle discovery (Phase 4)
When `nextPending(state)` is null AND `pastCutoff(now, state.cutoffEpoch)` is false, run ONE bounded discovery cycle (at most `discovery_k_per_cycle` new tasks), tiers in priority order, stopping as soon as enough safe tasks are found:

- **Tier 1 (auto)** — leftover auto-fixable findings: read `findings.jsonl`, take entries with severity `auto` not yet resolved. (NEEDS_HUMAN findings are surfaced in the morning report only, never auto-picked.)
- **Tier 2 (auto)** — in-repo work in the pinned `discovery_repo` ONLY: `grep -rEIn 'TODO|FIXME|XXX|HACK' --include='*.js' --include='*.ts' --include='*.tsx' --include='*.jsx' --include='*.py' --exclude-dir=node_modules --exclude-dir=dist --exclude-dir=build --exclude-dir=.next --exclude-dir=vendor --exclude-dir=.venv <repo>` → `parseTodos`; plus `gh issue list -R <slug> --state open --label good-first-issue,chore,docs,test --json number,title,body`. (Use SEPARATE quoted `--include` flags — `--include=*.{js,ts}` is brace+glob-expanded by zsh and the command FAILS; verified in the overnight dry-run.) Per-repo cap.
- **Tier 3 (auto + MANDATORY backup)** — research-proposal/plan docs: extract explicit action items; you MAY auto-edit (per the user's decision) but ONLY after `backupFile(...)` of the original (non-git docs) — see Guardrails §backup. HARD-EXCLUDE contract/legal docs (`isProtectedPath`).
- **Tier 4 (propose-only)** — calendar via the `.ics` watched folder: if a `*.ics` exists in `~/sleep-well/calendar/`, parse it with `lib/ics.mjs` `parseIcs` → `deriveCalendarTasks` (artifact-implying events only). These are ALWAYS propose-only (morning suggestions, never auto-run). NOTE: the direct Calendar.app path via computer-use is BLOCKED on this machine (dual-display coordinate bug) — use the .ics export instead.

For every candidate: `tierMode(tier, cfg)` must be `auto` to act (else log a morning suggestion only); normalize to the queue task schema; verify the task TYPE is in `ALLOWED_TASK_TYPES`; dedupe via `loadTried`/`markTried` (`tried.log`); append to the queue/state; write one audit line (what / tier / why-safe / evidence) to the dev log. Cap per cycle = `discovery_k_per_cycle`; per-repo cap applies.

**Never lower the safety bar to manufacture work.** If a full cycle yields ZERO safe candidates (or only NEEDS_HUMAN/ambiguous items), generate `morning-report.md` via `node ~/.claude/skills/sleep-well/bin/report.mjs` (it compiles the report from disk — the same generator the watchdog uses, so the report exists even with no live session) and go to GRACEFUL IDLE: `planRelay` + `ScheduleWakeup` until `state.cutoffEpoch`.

## Resilience: surviving API overload / outages (Phase 6)
The orchestrator IS a Claude session, so a full Anthropic outage disables sleep-well itself — a monitor cannot watch its own death. Two facts make this survivable: state is saved to disk after every transition and uncommitted work persists, so ANY outage loses TIME, never WORK; and reopening `/loop sleep-well` resumes from exactly where it died.

**Heartbeat:** at the top of EVERY loop iteration, write the current ISO timestamp to `process.env.HOME + "/sleep-well/state/heartbeat"`. This lets the morning report — and any optional out-of-band watchdog — see when progress last happened.

**Transient congestion** ("サービスが混雑しています" / overload / 529 / 5xx / transient network error — NOT a quota rate-limit, which is the Quota section): do NOT abandon the task.
1. The in-flight work is already uncommitted on disk; `saveState`.
2. Call `nextBackoff(attempt)` from `lib/backoff.mjs`. If `giveUp`, go to step 4. Otherwise relay-`ScheduleWakeup` for `delaySeconds` (use `planRelay` if it ever exceeds 3600) and RETRY the same failed step on wake, with `attempt` incremented.
3. On any successful call, reset `attempt = 0`.
4. **Give up gracefully** once the backoff schedule is exhausted (~3 h of retries): `saveState`; generate `morning-report.md` via `node ~/.claude/skills/sleep-well/bin/report.mjs` (it compiles the report from disk — the same generator the watchdog uses, so the report exists even with no live session); PushNotification "sleep-well paused — Anthropic/Codex service appears down; reopen /loop sleep-well to resume", and STOP the loop. Do NOT keep spinning against a dead API and burning quota.

**Hard multi-hour outage:** the session may be unable to run even the backoff turn — then nothing in-band can help, but disk state guarantees a clean manual resume (reopen `/loop sleep-well` when service returns). Unattended AUTO-restart through a hard outage requires an OUT-OF-BAND watchdog (a macOS launchd agent that reads the heartbeat and relaunches), which can only relaunch a headless `claude -p` session — trading the desktop-only preference for auto-restart. It is optional and OFF by default; see `docs/resilience-watchdog.md`.

**Codex outage** is already handled by the Quota section's degrade chain (Codex down → Claude review).

## Guardrails (NON-NEGOTIABLE)
- Never push, deploy, migrate, force-push, mass-delete, exfiltrate (scp / curl|sh), or edit protected docs. `classifyCommand` and `isProtectedPath` are the gate; when unsure, treat it as denied.
- Local git checkpoints only — never merge, never push.
- A stuck task is skipped to `needs_human`; never hang the whole night on one task.

## Notifications & remote (Phase 5)
- **One-way push:** when `push_enabled`, send PushNotification (status: proactive) on — each task done, anything needing your decision, and one morning summary. Keep each under 200 characters. (Reaches your phone when Claude Code Remote Control is paired.)
- **Two-way (optional):** to steer mid-run from your phone, open this `/loop sleep-well` session in the Claude Code mobile/web app and type — no extra setup in this skill.

## Calling the lib modules from Bash
**Always pass ABSOLUTE paths to lib functions and `fs` — Node does NOT expand `~`. Build paths from `process.env.HOME` (e.g. `process.env.HOME + '/sleep-well/findings.jsonl'`).**

Pattern (parse the queue):
```
node --input-type=module -e 'import {readFileSync} from "node:fs"; import {pathToFileURL} from "node:url"; const home=process.env.HOME; const {parseQueue}=await import(pathToFileURL(home+"/.claude/skills/sleep-well/lib/queue.mjs").href); process.stdout.write(JSON.stringify(parseQueue(readFileSync(home+"/sleep-well/queue.md","utf8"))))'
```
Use the same `node --input-type=module -e` pattern (or write a tiny runner script under `lib/`) to call state / guardrails / backup / reviewLoop / findings / codexReview.

## Learned
- (2026-07-10) 审查外部会话的产出时，基点 SHA 必须在其开工前/收工瞬间显式捕获——会话收尾常把 main 快进到自己的 HEAD，`--base main` 会得到空 diff（当晚实测浪费一轮 codex）。
- (2026-07-10) 监督模式可行架构已验证并记入 memory `session-supervision-pattern`（send_message 必弹确认、无法新建桌面会话→子代理接力）。
