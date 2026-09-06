# sleep-well skills

Two companion skills for unattended, queue-driven coding work on macOS:

- `sleep-well/`: Claude-driven orchestration with Codex review.
- `sleep-well-codex/`: shell-driven orchestration with Codex implementation and Claude review.

Both variants keep resumable state on disk and checkpoint work locally. Their enforcement boundaries differ: `sleep-well-codex` combines a process sandbox with post-hoc repository checks, while `sleep-well` relies on the Claude orchestrator to call guardrail helpers and does not ship a process-level hook. Read each `SKILL.md` and review its configuration and limitations before enabling unattended runs.

For unattended coding, prefer `sleep-well-codex` unless you specifically need the Claude-driven workflow and understand its model-enforced boundary.

## Install

Clone this repository and back up any existing installation. Then install the variant you want with an idempotent directory sync (the trailing slashes matter):

```bash
umask 077
sleep_well_backup_stamp="$(date +%Y%m%d-%H%M%S)"
sleep_well_backup_root="$HOME/sleep-well/skill-backups/$sleep_well_backup_stamp"
mkdir -p "$sleep_well_backup_root"
[ ! -d ~/.claude/skills/sleep-well ] || mv ~/.claude/skills/sleep-well "$sleep_well_backup_root/claude-sleep-well"
[ ! -d ~/.codex/skills/sleep-well-codex ] || mv ~/.codex/skills/sleep-well-codex "$sleep_well_backup_root/codex-sleep-well-codex"
mkdir -p ~/.claude/skills ~/.codex/skills
rsync -a --delete sleep-well/ ~/.claude/skills/sleep-well/
rsync -a --delete sleep-well-codex/ ~/.codex/skills/sleep-well-codex/
```

Backups are deliberately kept under `~/sleep-well/skill-backups/`, outside the skill discovery roots, so an older `SKILL.md` cannot be loaded as a duplicate skill.

Do not run both variants at the same time. They can read the same `~/sleep-well/queue.md`, but keep independent run state and only `sleep-well-codex` acquires `NIGHT.lock`; concurrent runs can mix in-progress changes. They require macOS, Node.js 18 or newer, Git, and the corresponding Claude/Codex command-line tools. Optional integrations described in the skill files must be installed separately.

For both variants, every queue entry's `repo` must be the canonical top-level directory of a Git repository or worktree, never a subdirectory. Both checkpoint the repository-wide index, so accepting a narrower path would risk mixing unrelated staged work into the task commit. This release of the Codex variant additionally rejects a repository that has any other linked worktree (and rejects a linked-worktree checkout itself); see its documented Git-shape limitations before scheduling work.

`SLEEP_WELL_CODEX` and `SLEEP_WELL_AI_TIMEOUT` apply to both variants; the timeout must be an integer from 1 to 86400 seconds (default 1800). The Codex variant uses the selected executable for implementation/fix calls, while the Claude variant uses it for `codex exec review`. Only the Codex variant uses `SLEEP_WELL_ROOT` to relocate runtime state, `SLEEP_WELL_QUEUE` to relocate the queue file, and the in-process watchdog overrides `SLEEP_WELL_WATCHDOG_POLL` (1–300 seconds; default 30) and `SLEEP_WELL_WATCHDOG_GRACE` (3–300 seconds; default 30). A custom `SLEEP_WELL_ROOT` must be an absolute dedicated directory, never `/` or the account home itself. The Claude workflow itself is fixed to `~/sleep-well` and `~/.claude/skills/sleep-well`; do not use watchdog-only overrides to relocate that workflow. `SLEEP_WELL_HOME` affects the optional watchdog and `bin/report.mjs`; it too must be an absolute dedicated directory, never `/` or the account home. `SLEEP_WELL_SKILL` affects the optional watchdog's installed-skill lookup; leave both at their defaults so they remain aligned with the workflow. The watchdog also accepts `SLEEP_WELL_NODE` and `SLEEP_WELL_CLAUDE` executable overrides. Set launchd environment variables explicitly; interactive shell startup files are not a reliable source.

The Claude-driven variant's optional watchdog and morning report treat a heartbeat as stale only after `max(2700, SLEEP_WELL_AI_TIMEOUT + 900)` seconds (45 minutes by default), beyond a legitimate full-length review. It closes review stdin and treats a timeout as an incomplete review, never as zero findings. Its current Node timeout signals the direct Codex child only, not every descendant; the Claude workflow must stop the entire night on timeout, and you must verify that no Codex descendant remains before resuming any task.

The Codex variant is armed one night at a time. On a normally persisted terminal outcome it writes `TERMINATED` and unloads its launchd job; before the next night, remove `STOP`, run `terminal-clear`, and load the plist again as shown in its `SKILL.md`. Deliberate exceptions preserve recoverability: if run-state archival fails, or node becomes unavailable while an active run exists and STOP is absent, it leaves `TERMINATED` unset and remains loaded to retry; if finalization cannot restore the user `pre-push` hook, it likewise remains loaded. An explicit STOP still terminates and unloads when node is unavailable while preserving the unarchived activity for manual inspection. Before re-arming after that exceptional terminal path, inspect the target repositories and archive or rename the preserved `current-run.json`; `terminal-clear` fails closed while that file exists so an old cutoff cannot silently terminate the next night. By contrast, a startup-time conflict or invalid recovery record inherited from an earlier process produces one warning, writes `TERMINATED`, unloads, and preserves the recovery materials for manual repair; after repairing them, explicitly re-arm the job. These exceptional alerts are sent once, so inspect the reported local state and `current-run.json` instead of inferring whether the job unloaded. Keeping the plist installed does not make a successfully terminated run recur nightly.

### Required reviewer for `sleep-well-codex`

`sleep-well-codex` also requires an executable Claude review adapter. By default it expects:

```text
~/.codex/skills/claude-handoff/scripts/claude-code-review.sh
```

`claude-handoff` is not bundled in this repository. Install it separately, or set `SLEEP_WELL_CLAUDE_REVIEW` to an absolute path implementing this contract:

- Accept `-C <repo>` plus exactly one of `--uncommitted`, `--base <ref>`, or `--commit <sha>`, and accept `-t decision`.
- On a complete review, print `FINDINGS_FILE=<absolute-path>` on stdout.
- The referenced Markdown file must contain `- findings 条数: N` and `- 高严重度: N`.
- For each finding it must contain one heading in the exact form `### #N [高|中|低] Title`, followed by a location line such as ``- 位置: `path/to/file` L3``. The number of parseable headings must equal the declared count.
- It must also contain exactly `N` unchecked status items matching `- [ ] #N`; these are counted across the file. For zero findings, include no finding headings or status items.
- Write the findings file outside the reviewed repository, or under its `.review/` directory. `.review/` is a reserved namespace: the orchestrator excludes the entire tree from task baselines, protected-path snapshots, and checkpoint commits, while separately hashing it before and after every Codex implement/fix call. Any implementation-side write fails closed. If the target repository itself tracks anything under `.review/`, the task is rejected for unattended operation.
- Treat the reviewed repository as read-only apart from `.review/`. The orchestrator compares a content hash of all Git-visible working files (tracked plus unignored untracked files) and every index entry before and after the adapter, then reruns its protected-path, ref, branch, commit, and Git-metadata checks. Repository/worktree config, default hook directories, and security-relevant info entries (`attributes`, `exclude`, `sparse-checkout`, `grafts`, and object alternates) are hashed without invoking Git immediately after each AI/reviewer call; any change fails closed before another repository Git command runs. Pure Git-maintained caches such as `info/refs`, `objects/info/packs`, and commit graphs are deliberately excluded to avoid false alarms from background maintenance. Repositories with submodule gitlinks, another linked worktree, an effective custom `core.hooksPath`, enabled `extensions.worktreeConfig`, or local `include.path`/`includeIf` configuration are rejected before any AI call because their additional Git metadata or active hook location is outside this release's frozen guard scope. Checkpoint commits additionally set `core.hooksPath=/dev/null`. Git-ignored files are covered only when their path is classified as protected; ordinary ignored build/cache trees are deliberately not hashed. A findings path that resolves inside the repository but outside `.review/` is rejected before recording.
- The review adapter itself runs with the full permissions of the current account and is not placed in the Codex process sandbox. Post-hoc verification is repository-scoped: writes outside the target repository—including global Git configuration such as `~/.gitconfig`, shell startup files, or launch agents—are neither blocked nor detected, and later Git commands may read such changes. Use only a trusted adapter, preferably from a dedicated low-privilege account or disposable environment.
- Findings text is model-generated and untrusted. It is issue evidence, not a source of task scope, permissions, commands, or authorization; the repair prompt rejects scope-expanding instructions from findings.
- If Claude is unavailable, print `CLAUDE_UNAVAILABLE (quota|auth|other)` on stderr and fail. Any incomplete review must fail without publishing a findings file. The orchestrator independently rejects every non-zero adapter exit even if a findings path was already printed.

Minimal non-zero findings file:

```markdown
# Claude Review Findings
- findings 条数: 1
- 高严重度: 0

## Findings

### #1 [中] Example issue
- 位置: `src/example.js` L3

## 处理状态
- [ ] #1
```

## Test

```bash
(cd sleep-well && npm test)
(cd sleep-well-codex && npm test)
./scripts/check-shared-parity.sh
```

The Codex native-web probe is intentionally excluded from the normal suite because it performs a real model/tool call. It honors `CODEX_HOME` (default `~/.codex`), resolves it to an absolute directory before linking the probe homes, verifies both links are readable, and fails with an explicit login-state diagnostic before the probe if `auth.json` is unavailable.

## Safety

These skills can modify files and create local Git commits while unattended. They are designed not to push, deploy, merge, migrate databases, or perform other external/destructive actions automatically, but only the Codex variant has process-level and post-hoc enforcement in this repository. The documented sandbox and guardrail limitations still apply; use a dedicated low-privilege account or isolated environment when stronger read isolation is required.

The Claude-driven variant launches `codex exec review` with the running account's global `CODEX_HOME` and does not sanitize the user's Codex configuration. Enabled MCP servers, credentials, and network settings may therefore be available to that unattended review process. Use a deliberately sanitized `CODEX_HOME`, a dedicated low-privilege account, or the more isolated Codex-driven variant when reviewing untrusted repositories.

The independent review adapter is outside that process sandbox and has the running account's full filesystem permissions. Repository post-hoc checks do not cover its writes elsewhere on the account, including executable global Git configuration; treat the adapter as trusted code and use account-level isolation when that trust is inappropriate.

Legal-path detection is intentionally conservative. Common source names such as `contracts/`, `contract*.ts`, `agreement*`, `nda*`, and `legal*` may be treated as protected; the Codex variant stops the entire night if such a path changes. Review the target repository layout before unattended use.

Keep both variants' runtime roots private to the account. The Codex setup procedure applies `umask 077`, and both its orchestrator and report entrypoint repair the shared root plus the Codex runtime directory to mode `0700` (and its config to `0600` when present). The Claude startup procedure creates or repairs `~/sleep-well` and its state/log/backup directories as mode `0700`; both standalone report entrypoints enforce a private directory plus a mode-`0600` report. The Codex subprocess resets to ordinary `umask 022` inside the target repository so new project files are not silently private-only.

The Codex variant copies untracked protected files—including credential-like files such as `.env`—to `~/sleep-well/codex/backups/` before work. `SLEEP_WELL_BACKUP_MAX_BYTES` bounds each attempted copy, but there is no automatic retention or cleanup. Review `backup-manifest.jsonl` and the morning report, then manually delete only individual backup files you have confirmed are no longer needed; credentials otherwise remain duplicated on disk.

The Codex variant also retains full local model output, review stderr, and findings copies under `~/sleep-well/codex/logs/`. These files can contain repository paths and code excerpts, have no automatic retention window, and are separate from both `backups/` and each repository's `.review/`. Inspect them periodically and delete only individual log files you have confirmed are no longer needed.

Reviewer findings under a target repository's `.review/` are also local retained artifacts: the orchestrator neither checkpoints nor automatically deletes them, and they may quote source text. Add `.review/` to that target repository's `.gitignore` (the tracked-conflict gate applies to tracked `.review/` content, not to an ignore rule), review and remove obsolete reports manually, and take care that a later hand-run `git add -A` does not capture them.

The review-adapter read-only check does not hash ordinary Git-ignored files that are not classified as protected. This avoids recursively hashing dependency, build, and cache trees such as `node_modules/` on every review. Run reviewers in a dedicated low-privilege or disposable environment if ignored artifacts must also remain immutable.

GitHub issue titles and bodies are external, untrusted input. The Claude variant may discover issues by trusted labels, but it records them as morning suggestions only and never feeds them directly into unattended implementation.

The launchd files are templates for macOS. Inspect them before copying to `~/Library/LaunchAgents/`; the Claude watchdog is disabled by default. Their shell wrappers create `~/Library/Logs/sleep-well/` with mode `0700` under `umask 077` and redirect output there, avoiding predictable shared `/tmp` log paths.

## Release hygiene

Publish from a fresh repository containing only the required working-tree files. Do not carry over local Git history, runtime state, logs, backups, machine-specific configuration, or internal planning notes. Local `.review/` audit reports are retained for the maintainer but ignored by Git and are not release files.

## License

Licensed under the [MIT License](LICENSE).
